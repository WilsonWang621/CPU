# 双发射 Chisel 实现

## 交互式总体架构

![可参数化多发射 Chisel CPU 动态总体架构图](../docs/architecture/dual-issue-overview.gif)

[交互图 HTML](../docs/architecture/dual-issue-overview.html) · [可编辑 JSON](../docs/architecture/dual-issue-overview.json) · [模块盘点与源码依据](../docs/architecture/dual-issue-overview.md)。11 个组件依据当前源码绘制，节点说明含职责、I/O 和源码位置；青色实线突出 ADD 数据路径，虚线表示提交与恢复控制。动画表示连接方向，不是周期仿真。GitHub 上播放 GIF，下载 HTML 后可在浏览器中交互阅读。

## 实现与验证

以保留的双发射 Verilog 参考实现（`d134aa1`，ROB32 版本）逐模块迁移的原生 Chisel 工程。CPU、缓存、译码、乘除法及 AXI 适配器均由 Scala/Chisel 生成；构建不读取或嵌入 Verilog 参考 CPU。生成器使用已缓存的 Chisel 6.5.0、Scala 2.13.12、sbt 1.10.2 和 firtool 1.62.0。根目录课程默认 filelist 现在直接选择本工程的生成 RTL。

保留双分派、双整数发射、独立访存端口、双提交、32 项 ROB、三组各 4 项 IQ、3 个分支检查点、8 个 Load 槽、16 个 Store 槽、1 KiB I-cache、2 KiB D-cache。同步复位、空闲行预准备、访存选择提前一拍、缓存返回选择、取消响应排空和分支恢复的时钟边界均对应原设计。前缀节点、局部掩码、字节控制及反相器分发树继续使用 `keep_hierarchy`，面积和延迟均计入官方综合。

默认电路的官方测量为 **502.70 MHz、35930.97 μm²**，延迟 10 / 20 的 IPC 几何平均为 **1.222171 / 1.113846**。最新工作补齐真实发射宽度、独立 PRF 和缓存相联度参数，见[课程要求与架构权衡](reports/requirements-2026-10-16/report.md)及[14 组参数敏感度](reports/requirements-2026-10-16/parameter-sensitivity.md)。当前默认 RTL 与冻结 v13 的全部硬件 token 一致，并已按当前输入重新综合。v13 的完整双 CPU 逐拍 AXI 对照和组件证明保留在[历史验收报告](reports/final/report.md)，候选探索见[验收进度](reports/progress.md)。

在本目录执行：

```sh
make generate
APPIMAGE_EXTRACT_AND_RUN=1 make build JOBS=4
make test
make perf LATENCY=10
make perf LATENCY=20
APPIMAGE_EXTRACT_AND_RUN=1 make synth
```

`make generate` 直接从可编辑源码生成 `rtl/student_top.sv`；`rtl/filelist.f` 可直接交给根目录官方 `build.py` 和 `synth.py`。综合沿用 2.0ns、ASAP7 RVT TT、INVx1 驱动与 5fF 负载，不改课程脚本、面积算法或时序约束。目标为频率 ≥500MHz、总面积 ≤36,000μm²、延迟 10 IPC 几何平均 ≥1.0985，以及全部 19 项正确性。

| Verilog 参考源码 | Chisel 源码 |
| --- | --- |
| `cpu_top.sv`, `cpu_pkg.sv` | `Core.scala`, `Common.scala` |
| `v2_frontend.sv` | `Frontend.scala` |
| `v2_dcache.sv` | `DCache.scala` |
| `decoder.sv`, `alu.sv`, `branch_unit.sv` | `Decode.scala` |
| `muldiv.sv` | `MulDiv.scala` |
| `v2_rename.sv` | `Rename.scala` |
| 选择器与顺序比较 | `Select.scala` |
| 前缀加法、分发、掩码、优先寄存器与读取模块 | `LocalLogic.scala` |
| `memory_controller.sv`, `pararisc_axi_adapter.sv` | `Bus.scala` |
| `student_top.sv` | `Top.scala` |

`Generate.scala` 支持 `--module` 单独生成各模块，供 SAT 和原测试台核对。`scripts/prove_modules.py` 将生成 RTL 与当前根目录交付 Verilog 比较，记录输入 SHA-256、Yosys 配方及日志；组合等价证明穷尽全部输入，时序检查明确标记为有界检查。最终三检查点 RAT 使用 `scripts/prove_rename.py` 对 764 位状态及 24 位输出做归纳等价证明，合法索引 0..2 保持不变，未用编码 3 在两边均映射为 0。仲裁器的整机提取证明显式采用两缓存始终接收响应的连接常量。

整机逐拍对照使用两个完整 CPU，共享课程 AXI 返回，并检查请求有效、传输数据以及 R/B 接收时刻；AXI 无效时的负载不参与比较。在根目录执行：

```sh
python3 dual-issue-chisel/scripts/prepare_differential.py
APPIMAGE_EXTRACT_AND_RUN=1 make build \
  FILELIST=dual-issue-chisel/build/differential/sources/filelist.f \
  BUILD=dual-issue-chisel/build/differential/sim JOBS=2
make perf SIM=dual-issue-chisel/build/differential/sim/sim LATENCY=20 MAX_CYCLES=20000000
make test SIM=dual-issue-chisel/build/differential/sim/sim LATENCY=20 MAX_CYCLES=20000000
```

该对照文件仅用于验证，独立交付和综合始终使用 `rtl/filelist.f`。

核对最新完整要求归档与当前源码：

```sh
python3 scripts/audit_requirements.py
```

`make verify-units` 可重跑原 RTL 的独立模型检查；形式证明支持 `python3 scripts/prove_modules.py --native-file rtl/student_top.sv --modules decoder,alu,branch-unit,operand,axi-adapter,memory-controller`，需提供可执行 Yosys（`--yosys`）或使用课程 AppImage 环境。完整 RAT 证明使用 `python3 scripts/prove_rename.py`；参数见脚本 `--help`。

参数矩阵由 `scripts/parameter_profiles.json` 固定，执行 `python3 scripts/requirements_programs.py` 后使用 `python3 scripts/check_parameters.py --generate --full-correctness`。`--issue-width` 计全部新发射指令，默认 3（两个整数端口及一个 LSU）；`--integer-ports` 控制整数端口数。`--prf` 独立于 `--rob`，表示推测值槽数，另有固定 32 字 committed ARF。两缓存分别支持 1/2/4 路及容量配置。完整复现命令和参数含义见上述最新报告。
