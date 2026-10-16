# Verilog 参考实现与默认 Chisel 参数

Verilog 参考实现的参数定义与连接见 [student_top.sv](../verilog/student_top.sv)。以下为该实现的缺省值；当前默认课程入口使用下节的原生 Chisel 配置。

| 顶层参数 | 默认值 | 含义 |
| --- | ---: | --- |
| `ROB_BITS` | 5 | ROB 项数为 `2^ROB_BITS`，即 32 |
| `IQ_ENTRIES` | 4 | 每组发射队列容量，共三组 |
| `LOAD_SLOTS` / `STORE_SLOTS` | 8 / 16 | Load / Store 槽数 |
| `CHECKPOINTS` | 3 | 分支检查点数 |
| `ISSUE_WIDTH` / `COMMIT_WIDTH` | 2 / 2 | 整数端口数 / 提交宽度 |
| `IC_INDEX_BITS` | 5 | 指令缓存容量为 `32 × 2^IC_INDEX_BITS` 字节，即 1 KiB |
| `DC_INDEX_BITS` | 4 | 数据缓存组索引位数 |
| `DC_LINE_BITS` | 6 | 数据缓存行宽为 `2^DC_LINE_BITS` 字节，即 64 B |
| `CONTROL_TREE` / `ROB_WRITE_TREE` / `CACHE_TREE` / `COMMIT_TREE` | 1 | 启用相应控制分发树 |
| `REGISTER_REDIRECT` | 1 | 启用寄存重定向路径 |

数据缓存为两路，容量为 `2 × 2^DC_LINE_BITS × 2^DC_INDEX_BITS` 字节，默认 2 KiB。顶层固定外部 RAM 为 256 MiB，最多 16 笔在途请求。

参数变化会改变实际电路及性能，验收结果仅对应冻结输入。双发射历史容量与实现对照见[阶段 6](../reports/dual-issue/frequency-stage6.md)、[阶段 8](../reports/dual-issue/frequency-stage8.md)，最终默认见[阶段 10](../reports/dual-issue/frequency-stage10.md)。单发射参数由[独立 baseline.json](../single-issue-chisel/baseline.json)固定，各阶段完整参数对照见[报告索引](../reports/README.md)。

## 原生 Chisel 的独立参数

Chisel 完整 CPU 使用 [Config](../dual-issue-chisel/src/main/scala/tier3/Common.scala) 和 [Generate](../dual-issue-chisel/src/main/scala/tier3/Generate.scala)。`--issue-width` 表示整数与 LSU 的全局新发射上限，默认 3；两个整数端口由 `--integer-ports 2` 指定，分派/提交宽度分别由 `--dispatch-width` / `--commit-width` 指定，默认均为 2。它与上表 Verilog 参数名的含义不同。

`--rob`、`--prf`、`--iq` 分别指定 ROB 项数、推测 PRF 值槽数、每组 IQ 项数，默认 32/32/4。PRF 之外还有固定 32 字 committed ARF。`--icache-bytes`、`--dcache-bytes` 及 `--icache-ways`、`--dcache-ways` 分别配置容量与 1/2/4 路相联度，默认 1024/2048 B、1/2 路。

完整范围、14 组实际组合、正确性范围、原始周期和 IPC 分析见[参数敏感度报告](../dual-issue-chisel/reports/requirements-2026-10-16/parameter-sensitivity.md)。默认 RTL 的综合输入绑定见[当前要求验收](../dual-issue-chisel/reports/requirements-2026-10-16/report.md)。
