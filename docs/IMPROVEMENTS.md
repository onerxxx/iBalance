# iBalance 改进优化建议

> 初稿基于 2026-08-15 全项目走查；**2026-08-17 逐项复核**；**2026-08-19 再次逐项复核**；**2026-08-22 第三次复核**（覆盖其后的：#23 全部落库、日/周用量板块上线、macOS 26 基线升级、面板置顶浮窗、平台自动化开关、PanelWindow 重构尝试与回滚、ASCII 点阵图标机制删除等；`swift/` 现 12 个源文件共 **11820** 行，其中 main.swift **4029** / Panel.swift **5559**，忽略 `backups/`）。
> 每项标注当前状态：✅ 已完成 / 🟡 部分完成 / ❌ 未动；已完成项正文压缩为结论，细节见文末附录 B / C / D。
> 优先级标注：🔴 高（建议尽快做）/ 🟡 中（有价值，择机做）/ 🟢 低（锦上添花）

---

## 一、安全与凭据 🔴

### 1. `swift/config.json` 含真实凭据，且**已提交进 git 历史** 🔴 🟡 已移出跟踪，轮换未做

已做（2026-08-17）：`swift/config.json` 加入 .gitignore（注释同步修正），`git rm --cached` 移除跟踪并推送——云端 HEAD 不再有该文件，本地文件保留（build.sh 继续用作打包源）；`backups/` 内含凭据的 config.json 副本也已移出版本控制。**2026-08-20 补强**：`backups/` 整个目录加入 .gitignore 并从索引移除（`949aad3`），历史备份不再有再次入库的通道。

仍未做：

- **轮换 DeepSeek API Key**：`1f7e285` 与 `666eb3e` 两个历史提交里仍含真实 Key/token，仅移出跟踪不改变历史。私密单人仓库暴露面有限，但仓库转公开前必须先 `git filter-repo` 重写历史 + force push；
- 本地 `swift/config.json` 仍是真实凭据（有意保留作打包源）；若未来需要「clone 即可构建」，补一份 `config.example.json` 空模板 + build.sh 缺文件容错（#22）——截至本轮 `config.example.json` 仍不存在。

### 2. 凭据明文落盘 🔴 🟡（权限已收紧 ✅，Keychain 仍未做）

2026-08-18 配置/缓存迁移到 `~/Library/Application Support/com.local.ibalance/`（`Config.swift` 新增 `AppDataStore`）：目录权限 700（`prepareDirectory`），`secureWrite` 原子写入 + 文件权限 600（实测 `drwx------` / `-rw-------` 已生效）；首次启动自动迁移旧版 `.app` 同目录文件并**保留旧文件副本**可回退。但 token 仍以明文 JSON 保存，尚未迁移 Keychain（全项目仍无 `SecItem` 调用）。涉及凭据共 **5 类**：DeepSeek Key、WorkBuddy token/refreshToken、TRAE 加密 authInfo、ZCode 明文 JWT（随 zcodeAccounts 存 config，切号时还要写 credentials.json 三键）、Codex access/refresh/idToken（随 codexAccounts 存 config；切号时另写外部 `~/.codex/auth.json`）。千问平台已于 2026-08-17 整体下线。

建议：

- token 类迁移 Keychain（`SecItemAdd` / `kSecClassGenericPassword`），config.json 只留非敏感设置；Codex 凭据迁移后切号写 auth.json 的逻辑不受影响（数据源换成 Keychain 读取即可）。

### 3. `/tmp` 日志无条件 dump 签到接口完整响应体 🟡 部分（加固项已明确搁置）

✅ 已完成：四份私有 appendLog 合并为 `Logger.swift` 统一日志器。**2026-08-20 起持续扩展**：新增 refresh / network / layout 三个频道，并加了 `measure` / `measureSync` 性能打点工具（`bcd8de4`）——日志面变大，脱敏需求随之上升。
⏸ 搁置中：权限、脱敏、轮转、`~/Library/Logs/` 迁移与 symlink 防护——**2026-08-17 用户明确决定暂不修复**（安全债记录在案，此项不再重复催办）。若日后重启：`Logger.swift` 先 `fileExists` 再追加的写法顺带挡住了预创建 symlink 的部分风险。

