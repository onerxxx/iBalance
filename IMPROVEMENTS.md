# iBalance 改进优化建议

> 基于 2026-08-15 对全项目的完整走查（`swift/` 下 9 个源文件共约 5700 行 + build.sh/Info.plist/git 状态；忽略 `backups/`）。
> 上一轮（2026-08-11）的建议大部分已落地，完成情况见文末附录。
> 优先级标注：🔴 高（建议尽快做）/ 🟡 中（有价值，择机做）/ 🟢 低（锦上添花）

---

## 一、安全与凭据 🔴

### 1. `swift/config.json` 模板已含真实凭据，且是 git 跟踪文件 🔴

`.gitignore` 注释还写着「swift/config.json 是空 Key 模板，需要入库」，但实际上该文件现在存有**真实 DeepSeek API Key 和两个 WorkBuddy 账号的完整 token/refresh_token**。它同时被 build.sh 拷进 .app 的 Resources 作为内置 fallback——本地构建出的 .app 内部就带着这些凭据，一旦 `git commit -a` 就会永久进入 git 历史。

建议：

- 立刻把 `swift/config.json` 恢复为空凭据模板（真实值只留根目录 `config.json`，已在 .gitignore）；
- 更新 `.gitignore` 注释；若模板确需入库，打 zip 前的泄漏校验（PACKAGING.md）应同时覆盖它。

### 2. 凭据明文落盘且文件权限 644 🔴

`Config.swift:179-187` 保存 config.json、`WorkBuddy.swift:297-299/324` 写 WorkBuddy 认证文件，均为默认权限，同机任何进程可读。涉及 4 类凭据：DeepSeek Key、千问 ticket、WorkBuddy token/refreshToken、TRAE 加密 authInfo。

建议（与旧 #12 相同，仍未做）：

- token 类迁移 Keychain（`SecItemAdd` / `kSecClassGenericPassword`），config.json 只留非敏感设置；
- 迁移前至少 `FileManager.setAttributes([.posixPermissions: 0o600])` 收紧权限。

### 3. `/tmp` 日志无条件 dump 签到接口完整响应体 🔴

`Trae.swift:405-412 / 448-456`：签到成功与失败都把**完整响应体**写进 `/tmp/iBalance_trae_checkin.log`（默认 644，任何本地进程可读，且无轮转、永不清理）。`Trae.swift:318` 与 `WorkBuddy.swift:156` 还各有一份实现写同一个 `/tmp/iBalance_switch.log`（记录 uid/username，同样无锁无上限；`/tmp` 固定文件名在多用户机器上有预创建/symlink 风险）。

建议：

- 日志加 debug 开关（默认关）、落盘前脱敏、迁到 `~/Library/Logs/iBalance/` 并加轮转；
- 两份 appendLog 实现合并为单一日志器。

---

## 二、健壮性

### 4. 刷新失败完全静默，「更新于」时间照常刷新 🔴

`main.swift:1014-1026`（WorkBuddy）、`1056`（TRAE）、`1096-1104`（千问）：fetch 失败无 else 分支，面板继续显示旧值，而底部「更新于」时间正常更新（`main.swift:998`）——用户无法区分「新数据」和「10 分钟前的旧数据」，直接损害余额工具的可信度。

建议：快照增加 per-服务的 error/stale 标记，卡片副标题显示「刷新失败 · HH:mm」；`notifyError`（`main.swift:1010`）从 DeepSeek 专用扩展为通用错误通道。

### 5. performRefresh 无去重、无取消 🔴

`main.swift:696-699`：定时器、打开面板（489）、网络恢复（309）、手动刷新可并发触发多个 `performRefresh` Task，互不去重也不取消。慢的旧响应会覆盖新缓存，且四服务 `async let`（989-992）不响应取消，重复请求还可能触发签到服务同款风控。

建议：保存 `refreshTask`，新刷新先 `cancel()` 旧的 + `isRefreshing` 守卫。

### 6. NetworkMonitor 回调不在主线程，直接改 @MainActor 状态 🟡

`main.swift:306-311`：`onChange` 由 NWPathMonitor 的后台队列触发，闭包内直接写 `self.isOffline` 并调 `onRefresh()`/`updateTitle()`（触 UI）。建议包一层 `Task { @MainActor in ... }`。

### 7. 网络层把所有错误压成 `(nil, 0)`，401 与超时不可区分 🔴

