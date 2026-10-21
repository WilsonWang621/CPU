# 单发射实验报告

当前默认为 **v110：422.44 MHz / 17,933.13 μm²**，IPC 延迟 10/20 为 **0.87846442 / 0.84602401**，正确性各 19/19，达到 Tier2 + 400 MHz 的本地 97 分门槛。见 [v110 优化报告](area-recovery-2026-10-21/report.md)、[latest-measurement.json](../latest-measurement.json) 和 [baseline.json](../baseline.json)。[v109 新流程复测](remeasure-2026-10-21/report.md)保留超面积结论，下方阶段表保留历史记录。生成、编译和测试命令见[工程说明](../README.md)。

| 阶段 | 性能 / 参数对照 | 优化记录 |
| --- | --- | --- |
| [stage1](stage1/) | [comparison](stage1/comparison.md) | [notes](stage1/optimization-notes.md) |
| [stage2](stage2/) | [comparison](stage2/comparison.md) | [notes](stage2/optimization-notes.md) |
| [stage3](stage3/) | [comparison](stage3/comparison.md) | [notes](stage3/optimization-notes.md) |
| [stage4](stage4/) | [comparison](stage4/comparison.md) | [notes](stage4/optimization-notes.md) |
| [stage5](stage5/) | [comparison](stage5/comparison.md) | [notes](stage5/optimization-notes.md) |

各候选目录保存冻结源码、生成 RTL、参数清单及原始日志。[validation/](validation/)保存算术、地址、队列和临时结果的独立验证。两条实现路线的完整索引见[仓库报告目录](../../reports/README.md)。
