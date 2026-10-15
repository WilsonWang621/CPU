# 默认实现参数

参数定义与核心连接见 [student_top.sv](../verilog/student_top.sv)。以下为最终验收使用的缺省值。

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
