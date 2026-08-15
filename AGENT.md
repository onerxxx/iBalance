# AGENT.md — iBalance 项目指南

本文件面向在本仓库中工作的 AI Agent / 开发者，介绍项目结构、构建流程与关键注意事项。

## 项目概述

**iBalance** 是一个 macOS 菜单栏常驻应用（NSStatusItem），用于在菜单栏实时显示多个 AI 服务的余额 / 额度：

- **DeepSeek**：API 余额查询（`api.deepseek.com/user/balance`），支持设置「常用充值额度」（`deepseek_common_quota`），设置后在面板显示用量进度
- **WorkBuddy**：直接调用 CodeBuddy API 查询当前账号剩余额度（菜单栏图标 SF Symbol `basketball.fill`），支持**多账号卡片、多号签到、OAuth 账号采集、token 自动刷新与多号切换**（切换 = 写 WorkBuddy 认证文件 + 杀进程重启，链路与 TRAE 切换一致）
- **千问（Qianwen）**：Token Plan 7 天限额 + 5h 窗口剩余百分比（走网关接口，自动读取 Edge 登录态，图标 `cup.and.heat.waves.fill`）
- **TRAE 积分**：读取 TRAE SOLO CN 本地 storage.json，自定义 byteCrypto 解密 token 后查询积分，支持**多账号采集 / 切换（写回 storage.json + 杀进程重启 TRAE）与自动签到**
- **Cockpit Tools**：菜单项可打开本地 App（Bundle ID `com.jlcodes.cockpit-tools`），未安装时弹提示

交互方式：**左键**点菜单栏图标弹出详情面板（NSPopover，余额卡片 + 设置 + 操作）；**右键**弹出传统 NSMenu（兜底入口，选项与面板同步）。

应用为纯菜单栏应用（`LSUIElement = true`，无 Dock 图标），最低支持 macOS 12（Apple Silicon, arm64）。

## 目录结构

