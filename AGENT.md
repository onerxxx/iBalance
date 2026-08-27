# AGENT.md — iBalance 项目指南

本文件面向在本仓库中工作的 AI Agent / 开发者，介绍项目结构、构建流程与关键注意事项。
（2026-08-20 更新：根目录 `config.json` 已移除，用户配置唯一权威来源为 `~/Library/Application Support/com.local.ibalance/`；2026-08-19 千问平台已下线，ZCode / Codex 已接入，配置迁移 Application Support，签名证书已重建。
2026-08-27 更新：App 内自动更新上线（GitHub Releases 匿名拉取），新增根目录 `release.sh` 发版脚本与 `swift/UpdateService.swift`；仓库已转公开；端到端更新链路真机验证通过；明确「日常迭代禁发 Release」铁律。）

## ⚠️ Agent 工作流铁律

- **每次改完 Swift 代码必须编译并重启 App**：`cd swift && ./build.sh` 一条命令完成（编译 + 打包 + 签名 + 自动停旧进程并重启）。仅 `swiftc -typecheck` 通过不算交付——改动要重启后才能在真实 App 里验证与观感确认。
- **日常代码修改严禁跑 `release.sh` / 不要上传 GitHub Release**：日常迭代验证一律只跑 `build.sh`（fast 模式）编译重启即可。`release.sh` 仅在「真正需要向他人分发新版本」时由用户主动要求执行——它会产生 `-O` 慢编译、消费版本号计数器并向公开仓库发布正式 Release（对外可见、且会触发所有用户 App 的更新提示）。没有用户的明确发版指令就不要碰它。

## 项目概述

**iBalance** 是一个 macOS 菜单栏常驻应用（NSStatusItem），用于在菜单栏实时显示多个 AI 服务的余额 / 额度：

- **DeepSeek**：API 余额查询（`api.deepseek.com/user/balance`），「DeepSeek 设置」弹窗一次性配置 API Key 与「常用充值额度」（`deepseek_common_quota`），设置后在面板显示用量进度
- **Zhipu**（智谱 BigModel）：自动解密浏览器 Edge/Chrome 系 Cookies 登录态（`bigmodel_token_production` JWT，v10 解密后跳过 App-Bound 32 字节填充——复刻已下线千问 edgeTicket 方案），调财务报告接口查可用余额；手填 token 可覆盖自动采集
- **WorkBuddy**：直接调用 CodeBuddy API 查询当前账号剩余额度，支持**多账号卡片、多号签到、OAuth 账号采集、token 自动刷新与多号切换**（切换 = 写 WorkBuddy 认证文件 + 杀进程重启）
- **TRAE 积分**：读取 TRAE SOLO CN 本地 storage.json，自定义 byteCrypto 解密 token 后查询积分，支持**多账号采集 / 切换（写回 storage.json + 杀进程重启 TRAE）与自动签到**
- **ZCode**（智谱 Coding Plan）：读取本机 `~/.zcode/v2/config.json` 的 JWT 查询额度百分比与重置倒计时，支持**JSON 导入多账号、多号切换**（写凭据文件 + 杀进程重启 ZCode）
- **Codex**：从本机 `~/.codex/auth.json` 导入登录账号，调用 usage 接口查询额度百分比，支持**多账号、多号切换**（退出 Codex → 原子写回 auth.json 的 access/refresh/id token → 重启 Codex）
- **Cockpit Tools**：菜单项可打开本地 App（Bundle ID `com.jlcodes.cockpit-tools`），未安装时弹提示

> 千问（Qianwen）平台已于 2026-08 下线，相关代码与配置字段已全部移除。

交互方式：**左键**点菜单栏图标弹出详情面板（NSPopover，余额卡片 + 日/周用量 + 设置 + 操作）；**右键**弹出传统 NSMenu（兜底入口，选项与面板同步）。余额卡片支持**拖拽排序**（平台组顺序持久化，菜单栏条目顺序与面板共用同一份 UserDefaults）。

应用为纯菜单栏应用（`LSUIElement = true`，无 Dock 图标，也因此不出现在 ⌘⌥Esc「强制退出」面板——系统机制使然，已拍板保持此形态），编译目标 `arm64-apple-macos26`（macOS 26+ Liquid Glass 适配基线）。

### App 内自动更新（2026-08-27 上线）

