<div align="center">

<img src="swift/icons/App-Icon-Default-1024@1x.png" width="96" alt="iBalance">

# iBalance

macOS 菜单栏应用，在本机聚合多个 AI 服务的余额与额度。

macOS 26 及以上 · Apple Silicon · Swift + AppKit

</div>

## 特性

- 菜单栏常驻：左键弹出详情面板，右键为传统菜单；每个条目可单独控制是否在菜单栏显示
- 多账号：采集或导入多个账号，一键切号（写回对应应用的本机凭据并重启该应用）
- 自动签到：WorkBuddy 与 TRAE 每号每日随机延迟签到，另有手动签到与签到历史
- 用量统计：今日 / 本周用量按本地差值计算，跨天跨周自动重置，充值与重置自动校准
- Token 板块：ZCode / WorkBuddy / Codex 的词元统计，周期可切（5h / 1d / 7d / 30d / All），含活动热力图、项目与模型排行、最近会话均速 tok/s
- 3D 硬币：自绘的金属硬币，可在设置中实时调参，Token 大数字旁的小硬币同步跟随
- 外观可调：面板背景色与上下两端不透明度、次背景色、用量色、主标题字号；header 图标可拖拽换位
- 主题预设：内置六套，也可把当前参数存成自己的预设；改动自动保存，可认下、重置或恢复初始
- 浅色主题：一键强制浅色外观，配色与副文本对比度自动重算
- 应用内更新：手动检查或每日自动检查 GitHub Releases，校验 SHA256 与签名后替换并重启
- 配置导出 / 导入：设置与账号凭据打包为 JSON，便于迁移与备份
- 本地优先：配置与缓存都在本机，无遥测、无上报

## 支持的平台

| 平台 | 接入方式 | 多账号 | 自动签到 | 切换账号 | Token 统计 |
| --- | --- | --- | --- | --- | --- |
| DeepSeek | 官方 API 查询余额，可设置常用充值额度以显示用量进度 | — | — | — | — |
| Zhipu（智谱 BigModel） | 读取浏览器登录态查可用余额，可手填 token 覆盖 | — | — | — | — |
| Qwen（通义千问） | 读取浏览器登录态查周额度，可手填 ticket 覆盖 | — | — | — | — |
| WorkBuddy | CodeBuddy 积分查询，OAuth 采集账号，token 自动刷新 | ✓ | ✓ | ✓ | ✓ |
| TRAE | 读取本地 storage.json（解密）查询积分 | ✓ | ✓ | ✓ | — |
| ZCode（智谱 Coding Plan） | 读取本机 JWT，展示额度百分比与重置倒计时，JSON 导入 | ✓ | — | ✓ | ✓ |
| Codex | 从本机 auth.json 导入，usage 接口查询额度百分比 | ✓ | — | ✓ | ✓ |

面板提供余额卡片分组、同平台多账号归拢、千分位滚动数字与临期标记；数据均来自各平台官方接口与本机登录态。另有 Cockpit Tools 快捷入口（检测到本地安装时显示）。

## 安装

要求：macOS 26 及以上，Apple Silicon。

### 下载安装

1. 到 [Releases](https://github.com/onerxxx/iBalance/releases/latest) 下载最新的 `.zip`
2. 解压后将 `iBalance.app` 拖入「应用程序」
3. 双击打开，菜单栏出现图标即表示运行成功（纯菜单栏应用，无 Dock 图标）

> 应用以自签证书分发、未经公证，经浏览器下载解压的包会带 quarantine 标记。首次打开若提示「已损坏」或「无法验证开发者」，在终端执行下面一行后重新打开：
>
> ```bash
> xattr -dr com.apple.quarantine /Applications/iBalance.app
> ```

### 命令行安装

`curl` 链路不产生 quarantine 标记，无需放行操作：

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

应用内已内置更新：右键菜单「检查更新…」手动检查（有新版本即拉起更新窗口，无新版或失败走系统提示），也可在「关于」页打开自动检查（每日静默一次，下载前完成 SHA256 与签名校验）。

部分功能依赖对应应用的本地登录态（浏览器 Cookie、auth 文件等），首次使用时按系统弹窗授予相应权限即可。

## 设置窗口

侧栏六页：主题外观 / 3D 硬币 / 签到 / 平台 / 账号 / 关于。改动即时生效并自动落盘，没有「保存」按钮。入口为面板 header 左上角的设置按钮（退出按钮右侧）；部分入口会直接落到对应页面，例如卡片右键「Key / 额度设置…」直达账号页。

| 页面 | 内容 |
| --- | --- |
| 主题外观 | 主题预设（内置六套 + 自建，改动自动保存）、面板背景色与两端不透明度、次背景色、主前景色、用量色、浅色主题、卡片字号、图标与卡片样式 |
| 3D 硬币 | 硬币预览，颜色 / 尺寸 / 厚度 / 边纹 / 阴影 / 运动参数实时可调 |
| 签到 | 自动签到开关、各账号签到状态、手动签到与签到历史 |
| 平台 | 逐平台开关：是否参与刷新 / 自动签到 / 面板余额卡片 / 用量行 |
| 账号 | 各平台账号列表与逐条删除、Key / 额度与 token 覆盖、账号导入与 WorkBuddy 同步 |
| 关于 | 版本信息、自动检查更新、更新窗口演示、配置导出 / 导入 |

## 隐私与安全

- 配置、token 与缓存都存放在本机，不上传任何第三方服务器：

  ```
  ~/Library/Application Support/com.local.ibalance/    # 目录 0700 / 文件 0600
  ```

- 凭据只用于向对应平台的官方接口查询余额；切号写回的是该应用自己的本机凭据文件，随后重启该应用生效
- 配置文件里敏感字段只留占位，真实值存 macOS 钥匙串（打包为一条，解锁一次即可读全量）
- 「关于」页导出的备份文件含明文凭据，仅用于本机之间迁移，请自行妥善保管
- 移动或更新 App 不影响已有数据；旧位置的历史配置会自动迁移
- 敏感配置文件已由 `.gitignore` 排除，不会进入版本控制；发版打包内置凭据泄漏校验

## 构建与开发

```bash
git clone https://github.com/onerxxx/iBalance.git
cd iBalance/swift
./build.sh              # 编译 + 打包 + 签名 + 自动重启 App
./build.sh --release    # 正式发版才需要：-O 优化编译
```

- 版本号按 `YYYY.M.D.N` 自动生成（日期 + 当日序号），计数存 `swift/.build_state`
- 使用固定自签证书 iBalance Local Sign（10 年有效）签名。不要改用 ad-hoc 或删除该证书，否则每次重建都会丢失 macOS TCC 授权与登录项
- 对外分发使用根目录 `release.sh`：先提交并推送当前改动，再打 zip、创建 GitHub Release，并做凭据泄漏校验
- 设置界面是独立 SwiftPM target `SettingsUI`（`swift/SettingsUI/`）。该 target 不要使用 `@State` / `#Preview` 等 SwiftUI 宏——本机工具链是 Command Line Tools，缺少 SwiftUIMacros 插件会编译失败；状态统一放在 `@Observable` 模型里
- 面板与弹窗中不便用 SwiftUI 重写的部分（3D 硬币舞台、平台开关表格）由 `SettingsHostedContent` 整块内嵌到设置窗口右栏
- 项目结构、数据流与编码约定见 [AGENT.md](AGENT.md)