---

## 二、健壮性

### 4. 刷新失败完全静默，「更新于」时间照常刷新 🔴 ✅ 已完成（2026-08-17，v2026.8.17.19）

采用 **footer 方案**：`main.swift` 的 `failedServices: Set<String>` 由各 `refreshOne*` 在失败/成功分支维护；footer「更新于 HH:mm:ss」后追加显示（如「更新于 12:30:15 · TRAE、ZCode 刷新失败」）。关键口径：未配置不计失败；多号服务任一账号失败即标记整服务；取消导致的提前 return 不写状态。近两轮未变动。

### 5. performRefresh 无去重、无取消 ✅ 已完成（2026-08-15）

`refreshTask` 先 `cancel()` 旧任务再起新任务；`performRefresh` 与各 `refreshOne*` 在写缓存点加了 `Task.isCancelled` 协作式守卫。

### 6. NetworkMonitor 回调不在主线程 ✅ 已完成

`NetworkMonitor` 标为 `@MainActor`，`pathUpdateHandler` 通过 `Task { @MainActor in ... }` 回主线程。

### 7. 网络层把所有错误压成 `(nil, 0)`，401 与超时不可区分 🔴 ❌

`Network.swift` 未变（134 行，`bcd8de4` 仅小改未重构）：超时/DNS/连接拒绝/任务取消全部变成 status 0。后果不变：

- token 过期（401）与网络抖动在 UI 上都是同一种「获取失败」，无法引导用户重新采集（Codex 接入后 access token 过期场景更多，此项价值上升）；
- `requestWithRetry` 对「离线」「已取消」也照样 backoff 重试。

建议：`HTTP.request` 返回 `Result<Data, NetworkError>`（`.timeout / .offline / .http(Int, Data) / .cancelled`），401 单独处理并触发「请重新采集账号」提示；顺带统一默认 timeout 常量（当前 10/15 散传）。

### 8. 进程切号链路 ✅ 已完成（2026-08-17 两批 + 2026-08-19 Codex 接入，均已落库 `f47bd36`）

已具备：bundle id 精确匹配（`ProcessUtil.mainPids(bundleId:)`，Electron helper 天然排除）、`kill(pid, 0)` 判活、失败回滚 + 通知；Codex 切号（杀 `com.openai.codex` → 字段级更新 `~/.codex/auth.json` tokens、空值 `removeValue`、原子写入保留原文件权限 → `open -n -a Codex`，任一步失败重启恢复原账号）；切号编排统一为 `performAccountSwitch(serviceName:failureMessage:action:)` 单入口（TRAE / WorkBuddy / ZCode / Codex 四平台共用）；Codex 采集一并读取 `refresh_token` / `id_token`。

### 9. Config 解析失败静默回退默认值，随后 save 覆盖用户全部配置 🔴 ❌

`Config.swift` 未变：decode 用 `try?` 静默回退默认值（现 `Config.swift:354-355`），下一次 `save` 就用默认值覆盖用户配置；`secureWrite` 写入失败（磁盘满 / Application Support 不可写）也只 `return` 无任何反馈（现 `Config.swift:337`）。配置路径迁移已完成（数据在用户目录，App 更新不再触碰），但解析/保存错误处理仍待补强——**注意新风险**：迁移后首次加载若 decode 失败，`shouldPersist` 路径会把默认值直接落盘到 Application Support，覆盖迁移副本的时机提前了。且配置字段近两轮持续增加（floatingPanelWidth/Height、debugUsageEnabled、各平台刷新开关等），decode 兼容面在扩大。

建议：解析失败时保留原文件改名 `.bak` 并通过 UI 告知；save 返回结果并在失败时提示。

### 10. 零散健壮性问题 🟡 两项已缓解，四项仍在（行号按 08-22 HEAD 更新）

