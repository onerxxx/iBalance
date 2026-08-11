# AGENT.md — iBalance 项目指南

本文件面向在本仓库中工作的 AI Agent / 开发者，介绍项目结构、构建流程与关键注意事项。

## 项目概述

**iBalance** 是一个 macOS 菜单栏常驻应用（NSStatusItem），用于在菜单栏实时显示多个 AI 服务的余额 / 额度：

- **DeepSeek**：API 余额查询（`api.deepseek.com/user/balance`）
- **WorkBuddy**：直接调用 CodeBuddy API 查询当前账号剩余额度（菜单栏图标 Unicode 🆆）
- **千问（Qianwen）**：Token Plan 7 天限额剩余百分比（走网关接口，自动读取 Edge 登录态，菜单栏图标 Unicode 🅠）
- **TRAE 积分**：读取 TRAE SOLO CN 本地 storage.json，自定义 byteCrypto 解密 token 后查询积分，支持**签到 / 自动签到**
- **Cockpit Tools**：菜单项可打开本地 App（Bundle ID `com.jlcodes.cockpit-tools`），未安装时弹提示

应用为纯菜单栏应用（`LSUIElement = true`，无 Dock 图标），最低支持 macOS 12（Apple Silicon, arm64）。

## 目录结构

```
.
├── config.json              # 用户配置（含真实 API Key，优先级最高）⚠️ 勿提交/勿覆盖
├── iBalance.app/            # 构建产物（可双击运行的 .app bundle）
├── CHANGELOG.md             # 最近修改记录
├── IMPROVEMENTS.md          # 改进优化建议清单
├── reasonix.toml            # Reasonix 权限配置
├── swift/
│   ├── main.swift           # 入口 + AppDelegate（菜单栏 UI / 定时器 / 编排，~800 行）
│   ├── Config.swift         # AppConfig/WBAccount（Codable）+ 加载/保存
│   ├── Network.swift        # async HTTP + 重试 + 离线感知（NWPathMonitor）+ JSON 工具
│   ├── Crypto.swift         # SHA-512 / AES-CBC / PBKDF2
│   ├── Services/
│   │   ├── DeepSeek.swift   # DeepSeek 余额查询
│   │   ├── WorkBuddy.swift  # CodeBuddy 积分 + 多号签到 + OAuth + token 刷新
│   │   ├── Trae.swift       # TRAE 积分解密查询 + 签到
│   │   └── Qianwen.swift    # Edge Cookie 解密 + 千问配额网关查询
│   ├── build.sh             # 编译 + 打包脚本（自动收集全部 .swift）
│   ├── config.json          # 配置模板（API Key 为空，作为内置 fallback）
│   ├── Info.plist           # App 元信息（LSUIElement、ATS 本地网络放行等）
│   ├── AppIcon.icns         # Finder/Launchpad 图标
│   └── icons/
│       └── credit-card-filled.svg  # 菜单栏 template 图标（纯黑+透明底，系统自动 tint）
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
- 产物输出到项目根目录 `iBalance.app/`，与源码目录分离。
- 打包后用固定自签证书 **`iBalance Local Sign`**（10 年有效，存于登录钥匙串）执行 `codesign --force --sign`。
  **必须保持该签名**：ad-hoc 签名每次编译都变，macOS TCC 按签名识别应用，会导致「完全磁盘访问」等授权每次重建后失效。

## ⚠️ 关键陷阱（必读）

### 1. ~~build.sh 会覆盖根目录 config.json~~（已消除，2026-08-11）

build.sh 结束时改为**字段级合并**：根目录已存在用户配置时用 python3 合并（模板补新增 key，用户字段优先），不存在才复制模板。真实 API Key / 签到账号不会再被清空，无需人工备份恢复。

### 2. 不要删除签名证书 iBalance Local Sign

删除后 build.sh 会回退 ad-hoc 签名，重建应用会导致磁盘访问等 TCC 授权被重置。
若证书丢失，需重建自签证书并信任（openssl 自签 + `security add-trusted-cert`），且用户需在系统设置中重新授权一次。

### 3. 配置加载优先级

应用运行时按以下优先级读取配置（高 → 低）：

1. `.app` 同目录的 `config.json`（即项目根目录这份，用户编辑它）
2. `iBalance.app/Contents/Resources/config.json`（构建时拷贝的模板 fallback）

## 配置字段（config.json）

| 字段                                                                                | 说明                                                                        |
| --------------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| `deepseek_api_key`                                                                | DeepSeek API Key（sk-...），为空则菜单引导输入                                        |
| `refresh_interval`                                                                | 刷新间隔（秒），默认 300；菜单「刷新时间」子菜单可选 1/3/5 分钟                              |
| `deepseek_decimals` / `workbuddy_decimals` / `qianwen_decimals` / `trae_decimals` | 各服务菜单栏显示的小数位                                                              |
| `workbuddy_enabled`                                                               | WorkBuddy 用量开关                                                            |
| `workbuddy_auto_checkin`                                                          | WorkBuddy 多号自动签到开关                                                        |
| `workbuddy_accounts`                                                                | 预存签到账号列表：`[{uid, token, domain, nickname, refresh_token?, expires_at?}]`  |
| `cockpit_app_id`                                                                  | Cockpit Tools 的 Bundle ID                                                 |
| `qianwen_ticket`                                                                  | 千问网关 ticket 备用手动值（正常情况下自动读 Edge Cookie）                                    |
| `trae_storage_path`                                                               | TRAE SOLO CN 的 storage.json 路径（留空自动探测）                                    |
| `trae_auto_checkin`                                                               | TRAE 自动签到开关                                                               |
| `hide_main_icon`                                                                  | 隐藏菜单栏最前面的信用卡 SVG 图标（菜单「隐藏主icon」，默认 true）                                    |

> 已弃用并移除：`workbuddy_report_url`、`workbuddy_account`、`cockpit_url`（旧版遗留，新代码不再读写）。

## 代码结构（多文件，按模块划分）

| 文件                                | 职责                                               |
| ---------------------------------- | ------------------------------------------------ |
| `main.swift`                       | `@NSApplicationMain` 入口 + `@MainActor AppDelegate`：菜单栏 UI、菜单构建与回调、定时器、刷新/签到编排 |
| `Config.swift`                     | `AppConfig` / `WBAccount`（Codable）+ `ConfigStore.load/save`（含配置优先级）      |
| `Network.swift`                    | `HTTP.request/requestWithRetry`（async）、`NetworkMonitor`（NWPathMonitor 离线感知）、JSON 工具 |
| `Crypto.swift`                     | SHA-512 / AES-128-CBC / PBKDF2-HMAC-SHA1                              |
| `Services/DeepSeek.swift`          | DeepSeek 余额查询（Codable 响应）                        |
| `Services/WorkBuddy.swift`         | CodeBuddy 积分汇总、多号签到、OAuth 账号采集、token 自动刷新         |
| `Services/Trae.swift`              | storage.json 解密 token + 积分查询 + 签到               |
| `Services/Qianwen.swift`           | Edge Cookie 库解密 ticket + 控制台网关配额查询               |

### 编码约定

- 多文件模块化：服务逻辑放 `Services/<Name>.swift`（纯静态函数，无 UI），AppDelegate 只做编排与 UI。
- 网络请求一律走 `HTTP.request` / `HTTP.requestWithRetry`（async）；仅网络错误（status==0）重试，HTTP 4xx/5xx 不重试。
- AppDelegate 标 `@MainActor`：`config` 与各 cache 只在主线程读写，无数据竞争；异步工作用 `Task { ... }` 编排，结果自动回主线程。
- `NetworkMonitor.shared` 监听网络状态：离线时暂停刷新并在菜单栏显示「⚠︎ 离线」，恢复后立即刷新。
- 菜单栏图标必须是 **template image**（纯黑 SVG + 透明背景），由系统自动处理深浅色与 active/inactive 状态。
- 修改配置后调用 `ConfigStore.save(config)` 写回根目录 `config.json`（Codable 序列化，弃用字段不再落盘）。
- 通知 API 用 completion-handler 重载（尾随 `{ _ in }`），避免 Swift 6 解析到 async 重载报错。

## swift-tools（独立小工具）

`click.swift` / `presskey.swift` 是模拟鼠标点击 / 键盘按键的命令行工具，与主程序无依赖关系，单独用 `swiftc` 编译：

```bash
swiftc -framework Cocoa swift-tools/click.swift -o swift-tools/click
```

## 外部依赖

- **Cockpit Tools**：本地 macOS 应用（Bundle ID `com.jlcodes.cockpit-tools`）。仅「打开 Cockpit」菜单项依赖它；WorkBuddy 数据已直连 CodeBuddy API，不再依赖其 report 接口。
- 无需第三方包管理器（无 SPM/CocoaPods），纯系统框架：Cocoa、UserNotifications、Security、Network、libsqlite3。

## 安全注意

- 根目录 `config.json` 含真实 API Key 与 WorkBuddy token，**不要提交到 git，不要在日志/回复中泄露**。
- TRAE / Edge Cookie 解密逻辑涉及用户本地凭据，改动需格外谨慎。
