# AGENT.md — iBalance 项目指南

本文件面向在本仓库中工作的 AI Agent / 开发者，介绍项目结构、构建流程与关键注意事项。
（2026-08-20 更新：根目录 `config.json` 已移除，用户配置唯一权威来源为 `~/Library/Application Support/com.local.ibalance/`；2026-08-19 千问平台已下线，ZCode / Codex 已接入，配置迁移 Application Support，签名证书已重建。）

## 项目概述

**iBalance** 是一个 macOS 菜单栏常驻应用（NSStatusItem），用于在菜单栏实时显示多个 AI 服务的余额 / 额度：

- **DeepSeek**：API 余额查询（`api.deepseek.com/user/balance`），「DeepSeek 设置」弹窗一次性配置 API Key 与「常用充值额度」（`deepseek_common_quota`），设置后在面板显示用量进度
- **WorkBuddy**：直接调用 CodeBuddy API 查询当前账号剩余额度，支持**多账号卡片、多号签到、OAuth 账号采集、token 自动刷新与多号切换**（切换 = 写 WorkBuddy 认证文件 + 杀进程重启）
- **TRAE 积分**：读取 TRAE SOLO CN 本地 storage.json，自定义 byteCrypto 解密 token 后查询积分，支持**多账号采集 / 切换（写回 storage.json + 杀进程重启 TRAE）与自动签到**
- **ZCode**（智谱 Coding Plan）：读取本机 `~/.zcode/v2/config.json` 的 JWT 查询额度百分比与重置倒计时，支持**JSON 导入多账号、多号切换**（写凭据文件 + 杀进程重启 ZCode）
- **Codex**：从本机 `~/.codex/auth.json` 导入登录账号，调用 usage 接口查询额度百分比，支持**多账号、多号切换**（退出 Codex → 原子写回 auth.json 的 access/refresh/id token → 重启 Codex）
- **Cockpit Tools**：菜单项可打开本地 App（Bundle ID `com.jlcodes.cockpit-tools`），未安装时弹提示

> 千问（Qianwen）平台已于 2026-08 下线，相关代码与配置字段已全部移除。

交互方式：**左键**点菜单栏图标弹出详情面板（NSPopover，余额卡片 + 日/周用量 + 设置 + 操作）；**右键**弹出传统 NSMenu（兜底入口，选项与面板同步）。余额卡片支持**拖拽排序**（平台组顺序持久化，菜单栏条目顺序与面板共用同一份 UserDefaults）。

应用为纯菜单栏应用（`LSUIElement = true`，无 Dock 图标），最低支持 macOS 12（Apple Silicon, arm64）。

## 目录结构

```
.
├── cache.json               # 旧版余额缓存（迁移后保留为副本）
├── iBalance.app/            # 构建产物（可双击运行的 .app bundle）
├── IMPROVEMENTS.md          # 改进优化建议清单
├── PACKAGING.md             # 分发打包流程（zip 排除清单 + 敏感字段泄漏校验）
├── reasonix.toml            # Reasonix 权限配置
├── click_ibalance.lua       # Hammerspoon 脚本：模拟点击菜单栏图标弹出面板
├── macos-panel-ui-guide.md  # macOS 面板 UI 设计参考笔记
├── backups/                 # 大重构前的完整备份（如 v1.0-menubar-2026-08-12/）
├── cockpit-tools-main/      # Cockpit Tools 源码（外部项目，仅参考）
├── docs/                    # 补充文档（card-drag-framework.md、menubar-template-pitfalls.md、
│                            #   native-segmented-control-guide.md、iBalance-已损坏说明.html 等）
├── swift/
│   ├── main.swift           # 入口 + AppDelegate（菜单栏 UI / 定时器 / 面板与签到编排，~3000 行）
│   ├── Panel.swift          # 详情面板：NSPopover + 全部自定义控件 + 卡片拖拽排序（~2800 行）
│   ├── Config.swift         # AppConfig（Codable）+ AppDataStore（Application Support 持久化/迁移）+ 余额缓存
│   ├── Network.swift        # async HTTP + 重试 + 离线感知（NWPathMonitor）+ JSON 工具
│   ├── Crypto.swift         # SHA-512 / AES-CBC / PBKDF2
│   ├── Logger.swift         # 统一日志（取代各 Service 私有 appendLog）
│   ├── ProcessUtil.swift    # Electron 应用切号共用进程工具（找主进程/温和杀/强杀/等待退出）
│   ├── Services/
│   │   ├── DeepSeek.swift   # DeepSeek 余额查询
│   │   ├── WorkBuddy.swift  # CodeBuddy 积分 + 多号签到 + OAuth + token 刷新 + 多号切换（写认证文件 + 重启）
│   │   ├── Trae.swift       # TRAE 积分解密查询 + 多账号采集/切换 + 签到 + 设备指纹请求头
│   │   ├── Zcode.swift      # ZCode 额度查询 + JSON 导入 + 多号切换（写凭据 + 重启）
│   │   └── Codex.swift      # Codex auth.json 导入 + usage 查询 + 多号切换（写 auth.json + 重启）
│   ├── build.sh             # 编译 + 打包 + 签名 + 自动重启 App（自动收集全部 .swift）
│   ├── config.json          # 配置模板（复制进 Resources 作为 fallback；⚠️ 当前含真实凭据，见「安全注意」）
│   ├── Info.plist           # App 元信息（LSUIElement、ATS 本地网络放行等）
│   ├── AppIcon.icns         # Finder/Launchpad 图标
│   ├── .build_state         # 构建计数器（版本号用，勿删）
│   └── icons/               # SVG（菜单栏 template 图标 + 面板品牌图标）/ PNG / PDF（菜单栏矢量图标）
└── swift-tools/             # 独立小工具（模拟点击/按键，各自独立编译）
    ├── click.swift / click
    └── presskey.swift / presskey
```