- ❌ 签到历史 decode 失败返回 `[]`，`appendCheckinHistory` 随即用空数组覆盖旧 key（现 `main.swift:3986-4002`）——历史已接 UI（「签到历史」磁贴弹窗），解码失败即用户可见的历史全清；
- ❌ 三处 `Timer.scheduledTimer(target:)`（现 `main.swift:958/1834/3830`）强引用 target 且 terminate 时不 invalidate；建议 block-based timer（App Nap 漂移一并解决，或监听唤醒通知补刷新）；
- ❌ `openApplication` completion `{ _, _ in }`（现 `main.swift:3739`）启动失败无提示；各 `UNUserNotificationCenter.add` 回调同样全静默；
- ❌ 手动签到 Task 不可取消，若挂起则 `manualCheckinInProgress`（现 `main.swift:3059` 一带）永久为 true，签到按钮从此失灵且无提示；
- ✅ OAuth 轮询取消已修：轮询循环每轮主动检查取消，1.5s 内退出；
- 🟡 refresh 接口 `expiresAt`：已补多字段名 + `expiresIn` 相对值兜底，毫秒/秒归一化仍无（服务端若返回毫秒仍会算错），风险较低，观察即可。

---

## 三、代码质量

### 11. Trae.swift ↔ WorkBuddy.swift 重复 🟡 大头已消灭，小型重复仍在

✅ 进程管理链路已抽 `ProcessUtil.swift` + `Logger.swift`；切号编排收敛为 `performAccountSwitch` 单入口（四平台共享，连 Codex 接入也只写了平台特定的凭据写入）。
❌ 剩余小型重复：headers 构造（TRAE/WB 各 3-4 处重复）未收口成 `traeHeaders(token:)` / `wbHeaders(token:uid:)`；签到解析的「尝试 N 种字段名」模式仍是各写各的。

### 12. Panel.swift 多号卡片复制粘贴 ✅ 已完成（三平台 → 四平台合一）

WB/TRAE/ZCode/Codex 共用 `AccountCardSnapshot` + `CardStyle`（含 `platformID`，供拖拽排序与 icon 缩放口径使用）+ 通用 `rebuildAccountCards` / `applyAccountCardData`，各平台只留薄封装。

### 13. 性能：Formatter 与图标每次新建 ✅ 已完成（2026-08-17）

`fmtAmountCommas` 复用 static `commaFormatter`；DateFormatter 收敛为 static 缓存；Logger 时间戳 formatter 缓存；状态栏图标 lazy 缓存。弹窗/菜单等冷路径图标仍按需创建（频率低）。

### 14. main.swift / Panel.swift 巨型文件拆分 🔴 ✅ 已完成（2026-08-24，v2026.8.24.16）

按 08-22 复核方案落地：**纯代码搬移 + 访问级别放宽，零行为变更**，构建、签名、重启实测通过。swift/ 源文件 12 → 20 个：

- main.swift **4102 → 2177 行**：弹出 `Dialogs.swift`（638，DialogShell/InputDialog 等五类型）、`CheckinManager.swift`（818，AppDelegate 扩展：错峰签到 / 手动签到 / 签到历史 / 定时器 / CheckinRecord）、`AccountSwitcher.swift`（381，AppDelegate 扩展：WB OAuth / TRAE 采集 / Codex·ZCode 导入 / performAccountSwitch + 四平台切号入口）、`PinWindow.swift`（124，AppDelegate 扩展：popover ↔ NSPanel 转移与尺寸恢复）；
- Panel.swift **6024 → 1847 行**：弹出 `Controls.swift`（1914，全部自绘控件）、`UsagePanel.swift`（857，UsageRowSnapshot / 趋势图子弹窗 / UsageDots + BalancePanelView 用量扩展）、`PanelDrag.swift`（291，拖拽排序框架）、`PanelLayout.swift`（1153，build() 主装配 + 行构建器）；
- 拆分方式：顶层类型整块搬移；AppDelegate / BalancePanelView 的方法域以 `extension` 拆出，存储属性留在类体（`onContentChanged` / `rootViewRef` / `sectionTitleViews` / `rootBottomCap` / `charBlurTimer` 五个混在方法区的存储属性搬回 Panel.swift 类体，集中标注 MARK）；
- 访问级别：约 120 处被跨文件引用的 `private` 放开为默认 internal（Palette / bundleIcon / syncPanel / updateTitle 重载等），语义无变化；
- AGENT.md 目录树与代码结构表已同步。

### 15. 硬编码与常量收口 🟡 UDKey 持续收口，其余未做