`Network.swift:24`：超时/DNS/连接拒绝/任务取消全部变成 status 0。后果：

- `Trae.swift:94` / `WorkBuddy.swift:362` `guard status == 200` 后返回 nil——多号账号 **token 过期（401）** 与网络抖动在 UI 上都是同一种「获取失败」，无法引导用户重新采集；
- `Network.swift:40` 重试逻辑对「离线」「已取消」也照样 backoff 重试。

建议：`HTTP.request` 返回 `Result<Data, NetworkError>`（`.timeout / .offline / .http(Int, Data) / .cancelled`），401 单独处理并触发「请重新采集账号」提示；顺带统一默认 timeout 常量（当前 10/15 散传）。

### 8. 进程切换（TRAE/WorkBuddy 共三处缺陷 + 误杀风险）🔴

`Trae.swift:142-160` 与 `WorkBuddy.swift:92-110` 的 `switchAccount` 同构，共同问题：

1. **同步阻塞**：内部 `waitPidsExit` 用 `Thread.sleep` 最多 1.8s+（`Trae.swift:257`），在主线程调用会冻结 UI；
2. **失败无回滚**：写配置文件失败（`Trae.swift:151-154`）时进程已被杀但不重启，用户停留在「应用被杀未恢复」状态；`restartTrae/restartWorkBuddy`（`Trae.swift:304-309`）`try? task.run()` 吞错，open 失败无反馈；
3. **双实例风险**：`open -n` 强制新实例，若 SIGKILL 后进程未死透（`waitPidsExit` 结果被 `_ =` 丢弃）会出现双实例竞争写配置文件。

另有误杀风险：`Trae.swift:205` 按命令行 `contains("trae")` 匹配进程，任何命令行含 "trae" 的 .app 主进程都可能被误杀；`isPidRunning`（`Trae.swift:262-277`）每次 fork 一个 `/bin/ps`，轮询期间产生大量子进程，且 PID 复用窗口内 `kill` 可能误伤无关进程。

建议：抽公共 async `AppSwitcher`（见 #15），用 `NSWorkspace.runningApplications` 按 bundle id 精确匹配、`kill(pid, 0)` 判活、等待彻底退出再启动、失败回滚并通知。

### 9. Config 解析失败静默回退默认值，随后 save 覆盖用户全部配置 🔴

`Config.swift:170-173`：用户手改 config.json 出语法错误时静默回退默认值，下一次 `save` 就用默认值把用户配置整个覆盖。`Config.swift:185-187` 保存失败（磁盘满 / app 放 /Applications 时 bundle 同目录无写权限）也无任何反馈。

建议：解析失败时保留原文件改名 `.bak` 并通过 UI 告知；save 返回结果并在失败时提示；长期看配置应迁到 `~/Library/Application Support/iBalance/`（`.app` 旁放可编辑配置不符合 macOS 规范，app 移动/分发后配置「丢失」）。

### 10. 零散健壮性问题 🟡

- `main.swift:2031-2035`：签到历史 decode 失败返回 `[]`，`appendCheckinHistory` 随即用空数组覆盖旧 key——解码失败即历史全清（虽然该历史目前只写不读，见 #17）；
- `WorkBuddy.swift:511-518`：refresh 接口的 `expiresAt` 未做毫秒/秒归一化（authInfo 与 collectAccount 路径都归一化了），若服务返回毫秒会被当作秒，token 过期后永远不再刷新；
- `WorkBuddy.swift:571-593`：OAuth 轮询最长 600s，`try? await Task.sleep` 吞掉 `CancellationError` 后继续发请求（仅靠下一轮 `isCancelled()` 退出）；
- `main.swift:315-319/737-741/1924-1928`：`Timer.scheduledTimer(target:)` 强引用 target 且 terminate 时不 invalidate；建议 block-based timer（App Nap 漂移问题旧 #11 一并解决，或监听 `didWakeNotification` 唤醒后补刷新）；
- `main.swift:1876`：`openApplication` completion `{ _, _ in }` 启动失败无提示；各 `UNUserNotificationCenter.add` 回调同样全静默；
- `main.swift:1496-1500`：手动签到 Task 不可取消，若挂起则 `manualCheckinInProgress` 永久为 true，签到按钮从此失灵且无提示。

---

## 三、代码质量

### 11. Trae.swift ↔ WorkBuddy.swift 约 220 行逐字重复 🟡

