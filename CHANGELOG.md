# Changelog

## 2026-08-11（深夜）

### 🔧 build.sh 自动保护用户 config.json（IMPROVEMENTS #21）

- 构建结束时不再直接 `cp` 模板覆盖根目录 `config.json`：
  - 根目录已存在用户配置 → 用 python3 做字段级合并（模板打底补新增 key，用户字段优先），API Key / 签到账号等真实配置永远不会被清空；
  - 不存在时才复制模板。
- 已实测：构建后根 config 的 `deepseek_api_key`、`workbuddy_accounts` 原样保留，无需人工备份恢复。

### 🕐 刷新时间改为子菜单（1 / 3 / 5 分钟）

- 主菜单两个「刷新时间：1分钟/5分钟」平铺项合并为一个「刷新时间（N分钟）」项，展开子菜单单选 1/3/5 分钟；
- 选项用 `tag` 存秒数（60/180/300），切换后重启 Timer 并写回 config；主菜单项标题同步显示当前档位。

## 2026-08-11（晚）

### ⚡ 菜单栏额度先到先显示

- `performRefresh()` 原先用 `async let` 等四个服务全部返回后一次性绘制标题；
- 改为每个服务一个独立刷新函数（`refreshOneDeepSeek/WorkBuddy/Trae/Qianwen`），并行请求、**先到先显示**：任一服务返回即写缓存并立即重绘菜单栏标题，互不等待；
- 「刷新中…」状态在四个任务全部完成后才恢复，DeepSeek 错误通知与千问 TCC 引导逻辑保持不变。

## 2026-08-11

### 🏗️ 代码架构重构（IMPROVEMENTS.md #1-#9）

#### 拆分单文件为模块（#1）
- `main.swift`（~1970 行）拆分为 8 个文件：`main.swift`（~830 行，入口+AppDelegate）、`Config.swift`、`Network.swift`、`Crypto.swift`、`Services/{DeepSeek,WorkBuddy,Trae,Qianwen}.swift`
- build.sh 改为自动收集全部 `.swift` 编译，新增 `-parse-as-library` 与 `-framework Network`

#### Codable 重构（#2）
- `AppConfig` / `WBAccount` 及 DeepSeek、WorkBuddy 积分/auth 文件、TRAE 积分响应改用 Codable
- 新增 `FlexibleDouble` 统一处理 Double/Int/String 数值字段，消除 6+ 处重复兼容代码
- 签到接口结构变体多，保留 `JSONSerialization` 松散解析

#### async/await 网络层（#3）
- `syncRequest()`（DispatchSemaphore 阻塞线程）→ `HTTP.request()`（URLSession async），超时后不再泄漏 task
- OAuth 轮询 `Thread.sleep` → `Task.sleep`；刷新编排改用 `async let` 四服务并行

#### 消除重复代码（#4）
- `promptForApiKey` / `promptForQianwenTicket` 合并为通用 `promptForInput()`
- `getTraeToken()` 逻辑并入 `TraeService.getToken()`，积分查询复用

#### 清理死代码（#5）
- 删除 `onTraeCheckin()` / `showCheckinResult()`（手动签到菜单早已移除）
- 移除弃用字段 `workbuddy_report_url` / `workbuddy_account` / `cockpit_url`（不再读写、不再落盘）
- 模板 `workbuddy_accounts` 占位空账号改为 `[]`

#### 文档同步（#6）
- AGENT.md 更新目录结构、代码结构表、配置表、编码约定、外部依赖描述

#### 修复数据竞争（#7）
- AppDelegate 标 `@MainActor`：`config` 与各 cache 只在主线程读写
- 服务层纯静态函数化，异步编排统一 `Task`，结果自动回主线程

#### 统一重试 + 离线感知（#8）
- `HTTP.requestWithRetry`：仅网络错误重试（指数退避），HTTP 4xx/5xx 不重试
- `NetworkMonitor`（NWPathMonitor）：离线暂停刷新、菜单栏显示「⚠︎ 离线」、恢复立即刷新

#### TCC 判断精确化（#9）
- Edge Cookie `copyItem` 失败时仅在 `NSFileReadNoPermissionError` / `EPERM` 时判定为 TCC 拦截，避免误引导

## 2026-08-06

### 🎨 菜单栏图标更换

#### WorkBuddy / 千问图标换为新 SF Symbol
- 旧图标：WorkBuddy `w.square.fill`、千问 `figure.roll.circle.fill`（其间曾短暂改为加粗 W / Q 衬线字母自绘图标）
- 新图标：WorkBuddy `basketball.fill`、千问 `cup.and.heat.waves.fill`（沿用 `sfSymbolAttachment()` 内嵌标题方案）
- 图标尺寸、位置与间隔保持不变（12pt attachment、`U+2009` 细空格 + 双空格分段）
- 移除不再使用的 `boldLetterImage()`（自绘加粗字母 attachment）

### 👁️ 新增菜单项「隐藏主icon」

- 位于「关于 iBalance」之前（倒数第三项），勾选后隐藏最前面的信用卡 SVG 图标（`credit-card-filled`）
- 新增配置字段 `hide_main_icon`（默认 `false`），`loadConfig()` / `saveConfig()` 同步支持
- 聚焦刷新 `refreshStatusItemAppearance()` 尊重该设置，不会把图标带回
- 图标隐藏时 `updateTitle()` 不再为 ¥ 前补空格，避免左侧多余留白

### 🔐 build.sh 固定代码签名

#### 问题根因
- `swiftc` 编译产物默认 ad-hoc（linker-signed）签名，每次重建哈希都变；macOS TCC 按签名识别应用，导致「完全磁盘访问」等授权每次重建后失效、需重新授权

#### 修复方案
- 登录钥匙串新建本地自签代码签名证书 **`iBalance Local Sign`**（10 年有效，openssl 自签 + `security add-trusted-cert` 信任）
- `build.sh` 打包后自动 `codesign --force --sign "$SIGN_IDENTITY"`；证书缺失时告警并回退 ad-hoc 签名
- 首次切换签名需在系统设置中移除旧 TCC 条目并重新添加 `iBalance.app` 一次，之后重建不再重置授权

### 📝 文档

- 新建 `CHANGELOG.md`（本文件）
- `AGENT.md`：更新服务描述（WorkBuddy 走 CodeBuddy API、千问自动读取 Edge 登录态及新图标名）、构建与签名说明、新增陷阱「不要删除签名证书」、配置表补充 `hide_main_icon`、目录结构加入 `CHANGELOG.md`