## 构建与运行

```bash
cd swift && ./build.sh        # 编译全部 .swift 并打包为 ../iBalance.app（自动代码签名）
open iBalance.app             # 运行（或双击）
```

- build.sh 自动收集 `swift/` 下所有 `.swift`（含 `Services/` 子目录），无需手动列文件。
- 编译命令核心：`swiftc -parse-as-library -framework Cocoa -framework UserNotifications -framework Security -framework Network -lsqlite3 -target arm64-apple-macos12 -O *.swift`（`-parse-as-library` 是因为入口用 `@NSApplicationMain` 而非 top-level code）。默认 `-Onone` 快速编译，`./build.sh --release` 用 `-O`。
- 版本号自动生成：**`YYYY.M.D.N`**（日期 + 当日构建序号），由 `swift/.build_state` 计数器维护，同日递增、跨日重置；构建时由 PlistBuddy 写入 Info.plist（`CFBundleShortVersionString` = 日期、`CFBundleVersion` = 完整号）。
- `icons/*` 全量拷贝进 Resources：SVG（菜单栏 template 图标 + 面板品牌图标）、PNG（关于弹窗）、PDF（菜单栏平台矢量图标，优先于同名 SVG 加载）。
- 产物输出到项目根目录 `iBalance.app/`，与源码目录分离。
- **build.sh 会先停掉运行中的 iBalance 再组装 bundle**：否则 `open` 只会激活旧实例，新二进制根本没运行。SIGTERM 后循环等进程退出，5s 未退升级 SIGKILL，8s 仍未退则告警继续；结尾 `open` 前再做一次防御性确认。
- 打包后用固定自签证书 **`iBalance Local Sign`**（10 年有效，存于登录钥匙串）执行 `codesign --force --sign`。
  **必须保持该签名**：ad-hoc 签名每次编译都变，macOS TCC 按签名识别应用，会导致「完全磁盘访问」等授权每次重建后失效（详见陷阱 #2）。
- **build.sh 结束时会自动重启 iBalance**（注意：改代码后跑 build 会立即重启正在运行的 App）。
- 分发打包（zip）流程见 `PACKAGING.md`：排除清单 + zip 内模板 config 敏感字段泄漏校验，zip 文件名带版本号（取自 `swift/Info.plist`，**先 build 再打包**）。

## ⚠️ 关键陷阱（必读）

### 1. 用户配置与 App 解耦（已完成，2026-08-18）

运行时配置和余额缓存统一写入 `~/Library/Application Support/com.local.ibalance/`（目录 0700、文件 0600，`AppDataStore` 统一管理），不再依赖 `.app` 同目录文件。首次启动会从旧版 `.app` 同目录复制 `config.json` / `cache.json` 到新目录，并保留旧文件作为恢复副本；后续移动或更新 App 不会影响用户数据。

