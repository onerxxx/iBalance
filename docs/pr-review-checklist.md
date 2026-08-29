# PR 自查清单

> 面向 iBalance 的改动约定。项目是纯 AppKit、无自动化测试，因此评审靠人工核对，
> 这份清单用来固定「每次提 PR 前自己先过一遍」的顺序。

## 提交前

- [ ] `swift/build.sh` 能通过，主面板 / 右键菜单 / 置顶浮窗三条路径都手动点一遍
- [ ] 中文 conventional commit，scope 与既有口径一致（`panel` `Dialogs` `menubar` `update` `font` `swift`）
- [ ] 未跟踪文件只包含本次改动，工具产物（`.codegraph/`、`.build/`、`backups/`、zip 包）不入库
- [ ] 没有把 `config.json` 里的真实账号、token、cookie 带进 diff

## 样式改动

- 表格类排版参数只认 [swift/SmallTable.swift](../swift/SmallTable.swift)，用量表与 Token 面板两侧禁止各自硬编码
- 字号、颜色、间距优先走既有语义变量，不新增一次性魔法数
- 深色 / 浅色两套主题都要看，不能只在一种主题下调好

## 数据与网络

- 平台接入改动落在 `swift/Services/` 对应文件，切号与签到逻辑要单独回归
- 今日 / 本周用量为本地差值方案，跨天、跨周、充值、额度重置四种边界都要验
- 请求失败必须离线感知，不允许把错误直接抛到菜单栏可见位置

## 发版相关

- 改到分发结构时同步核对 [PACKAGING.md](PACKAGING.md) 的敏感字段泄漏校验
- 改到自更新链路时核对 [updater-implementation.md](updater-implementation.md)，SHA256 与签名校验缺一不可

## 评审时看什么

1. 先看行为差异，再看实现风格；应用户侧可见的回归优先级最高
2. 菜单栏应用没有「重新加载」兜底，任何崩溃路径都按阻断处理
3. 只改父容器还是连带改了子层，作用域要在描述里写清楚
