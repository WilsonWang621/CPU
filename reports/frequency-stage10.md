# 503.69 MHz 默认实现独立验收

2026-10-16，最终默认文件在已同步的官方综合流程下测得 **503.68913 MHz、35900.33400 μm²**。保留32项ROB、双发射/双提交、3个4项IQ、8个Load槽、16个Store槽、1 KiB指令缓存和2 KiB数据缓存。

| 验收项 | 本版结果 | 状态 |
| --- | ---: | --- |
| 频率 ≥500 MHz | 503.68912937 MHz | 通过 |
| 总面积 ≤36000 μm² | 35900.33400001 μm² | 通过 |
| IPC几何平均 ≥1.0985，延迟10 | 1.2221711020 | 6/6通过 |
| 延迟20的IPC几何平均 | 1.1138460960 | 6/6通过 |
| 完整RTL单元和定向检查 | 通过 | 完成 |
| 高地址检查 | 116周期，结果0x40100 | 通过 |
| 全部19项正确性，延迟20 | 正在运行 | 待完成 |

本版将缓存返回的驻留项与新发布项条件提前计算，避免晚到的控制先经过整片word-valid更新与动态读取；保持fill、完整Store、错误返回和槽位优先级。Load写回结果经过6叶保留层次的反相器树送往ROB、IQ和分派。访存预计算地址使用局部互斥优先选择与按字节分发的控制，触发器仍在原有捕获边沿。六项基准周期与上一版逐项一致。

综合层次树实际保留2016个反相器模块实例，共16008个`INVx1_ASAP7_75t_R`单元、700.18992 μm²，全部纳入总面积。ABC仍使用官方默认的`INVx1`驱动和5 fF负载。OpenSTA目标周期为2.0 ns，估算最小周期为1.9853515625 ns，2.0 ns下最差setup slack为+0.015595 ns；外部约束和库保持官方默认值。

最终导出的32个有效模块体与503.44 MHz冻结候选一致，整理后的文件已独立综合。结构化源码重新导出后与测量文件逐字节一致。仿真采用默认AppImage及课程build.py，保留`--assert`；新缓存返回条件逐槽与原表达式断言等价，局部优先选择另有40000项检查。

完整正确性使用最终二进制和最终RTL哈希进行独立记录，当前正在执行19项套件。最终结论以该日志及完成状态为准。原487.85 MHz版本已独立完成19/19，保存在[阶段9记录](frequency-stage9.md)。

源码、官方原始报告、约束、仿真日志和SHA-256清单位于[最终证据](data/2026-10-16/timing-stage10/clean-default/)。本轮另测得ROB16组合512.51 MHz、34464.95 μm²，尚无该组合的完整功能结论；默认仍采用ROB32。

复现默认文件：

```sh
APPIMAGE_EXTRACT_AND_RUN=1 make synth SYNTH_OUT=build/final-synth
APPIMAGE_EXTRACT_AND_RUN=1 make build BUILD=build/final-sim JOBS=2
make perf SIM=build/final-sim/sim LATENCY=10 MAX_CYCLES=20000000
make perf SIM=build/final-sim/sim LATENCY=20 MAX_CYCLES=20000000
make test SIM=build/final-sim/sim LATENCY=20 MAX_CYCLES=20000000
bash scripts/area_v2/verify_rtl.sh build/final-unit
```
