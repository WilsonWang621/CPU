# 实现状态

更新于 2026-10-01。本文只记录已经由命令复现的结果，不把规划中的 A/B 工作包标成完成。最新评分门槛以[课程仓库](https://github.com/ACMClassCourse-2025/RISC-V-CPU-2026)为准：Tier 3 要求总面积 ≤36,000 μm²、20 周期 GEOMEAN IPC ≥1.0985、频率 ≥300 MHz；500 MHz 可再加 4 分。

## 已实现

- 可构建的 `student_top`：32 个架构寄存器、RV32I 整数/控制流、八种 RV32M 运算、LW 与字节/半字/字加载、SB/SH/SW。
- 2 KiB 直接映射 I-cache 与 2 KiB 直接映射、write-through D-cache；命中路径可连续每拍执行一条非访存指令，store 会维护 D-cache 一致性并失效对应 I-cache 项。
- AXI4-Lite 控制器：AR/R、AW/W/B 独立握手；AW 与 W 分别保持到各自被接收；最多保留 16 个已发送 store 并在后台消费 B 响应。退出写的 B 响应按 FIFO 顺序晚于所有较早 store，保证最终排空。
- 非法编码、总线错误和未对齐半字/字 store 进入停止故障态，不产生后续架构副作用。
- Chisel 组合译码、ALU、分支和地址生成叶模块，以及对应 RTL 测试入口。
- RV32M 定向集成测试覆盖八种运算、除零和 `INT_MIN / -1`。

## 已复现结果

| 项目 | 命令/条件 | 结果 |
| --- | --- | --- |
| Verilator 构建 | `make build` | 通过 |
| RV32M 边界 | `make test-m`，延迟 3 | 通过，699 cycles |
| correctness 全集 | `make test LATENCY=3 MAX_CYCLES=30000000 SIM=build/sim` | 19/19 通过 |
| correctness 全集（官方 AppImage Verilator） | `make test SIM=build/sim LATENCY=10 MAX_CYCLES=10000000` | 19/19 通过 |
| perf 全集（官方 AppImage Verilator） | `make perf SIM=build/sim LATENCY=20 MAX_CYCLES=30000000` | 全部结果正确，几何平均 IPC **1.1173** |
| 官方综合工具 | AppImage 直运行 | Yosys 0.63、OpenSTA 3.1.0 可用 |

默认 1,000,000 周期上限下，`correctness_pi` 约 312 万条动态指令，即使理想双发射也不可能在上限内完成。完整功能回归需显式设置上限；当前实现的 `pi` 用 2,548,917 周期。

## 尚未完成

当前双槽整数/分支执行切片已使 IPC 越过 Tier 3 线，但缺少课程要求的乱序发射、ROB 按序提交、PRF/RMT/RS/LSQ 和参数化。I/D Cache 仍由寄存器阵列实现；综合展开约 505,856 位缓存数据与标签，即使全部映射为库中最小 0.2187 μm² 的触发器，面积下界也超过 110,000 μm²，尚不包含读写选择器与核心逻辑。因此当前 RTL 不满足 36,000 μm² 面积上限，也没有 500 MHz 时序结果。官方完整综合在展开大阵列后内存占用超过 2.5 GiB，已中止以便先改用 `sram_fakeram`。`docs/planning/todo.md` 中这些项目继续保持未完成。

后续须将 Cache 数据/标签放入课程 `sram_fakeram`，按其同步读时序重构取指和数据命中路径，并改用多周期除法器。之后用 `make synth CLOCK_PERIOD_NS=2.0` 验证面积和 500 MHz，再补齐真实乱序与参数扫描；每一步复跑 correctness、RV32M 和 20 周期 perf。
