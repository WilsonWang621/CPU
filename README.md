# ParaRisc

当前顶层 CPU 位于 [`verilog/student_top.sv`](verilog/student_top.sv)，目标为 RV32IM。实现包含双发射、乱序执行、按序提交、16 项 ROB、分支预测、指令缓存、数据缓存、L0 缓冲和 AXI4-Lite 访存接口。

## 当前实测指标

测试基于提交 `80b0d27`，Verilator 5.020，统一内存延迟 20 周期，性能测试上限 30,000,000 周期。

| 项目 | 结果 |
| --- | ---: |
| correctness | 19/19 通过 |
| perf 测试 | 6/6 通过 |
| 综合 IPC 几何平均 | **0.9068** |
| 综合 CPI（1/IPC） | 1.1028 |
| 总面积 | **27,418.569 μm²** |
| 组合逻辑面积 | 8,405.705 μm² |
| 时序逻辑面积 | 4,221.493 μm² |
| SRAM 估算面积 | 14,791.370 μm² |
| 估算最高频率 | **67.77 MHz** |
| 最小时钟周期 | 14.7568 ns |
| 2 ns 目标下 WNS | −12.7562 ns |

六项性能测试的详细结果如下。IPC 使用测试集 `metrics.json` 中的动态指令数除以仿真报告周期数，最终取几何平均。

| benchmark | instructions | cycles | IPC |
| --- | ---: | ---: | ---: |
| perf_median | 6,961 | 9,428 | 0.7383 |
| perf_multiply | 21,722 | 17,556 | 1.2373 |
| perf_qsort | 139,900 | 142,794 | 0.9797 |
| perf_rsort | 195,719 | 170,914 | 1.1451 |
| perf_towers | 5,278 | 7,411 | 0.7122 |
| perf_vvadd | 4,524 | 5,941 | 0.7615 |
| **GEOMEAN** |  |  | **0.9068** |

最新原始记录保存在 [`reports/data/2026-10-02/current-80b0d27/`](reports/data/2026-10-02/current-80b0d27/)，综合报告为 [`report.txt`](build/metrics-80b0d27/synth/opt/report.txt)，完整机器可读结果为 [`report.json`](build/metrics-80b0d27/synth/opt/report.json)。

## 仿真与正确性测试

```sh
# 编译当前 RTL
make build BUILD=build/current

# 运行全部 correctness 测试
make test BUILD=build/current LATENCY=20 MAX_CYCLES=30000000 SIM=build/current/sim

# 运行全部性能测试并计算 IPC 几何平均
make perf BUILD=build/current LATENCY=20 MAX_CYCLES=30000000 SIM=build/current/sim
```

## 手动综合

以后综合由用户手动运行；我只根据你提供的报告分析，不再主动执行综合。推荐命令：

```sh
make synth \
  SYNTH_OUT=build/synth-manual \
  MODE=opt \
  CLOCK_PERIOD_NS=2.0 \
  FILELIST=verilog/filelist.f
```

综合完成后，把下面三个文件发给我即可：

```text
build/synth-manual/opt/report.txt
build/synth-manual/opt/report.json
build/synth-manual/opt/timing.rpt
```

`CLOCK_PERIOD_NS=2.0` 对应 500 MHz 目标约束；它是综合优化目标，不代表最终可达频率。分析时重点看总面积、SRAM 面积、`estimated_fmax_mhz`、`minimum_period_ns`、WNS 和关键路径。

## RTL 参数

顶层默认参数如下：

```text
ROB_BITS       = 4   # ROB 深度 16
IC_INDEX_BITS  = 8   # 指令缓存索引位数
DC_INDEX_BITS  = 9   # 数据缓存索引位数
DC_LINE_BITS   = 6   # 数据缓存行大小 64 B
```

修改参数后，必须重新运行 correctness 和 perf，再将对应综合报告与测试结果一起比较。
