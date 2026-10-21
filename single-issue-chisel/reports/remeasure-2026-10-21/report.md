# 单发射 v109：新官方综合流程复测（2026-10-21）

同一 v109 电路在启用 ABC 缓冲和尺寸优化的官方流程下，测得 **423.31542 MHz、18,831.74030 μm²**。频率超过 400 MHz，但总面积超过 Tier2 上限 **831.74030 μm²（4.62%）**，不能把这次结果记为 95 分或 97 分达标。未修改架构、参数、Chisel 源码或交付 RTL，也未调整课程约束。

## 官方版本、现有实现与复用

本次开始时 `main` 为 `ab9fc97`，工作区干净；已检查本地/远程分支、历史与测试子模块。现有完整单发射 CPU、冻结 v109 源码和 RTL 均可复用，无需替换模块。根目录默认入口是双发射，本次始终显式指定 `single-issue-chisel/rtl/filelist.f`，未混用双发射成绩。

GitHub API 核对的最新官方 main 为 [`302f0cf3cccdaa5de084a2120e0d950c663e4cf5`](https://github.com/ACMClassCourse-2025/RISC-V-CPU-2026/commit/302f0cf3cccdaa5de084a2120e0d950c663e4cf5)，提交说明为 “Enable configurable ABC buffering and cell sizing constraints”。当前评测脚本已包含此更新。本次与该提交已归档的 Git blob 标识逐文件比较，`scripts/synth.py`、时序/面积/FakeRAM、编译、仿真和测试脚本均一致；Makefile 仅多自有可选 target include，评测规则不变。核对见 [framework-verification.json](framework-verification.json)。本次额外请求在线文件树遇到网络超时，未声称重新下载了整套官方文件；已读取同一官方提交的 README、AXI 与 SRAM 归档。

当前 Scala 全部文件与 [v109 冻结源码](../stage5/v109-final-cached-banked/source/)逐字节一致，交付 RTL SHA-256 仍为 `98875bedd710fc8373e539fd5ae3133ed8a3fa14b181335ec41198828eb58693`。本次直接测量该 RTL，未重新运行 Chisel 生成器。参数为 ROB32、IQ8、单发射/单提交、4 个检查点、Load8、Store8、L0 32 字、4 个 D-cache bank、I/D 各 4 KiB、64 B 行；Frontend I-cache 固定单路，D-cache bank 两路。完整参数见 [parameters.json](parameters.json)，输入及工具哈希见 [manifest.json](manifest.json)。

## 综合与 STA

| 指标 | stage5 历史归档 | 本次新流程 |
|---|---:|---:|
| 总面积（含 SRAM），μm² | 17,942.62274 | 18,831.74030 |
| 组合逻辑面积，μm² | 9,580.43052 | 10,469.54808 |
| 时序逻辑面积，μm² | 5,451.75360 | 5,451.75360 |
| FakeRAM SRAM 面积，μm² | 2,910.43862 | 2,910.43862 |
| STA 最小可行周期，ns | 2.9228515625 | 2.3623046875 |
| STA Fmax，MHz | 342.13164 | 423.31542 |
| 2.0 ns 目标下最差 setup slack，ns | -0.922730 | -0.361838 |

与历史记录相比，频率提高 **23.73%**，面积增加 **4.96%**；精确值见 [summary.json](summary.json)。组合逻辑面积增加，时序和 SRAM 面积保持一致。该比较反映新官方流程下同一 RTL 的测量变化，不是 CPU IPC 或流水线结构优化；两次综合工作目录不同，也不声称为隔离所有输入命名因素的单变量实验。

当前使用课程默认 ASAP7 RVT TT、`CLOCK_PERIOD_NS=2.0`、ABC `INVx1_ASAP7_75t_R` 驱动和 `5.0 fF` 输出负载，综合模式 `opt`。`abc.constr` 由未修改的官方脚本生成；原始 ABC 日志可确认执行 `read_constr`、`buffer`、`upsize -D 2000`、`dnsize -D 2000`。部分局部模块低于目标延迟时，ABC 明确跳过其 upsizing，不能理解为所有单元都进行了放大。

工具为 Yosys 0.63（`70a11c6bf`）、OpenSTA 3.1.0、Verilator 5.020。AppImage SHA-256 为 `49d9180387701ab2d35d0f706b153dbf06ac81defd22c39e010cd9c7a2020fa6`；与历史综合报告中的 Yosys/OpenSTA 版本一致，主要变化为官方脚本的 ABC 约束和优化流程。

423.32 MHz 是课程规定的理想时钟、无布线寄生 STA 估计，不是布局布线后的频率。2.0 ns 下仍有负 slack，没有达到 500 MHz。原始结果见 [综合报告](synthesis/report.txt)、[时序报告](synthesis/timing.rpt)、[详细报告 JSON](synthesis/report.json.gz)、[综合日志](synthesis/synth.log.gz)及 [映射网表](synthesis/mapped.v.gz)。

## 仿真与性能

| 项目 | 内存延迟 10（官方默认） | 内存延迟 20（历史对照） |
|---|---:|---:|
| 完整正确性 | 19/19，0 失败 | 19/19，0 失败 |
| 性能程序 | 6/6 | 6/6 |
| IPC 几何平均 | 0.878464423670 | 0.846024005871 |

| 程序 | 动态指令数 | 延迟 10 周期 | 延迟 10 IPC | 延迟 20 周期 | 延迟 20 IPC |
|---|---:|---:|---:|---:|---:|
| perf_median | 6961 | 8178 | 0.851186109 | 8527 | 0.816348071 |
| perf_multiply | 21722 | 23333 | 0.930956157 | 23421 | 0.927458264 |
| perf_qsort | 139900 | 167964 | 0.832916577 | 170728 | 0.819432079 |
| perf_rsort | 195719 | 217393 | 0.900300378 | 234842 | 0.833407142 |
| perf_towers | 5278 | 6062 | 0.870669746 | 6291 | 0.838976315 |
| perf_vvadd | 4524 | 5093 | 0.888278029 | 5352 | 0.845291480 |

延迟 20 的六项周期逐项与 stage5 v109 历史记录一致；综合优化没有改变本次测试的 RTL 周期行为。延迟 10 的新测 IPC 为 0.87846442，不能与旧延迟 20 的 IPC 直接当作性能提升比较。

原始日志：[正确性 L10](correctness-lat10.log)、[正确性 L20](correctness-lat20.log)、[性能 L10](perf-lat10.log)、[性能 L20](perf-lat20.log)。完整精度见 [summary.json](summary.json) 和两份 `performance-lat*.csv`。

按当前官方门槛作本地数值判断：Tier1 面积超限，Tier2 面积超限，Tier3 IPC 不足；本次没有通过任何性能档，因此不能获得频率加分。完整正确性通过对应 85 分的本地门槛判断，不是官方最终评分或完整架构要求审核。

本次从交付 RTL 用课程 `make build` 重新编译，保留 `--assert`，再调用官方 `make test/perf`。官方缺省延迟 10 为主要口径，延迟 20 用于和历史单发射报告比较。每个程序的周期上限为 30,000,000；各性能点 IPC 用测试子模块原始动态指令数除以本次实测周期，几何平均从未舍入的 IPC 计算。

软件回归验证的是 RTL 模拟器，不是映射后门级仿真或任意程序形式证明。本次未重新进行全部参数敏感度、MDU/缓存独立单元或整机形式验证；不把历史证明作为本次新执行。

## 中文路径故障与复现

直接在当前中文路径调用官方综合脚本时，Yosys 在 `read_json` 阶段报 `Unsupported \uXXXX sequence in JSON string: FFFF`。故障来自源码绝对路径属性的编码往返；失败日志见 [failed-unicode-synth.log](failed-unicode-synth.log)。

为保持官方脚本不变，将相同 RTL、filelist、scripts、Makefile 和 config.mk 复制到 `/tmp/pararisc-single-remeasure-20261021`，逐字节核对 RTL 后综合。工具包仍用同一个 AppImage，时序、面积、库和 ABC 参数不变。没有改写中间网表、删除路径属性、豁免 SRAM 或禁用优化来绕过问题。仿真使用原工作区重新编译的同哈希 RTL。

在仓库根目录运行：

```sh
bash single-issue-chisel/reports/remeasure-2026-10-21/reproduce.sh
```

脚本在新的英文临时目录复制输入、编译、跑两种延迟的完整正确性及性能，再执行官方综合。它保留工作目录和原始日志，不会修改 CPU 源码。不同工具包、库、脚本或 RTL 必须重新记录身份，不能沿用本报告数值。

[baseline.json](../../baseline.json)继续选择已冻结的 v109 电路，原字段保留 stage5 历史成绩，不覆盖旧证据；新增指针指向 [latest-measurement.json](../../latest-measurement.json)中的当前测量。新结果单独归档，没有将新频率与旧面积拼接成一个“达标配置”。