- ✅ **UDKey 收口（持续）**：全部 UserDefaults 持久化 key 收敛进 `enum UDKey`；近两轮新增 key（balancePlatformOrder、floatingPanelWidth/Height、debugUsageEnabled、各平台刷新开关等）均直接进 enum；裸字面量仅剩 1 处调试开关（`Panel.swift:2650` `IBLayoutAutoTest`，可收编或忽略）；
- ❌ URL / bundle id 仍散落（`platform.deepseek.com/usage`、`com.openai.codex` 在 main.swift/Codex.swift 各出现等）→ 收进 `enum Links` / 配置；
- 🟡 **面板宽度**：布局经 74d2b80 / 1793049 / 5687899 三轮调整后字面量再度漂移，需重新盘点后收成单一常量（浮窗尺寸已有 floatingPanelWidth/Height 持久化，可作参照）；
- ❌ 魔法数字（延时关面板、杀进程超时、600s OAuth、90 天历史、3pt 拖拽阈值、拖拽透明度等）→ 命名常量。

---

## 四、死代码清理 ✅ 持续进行（2026-08-16 ponytail 两轮 -428；本轮再删一批）

- Panel.swift：`UsageBar` / `UsageRing` / `animateFillColor` / `setInfoHighlighted` 死链 / PanelSnapshot 死字段及赋值块，全部删除；
- **2026-08-22（`1793049`）**：ASCII 点阵图标机制整体删除（AsciiIconProvider / registerMonoIcon / applyIconPolicy / 磁贴 mono 注册）；`swift-tools/` 独立小工具目录（click/presskey）删除，三处文档同步；
- 千问平台已整体下线（`67eeb0e`），`Qianwen.swift` 已删除；「配置Key」「日常额度」磁贴合并为「Key / 额度」（`onSetDsQuota` 回调与磁贴一并移除）；`subAccountDimEnabled` 开关引入一天后即被 `5687899` 移除（被浮窗尺寸持久化取代），未留死键；
- `docs/CheckinResultPanelController.swift` 为有意存档（头部注明不参与编译），不计死代码。

仅剩两个 P1 小项：`Palette` 旧名别名（`kBalanceForeground` 等三个，机械改名 diff 广）、`WorkBuddy.authInfo` 的 NSLock（调用方全在 @MainActor，锁无必要）。

---

## 五、功能增强

### 16. 手动签到 / 账号采集的进行中反馈 🔴 ✅ 已完成（2026-08-17，v2026.8.17.24）

`ActionTileButton.setInProgress(_:)` 呼吸脉冲 + 禁点；手动签到与 TRAE 采集磁贴均已接入。签到结果弹窗为 SF Symbol 信息行（`CheckinInfoItem`：checkmark.seal / flame / gift，显式预渲染成统一灰色，规避 NSTextAttachment 不继承前景色的问题）。

### 17. 空态与错误态引导 🟡 ❌

- TRAE/WB/ZCode/Codex 无任何账号时整个卡片区块消失（容器默认隐藏是有意设计），没有「先采集账号」的引导卡；
- 非当前账号首查未回显示 "—"，与「无法获取」不可区分。

### 18. 用量历史与低余额告警 🟡 大部分完成（日/周用量板块已上线，低余额告警未做）

✅ **已完成（`fc11c9a` 08-19 → `bcd8de4` 08-20 → `afe0f63` 08-21 三轮迭代）**：

- 面板新增「用量」分组（与「余额 / 设置 / 操作」同级 section），展示各平台今日 / 本周用量；
- **本地差值方案**（不接平台用量 API）：`UsageStore`（`Config.swift:518` 起）记录当日/当周首观基线，跨天/跨周重置、充值/重置校准，用量 = 基线与当前余额差值；数据随定时刷新 observe 写入 `usage.json`（随配置迁移进 Application Support）；
- 每日用量历史保留 60 天，支持 7 日 sparkline 与用量子弹窗（空间不足自动翻转到面板左侧弹出）；
- 平台级汇总：全部账号今日/本周用量对应相加（差值按账号独立计算后求和），兼容余额型/已用型/百分比口径；
- `debugUsageEnabled` 调试开关：七天随机样例只保存在内存，不污染 usage.json；
- todo.md 第 3 项三项全部勾完。

