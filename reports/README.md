# 版本报告索引

返回[仓库首页](../README.md)查看三套实现与运行命令，或进入[项目文档](../docs/README.md)查看架构和接口。**当前默认入口是双发射 Chisel**；本索引中的数字均为已归档测量，本次文档整理未重跑仿真、综合或 STA。旧阶段保留当时的实现、配置、工具流程和结论。

## 默认双发射 Chisel

2026-10-16 的[完整要求与架构权衡报告](../dual-issue-chisel/reports/requirements-2026-10-16/report.md)记录 **502.70 MHz、35,930.97 μm²、IPC 1.222171 / 1.113846（延迟 10 / 20）**，两种延迟的正确性各 19/19。[14 组参数实验](../dual-issue-chisel/reports/requirements-2026-10-16/parameter-sensitivity.md)记录各配置的实际测试范围，不能将默认配置的面积/频率推广到所有变体。

[机器可读验收](../dual-issue-chisel/reports/requirements-2026-10-16/acceptance.json)与[冻结输入和原始日志](../dual-issue-chisel/reports/requirements-2026-10-16/verified/)绑定源码、RTL、课程工具和测试集身份。运行 `python3 dual-issue-chisel/scripts/audit_requirements.py` 可审计这些证据与当前输入的一致性；该命令不重新执行测试或测量。

[v13 历史验收](../dual-issue-chisel/reports/final/report.md)保留全部正确性、两组性能的双 CPU 逐周期 AXI 对照，以及组件形式证明和有界检查范围。[迁移记录](../dual-issue-chisel/reports/progress.md)保留各候选与取舍。源码、生成和原生验证入口见[工程说明](../dual-issue-chisel/README.md)。

## 双发射 Verilog 参考

2026-10-16 的阶段 10 归档为 **503.69 MHz、35,900.33 μm²**；正确性为延迟 20 的 19/19，两组 IPC 见对应报告。下列报告曾将 Verilog 称为“默认实现”，这是测量时的入口。今天复现参考实现须显式使用 `FILELIST=verilog/reference_filelist.f`，并为 `make build/test/perf` 使用独立的构建目录与 `SIM`；不加 `FILELIST` 的当前根构建/综合会选择 Chisel。具体命令见[首页](../README.md#verilog-参考实现)。

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
| [10](dual-issue/frequency-stage10.md) | 503.69 MHz Verilog 最终参考实现完整验收 |

## 单发射 Chisel

单发射源码、生成器和数据归档集中在[独立工程](../single-issue-chisel/README.md)。[baseline.json](../single-issue-chisel/baseline.json) 指定交付生成所用的冻结源码，[latest-measurement.json](../single-issue-chisel/latest-measurement.json) 索引所选配置的已归档成绩。

2026-10-21 的 [v110 面积优化](../single-issue-chisel/reports/area-recovery-2026-10-21/report.md)只取消 `LocalMask`、`LocalWord` 的强制综合层次，保留全部容量和性能周期，得到 **422.44 MHz / 17,933.13 μm²**，延迟 10 / 20 的 IPC 为 **0.87846442 / 0.84602401**、正确性各 19/19，达到 Tier2 和 400 MHz 加分的本地数值门槛，未达到 500 MHz。这不是官方最终评分。[旧 v109 新流程复测](../single-issue-chisel/reports/remeasure-2026-10-21/report.md)的超面积结论及下表实验保留为历史记录。

| 阶段 | 性能 / 参数对照 | 实现与取舍 |
| --- | --- | --- |
| 1，v66 | [comparison](../single-issue-chisel/reports/stage1/comparison.md) | [优化记录](../single-issue-chisel/reports/stage1/optimization-notes.md) |
| 2，v71 | [comparison](../single-issue-chisel/reports/stage2/comparison.md) | [优化记录](../single-issue-chisel/reports/stage2/optimization-notes.md) |
| 3，v75 | [comparison](../single-issue-chisel/reports/stage3/comparison.md) | [优化记录](../single-issue-chisel/reports/stage3/optimization-notes.md) |
| 4，v94 | [comparison](../single-issue-chisel/reports/stage4/comparison.md) | [优化记录](../single-issue-chisel/reports/stage4/optimization-notes.md) |
| 5，v109 | [comparison](../single-issue-chisel/reports/stage5/comparison.md) | [优化记录](../single-issue-chisel/reports/stage5/optimization-notes.md) |

## 框架与原始数据

[框架同步记录](framework/upstream-sync-2026-10-15.md)说明官方综合工具更新和复核。[Verilog 原始数据索引](data/README.md)按日期和阶段保存冻结输入、原始日志、报告及哈希清单；两套 Chisel 的原始归档位于各自工程的 `reports/`。综合条件与面积口径见[首页测量说明](../README.md#当前结果与测量条件)及各报告，不能混用不同工具流程的成绩。

报告正文中的复现命令保留当时的路径与默认入口语境；执行前核对所选实现、filelist、`SIM` 和工作目录。当前通用命令以[首页](../README.md#快速运行)和各工程 README 为准，单发射冻结测量优先使用其报告中的 `reproduce.sh`。不改写冻结输入或历史报告来迎合当前导航。
