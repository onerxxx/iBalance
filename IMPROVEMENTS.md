# iBalance 改进优化建议

> 初稿基于 2026-08-15 全项目走查；**2026-08-17 逐项复核更新**（覆盖其后的 ZCode 平台接入、ponytail 两轮清理、错峰签到、面板视觉升级等改动；`swift/` 现 12 个源文件共 5079 行，忽略 `backups/` 与 `cockpit-tools-main/`）。
> 每项标注当前状态：✅ 已完成 / 🟡 部分完成 / ❌ 未动；已完成项正文压缩为结论，细节见文末附录 B。
> 优先级标注：🔴 高（建议尽快做）/ 🟡 中（有价值，择机做）/ 🟢 低（锦上添花）

---

## 一、安全与凭据 🔴

### 1. `swift/config.json` 含真实凭据，且**已提交进 git 历史** 🔴 🟡 已移出跟踪，轮换未做

已做（2026-08-17）：`swift/config.json` 加入 .gitignore（注释同步修正），`git rm --cached` 移除跟踪并推送——云端 HEAD 不再有该文件，本地文件保留（build.sh 继续用作打包源）。

仍未做：

- **轮换 DeepSeek API Key**：`1f7e285` 与 `666eb3e` 两个历史提交里仍含真实 Key/token，仅移出跟踪不改变历史。私密单人仓库暴露面有限，但仓库转公开前必须先 `git filter-repo` 重写历史 + force push；
- 本地 `swift/config.json` 仍是真实凭据（有意保留作打包源）；若未来需要「clone 即可构建」，补一份 `config.example.json` 空模板 + build.sh 缺文件容错（#22）。

### 2. 凭据明文落盘且文件权限 644 🔴 ❌（与旧 #12 相同，仍未做）

`Config.swift:213-222` 保存 config.json、`WorkBuddy.swift` 写 auth 文件均为默认权限，同机任何进程可读。涉及 5 类凭据：DeepSeek Key、千问 ticket、WorkBuddy token/refreshToken、TRAE 加密 authInfo、**ZCode 明文 JWT（新增，随 zcodeAccounts 存 config，切号时还要写 credentials.json 三键）**。

建议：

- token 类迁移 Keychain（`SecItemAdd` / `kSecClassGenericPassword`），config.json 只留非敏感设置；
- 迁移前至少 `FileManager.setAttributes([.posixPermissions: 0o600])` 收紧权限。

### 3. `/tmp` 日志无条件 dump 签到接口完整响应体 🟡 部分（加固项已明确搁置）

✅ 已完成：四份私有 appendLog 合并为 `Logger.swift` 统一日志器（`Logger.log(.switchAccount/.traeCheckin, ...)`）。
⏸ 搁置中：权限、脱敏、轮转、`~/Library/Logs/` 迁移与 symlink 防护——**2026-08-17 用户明确决定暂不修复**（安全债记录在案，此项不再重复催办）。若日后重启：`Logger.swift:12-29` 先 `fileExists` 再追加的写法顺带挡住了预创建 symlink 的部分风险。

---

## 二、健壮性

### 4. 刷新失败完全静默，「更新于」时间照常刷新 🔴 ✅ 已完成（2026-08-17，v2026.8.17.19）

采用 **footer 方案**（用户拍板，未做卡片副标题）：`main.swift` 新增 `failedServices: Set<String>`，五个 `refreshOne*` 在各自失败分支记录、成功分支清除；`makePanelSnapshot` 按固定顺序拼出 `failedText`，footer「更新于 HH:mm:ss」后追加显示（如「更新于 12:30:15 · 千问、TRAE 刷新失败」）。关键口径：

- **未配置不计失败**（DeepSeek 空 key / 千问空 ticket / WB·TRAE 未登录且无账号），避免没配某服务的用户永远看到失败标记；
- 多号服务任一账号获取失败即标记整服务（footer 是服务级粒度）；
- 取消导致的提前 return 不写状态（沿用 #5 的协作式取消守卫，被取代的旧刷新不污染标记）；
- `notifyError` 已参数化为通用错误通道（`service` 参数生成标题与标识），仍仅 DeepSeek 调用——其余服务每轮刷新都会失败，发通知会刷屏，走 footer 即可。