❌ 仍未做：低余额通知（阈值可配置）——grep 全项目无相关实现；配额告警与企业账号余额两需求仍待拍板。

### 19. 其余 UI 细节 🟢 ❌（一项已随改版消失，行号按 08-22 HEAD 更新）

- ❌ `valueLabel` 固定宽 + `byClipping`（现 `Panel.swift:5146`）：大额 `¥12,345.67` 会被硬裁 → `.byTruncatingHead` 或放宽约束；
- ❌ `switchRow` 整行 NSClickGestureRecognizer 而 NSSwitch 本身也响应点击（现 `Panel.swift:5324`），可能双触发 → 手势识别器忽略落在 switch 上的点击；
- ❌ HoverCard/ActionTileButton 自绘 mouseUp，无 `accessibilityRole = .button` / label，VoiceOver 不可用（拖拽排序全程鼠标驱动，键盘替代方案也无）；
- ✅ ~~`hideWbNickname` 反向语义存储~~：该设置已随账号卡片改版移除，快照直接携带正向语义的 `nickname` 字段，问题关闭。

近两轮顺手修掉的相邻问题：平台标题 compression resistance required + 昵称单行省略；行高修复 12pt 字形下沿裁切；hover 取点统一改 `NSEvent.mouseLocation` + 零点防护（`1793049`，修浮窗期间退出按钮假 hover 卡亮）。

### 20. 探测与兼容性 🟢 ❌（基线已升 macOS 26，Intel 兼容性问题加重）

- ❌ `detectTraeStoragePath`（现 `Config.swift:377`）仍按目录名前缀 "trae" 模糊匹配取 sorted 第一个：同时装 TRAE 与 TRAE SOLO CN 时静默选错且用户无法干预 → 返回候选列表供选择；
- ❌ WorkBuddy 认证路径仍硬编码（`WorkBuddy.swift:17`，CodeBuddyExtension 路径）→ 对齐 traeStoragePath 做成可配置 + 自动探测；
- ❌ **deployment target 已升至 `arm64-apple-macos26`（`afe0f63`，Liquid Glass 适配基线）**：Intel Mac 与 macOS 25 及以下全部无法运行且无提示 → 至少 README 标注系统要求（README 已于 `6e838e6` 建立，需补此节），或考虑降级基线换取兼容面。

---

## 六、构建与仓库健康

### 21. build.sh 自动重启不等待旧进程退出；删 bundle 早于杀进程 🔴 ✅ 已完成（2026-08-19）

两处均已修：停机逻辑移到「组装 .app bundle」之前（先停进程再 `rm -rf`）；`killall`（SIGTERM）后 `sleep 1.0` 优雅退出，随后 `wait_iBalance_exit` 每 0.1s 轮询 `pgrep -x` 直到为空才继续，5s 未退升级 `killall -9`，8s 极端兜底告警后继续；脚本末尾 open 前再调一次防御性确认（用 `SECONDS` 计真实秒数，已实测三场景）。

### 22. build.sh / Info.plist 零散问题 🟡 一项随迁移消除，其余仍在

- ✅ **python3 浅合并风险消除**：根目录 config 字段级合并逻辑已随配置迁移整体删除；**2026-08-20（`bcd8de4`）根目录 `config.json` 文件本身也移除**，配置唯一权威 = Application Support；
- ✅ **`--release` 模式**：默认 `-Onone` 快速编译，`./build.sh --release` 用 `-O`（正式分发用）；
- ✅ fonts 拷贝带 `|| true` 容错（`bcd8de4` 随 DepartureMono 入库补上）；
- ❌ `cp "$CONFIG"`（现 `build.sh:124`）与 `cp icons/*.svg`（`:127`）仍无容错：文件缺失时脚本中断且报错不友好；
- ❌ `find -maxdepth 2`（现 `build.sh:23`）：Services 下再嵌套子目录会静默漏编 → 放宽或去限制；
- ❌ `.build_state` 读写无并发保护，同时两个构建互相覆盖计数（影响小）；
- ❌ `codesign` 后无 `--verify` 自检（现 `build.sh:145-150`）；
- ❌ Info.plist 仍缺：`LSApplicationCategoryType`、`CFBundleDevelopmentRegion`（zh_CN）、`NSHumanReadableCopyright`。

