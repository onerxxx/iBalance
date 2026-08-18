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
- [ ] 面板新增「用量」分组（与「余额 / 设置 / 操作」同级的 section），展示各平台今日 / 本周用量
- [ ] 各 Service 补用量查询 API（DeepSeek usage、WorkBuddy billing 等，按平台能力而定）
- [ ] 用量数据随定时刷新更新，可考虑本地累计快照（cache）用于计算日/周增量
