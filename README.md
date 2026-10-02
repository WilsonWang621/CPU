# ParaRisc

当前默认实现已换成 Area-v2 结构的普通 Verilog CPU，顶层为 [`verilog/student_top.sv`](verilog/student_top.sv)，
核心为 [`verilog/area_v2_core.v`](verilog/area_v2_core.v)。采用独立发射队列、树形仲裁、ROB 槽号重命名、
分支检查点和非阻塞缓存，支持 AXI4-Lite、256 MiB 地址空间和退出响应处理。

## 最新实测结果

2026-10-02；Verilator 5.020、Yosys 0.63、ASAP7 RVT TT、OpenSTA。
内存延迟 20 周期，仿真上限 30,000,000 周期。

| 指标 | 结果 |
| --- | ---: |
| correctness，延迟 20 / 3 周期 | 19/19 / 19/19 |
| perf | 6/6 |
| IPC 几何平均 | **1.1723** |
| 完整实现频率，含物理缓冲树 | **368.27 MHz** |
| 最小时钟周期 | **2.7154 ns** |
| 3.333 ns 目标 WNS | **+0.6180 ns** |
| 完整面积，含缓冲树 | **31,337.960 μm²** |

频率来自 `make synth-stage1`：保持课程的 0.2 ns I/O 延迟、0.05 ns 不确定度、5 fF 输出负载，
计入真实缓冲单元面积并验证缓冲前后的全部引脚连接。结果属于理想时钟、无布线寄生的单元级 STA。
默认 `make synth` 的标准原始映射为 **20.68 MHz**，尚未满足 300 MHz；直接时序映射但全局缓冲之前为 **82.87 MHz**。
**368.27 MHz 不能当作默认综合或 OJ 未加物理缓冲流程的成绩。**

完整交付说明、参数、差异和原始证据见 [频率阶段报告](reports/frequency-stage1.md)；
[最终时序报告](reports/data/2026-10-02/timing-stage1/final-sta/report.txt)、
[机器可读记录](reports/data/2026-10-02/timing-stage1/delivery.json)。
旧实现的 67.77 MHz / IPC 0.9068 基线保存在 `reports/data/2026-10-02/current-80b0d27/`。

## 编译与验证

默认 filelist 已指向普通 Verilog 核心，不需要外部 SystemVerilog 转换工具。

```sh
make build BUILD=build/area-v2-verilog JOBS=8
make test SIM=build/area-v2-verilog/sim LATENCY=20 MAX_CYCLES=30000000
make perf SIM=build/area-v2-verilog/sim LATENCY=20 MAX_CYCLES=30000000
make verify-rtl
make run SIM=build/area-v2-verilog/sim PROGRAM=tests/rtl/high_address.data EXPECTED=0x40100 LATENCY=20
```

`make verify-rtl` 用 Icarus Verilog 检查 Verilog-2005 编译，并运行 AXI 背压与 M 扩展测试。
结构化源描述保存在 `verilog/area_v2/`，工程内的 `make export-verilog` 确定性地展开到交付 Verilog；输入和输出都有 SHA-256。

## 后续手动综合

```sh
# 原始课程映射，可用于对照
make synth

# 完整频率实现：冻结 RTL、直接时序映射、尺寸优化、真实缓冲树、原课程 STA 约束
make synth-stage1
```

后者将原始映射报告写入 `build/area-v2/frequency/raw/opt/`，完整实现报告写入 `build/area-v2/frequency/mapped/`。
本次实测原始产物保存在 `build/area-v2/synth-direct/opt/` 与 `build/area-v2/synth-buffered/`；关键报告已归档进仓库。

## 默认结构

32 项 ROB，两路分派/提交，两个整数端口与一个独立访存端口，三组 8 项发射队列，四个分支检查点，
8 个 Load 槽、16 个 Store 槽；1 KiB I-cache、2 KiB 两路 D-cache、64 B 行、四个 MSHR，AXI 最多 16 笔在途。
顶层参数包括 `ROB_BITS`、`IQ_ENTRIES`、`LOAD_SLOTS`、`STORE_SLOTS`、`CHECKPOINTS`、`ISSUE_WIDTH`、`COMMIT_WIDTH`、
`IC_INDEX_BITS`、`DC_INDEX_BITS` 与 `DC_LINE_BITS`。