### 5. performRefresh 无去重、无取消 ✅ 已完成（2026-08-15）

`main.swift:464` 新增 `refreshTask` 属性，`onRefresh()` 先 `cancel()` 旧任务再起新任务（`main.swift:1035-1036`）；`performRefresh` 与各 `refreshOne*` 在写缓存点加了 `Task.isCancelled` 协作式守卫。

### 6. NetworkMonitor 回调不在主线程 ✅ 已完成

`NetworkMonitor` 标为 `@MainActor`，`pathUpdateHandler` 通过 `Task { @MainActor in ... }` 回主线程（`Network.swift:52-78`），状态只由主线程读写。

### 7. 网络层把所有错误压成 `(nil, 0)`，401 与超时不可区分 🔴 ❌

`Network.swift:24`：超时/DNS/连接拒绝/任务取消全部变成 status 0。后果不变：

- token 过期（401）与网络抖动在 UI 上都是同一种「获取失败」，无法引导用户重新采集；
- `Network.swift:40` 重试逻辑对「离线」「已取消」也照样 backoff 重试。

建议：`HTTP.request` 返回 `Result<Data, NetworkError>`（`.timeout / .offline / .http(Int, Data) / .cancelled`），401 单独处理并触发「请重新采集账号」提示；顺带统一默认 timeout 常量（当前 10/15 散传）。

### 8. 进程切号链路 ✅ 已完成（2026-08-17，v2026.8.17.19-22，分两批）

第一批（8-15 后）：切号编排移后台线程不再冻结 UI；`kill(pid, sig)` 系统调用替代 fork /bin/kill；三平台共享 ProcessUtil。

第二批（8-17，本轮）：

- **bundle id 精确匹配**：`ProcessUtil.mainPids(bundleId:)` / `killMainProcesses(bundleId:label:)` 改用 `NSRunningApplication`（只登记主进程，Electron helper 天然排除，也不会误伤路径含关键词的无关进程）。三平台接入：TRAE `cn.trae.solo.app`、WorkBuddy `com.workbuddy.workbuddy`、ZCode `dev.zcode.app`（Zcode 原地内联写法并入）。按 bundle id 会杀掉**所有**实例，双实例竞争写配置的残留风险一并消除；关键词匹配版 `mainPids(containingAll:)` / `isHelperCommandLine` / `killMainProcess(pid:)` 已删除；
- **kill(pid, 0) 判活**：`isRunning` 改零开销系统调用探测（ESRCH=不存在，EPERM=存活），替代每 120ms fork 一个 /bin/ps 的轮询；僵尸态最多多等一轮 120ms，进 SIGKILL 兜底不影响正确性；SIGKILL 后等待结果也写入日志（不再 `_ =` 丢弃）；
- **失败回滚 + 通知**：三平台 `switchAccount` 返回 `Bool`，写配置失败时配置未被改动（原子写入），**照常重启恢复原账号**并返回 false；main.swift 三个切号编排据此发系统通知（「TRAE 切号失败：写入 storage.json 未成功，已重启恢复原账号」等）。三个 `restartXxx` 的 `try? task.run()` 改为 catch 后写切换日志。

### 9. Config 解析失败静默回退默认值，随后 save 覆盖用户全部配置 🔴 ❌

`Config.swift:204-208`：decode 用 `try?` 静默回退默认值，下一次 `save` 就用默认值覆盖用户配置；`Config.swift:219-221` 保存失败（磁盘满 / bundle 同目录无写权限）也无任何反馈。

建议：解析失败时保留原文件改名 `.bak` 并通过 UI 告知；save 返回结果并在失败时提示；长期看配置应迁到 `~/Library/Application Support/iBalance/`（`.app` 旁放可编辑配置不符合 macOS 规范，app 移动/分发后配置「丢失」）。

### 10. 零散健壮性问题 🟡 两项已缓解，四项仍在

