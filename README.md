<div align="center">

<img src="swift/icons/App-Icon-Default-1024@1x.png" width="128" alt="iBalance App 图标">

# iBalance

**一款纯原生 AppKit 打造的 macOS 菜单栏应用，实时聚合多个 AI 服务的余额与额度**

多账号管理 · 一键切号 · 自动签到 · 日/周用量与 Token 统计 · 外观深度可调 · 应用内自动更新

[![Latest Release](https://img.shields.io/github/v/release/onerxxx/iBalance)](https://github.com/onerxxx/iBalance/releases/latest)
[![macOS](https://img.shields.io/badge/macOS-12%2B_(arm64)-black?logo=apple&logoColor=white)](#-安装)
[![Swift](https://img.shields.io/badge/100%25-Swift_%2B_AppKit-F05138?logo=swift&logoColor=white)](#-构建与开发)
[![Downloads](https://img.shields.io/github/downloads/onerxxx/iBalance/total)](https://github.com/onerxxx/iBalance/releases)

</div>

---

## ✨ 特性一览

- 🧭 **菜单栏常驻** — 左键弹出详情面板、右键传统菜单兜底，各条目可独立控制菜单栏显隐
- 👥 **多账号管理** — 采集 / 导入多个账号，一键切号（写回对应应用的本机凭据并自动重启该应用）
- ✅ **错峰自动签到** — WorkBuddy / TRAE 每号每日随机延迟自动签到，另有一键手动签到与签到历史
- 📊 **用量统计** — 今日 / 本周用量采用本地差值方案，跨天跨周自动重置，充值与重置自动校准
- 🧮 **Token 用量板块** — ZCode / WorkBuddy / Codex 的 Token 统计：周期切换（5h / 1d / 7d / 30d / All）、词元活动热力图、项目与模型 Top 列表、最近会话均速 tok/s（并按平台聚合）
- 🪙 **3D 硬币** — 纯 CoreGraphics 自绘的金属硬币（盖面扫掠 + 边界阴影），设置窗口「3D 硬币」内可实时调参并预览，Token 板块大数字旁的小硬币同步跟随
- 🎨 **外观深度可调** — 面板背景色（含上下两端不透明度）、点阵主题色 / 点阵背景色 / 卡片 hover 底色、主标题字号与间距系数；header 图标可拖拽换位
- 🌗 **浅色主题** — 一键强制浅色外观，配色与副文本对比度自动重解算
- ⬆️ **应用内自更新** — 右键菜单「检查更新…」或设置里的自动检查，拉取 GitHub Releases 最新包，SHA256 + 签名双重校验后静默替换并自动重启
- 💾 **配置导出 / 导入** — 设置窗口「关于」一键把全部设置与账号凭据打包成 JSON，便于迁移与备份
- 🔒 **本地优先** — 配置与缓存在本机闭环，零遥测、零上报
- 🧩 **打磨的原生 UI** — 滚动数字动画、卡片拖拽排序、HoverCard 反馈、置顶浮窗与可折叠板块

## 📦 支持平台

| 平台 | 接入方式 | 多账号 | 自动签到 | 一键切号 | Token 统计 |
| --- | --- | :-: | :-: | :-: | :-: |
| **DeepSeek** | 官方 API 查询余额，可设置常用充值额度以显示用量进度 | — | — | — | — |
| **Zhipu**（智谱 BigModel） | 自动读取浏览器登录态查可用余额，支持手填 token 覆盖 | — | — | — | — |
| **Qwen**（通义千问） | 读取浏览器登录态查周额度，支持手填 ticket 覆盖 | — | — | — | — |
| **WorkBuddy** | CodeBuddy 积分查询，OAuth 采集账号，token 自动刷新 | ✅ | ✅ | ✅ | ✅ |
| **TRAE** | 读取本地 storage.json（解密）查询积分 | ✅ | ✅ | ✅ | — |
| **ZCode**（智谱 Coding Plan） | 读取本机 JWT，展示额度百分比与重置倒计时，JSON 导入 | ✅ | — | ✅ | ✅ |
| **Codex** | 从本机 auth.json 导入，usage 接口查询额度百分比 | ✅ | — | ✅ | ✅ |

> 另提供 **Cockpit Tools** 快捷入口（检测到本地安装时显示）。

面板核心能力一目了然：余额卡片分组展示、同平台多账号归拢、千分位滚动数字、临期/告警状态标记——所有数据均来自各平台官方接口与本机登录态。

## 🚀 安装

要求：Apple Silicon Mac（arm64），macOS 12 及以上。

### 方式一：图形界面下载

1. 前往 [Releases](https://github.com/onerxxx/iBalance/releases/latest) 下载最新的 `.zip`
2. 解压后将 `iBalance.app` 拖入「应用程序」文件夹
3. 双击打开，菜单栏出现图标即运行成功（纯菜单栏应用，无 Dock 图标）

> [!IMPORTANT]
> 应用使用自签证书分发且未经公证，**经浏览器下载并解压的包会带 quarantine 标记**，首次打开若提示「已损坏」或「无法验证开发者」，在终端执行后重新打开即可：
>
> ```bash
> xattr -dr com.apple.quarantine /Applications/iBalance.app
> ```

### 方式二：命令行一键安装（推荐）

`curl` 链路全程不产生 quarantine 标记，无需任何放行操作：

```bash
# 1. 从 GitHub Releases 解析最新版直链
URL=$(curl -fsSL https://api.github.com/repos/onerxxx/iBalance/releases/latest \
      | grep -o 'https://[^"]*\.zip' | head -1)

# 2. 下载并解压到「应用程序」
curl -fsSL "$URL" -o /tmp/iBalance.zip
ditto -x -k /tmp/iBalance.zip /Applications/

# 3. 启动
open /Applications/iBalance.app
```

### 更新

应用内已内置更新：**右键菜单 →「检查更新…」** 手动检查（有新版本直接拉起更新窗口，无新版 / 失败走系统提示）；也可在 **设置 → 关于** 打开 **自动检查更新**（每日静默一次，下载前完成 SHA256 与签名校验）。

部分功能依赖对应应用的本地登录态（如浏览器 Cookie、auth 文件），首次使用时按系统弹窗授予相应权限即可。

## 🎛 设置窗口

侧栏七项，改动**即时生效并自动落盘**，没有「保存」按钮。入口：面板 header 左上角的设置按钮（退出按钮右侧）；部分入口会直接落到对应面板（如卡片右键「Key / 额度设置…」→ 账号）。

| 面板 | 内容 |
| --- | --- |
| **主题外观** | 面板背景色（色盘，含上下两端不透明度）、主题色、点阵背景色、卡片 hover 背景色、浅色主题、卡片字号与主副标题间距、图标深浅互换、长进度卡片 |
| **签到** | 自动签到开关、每号签到状态、手动签到与签到历史 |
| **平台** | 逐平台开关：是否参与刷新 / 自动签到 / 面板余额卡片 / 用量行 |
| **账号** | 各平台账号列表（逐条删除）、Key / 额度与 token 覆盖 |
| **3D 硬币** | 硬币预览 + 颜色 / 尺寸 / 厚度 / 边纹 / 阴影（opacity、spread）/ 运动参数，实时可调 |
| **菜单栏** | 菜单栏「进行中」状态点的弹跳参数（带实时预览） |
| **关于** | 版本信息、自动检查更新、更新窗口演示、配置导出 / 导入 |

## 🔐 隐私与安全

- 所有配置、token 与缓存统一存放于本机，**不会上传任何第三方服务器**：

  ```
  ~/Library/Application Support/com.local.ibalance/    # 目录 0700 / 文件 0600
  ```

- 凭据仅用于向对应平台官方接口查询余额；**切号**时写回的是该应用自己的本机凭据文件，随后重启该应用生效
- 各平台 token / API Key 等敏感值在配置文件里只留占位，真实值存 macOS **钥匙串**（打包成一条，解锁一次即可读全量）
- 设置窗口「关于」的**导出文件含明文凭据**（迁移用），请自行妥善保管
- 移动或更新 App 不影响用户数据；旧版本 `.app` 同目录的历史配置会自动迁移
- 敏感配置文件已通过 `.gitignore` 排除，不会进入版本控制；发版打包内置了凭据泄漏校验闸门

## 🛠 构建与开发

```bash
git clone https://github.com/onerxxx/iBalance.git
cd iBalance/swift
./build.sh          # 编译 + 打包 + 签名 + 自动重启 App（fast 模式，约十余秒）
./build.sh --release   # 正式发版才需要：-O 优化编译
```

- 版本号自动生成 `YYYY.M.D.N`（日期 + 当日序号），由 `swift/.build_state` 维护
- 使用固定自签证书 **iBalance Local Sign**（10 年有效）签名；勿改用 ad-hoc / 删除该证书，否则每次重建都会丢失 macOS TCC 授权与登录项
- 向外分发新版本使用根目录 `release.sh`（打 zip + 创建 GitHub Release，带泄漏校验）
- 设置界面是独立 SwiftPM target `SettingsUI`（`swift/SettingsUI/`）。⚠️ 该 target **不要写 `@State` / `#Preview` 等 SwiftUI 宏** —— 本机工具链是 Command Line Tools，没有 `SwiftUIMacros` 插件，会编不过；状态统一放 `@Observable` 的模型里
- 面板/弹窗里不好用 SwiftUI 重写的块（3D 硬币舞台、平台开关表格）由 `SettingsHostedContent` 整块内嵌进设置窗口右栏

深入的项目指南（数据流、编码约定、踩坑记录）见 [AGENT.md](AGENT.md)。

## 📂 项目结构

```
.
├── AGENT.md                 # 开发指南（架构 / 口径 / 踩坑记录）
├── AGENTS.md                # 协作约定（改完即编译、不截图验收等）
├── release.sh               # 发版脚本：release 构建 → 打包 → GitHub Release
├── docs/                    # 专题文档（见下方索引）
└── swift/
    ├── main.swift              # 入口 + AppDelegate（菜单栏 / 定时器 / 刷新编排 / 设置接线）
    ├── Config.swift            # 配置模型与落盘（config.json + 钥匙串凭据）
    ├── Panel.swift             # 详情面板：余额卡片、header、气泡、配色 Palette
    ├── PanelLayout.swift       # 面板布局计算与装配
    ├── PanelDrag.swift         # 卡片排序拖拽 + header 图标拖拽换位
    ├── PinWindow.swift         # 面板置顶浮窗（borderless NSPanel + 拖动 / 缩放）
    ├── UsagePanel.swift        # 用量子面板（趋势柱状图 + 进度点阵 UsageDots）
    ├── TokensPanel.swift       # Token 板块（周期统计 / 词元活动热力图 / 项目与模型列表）
    ├── WbTokens.swift · CodexTokens.swift   # WorkBuddy / Codex 的 Token 统计
    ├── RollingNumberView.swift · SmallTable.swift  # 逐位滚动数字 / 小表格配色
    ├── Controls.swift          # 通用控件（HoverCard / HoverIconButton / 分段控件 …）
    ├── HoverMaterial.swift     # 卡片 hover 材质（共享宿主：渐变底 + 发丝描边）
    ├── CoinDemo.swift · CoinSVG.swift       # 3D 硬币（自绘 CG + SVG 雕塑管线）
    ├── GlassModalShell.swift · Dialogs.swift# 模态壳与弹窗封装
    ├── UpdateService.swift · UpdateProgressWindow.swift  # 应用内自更新与更新窗口
    ├── CheckinManager.swift · AccountSwitcher.swift      # 错峰签到 / 多账号采集与切号
    ├── BackupService.swift     # 设置窗口的配置导出 / 导入
    ├── MenuBarGlow.swift · DisplayTicker.swift           # 菜单栏光晕 / 逐帧驱动
    ├── KeychainStore.swift · Crypto.swift · Network.swift · ProcessUtil.swift · Logger.swift
    ├── SettingsWindow.swift    # 设置窗口宿主（NSHostingController + 内嵌 AppKit 面板）
    ├── SettingsUI/             # SwiftPM target：设置窗口的 SwiftUI 界面与模型（AppSettingsModel / AppSettingsView）
    ├── Services/               # 平台接入：DeepSeek / BigModel / Qwen / WorkBuddy / Trae / Zcode / Codex
    │                           #（另有 WbShare / BrowserCookieStore / AgentTaskStatus）
    ├── fonts/ · icons/         # 内嵌字体（Inter Variable / JetBrains Mono NL）与 SVG 图标
    └── build.sh                # 一键构建脚本
```

## 📖 文档索引

| 文档 | 内容 |
| --- | --- |
| [docs/PACKAGING.md](docs/PACKAGING.md) | zip 分发流程与敏感字段泄漏校验 |
| [docs/updater-implementation.md](docs/updater-implementation.md) | 应用内自更新的完整实现解析 |
| [docs/card-drag-framework.md](docs/card-drag-framework.md) | 余额卡片拖拽排序框架设计 |
| [docs/macos-panel-ui-guide.md](docs/macos-panel-ui-guide.md) | macOS 面板 UI 开发实践 |
| [docs/macos-26-appkit-migration.md](docs/macos-26-appkit-migration.md) | macOS 26 AppKit 迁移笔记 |
| [docs/native-segmented-control-guide.md](docs/native-segmented-control-guide.md) | 原生分段控件用法 |
| [docs/menubar-template-pitfalls.md](docs/menubar-template-pitfalls.md) | 菜单栏模板踩坑记录 |
| [docs/glass-modal-window-guide.md](docs/glass-modal-window-guide.md) | 玻璃质感模态窗的实现要点 |
| [docs/hover-confirm-layout-shift-pitfalls.md](docs/hover-confirm-layout-shift-pitfalls.md) | hover 确认与布局位移踩坑 |
| [docs/core-animation-pitfalls.md](docs/core-animation-pitfalls.md) | Core Animation 踩坑（含动态色落 layer 定格） |
| [docs/iBalance-已损坏说明.html](docs/iBalance-%E5%B7%B2%E6%8D%9F%E5%9D%8F%E8%AF%B4%E6%98%8E.html) | 首次打开提示「已损坏」的说明页 |

<details>
<summary>内部记录（非对外文档）</summary>

- `docs/IMPROVEMENTS.md`、`docs/IMPROVEMENTS-2026-09-08.md`：迭代记录
- `docs/UIUX-OPTIMIZATION.md`：UI/UX 优化清单
- `docs/FEATURE-IDEAS-2026-09-12.md`：待评估的功能想法

</details>

---

<div align="center">
<sub>用 AppKit 认真写的菜单栏小工具 · 觉得有用的话欢迎点个 Star ⭐</sub>
</div>