### 2. 不要删除签名证书 iBalance Local Sign

删除或私钥丢失后 build.sh 会回退 ad-hoc 签名，重建应用会导致磁盘访问等 TCC 授权被重置。

**2026-08-19 曾发生私钥丢失**（证书还在钥匙串但 `find-identity` 报 0 个有效身份），已按以下步骤重建：

1. openssl 生成自签证书（CN=iBalance Local Sign，10 年，含 codeSigning EKU）；
2. **导出 PKCS#12 必须加 `-legacy`**（OpenSSL 3.x 默认算法 macOS Security 框架不认，报 "MAC verification failed"）；
3. `security delete-certificate -Z <旧哈希>` 清掉无私钥的孤儿证书，`security import` 导入 + `security add-trusted-cert -r trustRoot -p codeSign` 信任；
4. 重建后需在系统设置里**重新授权一次** TCC（签名变更的一次性代价），此后签名稳定。

排查口诀：`security find-identity -v -p codesigning` 为空但 `find-certificate` 能找到证书 → 多半是私钥丢失（`security find-key -l <名称>` 验证）。

### 3. LSUIElement 面板激活陷阱

LSUIElement 应用默认非活跃，NSPopover 首帧按「非活跃」渲染玻璃材质会整体偏暗，且 `.transient` 行为不生效（点面板外不收起）。
修复范式（Panel.swift `show()`）：弹出前 `NSApp.activate(ignoringOtherApps: true)`、弹出后 `makeKey()`；`popoverDidClose` 里 `NSApp.hide` 归还焦点（弹系统设置菜单等场景用 `suppressHideOnClose` 跳过）；并用事件时间戳防「点图标关掉后同一次点击立刻重弹」的抖动。

### 4. AppKit 旋转锚点陷阱

layer-backed 视图经 Auto Layout 布局时 `anchorPoint` 会被 AppKit 重置为 (0,0)，build/init 时设锚点无效。绕中心旋转需子类化并在 `layout()` 里恢复锚点 + 补偿 position（见 Panel.swift `CenteredSpinButton`）。对控件用 layer transform 缩放也会破坏滑块渲染——缩小控件统一用 `controlSize = .mini`。

### 5. 配置加载优先级

应用运行时按以下优先级读取配置（高 → 低）：

1. `~/Library/Application Support/com.local.ibalance/config.json`
2. 首次启动时从旧版 `.app` 同目录迁移的 `config.json`
3. `iBalance.app/Contents/Resources/config.json`（构建时拷贝的默认 fallback，首次加载后也会落盘到 1）

## 配置字段（config.json）

| 字段                                                        | 说明                                                                        |
| --------------------------------------------------------- | ------------------------------------------------------------------------- |
| `deepseek_api_key`                                        | DeepSeek API Key（sk-...），为空则菜单/面板引导输入                                  |
| `deepseek_common_quota`                                   | DeepSeek 常用充值额度（元，0=未设置不显示），设置后面板显示用量进度                     |
| `refresh_interval`                                        | 刷新间隔（秒），默认 300；面板/菜单「刷新时间」可选 1/3/5 分钟                                |
| `workbuddy_decimals` / `trae_decimals`                    | 对应服务菜单栏显示的小数位（旧版统一 `decimals` 字段读取时兼容）                                  |
| `workbuddy_enabled`                                       | WorkBuddy 用量开关                                                            |
| `workbuddy_auto_checkin` / `trae_auto_checkin`            | WorkBuddy / TRAE 多号自动签到开关                                                 |
| `workbuddy_accounts`                                      | 预存签到账号列表：`[{uid, token, domain, nickname, refresh_token?, expires_at?}]`  |
| `hide_wb_nickname`                                        | 面板/菜单中隐藏 WorkBuddy 账号昵称（默认 true）                                        |
| `panel_gradient_enabled`                                  | 面板背景渐变开关                                                                  |
| `trae_accounts`                                           | TRAE 多号账号列表：`[{uid, username, auth_info}]`（auth_info 为原始加密块，切换时写回 storage.json） |
| `trae_storage_path`                                       | TRAE SOLO CN 的 storage.json 路径（留空自动探测）                                    |
| `zcode_accounts`                                          | ZCode 多号账号列表：`[{uid, token, nickname}]`（JSON 导入）                          |
| `codex_accounts`                                          | Codex 多号账号列表：`[{uid, token, email, refreshToken, idToken}]`（本机 auth.json 导入；旧配置缺 refresh/id token 时兼容仅 access token） |
| `menubar_visible`                                         | 菜单栏条目显隐表：`{条目id: bool}`（右键卡片「在菜单栏显示」开关持久化）                               |
| `cockpit_app_id`                                          | Cockpit Tools 的 Bundle ID                                                 |