- ❌ `main.swift:2479-2499`：签到历史 decode 失败返回 `[]`，`appendCheckinHistory` 随即用空数组覆盖旧 key——**风险升级**：历史已接 UI（「签到历史」磁贴弹窗），解码失败即用户可见的历史全清；
- ❌ `main.swift:626/1065/2358`：三处 `Timer.scheduledTimer(target:)` 强引用 target 且 terminate 时不 invalidate；建议 block-based timer（App Nap 漂移一并解决，或监听 `didWakeNotification` 唤醒后补刷新）；
- ❌ `main.swift:2305`：`openApplication` completion `{ _, _ in }` 启动失败无提示；各 `UNUserNotificationCenter.add` 回调同样全静默；
- ❌ `main.swift:1743-1808`：手动签到 Task 不可取消，若挂起则 `manualCheckinInProgress` 永久为 true，签到按钮从此失灵且无提示；
- ✅ OAuth 轮询取消已修：轮询循环每轮 `if await isCancelled()` 主动检查（`WorkBuddy.swift:410` 一带），取消后 1.5s 内退出；
- 🟡 refresh 接口 `expiresAt`：已补多字段名 + `expiresIn` 相对值兜底（`WorkBuddy.swift:348-355`），毫秒/秒归一化仍无（服务端若返回毫秒仍会算错），风险较低，观察即可。

---

## 三、代码质量

### 11. Trae.swift ↔ WorkBuddy.swift 重复 🟡 大头已消灭

✅ 进程管理整条链路（杀/等/重启/日志）已抽 `ProcessUtil.swift` + `Logger.swift`，双份实现删除约 170 行；switchAccount 收敛为「杀 → 写文件 → 重启」三步。
❌ 剩余小型重复：headers 构造（TRAE/WB 各 3-4 处重复）未收口成 `traeHeaders(token:)` / `wbHeaders(token:uid:)`；签到解析的「尝试 N 种字段名」模式仍是各写各的。

### 12. Panel.swift 多号卡片复制粘贴 ✅ 已完成（比原建议走得更远）

