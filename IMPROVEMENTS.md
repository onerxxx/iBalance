# iBalance 改进优化建议

> 基于 2026-08-11 对 `swift/main.swift`（约 1970 行）、`build.sh`、`AGENT.md` 的完整走查整理。
> 优先级标注：🔴 高（建议尽快做）/ 🟡 中（有价值，择机做）/ 🟢 低（锦上添花）

---

## 一、代码架构

### 1. 单文件已膨胀到近 2000 行，建议拆分模块 🟡 ✅ 已实施（2026-08-11）

AGENT.md 记录的还是「~1400 行」，实际已接近 2000 行。AppDelegate 一个类承担了 UI、配置、4 个服务的网络请求、加密解密、OAuth、签到调度全部职责，继续加功能会越来越难维护。

建议按现有 MARK 分区拆成独立文件（仍可用 `swiftc` 一次编译多个源文件，build.sh 里把 `$SRC` 换成 `*.swift` 即可）：

```
swift/
├── main.swift            # 入口 + AppDelegate（UI/菜单/定时器）
├── Config.swift          # AppConfig / WBAccount / loadConfig / saveConfig
├── Network.swift         # syncRequest / 重试 / 通用解析辅助
├── Services/
│   ├── DeepSeek.swift
│   ├── WorkBuddy.swift   # 余额 + 签到 + OAuth + token 刷新
│   ├── Trae.swift        # 积分 + 解密 + 签到
│   └── Qianwen.swift     # ticket 读取 + 网关查询
└── Crypto.swift          # sha512 / aesCbcDecrypt / PBKDF2
```

### 2. JSON 解析改用 Codable，消除大量手工字典解析 🔴 ✅ 已实施（2026-08-11）

全项目用 `JSONSerialization` + `as? [String: Any]` 逐层取值，同一种「Double/Int 双兼容」逻辑重复出现了 **6 处以上**（`expires_at`、`expiresIn`、`CycleCapacityRemain` 等）。典型如：

```swift
if let ea = d["expiresAt"] as? Double { expiresAt = ea }
else if let ea = d["expires_at"] as? Double { expiresAt = ea }
else if let ea = d["expiresAt"] as? Int { expiresAt = TimeInterval(ea) }
...
```

改为 `Codable` struct + 自定义 `init(from decoder:)`（或一个 `FlexibleDouble` 包装类型），配置和各 API 响应都能受益：解析错误更早暴露、字段重命名有编译期检查、代码量大约能减少 15–20%。

### 3. 并发模型现代化：semaphore 同步请求 → async/await 🟡 ✅ 已实施（2026-08-11）

`syncRequest()` 用 `DispatchSemaphore` 阻塞后台线程，再由调用方手工 `DispatchQueue.global().async` + `DispatchQueue.main.async` 回跳，嵌套层级深、容易漏主线程切换。macOS 12 起已支持 Swift Concurrency，而构建目标正好是 `macos12`，可以：

- `syncRequest` 改为 `async throws` 版本（`URLSession.data(for:)`）；
- `doRequest()` 里 4 个服务用 `async let` 并行，UI 更新天然在 `@MainActor` 上；
- WorkBuddy 的「失败 sleep 2 秒重试」改为 `try? await Task.sleep(nanoseconds:)`，不再阻塞线程。

顺带可修掉两个小问题：

- `syncRequest` 超时后 task 没有 `cancel()`，请求会继续在后台跑（轻微泄漏）；
- `wbOauthCollectAccount` 的轮询用 `Thread.sleep(1.5)`，同样可改为 async 循环。

### 4. 消除重复代码 🟡 ✅ 已实施（2026-08-11）

- `promptForApiKey()` 与 `promptForQianwenTicket()` 两函数 90% 相同（约 100 行重复），可抽一个通用的 `promptForInput(title:info:link:prefill:)`；
- `getTraeToken()` 与 `fetchTraeCredits()` 前半段（读 storage.json → base64 → 解密）完全重复，`fetchTraeCredits` 直接复用 `getTraeToken()` 即可；
- `fmtAmount` 与 `fmtAmountCommas` 的前半段类型解析逻辑重复，可共享一个 `toDouble(_ value: Any) -> Double?`。

### 5. 清理死代码与弃用字段 🟢 ✅ 已实施（2026-08-11）

- `onTraeCheckin()` / `showCheckinResult()` 手动签到逻辑保留但菜单已移除，确认不再需要就删掉（约 70 行）；
- `workbuddy_report_url`、`workbuddy_account`、`cockpit_url` 已弃用（记忆里也确认 report 接口不再使用），但 `loadConfig()`/`saveConfig()` 仍在读写，模板 config.json 里也还在，建议整体移除；
- `swift/config.json` 模板里 `workbuddy_accounts` 预置了一条 uid/token 全空的占位账号，建议改为空数组 `[]`，避免误导。