> 已弃用并移除：`workbuddy_report_url`、`workbuddy_account`、`cockpit_url`、`deepseek_decimals`、`qianwen_*`、`hide_main_icon`（旧版遗留，新代码不再读写、不再落盘）。

## 代码结构（多文件，按模块划分）

| 文件                                | 职责                                                                 |
| ---------------------------------- | ------------------------------------------------------------------ |
| `main.swift`                       | `@NSApplicationMain` 入口 + `@MainActor AppDelegate`：菜单栏 UI、面板生命周期、菜单构建与回调、刷新/签到定时器、各平台切号编排（统一走 `performAccountSwitch`：后台执行 → 回主线程刷新 → 延迟关面板）、签到历史记录、**App 级 Accent Color**（ObjC runtime swizzle `+[NSColor controlAccentColor]`，UserDefaults 持久化） |
| `Panel.swift`                      | 详情面板全部 UI：`PanelSnapshot` 数据快照、余额卡片（多账号）、设置/操作卡片、**卡片拖拽排序**（幽灵卡片 + Y 轴位移动画，顺序存 `panel_balance_platform_order`）、自定义控件（`HoverCard` / `HoverRowView` / `ActionTileButton` / `UsageBar` / `UsageRing` / `UsageDots` / `TintedVisualEffectView` / `CenteredSpinButton` 等） |
| `Config.swift`                     | `AppConfig` / `WBAccount` / `TraeAccount` / `ZCodeAccount` / `CodexAccount`（Codable）+ `AppDataStore`（Application Support 路径 / 0700-0600 权限 / 旧版迁移）+ `ConfigStore` / `BalanceCacheStore` / `UsageStore`（日/周用量本地差值基线，usage.json）+ `UDKey` |
| `Network.swift`                    | `HTTP.request/requestWithRetry`（async）、`NetworkMonitor`（NWPathMonitor 离线感知）、JSON 工具 |
| `Crypto.swift`                     | SHA-512 / AES-128-CBC / PBKDF2-HMAC-SHA1                              |
| `Logger.swift`                     | 统一带时间戳日志（分场景 category，后台线程安全）                                        |
| `ProcessUtil.swift`                | 切号共用进程工具：按 Bundle ID 找主进程、SIGTERM 温和杀、超时 SIGKILL、等待退出、耗时统计（WorkBuddy / TRAE / ZCode / Codex 复用） |
| `Services/DeepSeek.swift`          | DeepSeek 余额查询（Codable 响应）                        |
| `Services/WorkBuddy.swift`         | CodeBuddy 积分汇总、多号签到、OAuth 账号采集、token 自动刷新、多号切换（写认证文件 + 杀进程重启 WorkBuddy） |
| `Services/Trae.swift`              | storage.json 解密 token + 积分查询 + 多账号采集/切换（写 storage.json + 重启）+ 签到 + 设备指纹请求头 |
| `Services/Zcode.swift`             | `~/.zcode/v2/config.json` JWT 额度查询 + JSON 导入 + 多号切换（写凭据 + 重启 ZCode） |
| `Services/Codex.swift`             | `~/.codex/auth.json` 导入 + usage 接口额度查询 + 多号切换（原子写回 access/refresh/id token 并保持原文件权限 + 重启 Codex） |

### 面板数据流

