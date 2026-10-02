# 第一阶段：频率目标与架构替换

本报告记录第一阶段的冻结版本。当前源码和最新结果见 [第二阶段报告](frequency-stage2.md)。

目标是把 ParaRisc 的实际单元级 STA 频率提升到 300 MHz 以上。本阶段的频率、面积与性能结果均以本工程实测数据为准。

## 最终实测交付

| 项目 | 结果 |
| --- | ---: |
| 完整实现频率，含真实缓冲 | **368.27 MHz** |
| 最小时钟周期 | 2.7154 ns |
| 3.333 ns 目标 WNS | +0.6180 ns |
| 完整面积，含缓冲 | 31,337.960 μm² |
| 组合逻辑 | 19,608.350 μm² |
| 时序逻辑 | 11,729.610 μm² |
| 后处理新增缓冲 | 4490 个 |
| 非时钟最大扇出 | 5482 → 8 |
| 原始引脚连接收缩检查 | 1,007,204 个，全部一致 |

**300 MHz 频率目标已在完整实现流程下达到。**
默认 `make synth` 的标准原始映射为 20.68 MHz；直接时序映射、全局缓冲之前为 82.87 MHz。
368.27 MHz 必须对应 `make synth-stage1` 的完整物理缓冲流程，不能作为默认 `make synth` 或 OJ 未加缓冲流程的成绩。
若最终评分固定使用默认综合脚本，需要其采用同等的物理缓冲步骤；本次没有修改课程原始 `scripts/synth.py` 和时序约束。

交付源码逐字节匹配本次冻结综合输入，哈希见 [delivery.json](data/2026-10-02/timing-stage1/delivery.json)。
最终 [report.txt](data/2026-10-02/timing-stage1/final-sta/report.txt)、[report.json](data/2026-10-02/timing-stage1/final-sta/report.json)
和 [timing.rpt](data/2026-10-02/timing-stage1/final-sta/timing.rpt) 已归档。
实测网表为 `build/area-v2/synth-buffered/mapped.v`。

## 实现

默认 `verilog/filelist.f` 已切换到新的普通 Verilog CPU、AXI4-Lite 适配器与 `student_top`。
原 ParaRisc 后端和缓存保留在仓库内，不再进入默认编译。

本工程采用 32 项 ROB、两路分派与提交、两个整数队列、一个独立访存队列，
队列各 8 项；平衡树选择最老的就绪指令；ROB 槽号重命名、四个分支检查点；8 个 Load 槽、16 个 Store 槽；
1 KiB 指令缓存、2 KiB 两路数据缓存、64 B 行、四个 MSHR，写穿透与写不分配。

本工程的实现与接口适配如下：

- 使用显式位宽、位偏移和线性寄存器数组，默认源码通过 Icarus `-g2005` 检查；不需要 sv2v、slang 或额外工具链。
- 取指 PC、预测目标、BTB 标签与目标保留完整地址，RAM 范围扩展到课程规定的 256 MiB。
- 有序内存请求接入 AXI4-Lite；AW/W 独立握手，方向 FIFO 恢复 R/B 返回顺序，最多 16 笔在途。
- MMIO 退出等到 AXI B 响应被接收，满足本工程模拟器的完成约定。

`verilog/area_v2_core.v` 是直接交付的 Verilog 实现；`verilog/area_v2/` 保存结构化源描述，
`python3 scripts/area_v2/export_plain.py` 以工程内的确定性生成规则展开记录布局、数组与循环。
生成文件和输入都有 SHA-256，重新生成无需访问网络。

## 功能与性能验证

统一内存延迟 20 周期、最多 30,000,000 周期，与原 README 基线一致。

| 验证 | 结果 |
| --- | ---: |
| correctness，LATENCY=20 | 19/19 |
| correctness，LATENCY=3 | 19/19 |
| perf | 6/6 |
| IPC 几何平均 | 1.1723 |
| Verilog-2005 编译检查 | 通过 |
| AXI 混合读写、独立背压、R/B 顺序、错误响应 | 240 笔通过 |
| M 扩展随机与边界算术 | 2,577 组通过 |
| MDU flush | 24 组通过 |
| 高地址取指和数据访问 | PC=0x40100、数据=0x80000，通过 |

| benchmark | instructions | cycles | IPC |
| --- | ---: | ---: | ---: |
| perf_median | 6961 | 6696 | 1.0396 |
| perf_multiply | 21722 | 16056 | 1.3529 |
| perf_qsort | 139900 | 119669 | 1.1691 |
| perf_rsort | 195719 | 133031 | 1.4712 |
| perf_towers | 5278 | 5260 | 1.0034 |
| perf_vvadd | 4524 | 4230 | 1.0695 |

原始日志和精确 IPC CSV 位于 `reports/data/2026-10-02/timing-stage1/`。
源描述和展开后的版本在这六个 benchmark 上的运行周期逐项一致。

## 时序流程

本工程保留课程 I/O 预算：输入/输出延迟各 0.2 ns，输入/时钟转换各 0.05 ns，时钟不确定度 0.05 ns，输出负载 5 fF。
综合与时序分析使用课程 AppImage、ASAP7 RVT TT 库和 `scripts/timing.py` / `scripts/timing.tcl`。

`make synth` 保留原始映射流程。`make synth-stage1` 提供完整实现流程：冻结 RTL，使用直接时序映射、
缓冲与单元尺寸优化，再给映射后重新连接的高扇出网络插入真实 `BUFx2_ASAP7_75t_R` 缓冲树。
缓冲面积进入总面积；把所有缓冲收缩为 Y=A 后，必须恢复每个原始单元引脚的连接，且顶层端口和时钟保持一致。
原始映射报告与带缓冲的实现报告分别保存，禁止混用。

最终建立时间检查使用 3.333 ns 周期；最高频率由完整时序分析搜索最小可行周期，包含时钟不确定度和库最小周期约束。
这是无布线寄生、理想时钟的单元级 STA，与课程工具的范围一致；并非布局布线签核频率。

## 复现

```sh
make build BUILD=build/area-v2-verilog JOBS=8
make test SIM=build/area-v2-verilog/sim LATENCY=20 MAX_CYCLES=30000000
make perf SIM=build/area-v2-verilog/sim LATENCY=20 MAX_CYCLES=30000000
make verify-rtl
make run SIM=build/area-v2-verilog/sim PROGRAM=tests/rtl/high_address.data EXPECTED=0x40100 LATENCY=20
make synth-stage1
```

`make synth-stage1` 的报告位于 `build/area-v2/frequency/mapped/`，包含 `report.txt`、`report.json`、`timing.rpt`、
`constraints.sdc`、`buffering.json` 和完整映射网表；原始报告位于其 `raw/opt/` 子目录。
后续修改后的综合可由用户按此命令手动复现。
