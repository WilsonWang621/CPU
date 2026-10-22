# Verilog 参考实现原始测量数据

归档布局为 `<日期>/<阶段或实验>/<候选>/`。候选目录保存该次测量的冻结 RTL、参数、工具与约束、综合/时序报告、性能和正确性日志；具体字段随阶段演进。

| 归档 | 内容 |
| --- | --- |
| [2026-10-02](2026-10-02/) | 早期基准及双发射阶段 1–6 |
| [2026-10-15](2026-10-15/) | 框架同步、阶段 7–9 及冻结候选 |
| [2026-10-16](2026-10-16/) | 阶段 10 最终验收 |

Verilog 参考实现的最终冻结证据位于 [clean-default](2026-10-16/timing-stage10/clean-default/)，`identity.json` 记录当时的选择状态，`archive-manifest.json` 固定归档文件哈希。目录名中的 `default` 对应测量时的 Verilog 入口；当前根目录默认选择双发射 Chisel。归档中的源码、工具输入及日志保留测量时的内容和路径。

默认双发射 Chisel 的证据位于[完整要求归档](../../dual-issue-chisel/reports/requirements-2026-10-16/verified/)，其[报告](../../dual-issue-chisel/reports/requirements-2026-10-16/report.md)解释源码、RTL 和测量的绑定关系。实际运行入口见[仓库首页](../../README.md)，各实现的验收范围见[报告索引](../README.md)。本索引不表示重新执行了历史测量。

单发射原始实验位于 [single-issue-chisel/reports/](../../single-issue-chisel/reports/)，由该工程的 `baseline.json` 和各阶段对照表索引。
