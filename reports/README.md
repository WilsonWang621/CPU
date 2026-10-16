# 版本报告索引

当前默认结果见[双发射阶段 10](dual-issue/frequency-stage10.md)：503.69 MHz、35,900.33 μm²、延迟 20 IPC 1.113846、19/19 正确性。旧阶段保留当时的配置、流程和实测结果。

## 双发射 Verilog

| 阶段 | 报告内容 |
| --- | --- |
| [1](dual-issue/frequency-stage1.md) | 初始时序与额外物理缓冲实验 |
| [2](dual-issue/frequency-stage2.md) | 宽数组读取与空闲槽预写 |
| [3](dual-issue/frequency-stage3.md) | 默认综合路径优化 |
| [4](dual-issue/frequency-stage4.md) | 局部读取、恢复与地址路径实验 |
| [5](dual-issue/frequency-stage5.md) | 内存 IQ 下一状态选择及退休路径 |
| [6](dual-issue/frequency-stage6.md) | v42 旧流程基准与容量对照 |
| [7](dual-issue/frequency-stage7.md) | 新综合流程与 433.90 MHz 候选 |
| [8](dual-issue/frequency-stage8.md) | 分发树、选择器及 500 MHz 候选 |
| [9](dual-issue/frequency-stage9.md) | 487.85 MHz 默认输入独立复验 |
| [10](dual-issue/frequency-stage10.md) | 503.69 MHz 最终默认实现完整验收 |

## 双发射 Chisel

[最终验收报告](../dual-issue-chisel/reports/final/report.md)：原生双发射 Chisel **502.70 MHz、35930.97 μm²、IPC 1.222171 / 1.113846、19/19 正确性**；全部正确性和两组性能与参考 Verilog 逐周期 AXI 对照通过。[迁移记录](../dual-issue-chisel/reports/progress.md)保留各候选和证明边界。

## 单发射 Chisel

单发射源码、生成器和数据归档集中在[独立工程](../single-issue-chisel/README.md)，避免混用两条实现路线的参数与成绩。

| 阶段 | 性能 / 参数对照 | 实现与取舍 |
| --- | --- | --- |
| 1，v66 | [comparison](../single-issue-chisel/reports/stage1/comparison.md) | [优化记录](../single-issue-chisel/reports/stage1/optimization-notes.md) |
| 2，v71 | [comparison](../single-issue-chisel/reports/stage2/comparison.md) | [优化记录](../single-issue-chisel/reports/stage2/optimization-notes.md) |
| 3，v75 | [comparison](../single-issue-chisel/reports/stage3/comparison.md) | [优化记录](../single-issue-chisel/reports/stage3/optimization-notes.md) |
| 4，v94 | [comparison](../single-issue-chisel/reports/stage4/comparison.md) | [优化记录](../single-issue-chisel/reports/stage4/optimization-notes.md) |
| 5，v109 | [comparison](../single-issue-chisel/reports/stage5/comparison.md) | [优化记录](../single-issue-chisel/reports/stage5/optimization-notes.md) |

## 框架与原始数据

[框架同步记录](framework/upstream-sync-2026-10-15.md)说明官方综合工具更新和复核。[data/](data/README.md)按日期和阶段保存冻结输入、原始日志、报告及哈希清单。所有报告中的复现命令均从仓库根目录运行，单发射命令使用 `make -C single-issue-chisel`。