### 23. 仓库卫生 ✅ 大部分关闭（2026-08-19 `f47bd36` 落库 + 后续清理）

- ✅ **此前 9 个文件未提交改动已全部落库**（`f47bd36`：配置迁移 + Codex 切号 + 操作区打磨，含 `docs/card-drag-framework.md` 入库），此后每日均有提交，当前工作区干净、与 origin/main 同步；
- ✅ **AGENT.md 千问残留清理**：功能列表、源码树、文件职责表的千问描述已删，仅保留「已下线」说明性条目；配置权威口径同步为 Application Support；
- ✅ demo/ 玻璃背景原型及编译产物、`.reasonix` 本地工作状态、`swift-tools/` 均已移出版本控制；README 新增（项目概述 / 构建 / 数据位置）；
- ✅ `swift/.build/` 已忽略；CHANGELOG.md 删除已落账；`backups/` 整目录忽略（见 #1）；
- ⚠️ 仅剩一处漂移：todo.md 第 2 项「菜单栏平台品牌 icon」实际已实现（`attachIcon`，现 `main.swift:2135`，品牌图标烘焙进 template 位图，`docs/menubar-template-pitfalls.md` 记录踩坑），复选框仍未勾——勾掉即可；
- ❌ #1 凭据轮换依旧未做（见 #1）。

---

## 七、建议的落地顺序（2026-08-22 修订）

| 顺序 | 事项 | 理由 |
| --- | --- | --- |
| 1 | #1 轮换 DeepSeek Key + config.example.json | 凭据已进 git 历史，先止损；零成本 |
| 2 | #7 网络错误分类 | 数据可信度的另一半；Codex 接入后 401 引导重新采集需求更实 |
| 3 | #9 Config 失败保护 | 「出问题才知道疼」的静默失败；配置字段越多暴露面越大 |
| 4 | #10 签到历史 decode 防覆盖 + 手动签到可取消 | 历史已有 UI，数据丢失从隐患变可见事故 |
| 5 | #14 拆分（含 UsagePanel/PinWindow 新候选） | ✅ 已完成（2026-08-24）：main 4102→2177 / Panel 6024→1847，新增 8 文件，见 #14 |
| 6 | #2 Keychain 迁移（二期） | 权限已收紧，明文债择机还 |
| 7 | #18 剩余低余额告警 + #17 空态引导 | 用量板块地基已打好，告警是顺路活 |
| 8 | #20 探测兼容 + #22 build.sh/Info.plist 收尾 + #19 UI 细节 | 锦上添花，择机 |

---

## 附录 A：上上轮（2026-08-11）建议完成情况

| 旧编号 | 事项 | 状态 |
| --- | --- | --- |
| #1-#9 | 拆模块、Codable、async/await、去重、死代码清理、文档一致性、数据竞争、网络重试/离线感知、TCC 判断 | ✅ 已实施（2026-08-11） |
| #10 | 千问 SEC_TOKEN 正则脆弱 | ✅ 已随千问平台下线失效（2026-08-17） |
| #11 | Timer App Nap 漂移 | ❌ 未做（本轮 #10 收编） |
| #12 | 凭据迁移 Keychain | ❌ 未做（本轮 #2，升级为 🔴 并补充文件权限问题） |
| #13 | Edge 多 profile | ✅ 已随千问平台下线失效（2026-08-17） |
| #14 | 菜单栏状态可见性 | 🟡 离线标记已做；服务失败可见性未做（本轮 #4） |
| #15 | 用量历史与趋势 | ✅ 日/周用量板块已上线（2026-08-19~21，本轮 #18）；低余额告警未做 |
| #16 | 千问 5h 额度展示 | ✅ 已关闭：千问平台已整体下线（2026-08-17） |
| #17 | 开机自启动 | ❌ 未做 |
| #18 | 设置收纳子菜单 | ⏸ 已被面板 UI 取代，主菜单仅剩兜底入口，建议关闭 |
| #19 | 刷新间隔档位 | ✅ 已做（1/3/5 分钟） |
| #20 | 多 DeepSeek 账号 | ❌ 未做 |
| #21 | build.sh 保护 config.json | ✅ 已做（字段级合并；2026-08-18 随配置迁移整体移除，2026-08-20 根 config.json 文件本身也删除，问题彻底消除） |
| #22 | 版本号自动递增 | ✅ 已做（日期 + .build_state） |
| #23 | 基础测试 | ❌ 未做，解密链路 fixture 验证仍值得做 |