- **检查入口**：操作区「检查更新」磁贴（手动）+ 设置卡「自动检查更新」开关（默认开；启动 20s 后静默检查，每自然日至多一次，「稍后再说」当日 snooze 不再打扰）。
- **更新链路**（`swift/UpdateService.swift`，自研非 Sparkle）：GET `api.github.com/repos/onerxxx/iBalance/releases/latest` → 版本数值逐段比较（tag `v<CFBundleVersion>`）→ URLSession 流式下载 zip → SHA256 校验（asset.digest 优先、正文 `SHA256:` 行兜底，缺失拒装）→ `codesign --verify --deep --strict` → ditto 暂存新 app 到旧 bundle 同卷同级隐藏目录 → spawn 独立 sh（等进程退净 + pkill 兜底防 open 激活旧实例）→ NSApp.terminate 自动重启。
- **前提**：仓库必须保持**公开**（Releases 匿名可拉）；签名身份必须恒为 `iBalance Local Sign`（TCC 授权/登录项跨版本连续的根），私钥 `.p12` 已知丢失过一次（见陷阱 #2），务必备份。

## 目录结构

```
.
├── AGENT.md                 # 本文件（项目指南）
├── README.md                # 仓库说明
├── release.sh               # 发版脚本：build --release → ditto 打 zip → gh release create（铁律：仅用户要求发版时跑）
├── iBalance.app/            # 构建产物（可双击运行的 .app bundle）
├── iBalance-<版本>.zip       # 历次 release.sh 打包产物（发版上传的同一文件，可删）
├── cache.json               # 旧版余额缓存（迁移后保留为副本）
├── todo.md                  # 开发待办
├── reasonix.toml            # Reasonix 权限配置（已 gitignore）
├── backups/                 # 大重构前的完整备份（只读参照，勿改动）
├── cockpit-tools-1.3.24/    # Cockpit Tools 源码快照（外部项目，仅参考；另有一份主分支副本已删）
├── docs/                    # 补充文档：PACKAGING.md（zip 分发校验）、IMPROVEMENTS.md、updater-implementation.md、
│                            #   card-drag-framework.md、menubar-template-pitfalls.md、native-segmented-control-guide.md、
│                            #   macos-panel-ui-guide.md、macos-26-appkit-migration.md、UIUX-OPTIMIZATION.md、
│                            #   CheckinResultPanelController.swift、iBalance-已损坏说明.html 等
├── Inter-4.1/               # Inter Variable 字体源目录
├── swift/
│   ├── main.swift           # 入口 + AppDelegate（菜单栏 UI / 定时器 / 刷新与菜单编排 / App 自更新流程编排，~2500 行）
│   ├── Panel.swift          # 详情面板：快照类型 + BalancePanelView 主体（存储属性/字体/数据更新）+ VC（~1650 行）
│   ├── Dialogs.swift        # 弹窗统一封装：DialogShell / InputDialog / 各业务弹窗（~640 行）
│   ├── CheckinManager.swift # 签到域（AppDelegate 扩展）：错峰自动签到 / 手动签到 / 签到历史 / 定时器（~820 行）
│   ├── AccountSwitcher.swift# 多账号采集与切换（AppDelegate 扩展）：WB OAuth / TRAE·Codex·ZCode 导入 / performAccountSwitch（~380 行）
│   ├── PinWindow.swift      # 面板置顶浮窗（AppDelegate 扩展）：popover ↔ 无边框 NSPanel 内容转移（~120 行）
│   ├── Controls.swift       # 自绘控件：MiniSwitch / HoverCard / ActionTileButton / QuietScrollView 等（~1900 行）
│   ├── UsagePanel.swift     # 用量板块：UsageRowSnapshot / 趋势图与子弹窗 / UsageDots + BalancePanelView 用量扩展（~860 行）
│   ├── PanelDrag.swift      # 卡片拖拽排序（BalancePanelView 扩展）：拖动状态机 / 幽灵卡片 / 重排动画（~290 行）
│   ├── PanelLayout.swift    # 布局构建（BalancePanelView 扩展）：build() 主装配 + 各类行构建器（~1150 行）
│   ├── Config.swift         # AppConfig（Codable）+ AppDataStore（Application Support 持久化/迁移）+ 余额缓存
│   ├── Network.swift        # async HTTP + 重试 + 离线感知（NWPathMonitor）+ JSON 工具
│   ├── UpdateService.swift  # App 自更新（2026-08-27）：GitHub Releases 检查 / 流式下载 / SHA256+codesign 校验 / 同卷暂存 / spawn sh 互换重启
│   ├── Crypto.swift         # SHA-512 / AES-CBC / PBKDF2
│   ├── Logger.swift         # 统一日志（取代各 Service 私有 appendLog）
│   ├── ProcessUtil.swift    # Electron 应用切号共用进程工具（找主进程/温和杀/强杀/等待退出）
│   ├── RollingNumberView.swift # 余额数值「里程表」逐位滚动视图（数字轮独立 tween 自驱动）
│   ├── Services/
│   │   ├── DeepSeek.swift   # DeepSeek 余额查询
│   │   ├── BigModelService.swift # Zhipu 余额查询（浏览器 Cookie 采集）
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
```

