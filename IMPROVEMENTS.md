# iBalance 改进优化建议

> 初稿基于 2026-08-15 全项目走查；**2026-08-17 逐项复核**；**2026-08-19 再次逐项复核**（覆盖其后的：配置/缓存迁移 Application Support、Codex 余额接入（已提交）+ 切号（未提交）、千问平台下线（已提交）、平台卡片拖拽排序、切号编排统一、DeepSeek 设置弹窗合并、面板视觉微调等；`swift/` 现 12 个源文件共 **7707** 行，其中 main.swift 3008 / Panel.swift 2789，忽略 `backups/` 与 `cockpit-tools-main/`）。
> ⚠️ **2026-08-18/19 一轮改动（配置迁移、拖拽排序、Codex 切号等 9 个文件）尚未提交**，见 #23。
> 每项标注当前状态：✅ 已完成 / 🟡 部分完成 / ❌ 未动；已完成项正文压缩为结论，细节见文末附录 B / C。
> 优先级标注：🔴 高（建议尽快做）/ 🟡 中（有价值，择机做）/ 🟢 低（锦上添花）

---

## 一、安全与凭据 🔴

### 1. `swift/config.json` 含真实凭据，且**已提交进 git 历史** 🔴 🟡 已移出跟踪，轮换未做

已做（2026-08-17）：`swift/config.json` 加入 .gitignore（注释同步修正），`git rm --cached` 移除跟踪并推送——云端 HEAD 不再有该文件，本地文件保留（build.sh 继续用作打包源）；`backups/` 内含凭据的 config.json 副本也已移出版本控制。

仍未做：

- **轮换 DeepSeek API Key**：`1f7e285` 与 `666eb3e` 两个历史提交里仍含真实 Key/token，仅移出跟踪不改变历史。私密单人仓库暴露面有限，但仓库转公开前必须先 `git filter-repo` 重写历史 + force push；
- 本地 `swift/config.json` 仍是真实凭据（有意保留作打包源）；若未来需要「clone 即可构建」，补一份 `config.example.json` 空模板 + build.sh 缺文件容错（#22）。

### 2. 凭据明文落盘 🔴 🟡（权限已收紧 ✅，Keychain 仍未做）

2026-08-18 配置/缓存迁移到 `~/Library/Application Support/com.local.ibalance/`（`Config.swift` 新增 `AppDataStore`）：目录权限 700（`prepareDirectory`），`secureWrite` 原子写入 + 文件权限 600（实测 `drwx------` / `-rw-------` 已生效）；首次启动自动迁移旧版 `.app` 同目录文件并**保留旧文件副本**可回退。但 token 仍以明文 JSON 保存，尚未迁移 Keychain。涉及凭据已增至 **5 类**：DeepSeek Key、WorkBuddy token/refreshToken、TRAE 加密 authInfo、ZCode 明文 JWT（随 zcodeAccounts 存 config，切号时还要写 credentials.json 三键）、**Codex access/refresh/idToken**（本轮新增，随 codexAccounts 存 config；切号时另写外部 `~/.codex/auth.json`）。千问平台已于 2026-08-17 整体下线。

建议：

- token 类迁移 Keychain（`SecItemAdd` / `kSecClassGenericPassword`），config.json 只留非敏感设置；Codex 凭据迁移后切号写 auth.json 的逻辑不受影响（数据源换成 Keychain 读取即可）。

### 3. `/tmp` 日志无条件 dump 签到接口完整响应体 🟡 部分（加固项已明确搁置）

✅ 已完成：四份私有 appendLog 合并为 `Logger.swift` 统一日志器（`Logger.log(.switchAccount/.traeCheckin, ...)`）。
⏸ 搁置中：权限、脱敏、轮转、`~/Library/Logs/` 迁移与 symlink 防护——**2026-08-17 用户明确决定暂不修复**（安全债记录在案，此项不再重复催办）。若日后重启：`Logger.swift` 先 `fileExists` 再追加的写法顺带挡住了预创建 symlink 的部分风险。

