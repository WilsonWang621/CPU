# ParaRisc

当前默认实现已换成 Area-v2 结构的普通 Verilog CPU，顶层为 [`verilog/student_top.sv`](verilog/student_top.sv)，
核心为 [`verilog/area_v2_core.v`](verilog/area_v2_core.v)。采用独立发射队列、年龄关系矩阵仲裁、ROB 槽号重命名、
分支检查点和非阻塞缓存，支持 AXI4-Lite、256 MiB 地址空间和退出响应处理。

## 当前版本与验证状态

2026-10-03 核对：当前工作区基于提交 `5829a3f`，包含尚未提交的发射选择、访存地址预计算和分支重定向优化。
本页结果对应当前工作区，不把提交标题中的 144 MHz 或历史报告中的结果作为当前成绩。

当前交付核心 `verilog/area_v2_core.v` 的 SHA-256：

```text
68ca57af4f68808c0b0e83996efac607a8cb5d3a1ab9460703e0e6dae4ec00a3
```

结构化源文件与交付核心的哈希均与 [`verilog/area_v2_core.json`](verilog/area_v2_core.json) 一致。
本地已有综合报告的核心输入哈希与当前核心一致；综合采用课程默认 `opt` 流程、Yosys 0.63、ASAP7 RVT TT 和 OpenSTA。

| 指标 | 结果 |
| --- | ---: |
| 默认流程估算频率 | **155.98 MHz** |
| 最小时钟周期 | **6.4111 ns** |
| 2.000 ns 目标 WNS | **−4.4105 ns** |
| 总面积 | **34,676.562 μm²** |
| 当前工作区 correctness / perf / IPC | 尚未确认，不能沿用旧版结果 |

综合证据在本地 `build/frequency-next/redirect/synth/opt/` 下的 `report.txt`、`report.json` 和 `timing.rpt`；
`build/` 被 Git 忽略，这些文件不会随仓库克隆分发。结果属于理想时钟、无布线寄生的单元级 STA。
当前面积低于 36,000 μm²，但频率仍未达到 300 MHz；当前工作区还需要完整正确性和性能回归。

### 历史基线（不同源码版本）

| 版本 | 默认综合频率 | 面积 | 正确性与性能证据 |
| --- | ---: | ---: | --- |
| 阶段 4 v24 | 153.78 MHz | 34,321.772 μm² | correctness 19/19，perf 6/6，IPC 1.12820826 |
| 提交 `5829a3f` 的本地综合 | 158.07 MHz | 34,286.853 μm² | 此处仅确认综合报告与该提交的 RTL 输入哈希一致 |

v24 的测试条件为内存延迟 20 周期、仿真上限 30,000,000 周期；归档证据见
[阶段 4 报告](reports/frequency-stage4.md)、
[正确性日志](reports/data/2026-10-02/timing-stage4/v24-correctness-l20.log)、
[性能日志](reports/data/2026-10-02/timing-stage4/v24-perf.log) 和
[综合报告](reports/data/2026-10-02/timing-stage4/v24/report.txt)。
`5829a3f` 的本地综合证据在 `build/synth-current-5829a3f/opt/`。
当前工作区频率未超过该提交的本地结果，尚不能认定本轮修改带来了收益。

旧版 **368.27 MHz** 来自额外的直接时序映射和物理缓冲流程 `make synth-stage1`，
不能作为当前默认综合或 OJ 成绩；历史细节见 [阶段 1 报告](reports/frequency-stage1.md)。

## 本轮改动

- 发射队列在分配时记录槽位年龄关系，用单热授权信号选择执行包。
- 访存地址随操作数准备提前计算并寄存，缩短发射选择之后的地址计算路径。
- 分支是否需要重定向提前计算并寄存，减少恢复周期的组合判断。

相关源文件位于 `verilog/area_v2/`。新增模块和定向测试目前尚未全部纳入 Git 跟踪，提交时需一并收录。

## 编译与验证

默认 filelist 已指向普通 Verilog 核心，不需要外部 SystemVerilog 转换工具。

```sh
make export-verilog
make build BUILD=build/area-v2-verilog JOBS=8
make test SIM=build/area-v2-verilog/sim LATENCY=20 MAX_CYCLES=30000000
make perf SIM=build/area-v2-verilog/sim LATENCY=20 MAX_CYCLES=30000000
make verify-rtl
make run SIM=build/area-v2-verilog/sim PROGRAM=tests/rtl/high_address.data EXPECTED=0x40100 LATENCY=20
```

`make verify-rtl` 用 Icarus Verilog 检查 Verilog-2005 编译，并运行 AXI 背压与 M 扩展测试。
它还覆盖重命名、前端、缓存返回、分支恢复和退休等定向测试；本轮新增的
`v2_issue_order_tb.sv` 与 `v2_address_add_tb.sv` 尚未接入该入口。
结构化源描述保存在 `verilog/area_v2/`，工程内的 `make export-verilog` 确定性地展开到交付 Verilog；输入和输出都有 SHA-256。

## 后续手动综合

```sh
# 课程默认综合，用于当前频率和面积评估
make synth

# 历史实验流程：直接时序映射和物理缓冲，不替代默认评测
make synth-stage1
```

`make synth` 将报告写入 `build/synth/opt/`。
`make synth-stage1` 将直接映射报告写入 `build/area-v2/frequency/raw/opt/`，缓冲后的报告写入 `build/area-v2/frequency/mapped/`。

## 默认结构

32 项 ROB，两路分派/提交，两个整数端口与一个独立访存端口，三组 8 项发射队列，四个分支检查点，
8 个 Load 槽、16 个 Store 槽；1 KiB I-cache、2 KiB 两路 D-cache、64 B 行、四个 MSHR，AXI 最多 16 笔在途。
顶层参数包括 `ROB_BITS`、`IQ_ENTRIES`、`LOAD_SLOTS`、`STORE_SLOTS`、`CHECKPOINTS`、`ISSUE_WIDTH`、`COMMIT_WIDTH`、
`IC_INDEX_BITS`、`DC_INDEX_BITS` 与 `DC_LINE_BITS`。