## 构建与运行

```bash
cd swift && ./build.sh        # 编译全部 .swift 并打包为 ../iBalance.app（自动代码签名）
open iBalance.app             # 运行（或双击）
```

- build.sh 自动收集 `swift/` 下所有 `.swift`（含 `Services/` 子目录），无需手动列文件。
- 编译命令核心：`swiftc -parse-as-library -framework Cocoa -framework UserNotifications -framework Security -framework Network -lsqlite3 -target arm64-apple-macos26 *.swift`（`-parse-as-library` 是因为入口用 `@NSApplicationMain` 而非 top-level code）。默认 `-Onone` 快速编译，`./build.sh --release` 用 `-O`。
- 版本号自动生成：**`YYYY.M.D.N`**（日期 + 当日构建序号），由 `swift/.build_state` 计数器维护，同日递增、跨日重置；构建时由 PlistBuddy 写入 Info.plist（`CFBundleShortVersionString` = 日期、`CFBundleVersion` = 完整号）。
- `icons/*` 全量拷贝进 Resources：SVG（菜单栏 template 图标 + 面板品牌图标）、PNG（关于弹窗）、PDF（菜单栏平台矢量图标，优先于同名 SVG 加载）。
- 产物输出到项目根目录 `iBalance.app/`，与源码目录分离。
- **build.sh 会先停掉运行中的 iBalance 再组装 bundle**：否则 `open` 只会激活旧实例，新二进制根本没运行。SIGTERM 后循环等进程退出，5s 未退升级 SIGKILL，8s 仍未退则告警继续；结尾 `open` 前再做一次防御性确认。
- 打包后用固定自签证书 **`iBalance Local Sign`**（10 年有效，存于登录钥匙串）执行 `codesign --force --sign`。
  **必须保持该签名**：ad-hoc 签名每次编译都变，macOS TCC 按签名识别应用，会导致「完全磁盘访问」等授权每次重建后失效（详见陷阱 #2）。
- **build.sh 结束时会自动重启 iBalance**（注意：改代码后跑 build 会立即重启正在运行的 App）。
- **发版（仅用户明确要求时）**：仓库根 `bash release.sh ["更新说明"]` = `build.sh --release` → `ditto -c -k --sequesterRsrc --keepParent` 打 zip → SHA256 写入 Release 正文 → `gh release create v<CFBundleVersion>` 上传。约定：tag 必须为 `v<CFBundleVersion>` 全号；asset 只放一个 zip，文件名 `iBalance-<全版本>.zip`；同日重发需先 `gh release delete <tag> --cleanup-tag -y`。接收方全程无 quarantine（curl/brew/App 内下载均不打标），无需公证即可直接打开。

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

### 6. DialogShell 模态弹窗三件套（2026-08-27 血泪坑，新弹窗必须遵守）

任何在面板交互链路之外（尤其后台 Task / 定时器）触发 `DialogShell.present()` 的代码，必须同时做到：

1. **`NSApp.activate(ignoringOtherApps: true)`**：accessory app 弹窗前必须自我激活；
2. **`keepPanelAliveDuring { shell.present() }` 包裹**：裸 present 时若 popover 处于 `.transient`，弹窗上的点击会被判为「面板外」→ popover 关闭 → `popoverDidClose` 的 `NSApp.hide` **连坐把 modal 窗一起藏掉**；
3. **runModal 前强制窗口上屏**（present() 已内置 `alert.window.orderFrontRegardless()`）：后台 Task 冷启动竞态下 runModal 窗口可能从未被 WindowServer 登记显示——表象是「弹窗闪没 / 无界面可点、进程假死」，主线程吊死在 modal loop。排查手段：`sample <pid> 2 -file` 抓主线程栈看是否停在 `-[NSAlert runModal]`；swift 单文件调 CGWindowList 枚举窗口。

另：自更新下载走专用 URLSession（request 30s / resource 120s 硬顶）——默认配置对 CDN 龟速滴流近乎无限等待。

## 配置字段（config.json）