三平台（WB/TRAE/**ZCode**）合一：`AccountCardSnapshot` 统一快照 + `CardStyle`（icon/标题/签到行/到期行差异化）+ 通用 `rebuildAccountCards` / `applyAccountCardData`，各平台只留薄封装。原 200 行 × 2 的复制粘贴和同构 Snapshot 结构体已不存在。

### 13. 性能：Formatter 与图标每次新建 ✅ 已完成（2026-08-17）

- `fmtAmountCommas` 复用 static `commaFormatter`（按调用调整小数位，仅主线程）；
- main.swift 7 处 per-call `DateFormatter` 全部收敛为 static 缓存（`dfDay`/`dfTime`/`dfClock`/`dfMonthDay`/`dfParseTime`，`makeDateFormatter` 工厂），`Logger.log` 的时间戳 formatter 同样缓存（后台线程调用，10.9+ 线程安全）；
- `dfParseTime.defaultDate` 创建时固定当年 1 月 1 日（跨年仅影响近似比较），避免共享实例被并发改写；
- 状态栏图标 `statusIcon` lazy 缓存一次读盘，`refreshStatusItemAppearance`（8 种焦点通知高频触发）不再每次 `NSImage(contentsOf:)`。
- 备注：弹窗/菜单等冷路径的图标加载（main.swift 剩余几处 `NSImage(contentsOf:)`）仍按需创建，频率低不值得缓存。

### 14. main.swift（~2500 行）/ Panel.swift（~1980 行）继续拆分 🟡 ❌（且原建议一条已过时）

服务层这轮反而做得好（新增 Logger/ProcessUtil/Zcode 拆出），但入口和面板两个文件继续膨胀。按 MARK 拆（build.sh 自动收集 *.swift，零成本）：

- ~~`AppAccent.swift` ← NSColor swizzle 扩展~~ **已过时**：App 级强调色 swizzle 已整体移除，不存在了；
- `CheckinManager.swift` ← 签到域：错峰签到（60s 轮询 + 每号随机就绪时刻）、手动签到编排、签到历史、streak 工具（main.swift 里最大的一块，约 700 行）；
- `AccountSwitcher.swift` ← TRAE 采集 + 三平台切号编排（main.swift:2140-2350 一带）；
- `Dialogs.swift` ← DialogShell / InputDialog / 各业务弹窗；
- `Controls.swift` ← Panel.swift 前半的自绘控件（HoverCard / ActionTileButton / 点阵 / MiniSwitch 等，约 700 行且自包含）。

### 15. 硬编码与常量收口 🟡 UDKey 已完成，其余未做

- ✅ **UDKey 收口（2026-08-17）**：main.swift 全部 UserDefaults key 字面量（约 64 处调用、17 个 key）收敛到 `Config.swift` 的 `enum UDKey`（per-uid 函数 + 静态属性），`forKey: "..."` 字面量清零；字符串格式与历史版本逐字一致，已落盘的签到数据不受影响；`checkinReadyTimestamp` 顺带由 keyPrefix 拼接改为直接收 key；
- ❌ URL / bundle id 仍散落（`platform.deepseek.com/usage` 等）→ 收进 `enum Links` / 配置；
- ❌ **面板宽度仍三处矛盾**：头注释「宽 250pt」（`Panel.swift:3`）vs `width: 257`（`Panel.swift:681`）vs `widthAnchor 260`（`Panel.swift:1357`，root 内容宽 246）——统一为单一 `panelWidth` 常量；
- ❌ 魔法数字（0.6s 延时关面板、0.8s/1.0s 杀进程超时、600s OAuth、90 天历史等）→ 命名常量。

---

## 四、死代码清理 ✅ 已完成（2026-08-16 ponytail 两轮，6460→6032 净 -428）

- Panel.swift：`UsageBar` / `UsageRing` / `animateFillColor` / `setInfoHighlighted` 死链 / PanelSnapshot 11 个死字段（含 qwH5）及 main.swift 赋值块 / `onToggleQwDecimals` 声明+接线，全部删除；
- **签到历史已接 UI**：「签到历史」磁贴 + 弹窗（显示最近两天，存储留 90 天），原「只写不读」问题关闭；
- ProcessUtil 进程工具去重、三套卡片合并（→ #8/#11/#12）。
- 仅剩两个 P1 小项：`Palette` 旧名别名（`kBalanceForeground` 等三个，机械改名 diff 广）、`WorkBuddy.authInfo` 的 NSLock（调用方全在 @MainActor，锁无必要）。

---

## 五、功能增强

### 16. 手动签到 / 账号采集的进行中反馈 🔴 ❌

- `ActionTileButton` 仍无 disabled/loading 态：手动签到（每号 3s 间隔 × N 号可达 10s+）期间磁贴仍可点、无任何指示，结束才弹窗；
- TRAE 采集进行中仍只改菜单标题「正在采集…」（`main.swift:2150`），`traeCollectInProgress` 未暴露进面板快照，磁贴无反馈（WB 有文案切换，TRAE 未对齐）。

### 17. 空态与错误态引导 🟡 ❌

- TRAE/WB/ZCode 无任何账号时整个卡片区块消失（ZCode 容器默认隐藏是有意设计），没有「先采集账号」的引导卡；
- 非当前账号首查未回显示 "—"，与「无法获取」不可区分。

### 18. 用量历史与低余额告警 🟡 ❌（旧 #15，仍未做）

每次刷新把各服务余额快照追加到本地（JSONL/SQLite），即可做「今日已消耗 / 较昨日」、7 日 sparkline、低余额通知（阈值可配置）。签到历史机制已验证了「UserDefaults 存结构化列表 + UI 读取」这条路可行，可复用模式。配额告警与企业账号余额两需求待拍板。

### 19. 其余 UI 细节 🟢 ❌（一条已随死代码清理消失）

- `valueLabel` 固定宽 + `byClipping`（`Panel.swift:1775`）：大额 `¥12,345.67` 会被硬裁（左侧字符直接切掉）→ `.byTruncatingHead` 或放宽约束；
- ~~千问 qwH5 死字段接线~~ 已随死字段删除关闭；
- `switchRow` 整行加 NSClickGestureRecognizer 而 NSSwitch 本身也响应点击（`Panel.swift:1912`），可能双触发 → 手势识别器忽略落在 switch 上的点击；
- HoverCard/ActionTileButton 自绘 mouseUp，无 `accessibilityRole = .button` / label（全项目 0 处），VoiceOver 不可用；
- `hideWbNickname` 仍反向语义存储 + 取反切换（`main.swift:1090`）→ 快照直接存 `showNickname` 正向语义。

### 20. 探测与兼容性 🟢 ❌

- `detectTraeStoragePath`（`Config.swift:222-235`）仍按目录名前缀 "trae" 模糊匹配取 sorted 第一个：同时装 TRAE 与 TRAE SOLO CN 时静默选错且用户无法干预 → 返回候选列表供选择；
- Edge Cookie 仍只读 `Default` profile（`Qianwen.swift:30`，旧 #13）→ 扫描 `Microsoft Edge/*/Cookies` 按 mtime 取最新；
- WorkBuddy 认证路径仍硬编码（`WorkBuddy.swift:17`，现为 CodeBuddyExtension 路径）→ 对齐 traeStoragePath 做成可配置 + 自动探测；
- User-Agent 仍两处硬编码（`Qianwen.swift:95/120`）→ 提取常量并保持一致；
- 仍只构建 arm64（`build.sh:44`）：Intel Mac 无法运行且无提示 → 至少 README 标注，或双架构。

---

## 六、构建与仓库健康

### 21. build.sh 自动重启不等待旧进程退出；删 bundle 早于杀进程 🔴 ❌

- `build.sh:137-141`：`killall` 后固定 `sleep 0.5` 就 `open`：旧进程未退时 open 只会激活旧实例，**新二进制根本没运行**，用户误以为已升级 → 循环等 `pgrep` 为空再 open；
- `build.sh:50`：先 `rm -rf "$APP_DIR"` 后在 137 行才杀进程——正在运行的旧 bundle 先被删掉 → 调整顺序：先停进程再删目录。

### 22. build.sh / Info.plist 零散问题 🟡 ❌

- `cp "$CONFIG"`（78）与 `cp icons/*.svg`（81）无容错：文件缺失时脚本中断且报错不友好（对比 png 行有 `|| true`）；
- `find -maxdepth 2`（22）：Services 下再嵌套子目录会静默漏编 → 放宽或去限制；
- `.build_state` 读写无并发保护，同时两个构建互相覆盖计数（影响小）；
- `codesign`（100-102）后无 `--verify` 自检；
- 配置合并用 python3 `tpl.update(cur)` 是**浅合并**，嵌套对象无法逐 key 合并（当前字段都是扁平的所以未爆雷，注明限制或改 jq）；
- Info.plist 仍缺：`LSApplicationCategoryType`、`CFBundleDevelopmentRegion`（zh_CN）、`NSHumanReadableCopyright`。

### 23. 仓库卫生 ✅ 基本完成

- ✅ 源码与文档已全部提交（`Panel.swift`、`docs/`、`PACKAGING.md`、`AGENT.md` 等），工作区干净；
- ✅ `swift/.build/` 已加入 .gitignore；CHANGELOG.md 的删除已提交（git 已不跟踪）；
- ⚠️ 唯一遗留即 #1：`swift/config.json` 带着真实凭据入库，处理方式见 #1。

---

## 七、建议的落地顺序（2026-08-17 修订）

| 顺序 | 事项 | 理由 |
| --- | --- | --- |
| 1 | #1 轮换 DeepSeek Key + 恢复 config 模板 + 改 .gitignore 注释 | 凭据已进 git 历史，先止损再清理 |
| 2 | #2 凭据权限 600 | 安全止损（Keychain 迁移可作二期） |
| 3 | #7 网络错误分类 | 产品核心价值：数据可信度的另一半（#4 已完成，401 引导重新采集依赖此项） |
| 4 | #9 Config 失败保护 + #21 build.sh 重启修复 | 都是「出问题才知道疼」的静默失败 |
| 5 | #10 签到历史 decode 防覆盖 + 手动签到可取消 | 历史已有 UI，数据丢失从隐患变可见事故 |
| 6 | #16 签到/采集反馈、#17 空态、#18 用量历史 | 体验增强，按需 |
| 7 | #15 剩余（Links 收口 + panelWidth 常量 + 魔法数字） | 纯整洁度，择机 |

---

## 附录 A：上上轮（2026-08-11）建议完成情况

| 旧编号 | 事项 | 状态 |
| --- | --- | --- |
| #1-#9 | 拆模块、Codable、async/await、去重、死代码清理、文档一致性、数据竞争、网络重试/离线感知、TCC 判断 | ✅ 已实施（2026-08-11） |
| #10 | 千问 SEC_TOKEN 正则脆弱 | 🟡 部分缓解，解析仍集中一处，无降级提示 |
| #11 | Timer App Nap 漂移 | ❌ 未做（本轮 #10 收编） |
| #12 | 凭据迁移 Keychain | ❌ 未做（本轮 #2，升级为 🔴 并补充文件权限问题） |
| #13 | Edge 多 profile | ❌ 未做（本轮 #20） |
| #14 | 菜单栏状态可见性 | 🟡 离线标记已做；服务失败可见性未做（本轮 #4） |
| #15 | 用量历史与趋势 | ❌ 未做（本轮 #18） |
| #16 | 千问 5h 额度展示 | ✅ 已关闭：qwH5 随死字段删除（2026-08-16） |
| #17 | 开机自启动 | ❌ 未做 |
| #18 | 设置收纳子菜单 | ⏸ 已被面板 UI 取代，主菜单仅剩兜底入口，建议关闭 |
| #19 | 刷新间隔档位 | ✅ 已做（1/3/5 分钟） |
| #20 | 多 DeepSeek 账号 | ❌ 未做 |
| #21 | build.sh 保护 config.json | ✅ 已做（字段级合并） |
| #22 | 版本号自动递增 | ✅ 已做（日期 + .build_state） |
| #23 | 基础测试 | ❌ 未做，解密链路 fixture 验证仍值得做 |

## 附录 B：本轮（2026-08-15 → 08-17）完成情况

| 本轮编号 | 事项 | 状态 |
| --- | --- | --- |
| #3 | /tmp 日志四份实现合并 | ✅ Logger.swift 统一日志器（加固项用户明确搁置） |
| #5 | performRefresh 去重 + 取消 | ✅ refreshTask + Task.isCancelled 协作守卫 |
| #4 | 刷新失败静默 | ✅ footer「更新于」后追加「· xx 刷新失败」标记（failedServices，未配置不计） |
| #8 | 进程切号链路 | ✅ 第二批补齐：bundle id 精确匹配 + kill(pid,0) 判活 + 失败回滚通知（v2026.8.17.19-22） |
| #13 | Formatter/图标每次新建 | ✅ static 缓存全套（NumberFormatter / 5 个 DateFormatter / Logger 时间戳 / 状态栏图标） |
| #15 | UDKey 收口 | ✅ 17 个 key / 约 64 处调用收敛进 enum UDKey；Links、panelWidth、魔法数字仍待做 |
| #6 | NetworkMonitor 主线程 | ✅ @MainActor + Task hop |
| #8 | 进程切号三缺陷 | 🟡 主线程冻结 / fork 风暴 / 匹配过宽已修；回滚与 bundle id 精确匹配待做 |
| #10 | OAuth 轮询取消 | ✅ isCancelled 主动检查 |
| #11 | Trae/WB 220 行重复 | 🟡 进程链路 + 日志已抽 ProcessUtil/Logger；headers 等小重复待收口 |
| #12 | 多号卡片复制粘贴 | ✅ 三平台合一 AccountCardSnapshot + CardStyle |
| 四 | 死代码清理约 -300 行 | ✅ ponytail 两轮 6460→6032（净 -428，含签到历史接 UI 新增 ~60 行） |
| #23 | 仓库卫生 | ✅ 源码文档全提交、.build 忽略、CHANGELOG 删除落账 |
| （新增事实） | ZCode 平台接入 | ℹ️ 凭据类型 +1（明文 JWT），已并入 #2 描述 |