### 6. 修复文档与代码不一致 🟢 ✅ 已实施（2026-08-11）

AGENT.md 已有多处过时：

- 「~1400 行」→ 实际 ~1970 行；
- WorkBuddy 图标写的是 SF Symbol `basketball.fill`、千问 `cup.and.heat.waves.fill`，实际代码已换成 Unicode 字符 🆆 / 🅠；
- 外部依赖一节仍写「WorkBuddy 数据依赖 Cockpit Tools」，实际已直连 CodeBuddy API。

---

## 二、健壮性

### 7. 后台线程直接读写共享状态，存在数据竞争 🔴 ✅ 已实施（2026-08-11）

`config`（含 `workbuddyAccounts` 数组）和 `cacheDs/cacheWb/cacheTrae/cacheQw` 在多个后台队列与主线程间无保护地读写：

- `wbAutoCheckinIfNeeded()`（utility 队列）里 `refreshWbAccountToken` 会写 `config.workbuddyAccounts` 并调 `saveConfig()`；
- `onAddWbAccount`（userInitiated 队列）也在写同一数组；
- `updateTitle()`（主线程）同时在读各 cache。

当前是单写者场景居多所以没爆雷，但 OAuth 采集与整点签到并发时可能互相覆盖 config。建议：所有 config 变更收敛到主线程，或加一个串行 `DispatchQueue(label: "config")` 保护读写（迁 async/await 后用 actor 更自然）。

### 8. 网络层缺少统一错误处理与离线感知 🟡 ✅ 已实施（2026-08-11）

- 只有 WorkBuddy 有一次「sleep 2 秒重试」，DeepSeek / TRAE / 千问失败即静默（仅 DeepSeek 弹通知）；
- 无网络时每次刷新照样发 4 组请求。可用 `NWPathMonitor` 监听网络状态，断网时暂停定时刷新并在菜单栏显示离线标记，恢复后立即刷一次；
- 建议统一一个 `fetchWithRetry`：指数退避、最多 2 次、区分「网络错误」与「业务错误」（HTTP 401 说明 token 失效，重试无意义）。

### 9. TCC 拦截判断过于粗糙 🟡 ✅ 已实施（2026-08-11）

`edgeQianwenTicket()` 里 `copyItem` 只要抛错就置 `qwTccBlocked = true`，但复制失败也可能是磁盘满、Edge 正在写库等。可以判断 `NSError` 的 domain/code（`NSCocoaErrorDomain` + `NSFileReadNoPermissionError`）再下结论，避免误引导用户去开「完全磁盘访问」。

### 10. 千问 SEC_TOKEN 用正则抓 HTML，脆弱 🟢

`regexFirstGroup("SEC_TOKEN:\\s*\"([^\"]+)\"", in: html)` 依赖页面内联脚本格式，页面改版即失效且无降级提示。建议：失败时在菜单项显示「千问数据获取失败」状态（见功能建议第 3 条），并把解析逻辑集中一处，方便后续修。

### 11. Timer 在 App Nap / 系统睡眠下会漂移 🟢

`Timer.scheduledTimer` 依赖 runloop，macOS App Nap 开启后定时器可能被大幅延迟。对「每小时签到轮询」影响不大，但「菜单栏 1 分钟刷新」可能被拉长。可考虑：

- `checkinTimer` 改用 `DispatchSourceTimer`（不依赖 runloop，可配 `leeway`）；
- 或加 `NSWorkspace.didWakeNotification` 监听，唤醒后立即补一次刷新/签到检查。

---

## 三、安全与隐私

### 12. 敏感凭据全部明文存 config.json 🔴

DeepSeek API Key、WorkBuddy 多账号的 token/refreshToken、千问 ticket 全部明文落盘在 `~/.../config.json`。任何进程都能读。建议：

- 迁移到 **Keychain**（`SecItemAdd` 存 `kSecClassGenericPassword`），config.json 只留非敏感设置（小数位、刷新间隔、开关）；
- 做一次性迁移：首次启动检测到 config.json 里有 key/token 就写入 Keychain 后从文件中抹掉；
- 至少应把根目录 `config.json` 加入 `.gitignore`（项目目前无 git 仓库，若未来初始化 git 这是第一道防线）。

### 13. Edge Cookie 读取仅支持 Default profile 🟢

硬编码 `Microsoft Edge/Default/Cookies`，多 profile（Profile 1/2…）或其他 Chromium 系浏览器（Chrome/Arc）登录的用户无法自动读取。可以扫描 `Microsoft Edge/*/Cookies` 按修改时间取最新，或配置项指定 profile。

---

## 四、功能增强

### 14. 菜单栏增加状态可见性 🔴

目前各服务失败完全静默，用户无法区分「没数据」和「获取失败」。建议：