---

## 二、健壮性

### 4. 刷新失败完全静默，「更新于」时间照常刷新 🔴 ✅ 已完成（2026-08-17，v2026.8.17.19）

采用 **footer 方案**：`main.swift` 的 `failedServices: Set<String>` 由各 `refreshOne*` 在失败/成功分支维护；footer「更新于 HH:mm:ss」后追加显示（如「更新于 12:30:15 · TRAE、ZCode 刷新失败」）。关键口径：未配置不计失败；多号服务任一账号失败即标记整服务；取消导致的提前 return 不写状态。本轮未变动。

### 5. performRefresh 无去重、无取消 ✅ 已完成（2026-08-15）

`refreshTask` 先 `cancel()` 旧任务再起新任务；`performRefresh` 与各 `refreshOne*` 在写缓存点加了 `Task.isCancelled` 协作式守卫。

### 6. NetworkMonitor 回调不在主线程 ✅ 已完成

`NetworkMonitor` 标为 `@MainActor`，`pathUpdateHandler` 通过 `Task { @MainActor in ... }` 回主线程。

### 7. 网络层把所有错误压成 `(nil, 0)`，401 与超时不可区分 🔴 ❌

`Network.swift` 未变：超时/DNS/连接拒绝/任务取消全部变成 status 0。后果不变：

- token 过期（401）与网络抖动在 UI 上都是同一种「获取失败」，无法引导用户重新采集（Codex 接入后 access token 过期场景更多，此项价值上升）；
- `requestWithRetry` 对「离线」「已取消」也照样 backoff 重试。

建议：`HTTP.request` 返回 `Result<Data, NetworkError>`（`.timeout / .offline / .http(Int, Data) / .cancelled`），401 单独处理并触发「请重新采集账号」提示；顺带统一默认 timeout 常量（当前 10/15 散传）。

### 8. 进程切号链路 ✅ 已完成（2026-08-17 两批 + 2026-08-19 Codex 接入）

已具备：bundle id 精确匹配（`ProcessUtil.mainPids(bundleId:)`，Electron helper 天然排除）、`kill(pid, 0)` 判活、失败回滚 + 通知。

本轮（2026-08-18/19）新增：

- **Codex 切号接入**（`CodexService.switchAccount`）：杀 `com.openai.codex` → `JSONSerialization` 字段级更新 `~/.codex/auth.json` 的 tokens（空 refresh/id token 时 `removeValue`，避免续期时串回原账号）→ 原子写入并**保留原文件权限** → `open -n -a Codex`；读/序列化/写入任一失败均重启恢复原账号并返回 false；
- **切号编排统一**：main.swift 新增 `performAccountSwitch(serviceName:failureMessage:action:)`，TRAE / WorkBuddy / ZCode / Codex 四平台共用同一套「后台执行 → 失败通知 / 成功 syncPanel+onRefresh → 0.6s 关面板」编排，原先四份复制粘贴的线程切换与收尾代码删除；
- 采集侧同步升级：Codex 账号采集现在一并读取 `refresh_token` / `id_token`（`CodexAccount` 新增两字段，旧配置缺省为空仍兼容），保证切号后登录态完整。

### 9. Config 解析失败静默回退默认值，随后 save 覆盖用户全部配置 🔴 ❌

`Config.swift`：decode 用 `try?` 静默回退默认值，下一次 `save` 就用默认值覆盖用户配置；`secureWrite` 写入失败（磁盘满 / Application Support 不可写）也只 `return` 无任何反馈。配置路径迁移已完成（数据在用户目录，App 更新不再触碰），但解析/保存错误处理仍待补强——**注意新风险**：迁移后首次加载若 decode 失败，`shouldPersist` 路径会把默认值直接落盘到 Application Support，覆盖迁移副本的时机提前了。

