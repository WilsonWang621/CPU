# 单发射 v110：恢复新官方流程下的面积达标

保留 v109 的全部容量及流水线逻辑，只让 `LocalMask`、`LocalWord` 不再继承带 `keep_hierarchy` 的 `LocalLogic`。相同官方 ABC 约束下，面积从 **18,831.74030 μm² 降至 17,933.13116 μm²**，减少 **898.60914 μm²（4.77%）**；Fmax 为 **422.44224 MHz**。没有通过缩小 ROB、IQ、缓存或关闭功能来取得最终结果。

延迟 10/20 的完整正确性均为 **19/19**，六项性能均通过且周期逐项与 v109 一致；IPC 几何平均分别为 **0.87846442 / 0.84602401**。同一默认配置同时满足面积 ≤18,000 μm²、IPC ≥0.845、Fmax ≥400 MHz，达到 **Tier2 + 400 MHz 加分，即 97 分的本地数值门槛**。这不是官方最终评分或完整参数化要求审核。

## 复用与实现取舍

开始时 `main=b953bb4`、工作区干净。核对了分支、历史、子模块、默认 filelist、单发射生成/构建入口和 v109 源码。官方 main 经 GitHub API 核对仍为 [`302f0cf`](https://github.com/ACMClassCourse-2025/RISC-V-CPU-2026/commit/302f0cf3cccdaa5de084a2120e0d950c663e4cf5)。沿用现有完整单发射实现，根目录双发射入口保持原样。

新流程的面积构成显示，强制保持层次的 `LocalMask` 占约 1,031.07 μm²、`LocalWord` 占约 1,610.40 μm²。它们本质上是数据掩码和带使能寄存器。层次边界会阻止综合器跨边界合并数据选择、掩码和反馈 mux。因此，最终只将这两个类的父类改为普通 Chisel `Module`，允许官方 `synth -flatten` 与 ABC 对这些相邻逻辑共同优化。

`LocalLogic` 的注解实现以及 `RenameEntry`、`OperandEntry`、`LocalResultWord`、`WordCacheEntry`、地址/年龄等其他模块的继承均保留。没有改变 IO、寄存器更新条件、时钟/恢复边界、指令执行顺序规则或 Cache 行为，也没有在交付 RTL 上手工修改综合属性。源改动仅为 `LocalLogic.scala` 中两个父类名称。

全部参数保持：ROB32、IQ8、单发射/单提交、检查点4、Load8、Store8、L0 32 字、4 个 D-cache bank、I/D cache 各 4 KiB、64 B 行。默认 v110 的源文件和 RTL 冻结在本目录 `source/`、`rtl/`，实际交付入口仍是 `single-issue-chisel/rtl/filelist.f`。

## 候选比较

下表均使用更新后的官方综合脚本，`opt` 模式、2.0 ns 目标、`INVx1_ASAP7_75t_R` 驱动、5 fF ABC 负载。IPC 使用同一官方测试子模块，未使用旧面积或另一份 RTL 的频率拼接。

| 方案 | ROB / IQ / 检查点 | 总面积 μm² | Fmax MHz | IPC 延迟10 / 20 | 处置 |
|---|---|---:|---:|---|---|
| v109 新流程复测 | 32 / 8 / 4 | 18,831.74030 | 423.31542 | 0.87846442 / 0.84602401 | 面积超限，保留历史 |
| ROB16 | 16 / 8 / 4 | 17,448.95852 | 413.73737 | 0.87261806 / 0.84113429 | 未采用，未运行完整正确性 |
| IQ4 / 检查点2 | 32 / 4 / 2 | 17,681.15960 | 465.03179 | 0.86913805 / 0.83732230 | 未采用，未运行完整正确性 |
| **v110，取消两类数据模块的层次保留** | **32 / 8 / 4** | **17,933.13116** | **422.44224** | **0.87846442 / 0.84602401** | **采用** |

两组容量候选在官方延迟 10 下 IPC 均超过 0.845，但延迟 20 下均低于旧保守门槛；它们只完成性能和综合探索，不能继承最终配置的正确性结论。v110 保留全部容量，且两种延迟的 IPC 均不下降，因此选择 v110。候选参数、原始性能、综合报告见 [candidate-comparison.json](candidate-comparison.json) 和 `candidates/`。

## 综合与时序

| 项目 | v109，新官方流程 | v110，同一官方流程 |
|---|---:|---:|
| 总面积 μm²，含 SRAM | 18,831.74030 | 17,933.13116 |
| 组合逻辑面积 μm² | 10,469.54808 | 9,614.09574 |
| 时序逻辑面积 μm² | 5,451.75360 | 5,408.59680 |
| SRAM 面积 μm² | 2,910.43862 | 2,910.43862 |
| 最小可行周期 ns | 2.3623046875 | 2.3671875 |
| Fmax MHz | 423.31542 | 422.44224 |
| 2.0 ns 下最差 setup slack ns | -0.361838 | -0.366516 |

距离 18,000 μm² 面积上限余 **66.86884 μm²**。余量较小，后续源码、参数、工具或约束变化必须重新测量。频率相对 v109 新流程下降约 0.21%，但仍超过 400 MHz；没有达到 500 MHz，2.0 ns 下仍有负 slack。

使用同一课程 AppImage、Yosys 0.63（70a11c6bf）、OpenSTA 3.1.0、ASAP7 RVT TT，缓冲、尺寸优化和全部面积计数保持启用。完整库哈希、RTL 身份、ABC 约束、脚本与源码哈希见 [manifest.json](manifest.json) 和 [官方综合报告](synthesis/report.json.gz)。频率属于课程的理想时钟、无布线寄生 STA 估计，不是布局布线后的频率。

## 功能与行为保持的证据

对 v109 和 v110 的生成 SystemVerilog 做逐 token 比较：保留字符串字面量，只忽略注释、空白和 `keep_hierarchy` 属性后，**841,757 个 token 全部一致**。这证明本次生成 RTL 的代码差别只在层次保留属性；它不是新执行的门级等价或任意程序整机形式证明。具体输入 SHA-256 和方法见 [logic-identity.json](logic-identity.json)。综合器可因此合并重复逻辑或寄存器，所以映射后的时序面积略有变化，不能据此推断修改了 RTL 时钟边界。

| 程序 | 指令数 | 延迟10 周期 | 延迟20 周期 |
|---|---:|---:|---:|
| perf_median | 6961 | 8178 | 8527 |
| perf_multiply | 21722 | 23333 | 23421 |
| perf_qsort | 139900 | 167964 | 170728 |
| perf_rsort | 195719 | 217393 | 234842 |
| perf_towers | 5278 | 6062 | 6291 |
| perf_vvadd | 4524 | 5093 | 5352 |

仿真器从选定 Chisel 生成 RTL 重新编译，保留课程 `--assert`，所有运行最大 30,000,000 周期。不能把未采用候选的性能或频率与最终配置混用。原始记录为 `correctness-lat*.log`、`perf-lat*.log`；完整精度见 [summary.json](summary.json)。

## 默认入口与复现

`baseline.json`、`latest-measurement.json` 和发布的 `rtl/student_top.sv` 统一指向 v110。`Config()` 的容量参数没有变化；直接生成实验 RTL 与 `make generate` 仍使用同一参数。`make generate` 从本报告冻结的 Chisel 源码重建并核对电路，然后发布字节相同的已测 RTL；验证日志见 `verify-regeneration.log`。

在仓库根目录执行：

```sh
make -C single-issue-chisel generate
bash single-issue-chisel/reports/area-recovery-2026-10-21/reproduce.sh
```

复现脚本先核对发布 RTL 的哈希，再在新的英文临时目录复制输入，调用未修改的官方 build/test/perf/synth。英文路径用于规避已记录的 Yosys 中文路径 JSON 编码缺陷；不改评测算法、约束或电路。完整输入和证据摘要分别见 [manifest.json](manifest.json)、`evidence-sha256.json`。旧 v109 的不达标结果保留在 [上次复测](../remeasure-2026-10-21/report.md)，不覆盖历史实验。
