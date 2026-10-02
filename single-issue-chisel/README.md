# Single issue Chisel CPU

独立单发射乱序 RV32IM 工程，根目录的 v42 双发射实现已经封存。CPU 源码按译码/执行、乘除法、缓存/前端、总线、乱序核心分模块。

验收固定使用课程原样 `scripts/synth.py`、ASAP7 RVT TT 及课程默认时序约束；性能测试内存延迟 20、上限 30,000,000 周期。总面积包括 SRAM。

| 实现阶段 | 必须保留的门槛 | 频率目标 | 当前状态 |
|---|---|---:|---|
| 1 | 19/19 正确性，面积 ≤18,000 μm²，IPC ≥0.845 | >300 MHz | v66：304.22 MHz，已验收 |
| 2 | 阶段 1 全部门槛 | ≥400 MHz | 已尝试；最高可用 v71：307.69 MHz，未达 400 |
| 3 | 阶段 1 全部门槛 | ≥500 MHz | 已尝试；最高可用 v75：308.71 MHz，未达 500 |

新实验冻结生成 RTL、参数、源码哈希，记录六项性能细目、几何平均、面积、默认综合频率及关键路径。每阶段先记录前后参数对照，再提交验证过的模块实现。400/500 MHz 的尝试未达到目标；只有实测同时满足正确性、面积和 IPC 才标记达标。

```sh
make generate
make build
make test
make perf
make synth
```

生成器使用 Chisel 6.5.0 / Scala 2.13.12。仿真与综合均读取已生成的 `rtl/student_top.sv`，不需要修改课程评测流程。

首版旧格式记录位于 `reports/stage1/base-v1/`，包含冻结 RTL 和测试/综合日志，未包含源码哈希清单；后续实验保存完整源码清单。首版：19 项正确性通过；默认综合 48.471 MHz，面积 13,669.664 μm²，IPC 0.5557，尚未达到 Tier2。优化优先项是访存吞吐和完成/恢复控制扇出。

阶段 1 固定基准为 v66：19/19 正确性、六项性能通过，IPC **0.84776**，默认综合 **304.22 MHz / 17,605.84 μm²**。面积包含 **2,910.44 μm² SRAM**，默认综合目标周期保持 **2 ns**。配置为 ROB 32、IQ 8、I/D cache 各 4 KiB、4 个 Dcache bank、64 字节 line、BTB 64、history 1 位、L0 32 字、每 bank 4 项 Store 缓冲、8 项 Store 地址表、8 项 Load 队列、4 项分支快照；保持每拍一条发射和一条退休。

最终默认 CPU 为 **v75：308.71 MHz、17,754.13 μm²（其中 SRAM 2,910.44 μm²）、IPC 0.84602、正确性 19/19**。在 v66 配置基础上启用逐 bank 预取训练流水、直接使用 LoadQueue 已确认的接收许可、寄存分支恢复年轻掩码及 RAS 写入流水/待写旁路。400 MHz 和 500 MHz 都没有达到。

`baseline.json` 指向最终可复现的达标基准；`make generate` 从该基准冻结的 Chisel 源码重新生成并核对电路，再发布字节完全一致的已测 RTL。`Config()` 和直接 `sbt run` 的缺省参数也对应 v75；参数实验缺省值来自当前 `baseline.json`。直接从可编辑 `src/` 生成实验 RTL 可用 `sbt -batch 'run --out build/custom-rtl --rob 16'`，参数必须显式写在实验记录中。阶段 2 的 `baseline-v66` 明确复用阶段 1 的测量作为优化前对照，没有重复宣称新的测量。

此前 v44 的默认综合频率为 **204.39 MHz**，但面积 **18,040.56 μm²** 超限，不能作为达标基准。参数实验、失败记录与未经完整验证的结果都单独标记。加法器的 65 位输入已经过 Yosys SAT 形式证明，见 `reports/validation/adder/`。

优化前后、六项 IPC 和参数明细见 [阶段 1](reports/stage1/comparison.md)、[阶段 2](reports/stage2/comparison.md)、[阶段 3](reports/stage3/comparison.md)。各阶段 `optimization-notes.md` 说明采用与拒绝的结果，`baseline.json` 固定该阶段最后保留的 Tier2 版本。模块修改、参数变更与性能记录分别提交；完整历史保留在 Git 和每项实验冻结源码中。

| 模块 | 源码 | 职责 |
|---|---|---|
| ISA / ALU | `Decode.scala`, `Adder.scala` | RV32IM 译码、算术、移位、分支与已形式证明的前缀加法器 |
| MDU | `MulDiv.scala` | 分段乘法、迭代除法、恢复取消 |
| 前端 / Cache | `Cache.scala`, `Predictor.scala`, `WordCache.scala` | SRAM I/D cache、4 bank、预取、BTB/BHT/RAS、L0 字节一致性 |
| 重命名 / 恢复 | `Rename.scala`, `Core.scala` | 4 项分支快照、寄存年轻掩码、ROB 和 Store 表 |
| 调度 / 操作数 | `IssueChoice.scala`, `Operand.scala` | 单条最老就绪发射、依赖唤醒及旁路 |
| 访存归属 | `LoadQueue.scala`, `CacheOwner.scala` | 按 bank 准备 Load、旧 Store 等待、恢复后的 dead 响应排空 |
| AXI / 局部逻辑 | `Common.scala`, `PreparedQueue.scala`, `LocalLogic.scala` | AXI AW/W 独立接收、仲裁、队列、局部译码与寄存反馈 |

`rtl/` 已固定为最终选定的 Tier2 CPU；实验验收使用各目录内冻结的 RTL、源码哈希和原始日志。
