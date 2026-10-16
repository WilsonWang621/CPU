# 双发射 Chisel 实现

以根目录最终双发射 Verilog（`d134aa1`，默认 ROB32 版本）逐模块迁移的原生 Chisel 工程。CPU、缓存、译码、乘除法及 AXI 适配器均由 Scala/Chisel 生成；构建不读取或嵌入 Verilog 参考 CPU。生成器使用已缓存的 Chisel 6.5.0、Scala 2.13.12、sbt 1.10.2 和 firtool 1.62.0。

保留双分派、双整数发射、独立访存端口、双提交、32 项 ROB、三组各 4 项 IQ、3 个分支检查点、8 个 Load 槽、16 个 Store 槽、1 KiB I-cache、2 KiB D-cache。同步复位、空闲行预准备、访存选择提前一拍、缓存返回选择、取消响应排空和分支恢复的时钟边界均对应原设计。前缀节点、局部掩码、字节控制及反相器分发树继续使用 `keep_hierarchy`，面积和延迟均计入官方综合。

当前**尚未完成 Tier3 / 500MHz 验收**。初始完整候选已通过 19/19 正确性、两组性能、高地址、定向单元，以及两组性能的整机逐拍对照。已完成综合的候选尚未同时满足频率与面积；迁移与优化中的版本分别冻结，详见[验收进度](reports/progress.md)。Verilog 参考版的 503.69MHz 不代表本工程的实测频率。

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

`Generate.scala` 支持 `--module` 单独生成各模块，供 SAT 和原测试台核对。`scripts/prove_modules.py` 将生成 RTL 与当前根目录交付 Verilog 比较，记录输入 SHA-256、Yosys 配方及日志；组合等价证明穷尽全部输入，时序检查明确标记为有界检查。三检查点 RAT 的形式检查约束索引在 0..2，符合实际分配器接口。

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
