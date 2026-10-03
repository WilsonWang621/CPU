# 阶段 5 版本与模块 commit 对照

本轮从 v94 默认发布提交 `374a5cf` 开始，按模块实现、接线、冻结实验和默认发布拆分提交。v95–v109 是实验编号；各版本的原始源码、参数和已测 RTL 位于本目录的对应实验子目录。

| commit / Git 引用 | 模块与内容 | 对应实验 |
| --- | --- | --- |
| `283ad0a62a86508eb9ca257962074abe09d9fb89` | `PreparedQueue` 完整/部分头部预存，独立测试与原始验证日志 | v95、v96、v98、v100–v109 的取指头部实验 |
| `7eba21e6d1eb6b5d76fe5fba55f303ea6ff3aa7e` | `IssueAge` 成对年龄矩阵 | v97、v99 |
| `d5322ba916e6d5eaf8f2e9e102a3d1a2f4a4f670` | `Common` 实验参数、`LocalResultWord/Slice`、`LocalLoadValue`、`CompletionReady`，临时结果独立验证 | v96、v101–v103、v106、v107 |
| `e4f518bbbc225e81b355d9baa7f9d470d68985d6` | `Core/Cache` 接线、局部结果资格判定、debug 等价断言、生成与 stage5 实验/对照脚本 | v95–v109；局部结果资格判定对应 v98 |
| `76a8a4d0165b64319b860502f3adc24585c8353d` | 15 个候选的冻结源码/RTL、参数、综合/仿真原始日志、性能对照和上游参考证据 | v95–v109，含复用的 v94 对照 |
| `single-issue-v109` | v109 默认发布：启用完整头部预存、逐 bank 返回归属匹配和局部发射就绪，更新 `baseline.json`、发布 RTL 与说明 | v109，342.13164 MHz / 17942.62 μm² / IPC 0.84602401 / 正确性 19/19 |

`single-issue-v109` 是指向本文件首次加入的默认发布提交的本地 tag。可用 `git rev-parse single-issue-v109` 获取其完整 commit hash，或用 `git show single-issue-v109` 查看默认发布改动。

| 实验 | 相对基准的主要参数/模块 | 实测频率 MHz | 结论 |
| --- | --- | ---: | --- |
| v95 | `cached-fetch-head=1` | 327.99488 | 单独启用回退 |
| v96 | v95 + `result-slice-bits=16` | 322.82472 | 回退，默认不采用 |
| v97 | `issue-age-matrix=1` | 279.85788 | 回退，默认不采用 |
| v98 | v95 + `local-result-qualification=1` | 261.29115 | 回退，默认不采用 |
| v99 | 年龄矩阵 + debug | — | 正确性 19/19，无频率测量 |
| v100 | 头部预存 + bank 返回归属匹配 + 局部发射就绪 | 342.13164 | 完整验收通过，选中组合 |
| v101 | v100 + `prepared-load-result=1` | 336.39947 | 回退，默认不采用 |
| v102 | v100 + `load-value-copies=2` | 326.32250 | 回退，默认不采用 |
| v103 | v100 + `early-load-format=1` | 298.71645 | 回退，默认不采用 |
| v104 | v100 + `cached-fetch-instruction=1` | 306.12855 | 回退，默认不采用 |
| v105 | v104 + `parallel-dispatch-address=1` | 314.98001 | 回退，默认不采用 |
| v106 | v103 + `separate-operand-ready=1` | 330.74935 | 面积超限，默认不采用 |
| v107 | 临时结果、提前格式转换、并行地址、独立就绪 + debug | — | 正确性 19/19，无频率测量 |
| v108 | v100 + `issue-slice-bits=32` | 279.09512 | 回退，保留 16 位发射分片 |
| v109 | 最终源码、最终默认参数重新生成并完整复测 | 342.13164 | 最终默认，400 MHz 未达到 |

逐 bank 归属匹配、局部发射就绪、并行分派地址和发射分片的原模块提交为阶段 4 的 `2919338`，此前 v94 默认为 `374a5cf`。本轮默认发布启用归属匹配和局部发射就绪，保留 16 位发射分片，并行分派地址继续关闭。

冻结 `manifest.json` 的 `source_commit` 和 `worktree_diff` 保留测量当时的真实来源；本表记录整理后的模块提交，不修改测量 provenance。每个候选的实际电路以其冻结源码哈希、参数和 RTL 哈希为准。已核对 15 个版本共 283 个源码/构建文件哈希和全部 RTL 哈希；最终默认 19 个源码/构建文件及发布 RTL 与 v109 实测记录一致。完整性能和未运行项目见 [优化记录](optimization-notes.md) 与 [参数对照](comparison.md)。