## 附录 B：2026-08-15 → 08-17 轮完成情况

| 编号 | 事项 | 状态 |
| --- | --- | --- |
| #3 | /tmp 日志四份实现合并 | ✅ Logger.swift 统一日志器（加固项用户明确搁置） |
| #5 | performRefresh 去重 + 取消 | ✅ refreshTask + Task.isCancelled 协作守卫 |
| #4 | 刷新失败静默 | ✅ footer「更新于」后追加「· xx 刷新失败」标记（failedServices，未配置不计） |
| #8 | 进程切号链路 | ✅ 第二批补齐：bundle id 精确匹配 + kill(pid,0) 判活 + 失败回滚通知（v2026.8.17.19-22） |
| #13 | Formatter/图标每次新建 | ✅ static 缓存全套（NumberFormatter / DateFormatter / Logger 时间戳 / 状态栏图标） |
| #15 | UDKey 收口 | ✅ 全部 key 收敛进 enum UDKey；Links、panelWidth、魔法数字仍待做 |
| #16 | 签到/采集进行中反馈 | ✅ ActionTileButton 脉冲 + 禁点；签到/TRAE 采集磁贴接入（v2026.8.17.24） |
| #6 | NetworkMonitor 主线程 | ✅ @MainActor + Task hop |
| #10 | OAuth 轮询取消 | ✅ isCancelled 主动检查 |
| #11 | Trae/WB 220 行重复 | 🟡 进程链路 + 日志已抽 ProcessUtil/Logger；headers 等小重复待收口 |
| #12 | 多号卡片复制粘贴 | ✅ 三平台合一 AccountCardSnapshot + CardStyle |
| 四 | 死代码清理约 -300 行 | ✅ ponytail 两轮 6460→6032（净 -428，含签到历史接 UI 新增 ~60 行） |
| #23 | 仓库卫生 | ✅ 源码文档全提交、.build 忽略、CHANGELOG 删除落账 |
| （新增事实） | ZCode 平台接入 | ℹ️ 凭据类型 +1（明文 JWT），已并入 #2 描述 |

## 附录 C：2026-08-17 → 08-19 轮完成情况（v2026.8.18.x → v2026.8.19.6，已于 `f47bd36` 落库）

| 事项 | 状态 |
| --- | --- |
| 配置/缓存迁移 Application Support | ✅ `AppDataStore`：目录 700 / 文件 600 / 原子写、旧文件迁移留副本、build.sh 移除根 config 合并（#2 权限项关闭，#9 路径项关闭） |
| Codex 平台 | ✅ 余额接入 + 千问下线（`67eeb0e`）；切号 + refresh/idToken 采集 + 权限保留写 auth.json + 失败回滚（`f47bd36`） |
| performAccountSwitch 统一切号编排 | ✅ 四平台（TRAE/WB/ZCode/Codex）共用，重复编排代码删除（#11 再进一步） |
| 平台卡片拖拽排序 | ✅ 幽灵卡片截图（保留 hover 外观）/ Y 轴让位动画 / drop highlight / hover 锁定 / reduce-motion 直落 / 光标栈异常恢复；`UDKey.balancePlatformOrder` 持久化；菜单栏条目顺序共享同一排序；`docs/card-drag-framework.md` 框架文档 |
| DeepSeekSettingsDialog | ✅ API Key + 日常额度合并为一弹窗（带 api_keys 链接），磁贴合并为「Key / 额度」，`onSetDsQuota` 移除 |
| 签到结果弹窗 SF Symbol 信息行 | ✅ `CheckinInfoItem`（checkmark.seal/flame/gift）+ 预渲染灰色规避 NSTextAttachment 色偏 |
| 多账号刷新即时菜单栏同步 | ✅ 各服务非当前账号写回即 `updateTitle()`，轮末统一补一次（refreshTask 在 MainActor，线程安全） |
| 面板视觉微调 | ✅ 背景渐变起点固定、icon 缩放口径统一、昵称单行省略、平台标题压缩抵抗 required、行高修正 |
| build.sh --release | ✅ 默认 -Onone / 分发 -O |
| build.sh 停机顺序 + 等待退出（#21） | ✅ 先停进程再删 bundle；SIGTERM + 1.0s + pgrep 轮询 + 5s 升级 SIGKILL，open 前防御性复查 |
| 菜单栏平台品牌图标 | ℹ️ 已实现（attachIcon + template 位图烘焙，`docs/menubar-template-pitfalls.md`），todo.md 第 2 项复选框至今未勾（#23 剩余项） |