- 菜单顶部加只读状态区：各服务「上次刷新时间 + 成功/失败原因」；
- 失败的服务在菜单栏标题处给一个弱化标记（如灰色 ⚠︎）；
- 「刷新余额」菜单项可以加 `Cmd+R` 快捷键。

### 15. 用量历史与消耗趋势 🟡

每次刷新把各服务余额快照追加到本地文件（JSONL 或 SQLite），就能做：

- 菜单项显示「今日已消耗 xxx」「较昨日」；
- 简单 7 日趋势（菜单里用 NSImage 自绘 sparkline，或点开一个 NSWindow 图表）；
- 低余额告警：DeepSeek 余额 / 千问周额度低于阈值时主动通知（阈值可配置，如 `alert_threshold`）。

### 16. 千问 5 小时额度已获取但未展示 🟡

`cacheQw` 里已经缓存了 `h5Rem/h5Limit`（5 小时滚动窗口配额），但 `updateTitle()` 只显示周百分比。5 小时窗口往往比周限额更早触顶，建议在菜单里加一行只读项显示「5h 额度剩余 xx%」，触顶时甚至比周额度更有告警价值。

### 17. 开机自启动选项 🟡

菜单栏工具的典型诉求。macOS 13+ 用 `SMAppService.mainApp.register()` 一行搞定；要兼容 macOS 12 则写 LaunchAgent plist。菜单加一个「开机启动」开关即可。

### 18. 设置项收纳到子菜单 🟢

主菜单已 15+ 项，设置类（刷新间隔、小数位×2、隐藏 icon、API Key、Ticket）建议收进「设置 ▸」子菜单，主菜单只留：状态区、刷新、签到开关、打开 Cockpit、关于、退出。

### 19. 刷新间隔档位扩充 🟢

目前只有 1/5 分钟两档硬编码。可以改成 1 / 5 / 15 / 30 分钟四档，或干脆读 config 任意值、菜单只提供常用预设。

### 20. 多 DeepSeek 账号支持 🟢

WorkBuddy 已支持多账号，DeepSeek 只能配一个 API Key。若用户有多个 DeepSeek 账户（个人/团队），可把 `deepseek_api_key` 扩展为数组，菜单栏轮播或加前缀区分。

---

## 五、构建与发布

### 21. build.sh 自动保护用户 config.json，消除「覆盖陷阱」 🔴

这是项目记忆里明确记录的坑：`build.sh` 末尾 `cp` 模板覆盖根目录含真实 API Key 的 config.json。建议脚本内建保护，而不是靠人记：

```bash
# 已存在则合并：以用户现有 config 为准，仅补充模板里新增的 key
if [[ -f "$ROOT_CONFIG" ]]; then
    /usr/bin/python3 -c '
import json,sys
tpl=json.load(open(sys.argv[1])); cur=json.load(open(sys.argv[2]))
tpl.update(cur)   # 用户字段优先
json.dump(tpl,open(sys.argv[2],"w"),indent=2,ensure_ascii=False)
' "$CONFIG" "$ROOT_CONFIG"
else
    cp "$CONFIG" "$ROOT_CONFIG"
fi
```

顺带把「备份-合并」从人工步骤变成脚本行为后，AGENT.md 里的陷阱 1 也可以删掉。

### 22. 版本号自动递增 🟢

`Info.plist` 的 `CFBundleVersion` 目前手工维护。build.sh 里可以自动 `agvtool`-style 递增（`PlistBuddy` 读旧值 +1 写回），「关于」弹窗里显示的 Build 号才有意义。

### 23. 基础验证 / 测试 🟡

无测试对解密逻辑（`decryptTraeToken` 硬编码 salt、`edgeQianwenTicket` 的 AES/PBKDF2 参数）风险最大——这些参数一旦 TRAE/Edge 升级就会静默失效。最低成本的做法：

- 把一份已知的 TRAE 密文样本（脱敏后）作为 fixture，写一个小型 `test.swift` 或 Python 脚本验证解密链路端到端可跑通；
- build.sh 末尾加一步「编译后 smoke test」：`./iBalance.app/Contents/MacOS/iBalance --self-test`（加一个隐藏参数跑配置加载 + 各 URL 构造校验后退出）。

---

## 六、建议的落地顺序

| 顺序 | 事项 | 理由 |
| --- | --- | --- |
| 1 | build.sh 保护 config.json（#21） | 一行脚本能消掉最高频的人为事故 |
| 2 | 凭据迁移 Keychain（#12） | 安全风险最高，越早做迁移成本越低 |
| 3 | 修数据竞争（#7）+ 状态可见性（#14） | 稳定性 + 可观测性，日常体验提升最明显 |
| 4 | Codable 重构 + 拆文件（#2、#1） | 为后续所有功能改动铺路 |
| 5 | 用量历史 + 低余额告警（#15、#16） | 从「看余额」升级为「管余额」 |
| 6 | 其余按需 | 开机启动、子菜单收纳、趋势图等 |
