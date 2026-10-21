# 单发射实验报告

默认电路为 v109。2026-10-21 新官方综合流程复测为 **423.32 MHz / 18,831.74 μm²**，超过 Tier2 面积上限；当前结果见 [复测报告](remeasure-2026-10-21/report.md) 和 [latest-measurement.json](../latest-measurement.json)。下方阶段表为历史记录。参数和冻结实验由 [baseline.json](../baseline.json)固定。生成、编译和测试命令见[工程说明](../README.md)。

| 阶段 | 性能 / 参数对照 | 优化记录 |
| --- | --- | --- |
| [stage1](stage1/) | [comparison](stage1/comparison.md) | [notes](stage1/optimization-notes.md) |
| [stage2](stage2/) | [comparison](stage2/comparison.md) | [notes](stage2/optimization-notes.md) |
| [stage3](stage3/) | [comparison](stage3/comparison.md) | [notes](stage3/optimization-notes.md) |
| [stage4](stage4/) | [comparison](stage4/comparison.md) | [notes](stage4/optimization-notes.md) |
| [stage5](stage5/) | [comparison](stage5/comparison.md) | [notes](stage5/optimization-notes.md) |

各候选目录保存冻结源码、生成 RTL、参数清单及原始日志。[validation/](validation/)保存算术、地址、队列和临时结果的独立验证。两条实现路线的完整索引见[仓库报告目录](../../reports/README.md)。
