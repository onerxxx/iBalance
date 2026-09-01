# Animation Plans — iBalance

由 emil-improve-animations 审计产出（2026-09-01，scope：Agent 卡子账号条入场/离场动效链路）。

| # | Plan | Severity | Status |
|---|------|----------|--------|
| 001 | [sink alpha 表现层接管（打断弹亮）](001-sink-alpha-presentation-takeover.md) | HIGH | DONE (v2026.9.1.18) |
| 002 | [Motion token 收敛（chipStagger / stripSwap / easeOutCubic）](002-motion-token-consolidation.md) | MEDIUM | DONE (v2026.9.1.18) |
| 003 | [点阵淡变位图 1:1 烘焙（消除切换微位移跳动）](003-heat-dotfade-bitmap-1to1-bake.md) | MEDIUM | DONE (v2026.9.1.34) |
| 006 | [中断态动效重设计：信号断续 + 橙红 #FF7333](006-interrupted-glitch-signal.md) | HIGH | DONE (v2026.9.2.15) |

## 未立项（审计记录在案）

- **#2 结构重构**（MEDIUM）：换入/换出状态机散布 5 处（epoch / revealWork /
  exitInFlight / isCancelled 轮询 / pending 计数）+ 双通道动画。数值层已定稿正确，
  结构层是历次 bug 温床。若再出此类 bug，优先立项重构为集中式过渡助手。
- **#4 rise 起点硬编码**（LOW）：当前事件时序下不可达，随 #2 一并处理。
- **#5 animateLayerKey 注释漂移**（LOW）：未执行，随手可修。

## 用户定稿参数（不翻案）

sink easeIn 重力感、14pt/0.35s/0.06s、rise 10pt/0.4s/0.1s、点阵 1.0s 恢复、
dwell 0.8s——均经多轮手感迭代定稿，Motion 表豁免口径见各 token 注释。
