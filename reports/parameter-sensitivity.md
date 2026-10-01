# 性能参数敏感度报告

## 2026-10-01 基线

配置：单发射、各 2 KiB 直接映射 I/D word cache、最多 16 笔 posted store、统一下级内存，内存延迟 20 周期。命令为：

```sh
make perf LATENCY=20 MAX_CYCLES=30000000 SIM=build/sim
```

| benchmark | instructions | cycles | IPC |
| --- | ---: | ---: | ---: |
| perf_median | 6,961 | 36,458 | 0.1909 |
| perf_multiply | 21,722 | 32,708 | 0.6641 |
| perf_qsort | 139,900 | 411,733 | 0.3398 |
| perf_rsort | 195,719 | 822,631 | 0.2379 |
| perf_towers | 5,278 | 14,097 | 0.3744 |
| perf_vvadd | 4,524 | 33,344 | 0.1357 |

几何平均 IPC 为 **0.2836**。无 Cache、逐次等待 B 响应的最初基线为 0.0320，因此当前优化带来约 **8.86 倍**提升。目前仍没有宽度、PRF 和 ROB 的完整扫描；所有后续配置必须先通过相同正确性集合，再比较 IPC、面积和时序。

## 2026-10-01 双槽与容量实验

使用官方 AppImage Verilator 5.020、统一内存延迟 20 周期、六项 `perf_*` 的同一 GEOMEAN 口径。下表配置均通过对应的 19 项 correctness 回归，数据/标签仍由寄存器阵列实现，尚无有效面积/时序值。

| 实现阶段 | I-cache | D-cache | GEOMEAN IPC |
| --- | ---: | ---: | ---: |
| 单槽、word Cache、串行访存 | 2 KiB | 2 KiB | 0.2836 |
| 双槽整数/分支 + 32 B 行回填 | 2 KiB | 2 KiB | 0.6220 |
| 同上，增大直接映射容量 | 8 KiB | 8 KiB | 0.6725 |
| 加入 Store Queue 和双槽访存旁路 | 8 KiB | 8 KiB | 0.8559 |
| 增大 D-cache | 8 KiB | 32 KiB | **1.1173** |

32 KiB D-cache 对 qsort/rsort 的影响最大：当前 IPC 分别为 1.3343/1.4153。这个结果只证明容量对工作集有效，不能作为可提交配置；寄存器数组的面积下界已超过 Tier 3。下一轮要在 SRAM 宏版本上重新做容量扫描，并补充面积与 2 ns 时序。
