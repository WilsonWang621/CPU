# 统一实验索引

这里的 `index.csv` 和 `index.json` 是三套实现当前选定基准的机器可读索引。它们由仓库根目录的

```sh
python3 scripts/build_experiment_index.py
```

生成；脚本按 `experiment_id` 排序，重复运行不会重排或改写历史报告。每个数值都来自 `evidence_paths` 中列出的归档 JSON、CSV 或阶段报告。`source_identity` 保存参与测量的源文件 SHA-256（或其所在清单），`archive_commit` 单独记录报告 manifest 声明的归档提交；证据没有提供提交时保留为 `unknown`。

## 当前基准

| 实现 | 实验 ID | 采用方式 | 原始报告 |
| --- | --- | --- | --- |
| 默认双发射 Chisel | `dual-chisel-requirements-2026-10-16` | 默认构建与课程目标基准 | [requirements report](../../dual-issue-chisel/reports/requirements-2026-10-16/report.md) |
| 单发射 Chisel v110 | `single-chisel-v110-2026-10-21` | 独立实现基准 | [v110 report](../../single-issue-chisel/reports/area-recovery-2026-10-21/report.md) |
| 双发射 Verilog | `verilog-reference-stage10-2026-10-16` | 参考实现基准，不是默认入口 | [stage 10 report](../dual-issue/frequency-stage10.md) |

三行均是历史归档结果，不代表本次重新仿真、综合或 STA。实现、参数、工具链和输入身份不同的行不能直接横向比较；`comparable_with` 记录了可比较范围。探索阶段的候选仍保留在[阶段报告索引](../README.md)及各实现的 `comparison.csv` / `candidate-comparison.json` 中，缺少完整证据的候选没有被提升为当前基准。

## 字段说明

`correctness_lat10/20` 是通过数/官方正确性总数；没有对应归档证据时为 `unknown`。`ipc_lat10/20` 是六项性能的几何平均 IPC。面积和 Fmax 使用各自归档的综合/STA 口径。`comparison_baseline` 说明该行用于对比的目标或前一候选，不把官方评测流程的变化写成源码改动。

CSV 适合表格筛选，JSON 保留相同字段和完整来源路径，便于自动审计。不要直接编辑这两个产物；修改索引规则后重新运行汇总命令。
