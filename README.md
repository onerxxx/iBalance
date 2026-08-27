<div align="center">

# iBalance

**一款纯原生 AppKit 打造的 macOS 菜单栏应用，实时聚合多个 AI 服务的余额与额度**

多账号管理 · 一键切号 · 自动签到 · 日/周用量统计 · 应用内自动更新

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
- ⬆️ **应用内自更新** — 直接拉取 GitHub Releases 最新包，SHA256 + 签名双重校验后静默替换并自动重启
- 🔒 **本地优先** — 配置与缓存在本机闭环，零遥测、零上报
- 🎨 **深度打磨的原生 UI** — 滚动数字动画、卡片拖拽排序、HoverCard 反馈、置顶浮窗模式

## 📦 支持平台

| 平台 | 接入方式 | 多账号 | 自动签到 | 一键切号 |
| --- | --- | :-: | :-: | :-: |
| **DeepSeek** | 官方 API 查询余额，可设置常用充值额度以显示用量进度 | — | — | — |
| **Zhipu**（智谱 BigModel） | 自动读取浏览器登录态查可用余额，支持手填 token 覆盖 | — | — | — |
| **WorkBuddy** | CodeBuddy 积分查询，OAuth 采集账号，token 自动刷新 | ✅ | ✅ | ✅ |
| **TRAE** | 读取本地 storage.json（解密）查询积分 | ✅ | ✅ | ✅ |
| **ZCode**（智谱 Coding Plan） | 读取本机 JWT，展示额度百分比与重置倒计时，JSON 导入 | ✅ | — | ✅ |
| **Codex** | 从本机 auth.json 导入，usage 接口查询额度百分比 | ✅ | — | ✅ |

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

应用内已内置更新：点击操作区 **「检查更新」磁贴**手动检查，或在设置中开启 **自动检查更新**（每日至多一次，下载前完成 SHA256 与签名校验）。

部分功能依赖对应应用的本地登录态（如浏览器 Cookie、auth 文件），首次使用时按系统弹窗授予相应权限即可。

## 🔐 隐私与安全

- 所有配置、token 与缓存统一存放于本机，**不会上传任何第三方服务器**：

  ```
  ~/Library/Application Support/com.local.ibalance/    # 目录 0700 / 文件 0600
  ```

- 凭据仅用于向对应平台官方接口查询余额；**切号**时写回的是该应用自己的本机凭据文件，随后重启该应用生效
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

深入的项目指南（数据流、编码约定、踩坑记录）见 [AGENT.md](AGENT.md)。

## 📂 项目结构

```
.
├── AGENT.md                 # 开发指南（架构 / 约定 / 踩坑记录）
├── release.sh               # 发版脚本：release 构建 → 打包 → GitHub Release
├── docs/                    # 专题文档（见下方索引）
└── swift/
    ├── main.swift           # 入口 + AppDelegate（菜单栏 / 定时器 / 刷新编排）
    ├── Panel.swift          # 详情面板：全部自定义控件 + 卡片拖拽排序
    ├── PanelLayout.swift    # 面板布局计算
    ├── PinWindow.swift      # 面板置顶浮窗（borderless NSPanel + 拖动）
    ├── UsagePanel.swift     # 用量图表子面板
    ├── Dialogs.swift        # 弹窗统一封装（DialogShell / InputDialog …）
    ├── Controls.swift       # 通用控件（HoverCard / RollingNumberView …）
    ├── CheckinManager.swift # 错峰自动签到 / 签到历史
    ├── AccountSwitcher.swift# 多账号采集与切换编排
    ├── UpdateService.swift  # 应用内自更新（GitHub Releases 拉取 + 校验）
    ├── Network.swift        # async HTTP + 重试 + 离线感知
    ├── Crypto.swift         # SHA-512 / AES-CBC / PBKDF2
    ├── ProcessUtil.swift    # 进程工具（找主进程 / 温和杀 / 强杀 / 等待退出）
    ├── Services/            # 各平台接入：DeepSeek / WorkBuddy / Trae / Zcode / Codex / BigModel
    ├── fonts/ · icons/      # 内嵌字体（Inter Variable / JetBrains Mono NL）与 SVG 图标
    └── build.sh             # 一键构建脚本
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

---

<div align="center">
<sub>用 AppKit 认真写的菜单栏小工具 · 觉得有用的话欢迎点个 Star ⭐</sub>
</div>
