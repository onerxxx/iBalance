# 项目 TODO

## 已完成（近期）
- [x] 配置迁移到系统路径 `~/Library/Application Support/com.local.ibalance/`（含旧位置兼容迁移）
- [x] 菜单栏条目使用平台图标（PDF 矢量栅格化 + template 位图烘焙管线）
- [x] 日/周用量板块（本地差值方案 + UsageStore 基线持久化）
- [x] 用量历史面积图（7 天余额曲线 + 峰值 callout + 亮度阶梯）
- [x] WorkBuddy 多号 OAuth 采集 + token 自动刷新 + 自动签到错峰
- [x] ZhiPu（BigModel）余额卡片：token 浏览器采集支持 Edge + Chrome
- [x] 滚动数字视图 RollingNumberView（3s 滚轮动效）
- [x] 移除 QuietScrollView 平滑滚动管线，回归系统原生滚动
- [x] 启动不再弹 API Key 引导，改为菜单内手动配置
- [x] 面板 pin 浮窗模式 + 滚动顶部锚定 + 布局自测设施
- [x] macOS 26 适配（deployment target / 容器遮罩 / 通知 async API）

## 近期可做（小改进，低成本）
- [ ] `bundleIcon()` 加缓存：SVG 每轮重解析是遗留浪费点（实测解析 ~µs 级 vs 缓存命中 2.9µs，~400x 差距）
- [ ] 菜单栏图标接入 ASCII 像素字模（`AsciiIconProvider` 已有，menubar 渲染管线未接）
- [ ] 滚动提示层（ScrollFadeHint）参数面板入口收纳进设置弹窗（目前依赖 config.json 手调）
- [ ] 清理 `swift/` 下的临时文件（`*.orig` / `*.tmp_orig` / `scratch_*`），build.sh 已排除但仍碍眼
- [ ] 余额卡片右键菜单加「复制余额」快捷项
- [ ] 刷新失败时按平台分组显示错误原因（目前统一 footer 提示）

## 中期方向（功能扩展）
- [ ] **用量历史延长**：7 天 → 14/30 天可切换，SQLite 已就绪（-lsqlite3 已链接），只差 UI 与聚合查询
- [ ] **余额趋势提醒**：额度低于阈值（如 10%）时推送系统通知，阈值进 config.json 按平台可调
- [ ] **月度账单汇总**：按月聚合用量差值，生成简易报表（Markdown 导出或面板内查看）
- [ ] **更多平台接入**：Codex 卡片已有显隐开关但未接数据源；可参考 Cockpit Tools 的 API 清单补齐
- [ ] **ZCode 套餐到期提醒**：`planEndsAt` 已在缓存，加提前 N 天通知
- [ ] **账号分组管理**：多账号时按平台折叠/展开，或拖拽排序（目前顺序固定）

## 远期构想（可选）
- [ ] **SwiftUI 重写面板层**：AppKit 约束布局维护成本高（布局回归靠自测设施兜底），SwiftUI 声明式更适合密集迭代；菜单栏+popover 壳保留 AppKit
- [ ] **轻量 Sparkle 自动更新**：目前升级靠手动跑 build.sh + 重启，接入 Sparkle 后可静默更新（需解决自签证书与 Gatekeeper）
- [ ] **iOS/iPadOS 伴侣端**：余额数据上报到私有端点（如 iCloud KV 或自建），手机端小组件查看——工作量主要在数据同步协议
- [ ] **CLI 子命令**：`ibalance refresh` / `ibalance checkin` 供脚本/快捷指令调用，复用 Service 层
- [ ] **测试补齐**：Service 层（token 解析/刷新/签到判定）目前零测试，抽协议 mock 后可上 XCTest

## 维护性备忘（不做新功能也要留意）
- ~~build.sh 打包必须走 /tmp 副本替换 config~~（已过时：用户配置已迁 Application Support，`swift/config.json` 只是空 Key 模板，直接 `cp` 进 bundle 即可，无泄露风险）
- `refreshSeq` 版本控制 + `ownsRefresh` 守卫模式是刷新安全的核心，新子任务必须遵守
- 所有 HTTP 请求走 `Logger.measure` + `/tmp/iBalance_network.log`，排查问题先看日志
- 约束变更回归用 `IBLayoutAutoTest` 自动设施（25s 一轮迭代）