| 字段                                                        | 说明                                                                        |
| --------------------------------------------------------- | ------------------------------------------------------------------------- |
| `deepseek_api_key`                                        | DeepSeek API Key（sk-...），为空则菜单/面板引导输入                                  |
| `bigmodel_refresh_enabled` / `bigmodel_token_override`    | Zhipu 刷新开关 / 手填 token 覆盖（空 = 自动扫浏览器 Cookies 解密）                 |
| `deepseek_common_quota`                                   | DeepSeek 常用充值额度（元，0=未设置不显示），设置后面板显示用量进度                     |
| `refresh_interval`                                        | 刷新间隔（秒），默认 300；面板/菜单「刷新时间」可选 1/3/5 分钟                                |
| `workbuddy_decimals` / `trae_decimals`                    | 对应服务菜单栏显示的小数位（旧版统一 `decimals` 字段读取时兼容）                                  |
| `workbuddy_enabled`                                       | WorkBuddy 用量开关                                                            |
| `workbuddy_auto_checkin` / `trae_auto_checkin`            | WorkBuddy / TRAE 多号自动签到开关                                                 |
| `workbuddy_accounts`                                      | 预存签到账号列表：`[{uid, token, domain, nickname, refresh_token?, expires_at?}]`  |
| `hide_wb_nickname`                                        | 面板/菜单中隐藏 WorkBuddy 账号昵称（默认 true）                                        |
| `panel_gradient_enabled`                                  | 面板背景渐变开关                                                                  |
| `panel_usage_visible`                                     | 面板用量行显隐表：`{平台id: bool}`（平台开关弹窗「用量」列持久化，未记录默认显示）          |
| `trae_accounts`                                           | TRAE 多号账号列表：`[{uid, username, auth_info}]`（auth_info 为原始加密块，切换时写回 storage.json） |
| `trae_storage_path`                                       | TRAE SOLO CN 的 storage.json 路径（留空自动探测）                                    |
| `zcode_accounts`                                          | ZCode 多号账号列表：`[{uid, token, nickname}]`（JSON 导入）                          |
| `codex_accounts`                                          | Codex 多号账号列表：`[{uid, token, email, refreshToken, idToken}]`（本机 auth.json 导入；旧配置缺 refresh/id token 时兼容仅 access token） |
| `menubar_visible`                                         | 菜单栏条目显隐表：`{条目id: bool}`（右键卡片「在菜单栏显示」开关持久化）                               |
| `update_auto_check`                                       | 自动检查更新开关（默认 true；启动 20s 后静默检查 GitHub Releases，每日一次；关闭不影响手动「检查更新」磁贴）      |
| `cockpit_app_id`                                          | Cockpit Tools 的 Bundle ID                                                 |

> 已弃用并移除：`workbuddy_report_url`、`workbuddy_account`、`cockpit_url`、`deepseek_decimals`、`qianwen_*`、`hide_main_icon`（旧版遗留，新代码不再读写、不再落盘）。

## 代码结构（多文件，按模块划分）