杀进程/等待退出/重启/日志整条链路双份实现（`switchAccount`、`ms()`、`killXxxProcess`、`collectXxxMainPids`、`isHelperCommandLine`、`sendSIGTERM/KILL`、`waitPidsExit`、`appendSwitchLog`、`restartXxx`），连「readDataToEndOfFile 死锁」注释都只在 WorkBuddy 一侧有。签到部分也重复：`fetchCheckinStatus` 的「尝试 5 种字段名」解析、`claimCheckin` 的 headers/body/解析模式。

建议：抽 `AppSwitcher`（进程管理）+ `firstInt(in:keys:)` / `postJSON(url:headers:)` 工具，与 #8 一次修完；headers 构造（Trae 3 处、WB 4 处重复）各收口成 `traeHeaders(token:)` / `wbHeaders(token:uid:)`。

### 12. Panel.swift 中 WB/TRAE 卡片约 200 行复制粘贴 🟡

`rebuildWbCards`（1042-1114）与 `rebuildTraeCards`（1140-1206）、`applyWbCardData`（1117-1134）与 `applyTraeCardData`（1209-1227）近乎逐行复制；`WBAccountSnapshot` 与 `TraeAccountSnapshot`（53-78）字段完全同构（注释自认「结构对齐」）。新功能（加载态、失败标记）目前每处都要改两遍。

建议：合并为单一 `AccountSnapshot` + 泛型 `rebuildAccountCards`。main.swift 侧同理：`switchTraeAccount`/`switchWbAccount`（1835-1900）的「后台切换→syncPanel→延时关闭」编排、streak 补全逻辑（3 处重复的 `continuousDays > 0 ? ... : nextStreak 推算`）可各抽 helper。

### 13. 性能：Formatter 与图标每次新建 🟡

`fmtAmountCommas`（`main.swift:389-398`）每次调用 new 一个 `NumberFormatter`；`todayString/nowTimeString/latestCheckinTime/nextStreak`（1964-2005）每次 new `DateFormatter`——这条链路每次刷新触发多次，Formatter 创建是 Cocoa 出了名的贵。`refreshStatusItemAppearance`（379-386）每次 `NSImage(contentsOf:)` 读盘，而它被 7 种焦点通知高频触发。

建议：全部改 `static let` 缓存；状态栏图标加载一次存属性。

### 14. main.swift（2060 行）/ Panel.swift（1906 行）继续拆分 🟡

服务层已拆干净，但入口和面板两个文件又在膨胀。按 MARK 拆（build.sh 自动收集 *.swift，零成本）：

- `AppAccent.swift` ← NSColor swizzle 扩展（main.swift:10-117，自包含 107 行）
- `CheckinManager.swift` ← 签到域：wb/traeAutoCheckinIfNeeded、traeCheckinStatusFill、签到历史、streak 工具（约 500 行，最大一块）
- `AccountSwitcher.swift` ← TRAE 采集/切换 + WB 切换 + 切换日志（1777-1917）
- `Dialogs.swift` ← 全部 NSAlert 弹窗（约 300 行）
- `Controls.swift` ← Panel.swift:142-824 的自绘控件（约 680 行，占面板文件一半且自包含）

### 15. 硬编码与常量收口 🟢

- URL / bundle id 散落：`platform.deepseek.com/usage`（448）、千问 billing（466）、`cn.trae.solo.app`（451）、`com.workbuddy.workbuddy`（455）等 → 收进 `enum Links` / 配置；
- UserDefaults key 拼接约 20 处（`"trae_checkin_date_\(uid)"` 等）→ `enum UDKey` 收口；
- **面板宽度四处矛盾**：头注释「宽 250pt」vs `width: 257`（Panel.swift:640）vs `widthAnchor 260`（1328）vs main.swift:475 注释「320」——当前 viewWillAppear 会把宽度压窄 3pt，统一为单一 `panelWidth` 常量；
- 魔法数字（0.5s 判同点击、0.05s 弹面板延迟、600/300 退避、90 天历史等）→ 命名常量。

---

## 四、死代码清理（纯减法，约 -300 行）🟢

已全项目 grep 确认零引用：

