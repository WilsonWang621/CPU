# ParaRisc

当前默认实现已换成 Area-v2 结构的普通 Verilog CPU，顶层为 [`verilog/student_top.sv`](verilog/student_top.sv)，
核心为 [`verilog/area_v2_core.v`](verilog/area_v2_core.v)。采用独立发射队列、树形仲裁、ROB 槽号重命名、
分支检查点和非阻塞缓存，支持 AXI4-Lite、256 MiB 地址空间和退出响应处理。

## 双发射最终基准

2026-10-03，固定 v42，结束本条双发射优化路线。原样 `make synth`：

| 指标 | 结果 |
| --- | ---: |
| 默认综合频率 | **205.746 MHz** |
| 总面积 | **32,388.245 μm²** |
| 性能 IPC 几何平均（延迟 20） | **1.113846** |
| 正确性 / 性能 | **19/19 / 6/6** |
| 完整 RTL 定向检查 | 通过 |

**未达到 300 MHz。** 历史 368.27 MHz 来自额外物理缓冲流程，不能作为默认综合成绩。
最终证据见 [阶段 6 报告](reports/frequency-stage6.md) 和
[固定基准](reports/data/2026-10-02/timing-stage6/final-baseline.json)。

单发射 Chisel 实现位于独立目录 [single-issue-chisel](single-issue-chisel/README.md)。最终默认 v109：原样综合 **342.13 MHz**、总面积 **17,942.62 μm²（含 SRAM）**、延迟 20 的几何平均 IPC **0.84602**，正确性 **19/19**，满足 Tier2。阶段 5 将取指队列头部预存与逐 bank 返回归属匹配、局部发射就绪组合，相对 v94 的 332.14 MHz 提升 **3.01%**，六项性能周期不变；400/500 MHz 仍未达到。参考方法、参数/性能对照及未采用尝试见该目录的 `reports/stage1` 至 `stage5`。

Tier2 门槛：
面积 ≤18,000 μm²、IPC ≥0.845、原样综合频率 >300 MHz。新核达标状态以该目录的实际验收记录为准。

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

32 项 ROB，两路分派/提交，两个整数端口与一个独立访存端口，三组 4 项发射队列，三个分支检查点，
8 个 Load 槽、16 个 Store 槽；1 KiB I-cache、2 KiB 两路 D-cache、64 B 行、四个 MSHR，AXI 最多 16 笔在途。
顶层参数包括 `ROB_BITS`、`IQ_ENTRIES`、`LOAD_SLOTS`、`STORE_SLOTS`、`CHECKPOINTS`、`ISSUE_WIDTH`、`COMMIT_WIDTH`、
`IC_INDEX_BITS`、`DC_INDEX_BITS` 与 `DC_LINE_BITS`。
