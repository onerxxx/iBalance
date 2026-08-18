# iBalance

macOS 菜单栏常驻应用（NSStatusItem），实时聚合显示多个 AI 服务的余额 / 额度，并支持多账号管理与一键切号。

纯菜单栏应用（`LSUIElement = true`，无 Dock 图标），最低支持 macOS 12（Apple Silicon, arm64）。

## 支持平台

| 平台 | 能力 |
| --- | --- |
| **DeepSeek** | API 余额查询，设置常用充值额度后面板显示用量进度 |
| **WorkBuddy** | CodeBuddy API 积分查询，多账号卡片、多号签到、OAuth 账号采集、token 自动刷新、多号切换 |
| **TRAE** | 读取本地 storage.json（byteCrypto 解密）查询积分，多账号采集 / 切换 / 自动签到 |
| **ZCode** | 读取本机 JWT 查询额度百分比与重置倒计时，JSON 导入多账号、多号切换 |
| **Codex** | 从本机 auth.json 导入登录账号，usage 接口查询额度，多号切换 |
| **Cockpit Tools** | 菜单项打开本地 App 入口 |

切号 = 写回对应应用的本机凭据文件 + 杀进程重启该应用，全流程统一编排（后台执行 → 回主线程刷新 → 延迟关面板）。

## 交互

- **左键**点菜单栏图标：弹出详情面板（NSPopover，余额卡片 + 设置 + 操作磁贴）
- **右键**点菜单栏图标：传统 NSMenu 兜底入口，选项与面板同步
- 余额卡片支持**拖拽排序**，顺序持久化，菜单栏条目与面板共用同一份排序
- 「用量」分组展示各平台**今日 / 本周用量**：本地差值方案（记录当日/当周首观基线，跨天/跨周自动重置，充值/重置自动校准），随定时刷新更新
- 余额卡片 hover 显示账号信息，右键可开关各条目在菜单栏的显隐

## 构建与运行

```bash
cd swift && ./build.sh    # 编译 + 打包 + 签名 + 自动重启 App
```

- build.sh 自动收集 `swift/` 下所有 `.swift`（含 `Services/` 子目录），先停旧进程再组装 bundle
- 版本号自动生成 `YYYY.M.D.N`（日期 + 当日构建序号），由 `swift/.build_state` 维护
- 使用固定自签证书 **`iBalance Local Sign`**（10 年有效）签名。**勿删该证书**：换 ad-hoc 签名会导致 macOS TCC 授权（如完全磁盘访问）每次重建后失效
- 分发打包（zip）流程见 `PACKAGING.md`

## 用户数据

配置与余额缓存统一存放在：

```
~/Library/Application Support/com.local.ibalance/   # 目录 0700 / 文件 0600
```

首次启动会从旧版 `.app` 同目录自动迁移 `config.json` / `cache.json`，移动或更新 App 不影响用户数据。

## 目录结构（摘要）

```
swift/
├── main.swift           # 入口 + AppDelegate（菜单栏 / 定时器 / 面板与签到编排）
├── Panel.swift          # 详情面板：全部自定义控件 + 卡片拖拽排序
├── Config.swift         # AppConfig + Application Support 持久化/迁移 + 余额缓存
├── Network.swift        # async HTTP + 重试 + 离线感知
├── Crypto.swift         # SHA-512 / AES-CBC / PBKDF2
├── ProcessUtil.swift    # 切号共用进程工具（找主进程/温和杀/强杀/等待退出）
├── Services/            # DeepSeek / WorkBuddy / Trae / Zcode / Codex
└── build.sh             # 编译 + 打包 + 签名 + 自动重启
```

完整开发指南（数据流、编码约定、踩坑记录）见 `AGENT.md`。

## 安全注意

- 用户配置（API Key / 各平台 token）**不在版本控制中**（`.gitignore` 已排除），请勿提交
- 打 zip 分发前必须走 `PACKAGING.md` 的敏感字段泄漏校验