## 附录 D：本轮（2026-08-19 → 08-22，`f47bd36` → `5687899`）完成情况

| 事项 | 提交 | 状态 |
| --- | --- | --- |
| #23 未提交改动落库 | `f47bd36` | ✅ 配置迁移 + Codex 切号 + 拖拽框架文档一并入库，工作区转干净 |
| AGENT.md 千问残留清理 | `f47bd36` | ✅ 仅留「已下线」说明条目 |
| 日/周用量板块（#18 主体） | `fc11c9a` | ✅ 本地差值 UsageStore + 面板「用量」分组 + todo 第 3 项全勾 |
| 用量板块视觉细化 + 根 config.json 移除 | `bcd8de4` | ✅ 配置唯一权威 = Application Support；DepartureMono 字体入库 |
| 用量历史重构（60 天） | `afe0f63` | ✅ 每日历史 + 跨天/跨周宽容值 + 平台级汇总 + debugUsageEnabled |
| macOS 26 适配 | `afe0f63` | ✅ QuietScrollView 双 EMA 平滑滚动、target 升 `arm64-apple-macos26`、`docs/macos-26-appkit-migration.md`（副作用见 #20 Intel 兼容） |
| 平台自动化开关 | `7e175f7` | ✅ 各平台独立刷新开关（deepseekRefreshEnabled 等）+ 弹窗对齐 |
| PanelWindow 重构尝试与回滚 | `14f4099`→`459e20a`→`74d2b80` | ⚠️ NSPopover→无边框窗口重构未完成即回滚恢复编译，最终简化布局并移除 popover 位置锁定；教训：大重构应分支进行 |
| 面板置顶浮窗 | `1793049` + `5687899` | ✅ pin 时 popover 内容转移至无边框 NSPanel（无箭头/浮层/自绘拖动）、unpin 预建下一轮零等待、浮窗尺寸持久化（floatingPanelWidth/Height）；origin 锁定恢复（顶边锚 + KVO + duration=0 拉回） |
| hover 取点修复 | `1793049` | ✅ 6 处同步取点改 NSEvent.mouseLocation + 零点防护；浮窗期间禁用计算式 hover 同步 |
| 死代码清理延续 | `1793049` | ✅ ASCII 点阵图标机制（AsciiIconProvider 等）整体删除；swift-tools/ 目录删除 |
| 字体方案 | `1793049`→`5687899` | ℹ️ DepartureMono ↔ SF Mono 反复调整，HEAD 余额卡片回 DepartureMono（cascade 回退），pixelFont 保留给字符控件 |
| Logger 扩展 | `bcd8de4` | ℹ️ 新增 refresh/network/layout 频道 + measure/measureSync 性能打点（#3 脱敏需求上升） |
| backups 整目录 gitignore | `949aad3` | ✅ 含凭据的历史备份彻底出库（#1 补强） |
| README 新增 | `6e838e6` | ✅ 项目概述 / 构建 / 数据位置（缺系统要求标注，见 #20） |
| 杂项清理 | `d5fc348`/`7595547`/`16065ac` | ✅ .reasonix 出库、demo/ 原型及编译产物清除 |
| Codex 卡片图标 | `1793049` | ℹ️ 替换为 OpenAI 花瓣结图案（openai.svg 原件入库） |
</file_content>
<task_progress>
- [x] 查看 git 历史，确认 2026-08-19 后的提交
- [x] 核对未提交改动与工作区状态
- [x] 抽查关键项（#23 提交、AGENT.md、行号引用等）现状
- [x] 更新 IMPROVEMENTS.md
- [ ] 校验文档一致性
</task_progress>
</write_to_file>