- `Panel.swift`：`UsageBar`（645-661）、`UsageRing`（665-692）两个控件从未实例化；`animateFillColor`（120-128）、`HoverCard.setInfoHighlighted/applyInfoColor`（397-419）、`kCardBackgroundHover`（105）；
- `main.swift`：`resetAppAccentToDefault`（63-65）；`onToggleQwDecimals` 回调 + 接线（Panel.swift:836 / main.swift:438，菜单路径的 `toggleQwDecimals` 仍在用，保留本体）；
- **PanelSnapshot 11 个死字段**（`traeValue/traeUsed/traeLimit/qwH5/traeCheckinTime/traeCheckinDone/traeCheckinFailed/traeCheckinStreak/traeCheckinReward/wbCheckinDesc/qianwenDecimals`）：`Panel.update()` 从不消费，但 `makePanelSnapshot` 每次刷新都计算并读 30+ 次 UserDefaults——删字段既是减代码也是减负担；
- **签到历史只写不读**（`main.swift:2008-2035`）：每号维护 90 天记录写 UserDefaults，无任何 UI 展示。要么加「查看签到历史」入口（快照里已存 streak/time），要么连 `appendCheckinHistory` 与 5 处调用整体删除。

---

## 五、功能增强

### 16. 手动签到 / 账号采集的进行中反馈 🔴

- `ActionTileButton`（Panel.swift:423-560）无 disabled/loading 态：手动签到（每号 3s 间隔 × N 号可达 10s+）期间磁贴仍可点、无任何指示，结束才弹窗（main.swift:1549）；
- TRAE 采集进行中只改菜单标题「正在采集…」，面板磁贴无反馈（WB 有「取消添加」文案切换，Panel.swift:1026，TRAE 未对齐）——`traeCollectInProgress` 未暴露进快照。

### 17. 空态与错误态引导 🟡

- TRAE/WB 无任何账号时整个卡片区块消失，没有「先采集账号」的引导卡；
- 非当前账号首查未回显示 "—"，与「无法获取」不可区分（Panel.swift:1050-1054）。

### 18. 用量历史与低余额告警 🟡（旧 #15，仍未做）

每次刷新把各服务余额快照追加到本地（JSONL/SQLite），即可做「今日已消耗 / 较昨日」、7 日 sparkline、低余额通知（阈值可配置）。签到历史机制（#四）若保留可作为雏形。

### 19. 其余 UI 细节 🟢

- `valueLabel` 固定 60pt 宽 + `byClipping`（Panel.swift:1711-1717）：大额 `¥12,345.67` 会被硬裁（左侧字符直接切掉）→ `.byTruncatingHead` 或放宽约束；
- 千问无额度时点阵仍全灰渲染，DeepSeek 无 ratio 时隐藏（Panel.swift:999-1004 vs 971-977）→ 统一隐藏；`qwH5` 若要在面板展示 5h 窗口需先接线（当前是死字段，旧 #16 实际未完成）；
- `switchRow` 整行加 NSClickGestureRecognizer 而 NSSwitch 本身也响应点击（Panel.swift:1848-1849），可能双触发 → 手势识别器忽略落在 switch 上的点击；
- HoverCard/ActionTileButton 自绘 mouseUp，无 `accessibilityRole = .button` / label，VoiceOver 不可用；
- `hideWbNickSwitch.state = s.hideWbNickname ? .off : .on` 三重取反（Panel.swift:1037）→ 快照直接存 `showNickname` 正向语义。

### 20. 探测与兼容性 🟢

- `detectTraeStoragePath`（Config.swift:194-205）按目录名前缀 "trae" 模糊匹配取 sorted 第一个：同时装 TRAE 与 TRAE SOLO CN 时静默选错且用户无法干预 → 返回候选列表供选择；
- Edge Cookie 只读 `Default` profile（Qianwen.swift:30，旧 #13）→ 扫描 `Microsoft Edge/*/Cookies` 按 mtime 取最新；
- WorkBuddy 认证路径硬编码（WorkBuddy.swift:17）→ 对齐 traeStoragePath 做成可配置 + 自动探测；
- User-Agent 两处硬编码且与真实浏览器差异大（Qianwen.swift:95/113）→ 提取常量并保持一致；
- 只构建 arm64（build.sh:34）：Intel Mac（LSMinimumSystemVersion 同样允许 macOS 12）无法运行且无提示 → 至少 README 标注，或双架构。

---

## 六、构建与仓库健康

### 21. build.sh 自动重启不等待旧进程退出；删 bundle 早于杀进程 🔴

- `build.sh:127-131`：`killall` 后固定 `sleep 0.5` 就 `open`（无 `-n`）：旧进程未退时 open 只会激活旧实例，**新二进制根本没运行**，用户误以为已升级 → 循环等 `pgrep` 为空再 open；
- `build.sh:40`：先 `rm -rf "$APP_DIR"` 后在 127 行才杀进程——正在运行的旧 bundle 先被删掉 → 调整顺序：先停进程再删目录。

