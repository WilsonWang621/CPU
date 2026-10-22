# 实验索引

三套实现选定的基准保存在 [index.csv](index.csv) 和 [index.json](index.json) 中。在仓库根目录运行以下命令可以重新生成：

```sh
python3 scripts/build_experiment_index.py
```

脚本按 `experiment_id` 排序。每个数值的来源都列在 `evidence_paths` 中，包括归档的 JSON、CSV 或阶段报告。`source_identity` 记录实际参与测量的源码哈希，`archive_commit` 记录报告归档时的提交；原始记录未提供的信息填为 `unknown`。

## 当前基准

| 实现 | 实验 ID | 用途 | 原始报告 |
| --- | --- | --- | --- |
| 默认双发射 Chisel | `dual-chisel-requirements-2026-10-16` | 当前默认配置 | [测量报告](../../dual-issue-chisel/reports/requirements-2026-10-16/report.md) |
| 单发射 Chisel v110 | `single-chisel-v110-2026-10-21` | 单发射基准 | [v110 报告](../../single-issue-chisel/reports/area-recovery-2026-10-21/report.md) |
| 双发射 Verilog | `verilog-reference-stage10-2026-10-16` | Verilog 参考基准 | [阶段 10 报告](../dual-issue/frequency-stage10.md) |

这些结果来自历史测量。比较前需要核对实现、参数、工具链和评测流程，`comparable_with` 列给出了具体说明。其他候选版本见[阶段报告](../README.md)及各实现的 `comparison.csv` / `candidate-comparison.json`。

## 字段说明

`correctness_lat10/20` 表示在对应延迟下通过的正确性用例数和总数，`ipc_lat10/20` 表示六项性能测试的 IPC 几何平均值。面积和 Fmax 的测量条件见各自报告。`comparison_baseline` 记录比较对象，`evaluation_flow` 记录评测流程版本，便于区分代码优化和工具流程变化带来的差异。

CSV 可直接用表格软件打开，JSON 供脚本读取。更新数据时修改汇总脚本或补充原始记录，再运行生成命令；历史报告保持原样。