建议：解析失败时保留原文件改名 `.bak` 并通过 UI 告知；save 返回结果并在失败时提示。

### 10. 零散健壮性问题 🟡 两项已缓解，四项仍在

- ❌ 签到历史 decode 失败返回 `[]`，`appendCheckinHistory` 随即用空数组覆盖旧 key（现 `main.swift:2965-2981`）——历史已接 UI（「签到历史」磁贴弹窗），解码失败即用户可见的历史全清；
- ❌ 三处 `Timer.scheduledTimer(target:)`（现 `main.swift:641/1180/2835`）强引用 target 且 terminate 时不 invalidate；建议 block-based timer（App Nap 漂移一并解决，或监听唤醒通知补刷新）；
- ❌ `openApplication` completion `{ _, _ in }`（现 `main.swift:2757`）启动失败无提示；各 `UNUserNotificationCenter.add` 回调同样全静默；
- ❌ 手动签到 Task 不可取消，若挂起则 `manualCheckinInProgress`（现 `main.swift:2129-2195`）永久为 true，签到按钮从此失灵且无提示；
- ✅ OAuth 轮询取消已修：轮询循环每轮主动检查取消，1.5s 内退出；
- 🟡 refresh 接口 `expiresAt`：已补多字段名 + `expiresIn` 相对值兜底，毫秒/秒归一化仍无（服务端若返回毫秒仍会算错），风险较低，观察即可。

---

## 三、代码质量

### 11. Trae.swift ↔ WorkBuddy.swift 重复 🟡 大头已消灭，本轮再进一步

✅ 进程管理链路已抽 `ProcessUtil.swift` + `Logger.swift`；本轮切号编排又收敛为 `performAccountSwitch` 单入口（四平台共享，连 Codex 接入也只写了平台特定的凭据写入）。
❌ 剩余小型重复：headers 构造（TRAE/WB 各 3-4 处重复）未收口成 `traeHeaders(token:)` / `wbHeaders(token:uid:)`；签到解析的「尝试 N 种字段名」模式仍是各写各的。

### 12. Panel.swift 多号卡片复制粘贴 ✅ 已完成（三平台 → 四平台合一）

