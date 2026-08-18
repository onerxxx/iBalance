# 下个版本 TODO

## 1. 配置迁移到系统路径
- [x] 用户配置和余额缓存迁移到 `~/Library/Application Support/com.local.ibalance/`
- [x] 首次启动兼容迁移旧位置 `config.json` / `cache.json`，并保留旧文件副本
- [x] 更新 build.sh / 打包脚本：运行时不再依赖 `.app` 旁的用户配置

## 2. 菜单栏条目使用平台图标
- [ ] 菜单栏各平台余额条目前加平台品牌 icon（DeepSeek / ZCode / TRAE / WorkBuddy，复用 `swift/icons/` 下的素材）
- [ ] 图标尺寸适配菜单栏字体行高（约 14–16pt），非 template 保留品牌原色
- [ ] 隐藏主 icon 开关与条目显隐逻辑（`menuBarVisible`）保持兼容

## 3. 日/周用量板块
- [x] 面板新增「用量」分组（与「余额 / 设置 / 操作」同级的 section），展示各平台今日 / 本周用量
- [x] 本地差值方案（不接平台用量 API）：UsageStore 记录当日/当周首观基线，跨天/跨周重置、充值/重置校准，用量 = 基线与当前余额差值
- [x] 用量数据随定时刷新更新（每次刷新 observe 一次，基线持久化 usage.json）