```
.
├── config.json              # 用户配置（含真实 API Key，优先级最高）⚠️ 勿提交/勿覆盖
├── iBalance.app/            # 构建产物（可双击运行的 .app bundle）
├── IMPROVEMENTS.md          # 改进优化建议清单
├── PACKAGING.md             # 分发打包流程（zip 排除清单 + 敏感字段泄漏校验）
├── reasonix.toml            # Reasonix 权限配置
├── click_ibalance.lua       # Hammerspoon 脚本：模拟点击菜单栏图标弹出面板
├── macos-panel-ui-guide.md  # macOS 面板 UI 设计参考笔记
├── iBalance-已损坏说明.html  # 分发说明（Gatekeeper「已损坏」提示的处理指引）
├── backups/                 # 大重构前的完整备份（如 v1.0-menubar-2026-08-12/）
├── docs/                    # 补充文档（如 native-segmented-control-guide.md）
├── swift/
│   ├── main.swift           # 入口 + AppDelegate（菜单栏 UI / 定时器 / 面板与签到编排，~2050 行）
│   ├── Panel.swift          # 详情面板：NSPopover + 全部自定义控件（~1900 行）
│   ├── Config.swift         # AppConfig / WBAccount / TraeAccount（Codable）+ 加载/保存
│   ├── Network.swift        # async HTTP + 重试 + 离线感知（NWPathMonitor）+ JSON 工具
│   ├── Crypto.swift         # SHA-512 / AES-CBC / PBKDF2
│   ├── Services/
│   │   ├── DeepSeek.swift   # DeepSeek 余额查询
│   │   ├── WorkBuddy.swift  # CodeBuddy 积分 + 多号签到 + OAuth + token 刷新 + 多号切换（写认证文件 + 重启）
│   │   ├── Trae.swift       # TRAE 积分解密查询 + 多账号采集/切换 + 签到 + 设备指纹请求头
│   │   └── Qianwen.swift    # Edge Cookie 解密 + 千问配额网关查询
│   ├── build.sh             # 编译 + 打包 + 自动重启 App（自动收集全部 .swift）
│   ├── config.json          # 配置模板（作为内置 fallback；⚠️ 当前含真实凭据，见「安全注意」）
│   ├── Info.plist           # App 元信息（LSUIElement、ATS 本地网络放行等）
│   ├── AppIcon.icns         # Finder/Launchpad 图标
│   ├── .build_state         # 构建计数器（版本号用，勿删）
│   └── icons/               # SVG（菜单栏 template 图标 + 面板品牌图标）与 PNG（关于弹窗用）
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
- 编译命令核心：`swiftc -parse-as-library -framework Cocoa -framework UserNotifications -framework Security -framework Network -lsqlite3 -target arm64-apple-macos12 -O *.swift`（`-parse-as-library` 是因为入口用 `@NSApplicationMain` 而非 top-level code）。
- 版本号自动生成：**`YYYY.M.D.N`**（日期 + 当日构建序号），由 `swift/.build_state` 计数器维护，同日递增、跨日重置；构建时由 PlistBuddy 写入 Info.plist（`CFBundleShortVersionString` = 日期、`CFBundleVersion` = 完整号）。
- `icons/*.svg` 全量拷贝进 Resources：菜单栏 template 图标（纯黑+透明底，系统自动 tint）与面板品牌图标（保持原色，非 template）。
- 产物输出到项目根目录 `iBalance.app/`，与源码目录分离。
- 打包后用固定自签证书 **`iBalance Local Sign`**（10 年有效，存于登录钥匙串）执行 `codesign --force --sign`。
  **必须保持该签名**：ad-hoc 签名每次编译都变，macOS TCC 按签名识别应用，会导致「完全磁盘访问」等授权每次重建后失效。
- **build.sh 结束时会自动重启 iBalance**：检测到进程在跑先 `killall` 再 `open`，确保加载新二进制（注意：改代码后跑 build 会立即重启正在运行的 App）。
- 分发打包（zip）流程见 `PACKAGING.md`：排除清单 + zip 内三处 config 敏感字段泄漏校验，zip 文件名带版本号（取自 `swift/Info.plist`，**先 build 再打包**）。

## ⚠️ 关键陷阱（必读）

### 1. ~~build.sh 会覆盖根目录 config.json~~（已消除，2026-08-11）

build.sh 结束时改为**字段级合并**：根目录已存在用户配置时用 python3 合并（模板补新增 key，用户字段优先），不存在才复制模板。真实 API Key / 签到账号不会再被清空，无需人工备份恢复。

### 2. 不要删除签名证书 iBalance Local Sign

删除后 build.sh 会回退 ad-hoc 签名，重建应用会导致磁盘访问等 TCC 授权被重置。
若证书丢失，需重建自签证书并信任（openssl 自签 + `security add-trusted-cert`），且用户需在系统设置中重新授权一次。

### 3. LSUIElement 面板激活陷阱

LSUIElement 应用默认非活跃，NSPopover 首帧按「非活跃」渲染玻璃材质会整体偏暗，且 `.transient` 行为不生效（点面板外不收起）。
修复范式（Panel.swift `show()`）：弹出前 `NSApp.activate(ignoringOtherApps: true)`、弹出后 `makeKey()`；`popoverDidClose` 里 `NSApp.hide` 归还焦点（弹系统设置菜单等场景用 `suppressHideOnClose` 跳过）；并用事件时间戳防「点图标关掉后同一次点击立刻重弹」的抖动。

### 4. AppKit 旋转锚点陷阱

layer-backed 视图经 Auto Layout 布局时 `anchorPoint` 会被 AppKit 重置为 (0,0)，build/init 时设锚点无效。绕中心旋转需子类化并在 `layout()` 里恢复锚点 + 补偿 position（见 Panel.swift `CenteredSpinButton`）。对控件用 layer transform 缩放也会破坏滑块渲染——缩小控件统一用 `controlSize = .mini`。

### 5. 配置加载优先级

应用运行时按以下优先级读取配置（高 → 低）：

1. `.app` 同目录的 `config.json`（即项目根目录这份，用户编辑它）
2. `iBalance.app/Contents/Resources/config.json`（构建时拷贝的模板 fallback）

## 配置字段（config.json）

| 字段                                                                                | 说明                                                                        |
| --------------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| `deepseek_api_key`                                                                | DeepSeek API Key（sk-...），为空则菜单/面板引导输入                                  |
| `deepseek_common_quota`                                                           | DeepSeek 常用充值额度（元，0=未设置不显示），设置后面板显示用量进度                     |
| `refresh_interval`                                                                | 刷新间隔（秒），默认 300；面板/菜单「刷新时间」可选 1/3/5 分钟                                |
| `deepseek_decimals` / `workbuddy_decimals` / `qianwen_decimals` / `trae_decimals` | 各服务菜单栏显示的小数位                                                              |
| `workbuddy_enabled`                                                               | WorkBuddy 用量开关                                                            |
| `workbuddy_auto_checkin`                                                          | WorkBuddy 多号自动签到开关                                                        |
| `workbuddy_accounts`                                                                | 预存签到账号列表：`[{uid, token, domain, nickname, refresh_token?, expires_at?}]`  |
| `hide_wb_nickname`                                                                | 面板/菜单中隐藏 WorkBuddy 账号昵称（默认 true）                                        |
| `trae_accounts`                                                                   | TRAE 多号账号列表：`[{uid, username, auth_info}]`（auth_info 为原始加密块，切换时写回 storage.json） |
| `trae_auto_checkin`                                                               | TRAE 自动签到开关                                                               |
| `trae_storage_path`                                                               | TRAE SOLO CN 的 storage.json 路径（留空自动探测）                                    |
| `cockpit_app_id`                                                                  | Cockpit Tools 的 Bundle ID                                                 |
| `qianwen_ticket`                                                                  | 千问网关 ticket 备用手动值（正常情况下自动读 Edge Cookie）                                  |
| `hide_main_icon`                                                                  | 隐藏菜单栏最前面的信用卡 SVG 图标（默认 true）                                              |

> 已弃用并移除：`workbuddy_report_url`、`workbuddy_account`、`cockpit_url`（旧版遗留，新代码不再读写、不再落盘）。

## 代码结构（多文件，按模块划分）

| 文件                                | 职责                                                                 |
| ---------------------------------- | ------------------------------------------------------------------ |
| `main.swift`                       | `@NSApplicationMain` 入口 + `@MainActor AppDelegate`：菜单栏 UI、面板生命周期、菜单构建与回调、刷新/签到定时器、TRAE/WorkBuddy 多账号切换编排、签到历史记录、**App 级 Accent Color**（ObjC runtime swizzle `+[NSColor controlAccentColor]`，UserDefaults 持久化） |
| `Panel.swift`                      | 详情面板全部 UI：`PanelSnapshot` 数据快照、余额卡片（多账号）、设置/操作卡片、自定义控件（`HoverCard` / `HoverRowView` / `ActionTileButton` / `UsageBar` / `UsageRing` / `UsageDots` / `TintedVisualEffectView` / `CenteredSpinButton` 等） |
| `Config.swift`                     | `AppConfig` / `WBAccount` / `TraeAccount`（Codable）+ `ConfigStore.load/save`（含配置优先级） |
| `Network.swift`                    | `HTTP.request/requestWithRetry`（async）、`NetworkMonitor`（NWPathMonitor 离线感知）、JSON 工具 |
| `Crypto.swift`                     | SHA-512 / AES-128-CBC / PBKDF2-HMAC-SHA1                              |
| `Services/DeepSeek.swift`          | DeepSeek 余额查询（Codable 响应）                        |
| `Services/WorkBuddy.swift`         | CodeBuddy 积分汇总、多号签到、OAuth 账号采集、token 自动刷新、多号切换（写认证文件 + 杀进程重启 WorkBuddy） |
| `Services/Trae.swift`              | storage.json 解密 token + 积分查询 + 多账号采集/切换（写 storage.json + SIGTERM/SIGKILL + 重启）+ 签到 + 设备指纹请求头 |
| `Services/Qianwen.swift`           | Edge Cookie 库解密 ticket + 控制台网关配额查询               |

### 面板数据流

- AppDelegate 从各服务缓存 + 设置状态构建不可变的 **`PanelSnapshot`**，调用 `syncPanel()` 推给面板；面板不直接读配置/网络。
- 面板与右键菜单共用同一套无参回调（`toggleDsDecimals()` / `toggleQwDecimals()` / `applyRefreshInterval()` 等），勾选态/标题双向同步。
- 签到支持自动（TRAE + WorkBuddy）与手动「全部签到」，结果写入**签到历史记录**（含连续签到天数 streak），面板可查最近签到时间。
- 刷新采用**先到先显示**：四个服务各自独立刷新函数并行请求，任一返回即写缓存并立即重绘菜单栏标题与面板，互不等待；「刷新中…」在全部完成后才恢复。

### 编码约定

- 多文件模块化：服务逻辑放 `Services/<Name>.swift`（纯静态函数，无 UI），AppDelegate 只做编排与 UI，面板控件全在 Panel.swift。
- 网络请求一律走 `HTTP.request` / `HTTP.requestWithRetry`（async）；仅网络错误（status==0）重试，HTTP 4xx/5xx 不重试。
- AppDelegate 标 `@MainActor`：`config` 与各 cache 只在主线程读写，无数据竞争；异步工作用 `Task { ... }` 编排，结果自动回主线程。
- `NetworkMonitor.shared` 监听网络状态：离线时暂停刷新并在菜单栏显示「⚠︎ 离线」，恢复后立即刷新。
- 菜单栏图标必须是 **template image**（纯黑 SVG + 透明背景），由系统自动处理深浅色与 active/inactive 状态；面板品牌图标保持原色。
- 修改配置后调用 `ConfigStore.save(config)` 写回根目录 `config.json`（Codable 序列化，弃用字段不再落盘）。
- 通知 API 用 completion-handler 重载（尾随 `{ _ in }`），避免 Swift 6 解析到 async 重载报错。
- 隐藏调试开关：`--show-panel` 启动后自动弹出详情面板；`--spin-demo` 旋转常开（跳过启动刷新，避免刷新回调停掉演示动画）。

## swift-tools（独立小工具）

`click.swift` / `presskey.swift` 是模拟鼠标点击 / 键盘按键的命令行工具，与主程序无依赖关系，单独用 `swiftc` 编译：

```bash
swiftc -framework Cocoa swift-tools/click.swift -o swift-tools/click
```

## 外部依赖

- **Cockpit Tools**：本地 macOS 应用（Bundle ID `com.jlcodes.cockpit-tools`）。仅「打开 Cockpit」入口依赖它；WorkBuddy 数据已直连 CodeBuddy API，不再依赖其 report 接口。
- 无需第三方包管理器（无 SPM/CocoaPods），纯系统框架：Cocoa、UserNotifications、Security、Network、libsqlite3。

## 安全注意

- 根目录 `config.json` 含真实 API Key 与 WorkBuddy token，**不要提交到 git，不要在日志/回复中泄露**。
- ⚠️ **`swift/config.json`（模板）当前也被写入了真实 API Key 与 WorkBuddy 账号 token**：它会被 build.sh 拷进 .app 作为内置 fallback，打 zip 时必须靠 `PACKAGING.md` 的泄漏校验清空；条件允许应尽快将模板恢复为空凭据。
- TRAE / Edge Cookie 解密逻辑涉及用户本地凭据，改动需格外谨慎。
- 打 zip 分发前必须走 `PACKAGING.md` 的泄漏校验（zip 内三处 config 的敏感字段必须为空）。