- AppDelegate 从各服务缓存 + 设置状态构建不可变的 **`PanelSnapshot`**，调用 `syncPanel()` 推给面板；面板不直接读配置/网络。
- 面板与右键菜单共用同一套设置回调（刷新间隔、自动签到开关、小数位、显隐等），勾选态/标题双向同步。
- 签到支持自动（TRAE + WorkBuddy）与手动「全部签到」，结果写入**签到历史记录**（含连续签到天数 streak），面板可查最近签到时间。
- 刷新采用**先到先显示**：五个平台各自独立刷新函数并行请求，任一返回即写缓存并立即重绘菜单栏标题与面板，互不等待；「刷新中…」在全部完成后才恢复。
- **平台卡片拖拽排序**：面板拖拽改变平台组顺序，存 `panel_balance_platform_order`（UserDefaults）并回调 `onPlatformOrderChanged`，菜单栏条目顺序（`orderedMenuBarEntries`）与面板共用同一来源；未知/新增平台自动归一化追加到末尾（`BalancePlatform.normalizedOrder`）。
- **切号统一编排**：TRAE / WorkBuddy / ZCode / Codex 切号均走 `performAccountSwitch(serviceName:failureMessage:action:)`——后台线程执行平台特定写入/重启，回主线程刷新面板 + 触发刷新，失败发通知，0.6s 后关面板。

### 编码约定

- 多文件模块化：服务逻辑放 `Services/<Name>.swift`（纯静态函数，无 UI），AppDelegate 只做编排与 UI，面板控件全在 Panel.swift。
- 网络请求一律走 `HTTP.request` / `HTTP.requestWithRetry`（async）；仅网络错误（status==0）重试，HTTP 4xx/5xx 不重试。
- AppDelegate 标 `@MainActor`：`config` 与各 cache 只在主线程读写，无数据竞争；异步工作用 `Task { ... }` 编排，结果自动回主线程。
- `NetworkMonitor.shared` 监听网络状态：离线时暂停刷新并在菜单栏显示「⚠︎ 离线」，恢复后立即刷新。
- 菜单栏图标必须是 **template image**（纯黑 SVG + 透明背景），由系统自动处理深浅色与 active/inactive 状态；面板品牌图标保持原色。
- 修改配置后调用 `ConfigStore.save(config)`（Codable 序列化，弃用字段不再落盘；经 `AppDataStore.secureWrite` 原子写入 Application Support 并设 0600 权限）。
- 通知 API 用 completion-handler 重载（尾随 `{ _ in }`），避免 Swift 6 解析到 async 重载报错。
- 隐藏调试开关：`--show-panel` 启动后自动弹出详情面板；`--spin-demo` 旋转常开（跳过启动刷新，避免刷新回调停掉演示动画）。

## swift-tools（独立小工具）

`click.swift` / `presskey.swift` 是模拟鼠标点击 / 键盘按键的命令行工具，与主程序无依赖关系，单独用 `swiftc` 编译：

```bash
swiftc -framework Cocoa swift-tools/click.swift -o swift-tools/click
```

## 外部依赖

- **Cockpit Tools**：本地 macOS 应用（Bundle ID `com.jlcodes.cockpit-tools`）。仅「打开 Cockpit」入口依赖它；WorkBuddy 数据已直连 CodeBuddy API，不再依赖其 report 接口。
- **Codex Desktop / ZCode Desktop**：多号切换依赖本机已安装对应应用（`com.openai.codex` / `dev.zcode.app`），未安装时弹提示。
- 无需第三方包管理器（无 SPM/CocoaPods），纯系统框架：Cocoa、UserNotifications、Security、Network、libsqlite3。

## 安全注意

- ⚠️ **`swift/config.json`（模板）当前仍写有真实 API Key 与 WorkBuddy 账号 token**：它会被 build.sh 拷进 .app 作为内置 fallback，打 zip 时必须靠 `PACKAGING.md` 的泄漏校验清空；条件允许应尽快将模板恢复为空凭据。**运行时真实配置在 `~/Library/Application Support/com.local.ibalance/config.json`，不要把它当成模板改**。
- 根目录 `config.json` 已于 2026-08-20 移除（备份至 `backups/config.json.bak-2026-08-20`）；`.gitignore` 仍保留 `/config.json` 规则防止误提交。
- TRAE storage.json 解密、Codex auth.json / ZCode 凭据读写涉及用户本地凭据，改动需格外谨慎（写文件保持原权限、原子写入、失败恢复原账号）。
- 打 zip 分发前必须走 `PACKAGING.md` 的泄漏校验（zip 内模板 config 的敏感字段必须为空）。