### 22. build.sh / Info.plist 零散问题 🟡

- `cp "$CONFIG"`（78）与 `cp icons/*.svg`（81）无容错：文件缺失时脚本中断且报错不友好（对比 png 行有 `|| true`）；
- `find -maxdepth 2`（22）：Services 下再嵌套子目录会静默漏编 → 放宽或去限制；
- `.build_state` 读写无并发保护，同时两个构建互相覆盖计数（影响小）；
- `codesign` 后无 `--verify` 自检；
- 配置合并用 python3 `tpl.update(cur)` 是**浅合并**，嵌套对象无法逐 key 合并（当前字段都是扁平的所以未爆雷，注明限制或改 jq）；
- Info.plist 可补：`LSApplicationCategoryType`、`CFBundleDevelopmentRegion`（zh_CN）、`NSHumanReadableCopyright`。

### 23. 仓库卫生 🟡

- **`swift/Panel.swift`（1906 行源码）、`docs/`、`PACKAGING.md`、`AGENT.md` 更新等均未 `git add`**——面板是核心文件，只存在于工作区，误删即丢失；
- `swift/.build/`（SPM 残留？）未加入 .gitignore；
- CHANGELOG.md 已删但仍在 git 跟踪中（未提交删除）；
- 建议：源码与文档尽早提交，敏感的 `swift/config.json` 先做 #1 再提交。

---

## 七、建议的落地顺序

| 顺序 | 事项 | 理由 |
| --- | --- | --- |
| 1 | #1 清空 swift/config.json 模板凭据 + #23 提交源码 | 防止凭据进 git 历史、防核心源码丢失，几分钟的事 |
| 2 | #3 /tmp 日志脱敏下线 + #2 凭据权限 600 | 安全止损（Keychain 迁移可作二期） |
| 3 | #4 刷新失败可见 + #7 网络错误分类 | 产品核心价值：数据可信度；#4 依赖 #7 的错误枚举 |
| 4 | #5 刷新去重 + #8/#11 抽 AppSwitcher 修进程切换 | 一次重构同时消灭 220 行重复和三类切换缺陷 |
| 5 | #9 Config 失败保护 + #21 build.sh 重启修复 | 都是「出问题才知道疼」的静默失败 |
| 6 | 死代码清理（#四节）+ #13 Formatter 缓存 | 纯减法，为后续改动铺路 |
| 7 | #16 签到/采集反馈、#17 空态、#18 用量历史 | 体验增强，按需 |

---

## 附录：上轮（2026-08-11）建议完成情况

| 旧编号 | 事项 | 状态 |
| --- | --- | --- |
| #1-#9 | 拆模块、Codable、async/await、去重、死代码清理、文档一致性、数据竞争、网络重试/离线感知、TCC 判断 | ✅ 已实施（2026-08-11） |
| #10 | 千问 SEC_TOKEN 正则脆弱 | 🟡 部分缓解，解析仍集中一处，无降级提示 |
| #11 | Timer App Nap 漂移 | ❌ 未做（本轮 #10 收编） |
| #12 | 凭据迁移 Keychain | ❌ 未做（本轮 #2，升级为 🔴 并补充文件权限问题） |
| #13 | Edge 多 profile | ❌ 未做（本轮 #20） |
| #14 | 菜单栏状态可见性 | 🟡 离线标记已做；服务失败可见性未做（本轮 #4） |
| #15 | 用量历史与趋势 | ❌ 未做（本轮 #18） |
| #16 | 千问 5h 额度展示 | ❌ 实际未接线：qwH5 是快照死字段（本轮 #19） |
| #17 | 开机自启动 | ❌ 未做 |
| #18 | 设置收纳子菜单 | ⏸ 已被面板 UI 取代，主菜单仅剩兜底入口，建议关闭 |
| #19 | 刷新间隔档位 | ✅ 已做（1/3/5 分钟） |
| #20 | 多 DeepSeek 账号 | ❌ 未做 |
| #21 | build.sh 保护 config.json | ✅ 已做（字段级合并） |
| #22 | 版本号自动递增 | ✅ 已做（日期 + .build_state） |
| #23 | 基础测试 | ❌ 未做，解密链路 fixture 验证仍值得做 |