WB/TRAE/ZCode/**Codex** 共用 `AccountCardSnapshot` + `CardStyle`（本轮 CardStyle 新增 `platformID`，供拖拽排序与 icon 缩放口径使用）+ 通用 `rebuildAccountCards` / `applyAccountCardData`，各平台只留薄封装。

### 13. 性能：Formatter 与图标每次新建 ✅ 已完成（2026-08-17）

`fmtAmountCommas` 复用 static `commaFormatter`；main.swift 7 处 DateFormatter 收敛为 static 缓存；Logger 时间戳 formatter 缓存；状态栏图标 lazy 缓存。弹窗/菜单等冷路径图标仍按需创建（频率低）。

### 14. main.swift（3008 行）/ Panel.swift（2789 行）继续拆分 🟡 ❌（持续膨胀，优先级上升）

两个大文件本轮分别 +500 / +800 行。按 MARK 拆（build.sh 自动收集 *.swift，零成本）：

- `CheckinManager.swift` ← 签到域：错峰签到（60s 轮询 + 每号随机就绪时刻）、手动签到编排、签到历史、streak 工具（main.swift 里最大的一块，约 700 行）；
- `AccountSwitcher.swift` ← TRAE 采集 + `performAccountSwitch` + 四平台切号入口（main.swift:2720-2830 一带）；
- `Dialogs.swift` ← DialogShell / InputDialog / DeepSeekSettingsDialog / 各业务弹窗；
- `Controls.swift` ← Panel.swift 前半的自绘控件（HoverCard / ActionTileButton / 点阵 / MiniSwitch 等，约 700 行且自包含）；
- **新增**：`PanelDrag.swift` ← 本轮拖拽排序框架（BalancePanelView 内约 300 行：拖动状态机、幽灵卡片、重排动画、drop highlight，Panel.swift:1483「平台卡片排序」MARK 下整体自包含）+ HoverCard 的 drag 扩展，可与 `docs/card-drag-framework.md` 一起入库。

### 15. 硬编码与常量收口 🟡 UDKey 持续收口，其余未做

- ✅ **UDKey 收口（持续）**：2026-08-17 全部 UserDefaults key 收敛进 `enum UDKey`；本轮新增 `UDKey.balancePlatformOrder`（拖拽排序持久化），`forKey: "..."` 字面量仍为零；
- ❌ URL / bundle id 仍散落（`platform.deepseek.com/usage`、`com.openai.codex` 在 main.swift/Codex.swift 各出现等）→ 收进 `enum Links` / 配置；
- 🟡 **面板宽度**：仍是四处散落字面量且数值本轮又有漂移（头注释 245 / preferredContentSize 247 / 视图内在宽 250 / root 内容宽 236）→ 单一 `panelWidth` 常量；
- ❌ 魔法数字（0.6s 延时关面板、0.8s/1.0s 杀进程超时、600s OAuth、90 天历史、3pt 拖拽阈值、0.18/0.4/0.88/0.96 拖拽透明度等）→ 命名常量。

---

## 四、死代码清理 ✅ 已完成（2026-08-16 ponytail 两轮，6460→6032 净 -428）

- Panel.swift：`UsageBar` / `UsageRing` / `animateFillColor` / `setInfoHighlighted` 死链 / PanelSnapshot 11 个死字段及赋值块 / `onToggleQwDecimals`，全部删除；
- **签到历史已接 UI**：「签到历史」磁贴 + 弹窗，原「只写不读」问题关闭；
- ProcessUtil 进程工具去重、卡片合并（→ #8/#11/#12）。

本轮补充：千问平台已整体下线（HEAD `b412c0e`），`Qianwen.swift` 已删除；本轮「配置Key」「日常额度」两个磁贴合并为一个「Key / 额度」（`DsQuotaDialog` → `DeepSeekSettingsDialog`，`onSetDsQuota` 回调与磁贴一并移除）。`docs/CheckinResultPanelController.swift` 为有意存档（头部注明不参与编译），不计死代码。

仅剩两个 P1 小项：`Palette` 旧名别名（`kBalanceForeground` 等三个，机械改名 diff 广）、`WorkBuddy.authInfo` 的 NSLock（调用方全在 @MainActor，锁无必要）。

---

## 五、功能增强

### 16. 手动签到 / 账号采集的进行中反馈 🔴 ✅ 已完成（2026-08-17，v2026.8.17.24）

`ActionTileButton.setInProgress(_:)` 呼吸脉冲 + 禁点；手动签到与 TRAE 采集磁贴均已接入。本轮签到结果弹窗又升级为 SF Symbol 信息行（`CheckinInfoItem`：checkmark.seal / flame / gift，显式预渲染成统一灰色，规避 NSTextAttachment 不继承前景色的问题）。

### 17. 空态与错误态引导 🟡 ❌

- TRAE/WB/ZCode/Codex 无任何账号时整个卡片区块消失（容器默认隐藏是有意设计），没有「先采集账号」的引导卡；
- 非当前账号首查未回显示 "—"，与「无法获取」不可区分。

### 18. 用量历史与低余额告警 🟡 ❌（仍未做，需求已被 todo.md 正式化）

每次刷新把各服务余额快照追加到本地（JSONL/SQLite），即可做「今日已消耗 / 较昨日」、7 日 sparkline、低余额通知（阈值可配置）。todo.md 第 3 项「日/周用量板块」已把该需求正式化（面板用量分组 + 各 Service 用量 API + 本地快照累计），与本平台「快照存本地 + UI 读取」的既有模式（签到历史）同源，可复用。配额告警与企业账号余额两需求待拍板。

### 19. 其余 UI 细节 🟢 ❌（行号随本轮改动漂移）

- `valueLabel` 固定宽 + `byClipping`（现 `Panel.swift:2581`）：大额 `¥12,345.67` 会被硬裁 → `.byTruncatingHead` 或放宽约束；
- `switchRow` 整行加 NSClickGestureRecognizer 而 NSSwitch 本身也响应点击（现 `Panel.swift:2719`），可能双触发 → 手势识别器忽略落在 switch 上的点击；
- HoverCard/ActionTileButton 自绘 mouseUp，无 `accessibilityRole = .button` / label（全项目 0 处），VoiceOver 不可用（拖拽排序全程鼠标驱动，键盘替代方案也无）；
- `hideWbNickname` 仍反向语义存储 + 取反切换（现 `main.swift:1196`）→ 快照直接存 `showNickname` 正向语义。

本轮已顺手修掉的相邻问题：平台标题 compression resistance 提升为 required + 昵称单行省略（长昵称不再挤压金额）；行高 14→16 修复 12pt 字形下沿裁切。

### 20. 探测与兼容性 🟢 ❌

- `detectTraeStoragePath`（现 `Config.swift:324`）仍按目录名前缀 "trae" 模糊匹配取 sorted 第一个：同时装 TRAE 与 TRAE SOLO CN 时静默选错且用户无法干预 → 返回候选列表供选择；
- WorkBuddy 认证路径仍硬编码（`WorkBuddy.swift:17`，CodeBuddyExtension 路径）→ 对齐 traeStoragePath 做成可配置 + 自动探测；
- 仍只构建 arm64（build.sh `-target arm64-apple-macos12`）：Intel Mac 无法运行且无提示 → 至少 README 标注，或双架构。

---

## 六、构建与仓库健康

### 21. build.sh 自动重启不等待旧进程退出；删 bundle 早于杀进程 🔴 ✅ 已完成（2026-08-19）

两处均已修：停机逻辑移到「组装 .app bundle」之前（先停进程再 `rm -rf`）；`killall`（SIGTERM）后 `sleep 1.0` 优雅退出，随后 `wait_iBalance_exit` 每 0.1s 轮询 `pgrep -x` 直到为空才继续，5s 未退升级 `killall -9`，8s 极端兜底告警后继续；脚本末尾 open 前再调一次防御性确认（用 `SECONDS` 计真实秒数，不依赖循环次数，已实测三场景：TERM 即退 1s / 忽略 TERM 6s 内 SIGKILL / 无进程直接通过）。

### 22. build.sh / Info.plist 零散问题 🟡 一项随迁移消除，新增 --release

- ✅ **python3 浅合并风险消除**：根目录 config 字段级合并逻辑已随配置迁移整体删除（build.sh 不再触碰用户配置）；
- ✅ **新增 `--release` 模式**：默认 `-Onone` 快速编译，`./build.sh --release` 用 `-O`（正式分发用）；
- ❌ `cp "$CONFIG"` 与 `cp icons/*.svg` 无容错：文件缺失时脚本中断且报错不友好（对比 png/pdf 行有 `|| true`）；
- ❌ `find -maxdepth 2`：Services 下再嵌套子目录会静默漏编（当前恰好靠 maxdepth 2 覆盖 Services/）→ 放宽或去限制；
- ❌ `.build_state` 读写无并发保护，同时两个构建互相覆盖计数（影响小）；
- ❌ `codesign` 后无 `--verify` 自检；
- ❌ Info.plist 仍缺：`LSApplicationCategoryType`、`CFBundleDevelopmentRegion`（zh_CN）、`NSHumanReadableCopyright`。

### 23. 仓库卫生 ⚠️ 回退（本轮大量改动未提交 + 文档漂移）

- ❌ **9 个文件已修改未提交**（Config/Panel/Codex/main/build.sh + 四份文档），`docs/card-drag-framework.md` 未跟踪——配置迁移、拖拽排序、Codex 切号整套功能只存在于工作区，一次误操作即丢；建议尽快分批提交（迁移一笔、拖拽一笔、Codex 一笔）；
- ❌ **AGENT.md 文档漂移**：千问平台已下线，但 AGENT.md 仍有 3 处千问描述（功能列表第 11 行、源码树 `Qianwen.swift`、文件职责表）未清理；「关键陷阱 #1」与配置优先级段落已更新为 Application Support 口径；
- ⚠️ todo.md 第 2 项「菜单栏平台品牌 icon」实际已实现（`attachIcon` + 品牌图标烘焙进 template 位图，`docs/menubar-template-pitfalls.md` 记录了踩坑），但复选框仍未勾；
- ✅ `swift/.build/` 已忽略；CHANGELOG.md 删除已落账；#1 凭据问题依旧（见 #1）。

---

## 七、建议的落地顺序（2026-08-19 修订）

| 顺序 | 事项 | 理由 |
| --- | --- | --- |
| 1 | #23 分批提交当前改动 + AGENT.md 千问残留清理 | 大特性整套未落库，文档漂移会误导下次编辑，零成本先做 |
| 2 | #1 轮换 DeepSeek Key + config.example.json | 凭据已进 git 历史，先止损 |
| 3 | #7 网络错误分类 | 数据可信度的另一半；Codex 接入后 401 引导重新采集需求更实 |
| 4 | #9 Config 失败保护 + #21 build.sh 重启修复 | 都是「出问题才知道疼」的静默失败 |
| 5 | #10 签到历史 decode 防覆盖 + 手动签到可取消 | 历史已有 UI，数据丢失从隐患变可见事故 |
| 6 | #2 Keychain 迁移（二期） | 权限已收紧，明文债择机还 |
| 7 | #17 空态、#18 用量历史（与 todo.md 日/周用量同源） | 体验增强，按需 |
| 8 | #14 拆分（含 PanelDrag.swift）+ #15 剩余收口 | 纯整洁度，但两文件已近 3000 行，越晚越贵 |

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
| #15 | 用量历史与趋势 | ❌ 未做（本轮 #18） |
| #16 | 千问 5h 额度展示 | ✅ 已关闭：千问平台已整体下线（2026-08-17） |
| #17 | 开机自启动 | ❌ 未做 |
| #18 | 设置收纳子菜单 | ⏸ 已被面板 UI 取代，主菜单仅剩兜底入口，建议关闭 |
| #19 | 刷新间隔档位 | ✅ 已做（1/3/5 分钟） |
| #20 | 多 DeepSeek 账号 | ❌ 未做 |
| #21 | build.sh 保护 config.json | ✅ 已做（字段级合并；2026-08-18 随配置迁移整体移除，问题消除） |
| #22 | 版本号自动递增 | ✅ 已做（日期 + .build_state） |
| #23 | 基础测试 | ❌ 未做，解密链路 fixture 验证仍值得做 |

## 附录 B：2026-08-15 → 08-17 轮完成情况

| 编号 | 事项 | 状态 |
| --- | --- | --- |
| #3 | /tmp 日志四份实现合并 | ✅ Logger.swift 统一日志器（加固项用户明确搁置） |
| #5 | performRefresh 去重 + 取消 | ✅ refreshTask + Task.isCancelled 协作守卫 |
| #4 | 刷新失败静默 | ✅ footer「更新于」后追加「· xx 刷新失败」标记（failedServices，未配置不计） |
| #8 | 进程切号链路 | ✅ 第二批补齐：bundle id 精确匹配 + kill(pid,0) 判活 + 失败回滚通知（v2026.8.17.19-22） |
| #13 | Formatter/图标每次新建 | ✅ static 缓存全套（NumberFormatter / 5 个 DateFormatter / Logger 时间戳 / 状态栏图标） |
| #15 | UDKey 收口 | ✅ 17 个 key / 约 64 处调用收敛进 enum UDKey；Links、panelWidth、魔法数字仍待做 |
| #16 | 签到/采集进行中反馈 | ✅ ActionTileButton 脉冲 + 禁点；签到/TRAE 采集磁贴接入（v2026.8.17.24） |
| #6 | NetworkMonitor 主线程 | ✅ @MainActor + Task hop |
| #10 | OAuth 轮询取消 | ✅ isCancelled 主动检查 |
| #11 | Trae/WB 220 行重复 | 🟡 进程链路 + 日志已抽 ProcessUtil/Logger；headers 等小重复待收口 |
| #12 | 多号卡片复制粘贴 | ✅ 三平台合一 AccountCardSnapshot + CardStyle |
| 四 | 死代码清理约 -300 行 | ✅ ponytail 两轮 6460→6032（净 -428，含签到历史接 UI 新增 ~60 行） |
| #23 | 仓库卫生 | ✅ 源码文档全提交、.build 忽略、CHANGELOG 删除落账 |
| （新增事实） | ZCode 平台接入 | ℹ️ 凭据类型 +1（明文 JWT），已并入 #2 描述 |

## 附录 C：本轮（2026-08-17 → 08-19，v2026.8.18.x → v2026.8.19.6，**大部分未提交**）完成情况

| 事项 | 状态 |
| --- | --- |
| 配置/缓存迁移 Application Support | ✅ `AppDataStore`：目录 700 / 文件 600 / 原子写、旧文件迁移留副本、build.sh 移除根 config 合并（#2 权限项关闭，#9 路径项关闭） |
| Codex 平台 | ✅ 余额接入 + 千问下线（已提交 `b412c0e`）；切号 + refresh/idToken 采集 + 权限保留写 auth.json + 失败回滚（未提交） |
| performAccountSwitch 统一切号编排 | ✅ 四平台（TRAE/WB/ZCode/Codex）共用，重复编排代码删除（#11 再进一步） |
| 平台卡片拖拽排序 | ✅ 幽灵卡片截图（保留 hover 外观）/ Y 轴让位动画 / drop highlight / hover 锁定 / reduce-motion 直落 / 光标栈异常恢复；`UDKey.balancePlatformOrder` 持久化；菜单栏条目顺序共享同一排序；`docs/card-drag-framework.md` 框架文档（未跟踪） |
| DeepSeekSettingsDialog | ✅ API Key + 日常额度合并为一弹窗（带 api_keys 链接），磁贴「配置Key」「日常额度」合并为「Key / 额度」，`onSetDsQuota` 移除 |
| 签到结果弹窗 SF Symbol 信息行 | ✅ `CheckinInfoItem`（checkmark.seal/flame/gift）+ 预渲染灰色规避 NSTextAttachment 色偏 |
| 多账号刷新即时菜单栏同步 | ✅ 各服务非当前账号写回即 `updateTitle()`，轮末统一补一次（refreshTask 在 MainActor，线程安全） |
| 面板视觉微调 | ✅ 背景渐变起点固定 300pt（不再依赖余额区底边）、Codex/ZCode icon 缩放口径统一（-5%）、昵称单行省略、平台标题压缩抵抗 required、行高 14→16 |
| build.sh --release | ✅ 默认 -Onone / 分发 -O |
| build.sh 停机顺序 + 等待退出（#21） | ✅ 先停进程再删 bundle；SIGTERM + 1.0s + pgrep 轮询 + 5s 升级 SIGKILL，open 前防御性复查 |
| 菜单栏平台品牌图标 | ℹ️ 已实现（attachIcon + template 位图烘焙，`docs/menubar-template-pitfalls.md`），todo.md 第 2 项未勾 |
