# ParaRISC 参数化 Chisel：课程要求与架构权衡

全部课程要求已逐项实现并通过本地验收。默认同一 Chisel 配置满足 104 分档的正确性、面积、IPC 和频率门槛；14 组参数配置均通过完整正确性及性能测试。机器可读结果见 [acceptance.json](acceptance.json)，可运行 `python3 dual-issue-chisel/scripts/audit_requirements.py` 复核当前输入与原始证据。

本次沿用现有原生 Chisel CPU，补齐独立 PRF 容量、全局发射宽度和缓存相联度的实现及验证，并保留已达到面积、IPC、频率目标的默认电路。课程来源固定为 [官方 main `302f0cf`](https://github.com/ACMClassCourse-2025/RISC-V-CPU-2026/tree/302f0cf3cccdaa5de084a2120e0d950c663e4cf5)，测试子模块为 `29f980727f7d99a1842a58f34091c7579ba3fe85`。官方默认内存延迟为 10；延迟 20 是额外检查。

## 同一默认配置的测量

| 条件 | 结果 | 证据 |
| --- | ---: | --- |
| 官方全部正确性，延迟 10 / 20 | 各 19/19，0 失败 | [原始日志](verified/parameters/default/) |
| 全部六项性能，延迟 10 | IPC GM 1.2221711020297619 | [原始日志](verified/parameters/default/perf-lat10.log) |
| 全部六项性能，延迟 20 | IPC GM 1.1138460959843028 | [原始日志](verified/parameters/default/perf-lat20.log) |
| 总面积，含实际使用的 FakeRAM | 35,930.96658000839 µm² | [官方综合报告](verified/synthesis/report.json.gz) |
| 组合 / 时序 / SRAM 面积 | 22,145.284980008662 / 13,785.6816 / 0 µm² | 同上 |
| OpenSTA 测得最小周期 / Fmax | 1.9892578125 ns / 502.70004909180165 MHz | [时序报告](verified/synthesis/timing.rpt) |
| 2.0 ns 下最差 setup slack | +0.010982 ns | 同上 |

默认是 ROB32、推测 PRF32、固定 ARF32、三组各 4 项 IQ、两个整数端口及独立 LSU、双分派/双提交、三个分支检查点、8 个 Load 槽、16 个 Store 槽。I-cache 为 1 KiB 直接映射，D-cache 为 2 KiB 两路、64 B/行、4 MSHR；AXI 最多 16 个在途事务。**默认全局发射上限为 3**；工程名“双发射”描述双分派和两个整数端口，不表示整数加 LSU 每拍只能发射两条。

最终 RTL SHA-256 为 `47be40fda5f2efa7384113e6b8deb1e908c1c825f78a56b36ce2c6d9907a3b0e`。当前 Scala 再生成的默认 RTL 与该文件逐字节相同，综合报告的输入哈希也相同。与冻结 v13 相比，全部 352,319 个硬件 token 一致，只忽略注释、token 间空白及诊断字符串中的 Scala 行号；核对见 [default-circuit-equivalence.json](default-circuit-equivalence.json)。本次新增参数路径没有改变默认电路。

根目录 `verilog/filelist.f` 直接列出此原生 Chisel RTL，课程默认 `make build/test/perf/synth` 无需指定 FILELIST 即选择同一配置。旧 Verilog 文件保持原样，并通过 `verilog/reference_filelist.f` 独立选择。默认入口另外执行独立构建、完整正确性、性能和综合检查，见 [entry/](verified/entry/)。

时序使用课程默认 ASAP7 RVT TT、INVx1 驱动、5 fF 输出负载、0.2 ns 输入/输出延迟及 0.05 ns 时钟不确定度。频率来自 STA 的最小可行周期搜索，2.0 ns 只是约束。该结果为课程规定的理想时钟、无布线寄生估计。默认缓存使用触发器，实际没有实例化 FakeRAM，因此 SRAM 项为 0；缓存触发器面积全部计入总面积，没有豁免存储阵列。

## 现有实现盘点与复用

开始时核对了工作区、全部本地/远程分支、历史、子模块和未提交文件。`main` 上的原生 Chisel 是完整可运行 CPU；`Wilson`、历史集成分支及另外两个工作树也存在较旧实现，没有覆盖或切换这些工作树。本轮保留用户已有的 `AGENTS.md` 和文档改动，不提交或推送。

| 模块 | 本轮处置与验证依据 |
| --- | --- |
| `Frontend.scala` | 复用双指令取指、BHT/BTB、预测目标缓存和 FIFO；增加 1/2/4 路组织，保留回填物理槽归属 |
| `Decode.scala`、`MulDiv.scala` | 复用 RV32I、全部八条 M、分支/跳转与乘除；默认硬件保持已证明电路，增加独立 86 项 ISA 检查 |
| `Rename.scala`、`Core.scala` | 复用 ROB、检查点、三组 IQ、唤醒、转发、有序退休；增加独立 PRF 分配和全局发射限额 |
| `DCache.scala`、`LocalLogic.scala` | 复用非阻塞回填、等待项、写穿透、锁定 victim 和选择树；推广至 1/2/4 路 |
| `Bus.scala`、`Top.scala` | 复用 AXI 适配器、请求归属、同步高复位和退出排空；顶层公开缓存与总线容量参数 |
| sbt / 课程工具 | 复用 Chisel 6.5.0、Scala 2.13.12、sbt 1.10.2、firtool 1.62.0；保持官方评价脚本 |
| 单发射工程 / 旧 Mill 原型 | 独立保留，不替代目标中的多发射原生 Chisel CPU |

原 v13 缺少独立 PRF、全局发射上限、相联度的真实参数，以及完整参数敏感度报告，详见 [最初审计](audit.md)。没有重写已工作的 CPU。完整的参数范围、实际作用和测量分析见 [参数敏感度报告](parameter-sensitivity.md)。

## 乱序执行、退休与 ISA / 接口

`ArchitectureProbe` 继承生产 `Core`，只增加观察端口和断言。专用程序先发出一个较老的 cache-miss Load，再执行无关整数指令。检查实际写回发生时该 Load 仍在 ROB 中且未完成；按拍核对全部退休 PC 必须连续递增，最终恰好退休 12 条指令。默认、全局宽度 1/2、单整数端口加 PRF8 共四组配置，在内存延迟 10/40 下分别检查实际发射数不超过限制且达到配置上限。默认探针使用与被综合默认 CPU 相同的全部参数，测试电路从未用于面积或频率测量。

独立程序检查 x0、算术/逻辑/移位、带符号与无符号比较、全部分支的 taken/not-taken、AUIPC、JAL/JALR 链接与 bit0 清零、八条 M 指令的除零/溢出/负数、LB/LBU/LH/LHU/LW 与 SB/SH/SW 的小端掩码。另测 256 MiB RAM 最后一个字及 `0x0fffffc0` 处取指。每组参数均运行这些检查、官方完整正确性和全部六项性能。课程明确免除的 CSR、FENCE/FENCE.I、ECALL/EBREAK 不作为缺失功能。

`student_top` 采用官方 32 位 AXI4-Lite 端口、同步高有效 reset。退出先停止取指并排空较老访存，再用 `AWADDR=0x80000000`、`WSTRB=0xf` 发送返回值；官方模拟器在 B 握手时结束。独立 AXI 检查包含 240 笔混合事务、AW/W 独立背压、负载保持、读写响应重新归并及错误响应。缓存独立检查涵盖 1/2/4 路，每路都有 10,000 周期取指/重定向、预测目标、并发 miss/错误响应/消费者背压，以及字节写和同字冲突。

这些证据是完整官方软件回归和定向硬件不变量检查。历史组件形式证明仍保留在 [v13 证据](../final/report.md)；未声称任意程序下的整机形式等价或完成了物理布局布线。

## 架构探索与取舍

**将已验证的快配置作为默认。** 参数实验中，ROB16、PRF8 和 IQ2 分别降低延迟 10 的 IPC 约 0.65%、3.79%、2.64%；将 D-cache 缩为 1 KiB 降低约 4.28%。这些是 IPC 实测，不能推导各变体的 Fmax。旧 Verilog 的 ROB16 组合有更高频率测量，但不作为本次 Chisel 最终配置证据。默认 ROB32 / PRF32 / IQ4 / D-cache2KiB 同时保留已验证的三个门槛。

**独立 PRF 的灵活性有控制成本。** 默认 PRF 与 ROB 等容量时保留原先一一映射，省去独立分配的硬件；容量不同则按 live ROB 项建立占用位图，分配两个空闲物理值槽并保存 ROB-to-PRF 映射，退休和恢复释放所有权。源依赖仍用 ROB 生产者标签，实际值通过映射读取；所有活项的物理槽互异有断言。每条在途指令占一槽，包括 store/退出携带值；固定 32 字 ARF 与推测 PRF 分离。PRF64 在该程序集上没有 IPC 收益，PRF8 会较早反压，因此没有替换默认。

**执行带宽与调度灵活性分别测量。** 默认最多发射两个整数加一个 LSU。全局宽度 2 保留三个候选端口，按 ROB 年龄允许两条，IPC 仅下降约 0.52%；禁用第二整数端口则下降约 13.62%，说明保留候选执行资源的效果与只改总上限不同。全局宽度 1 下降约 29.24%。同拍 MDU/缓存的异步完成不重复计为新发射。

**相联度不保证单调改善。** 同容量两路 I-cache 的六项周期与直接映射完全相同；本数据下没有观察到增益。D-cache 改直接映射下降约 22.06%，说明本组程序对数据冲突明显更敏感。四路双缓存/PRF64 是组合探索，IPC 轻微下降约 0.02%；不能把该组合差异全部归因于某个参数，也未据此宣称面积或频率更优。

**优先缩短现有组合路径，避免增加周期。** 之前的时序探索保留了局部选择、写回分发和提前准备访存地址，仍沿用原时钟边界。Chisel 原生候选 v2 为 488.32 MHz / 36,277.82 µm²，v7 为 446.38 MHz / 35,928.98 µm²，v12 为 496.12 MHz / 35,924.22 µm²；只有 v13 达到 502.70 MHz / 35,930.97 µm²。单独保留译码/RAT 层次未必改善时序，最终采用直接指令分类、等价的 RAT 输入比较及选择性层次保留。各失败候选的验证范围见 [历史记录](../progress.md)，不继承默认正确性结论。

面积余量约 69.03 µm²，频率余量约 2.70 MHz，均较小。最终选择已有同时达标的默认电路；新的优化必须重新生成、测量和绑定证据后再替换。

## 从源码复现

在仓库根目录执行，工具包无需 FUSE：

```sh
python3 dual-issue-chisel/scripts/requirements_programs.py
python3 dual-issue-chisel/scripts/check_parameters.py --generate --full-correctness --workers 4
python3 dual-issue-chisel/scripts/check_parameters.py --profiles default --latencies 20
make test SIM=dual-issue-chisel/build/parameters/default/sim/sim LATENCY=10 MAX_CYCLES=20000000
python3 dual-issue-chisel/scripts/check_parameters.py --profiles default --latencies 10,20 --full-correctness --collect-only
python3 dual-issue-chisel/scripts/check_architecture.py --generate
python3 dual-issue-chisel/scripts/verify_units.py --associativity --generate
make -C dual-issue-chisel generate
python3 dual-issue-chisel/scripts/verify_default_identity.py
python3 dual-issue-chisel/scripts/check_entry.py
APPIMAGE_EXTRACT_AND_RUN=1 make synth SYNTH_OUT=dual-issue-chisel/build/requirements-entry/synth
python3 dual-issue-chisel/scripts/archive_requirements.py
python3 dual-issue-chisel/scripts/audit_requirements.py
```

参数检查使用官方 `make build/test/perf/run`，保留 `--assert`。`--collect-only` 只重新解析已有日志并检查输入身份，不当作新执行。完整归档包含每组参数、源码/RTL/二进制哈希、原始周期、测试输入、源码快照、探针 RTL、适配测试台和官方综合/STA 原始文件。审计会拒绝源码、脚本、程序集、日志或报告改变后的旧验收。

本地 Makefile 与官方版本相比只追加自有可选 targets 的 include；官方 build/test/perf/synth 规则及全部评价脚本逐文件保持一致，见 [framework-comparison.json](framework-comparison.json) 和 [官方 Makefile 原文](upstream/Makefile)。课程评价语义、测试期望值、面积算法和 STA 约束均未更改。