| 文件                                | 职责                                                                 |
| ---------------------------------- | ------------------------------------------------------------------ |
| `main.swift`                       | `@NSApplicationMain` 入口 + `@MainActor AppDelegate`：菜单栏 UI、面板生命周期、菜单构建与回调、刷新定时器与四服务并行刷新、`PanelSnapshot` 组装、标题位图渲染、通用工具（DateFormatter / 通知） |
| `Panel.swift`                      | 详情面板主体：`PanelSnapshot` / `AccountCardSnapshot` 快照类型、`Motion` / `Palette` 设计 token、字体 provider、`BalancePanelView` 类体（回调 / 存储属性 / 字体策略 / 数据更新 / 多号卡片通用实现）、`BalancePanelViewController`、`NumberRollAnimator`（2026-08-27 起仅保留数值文本解析 parse；滚动驱动已移交 RollingNumberView 自驱） |
| `RollingNumberView.swift`          | 余额数值逐位滚动视图（2026-08-27 重构为自驱动）：`DigitWheelView` 数字轮（12 格预渲染条带图层，每帧仅合成器平移零重绘）+ `TextSlotView` 静态字符槽 + 右对齐槽位排版（非等宽字体按真实 advance 连续插值）。终值一次下发 `setText(animated:rollDuration:)`，各轮独立 tween 到自己的目标数字后停下（异步落定，行进 d 格耗时 = rollDuration × d/10，实例级 ±6% 相位抖动打破同距同步）；displayLink 在面板隐藏时冻结挂起、回窗口续滚 |
| `Dialogs.swift`                    | 弹窗统一封装（自 main.swift 拆出）：`DialogShell` 布局系统、`InputDialog`、DeepSeek 设置、平台自动化开关等业务弹窗 |
| `CheckinManager.swift`             | 签到域（AppDelegate 扩展）：WB/TRAE 错峰自动签到（60s 轮询 + 每号随机就绪时刻）、手动签到编排、签到结果/历史弹窗、签到定时器、`CheckinRecord` 落库 |
| `AccountSwitcher.swift`            | 多账号采集与切换（AppDelegate 扩展）：WB OAuth 采集与轮询、TRAE storage 采集、Codex/ZCode JSON 导入、`performAccountSwitch` 统一切号编排 + 四平台切号入口 |
| `PinWindow.swift`                  | 面板置顶浮窗（AppDelegate 扩展）：pin 时 popover 内容转移至无边框 NSPanel、浮窗尺寸恢复、unpin 预建下一轮 popover |
| `Controls.swift`                   | 自绘控件（自 Panel.swift 拆出）：`MiniSwitch` / `MonoCharSwitch` / `MonoSegmentedControl` / `HoverRowView` / `HoverIconButton` / `RefreshIconButton` / `HoverCard` / `ActionTileButton` / `TintedVisualEffectView` / `QuietScrollView` / `ScrollFadeHint` / `PanelResizeHandle` 等 |
| `UsagePanel.swift`                 | 用量板块（自 Panel.swift 拆出）：`UsageRowSnapshot`、`UsageHistoryChartView` 一周趋势图 + 子弹窗控制器、`UsageDots` 点阵、`BalancePanelView` 用量扩展（表头/行构建、子弹窗开关） |
| `PanelDrag.swift`                  | 卡片拖拽排序（`BalancePanelView` 扩展）：拖动状态机、幽灵卡片快照、兄弟卡让位、drop highlight、重排动画 |
| `PanelLayout.swift`                | 布局构建（`BalancePanelView` 扩展）：`build()` 主装配、`addCard` / `balanceContentRow` / `collapsibleSectionTitle` / `switchRow` 等行构建器、字符模糊过渡 |
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

## 外部依赖

- **Cockpit Tools**：本地 macOS 应用（Bundle ID `com.jlcodes.cockpit-tools`）。仅「打开 Cockpit」入口依赖它；WorkBuddy 数据已直连 CodeBuddy API，不再依赖其 report 接口。
- **Codex Desktop / ZCode Desktop**：多号切换依赖本机已安装对应应用（`com.openai.codex` / `dev.zcode.app`），未安装时弹提示。
- 无需第三方包管理器（无 SPM/CocoaPods），纯系统框架：Cocoa、UserNotifications、Security、Network、libsqlite3。

## 安全注意

- ⚠️ **`swift/config.json` 必须保持零凭据**（API Key 留空 `""`、账号数组留空 `[]`）。它会被 build.sh 拷进 .app 作为内置 fallback，且 release.sh 会把整个 bundle 打包上传到**公开** Release。
  **2026-08-27 泄漏事故**：模板曾带真实 DeepSeek API Key 与 2 个 WorkBuddy 账号 token/refresh_token（JWT 内含手机号），被打进 v2026.8.27.48/.50/.52 三个公开 Release；已删除全部涉事 Release 并清洗模板，重发干净版 .53。**涉事凭据必须轮换（用户人工操作）：DeepSeek 平台作废重建 API Key；CodeBuddy 两账号重新登录刷新 token/refresh_token。**
  **运行时真实配置在 `~/Library/Application Support/com.local.ibalance/config.json`，不要把它当成模板改，更不要拷回模板位**。
  `release.sh` 已内置闸门：打包后解压校验 zip 内 config.json 无任何凭据特征（非空 api key / 带 token 的账号 / JWT、sk- 特征串），命中即中止上传。
- 根目录 `config.json` 已于 2026-08-20 移除（备份至 `backups/config.json.bak-2026-08-20`）；`.gitignore` 仍保留 `/config.json` 规则防止误提交。
- TRAE storage.json 解密、Codex auth.json / ZCode 凭据读写涉及用户本地凭据，改动需格外谨慎（写文件保持原权限、原子写入、失败恢复原账号）。
- 仓库自 2026-08-27 起为**公开**仓库（App 内自更新依赖 Releases 匿名可拉）：任何被提交/打包的内容都视同公开，敏感文件提交前必须确认 `.gitignore` 覆盖。
