# 默认综合优化，阶段 5

沿用阶段 4 的约束：原默认 `make synth`，目标频率超过 300 MHz、面积不超过 36,000 μm²，内存延迟 20 时六项性能 IPC 几何平均不低于 1.0985。保留双发射和缓存。只提交验证过的实现，失败实验保留数据并回退。

当前已验证版本为 **v30：200.39138943 MHz、34,380.04824 μm²、IPC 1.12803365**，完整 19 项正确性通过。相对本轮起点 158.07348 MHz 提高 **26.77%**，性能周期不变；300 MHz 目标尚未达到。

## 基点核对：v25

起始提交为 `5829a3f2736cddff99dd7ed513ebbf033c48afae`。其实际改动是在取指时只使用拍初空闲槽，不再依赖后端同拍 `pop_count`，从而移除后端控制到宽 FIFO 写入的组合路径。提交标题中的 144 MHz 和阶段 4 文档中的 153.78 MHz 都不是这一输入的测量结果。

已有本地 v25 报告的 `area_v2_core.v` SHA256 为 `a2adb7a364b4233f3c9f12c98d487979c17f69ec31e869193f35ba40e8bca0e7`，与起始提交逐字节一致。对应 **158.07347947 MHz、6.326171875 ns、34,286.85288 μm²**；19/19 正确性通过。性能周期分别为 median 7,130、multiply 16,998、qsort 133,882、rsort 132,901、towers 5,233、vvadd 4,252，IPC 几何平均约 **1.1280**。

本轮将该行为同步回 `v2_frontend.sv`，重新导出后与上述输入哈希相同。把已完成报告、输入哈希及验证日志归档到 [timing-stage5/v25](data/2026-10-02/timing-stage5/v25/)，并把已有预测器定向测试加入 `make verify-rtl`；本轮额外运行该测试，六组历史配置共 24,000 次读取检查通过。基点数字来自已有、哈希匹配的默认综合，不是本轮新跑的综合。

## 用户提供的参考仓库

- [WilsonWang621/CPU，Towns](https://github.com/WilsonWang621/CPU/tree/Towns)：本轮网页读取失败，GitHub 连接器读取仓库和分支均返回 404。不能声称已参考其 RTL，也不能把其他分支当作 Towns。
- [Galuisss/ACM-CPU](https://github.com/Galuisss/ACM-CPU)：本轮通过 GitHub 连接器核对，默认 `perf-redesign` 分支仍是 [3df298e94598e0ba0d6f478a7147039e411bbf19](https://github.com/Galuisss/ACM-CPU/commit/3df298e94598e0ba0d6f478a7147039e411bbf19)，与阶段 4 的已复测快照一致。继续读取这一固定快照的同步缓存、预计算 head 译码和局部读取结构；206.66 MHz、IPC 1.0448 的复测数字不当作本项目的成绩。

## 后续实验

v25 的最差路径经过内存 IQ 选择、地址加法和缓存。先尝试将每个内存 IQ 槽的有效地址在现有操作数更新边界准备，发射时只读取已保存地址，避免新增执行周期。随后按新时序路径决定下一项实验。每轮记录频率、面积、IPC、正确性与取舍。

| 版本 | 频率 MHz | 面积 μm² | IPC 几何平均，延迟 20 | 判断 |
| --- | ---: | ---: | ---: | --- |
| v25 | 158.07348 | 34,286.85 | 1.12803365 | 哈希匹配的已验证基点 |
| v26 | 144.87832 | 34,572.08 | 1.12803365 | 内存 IQ 地址预计算；周期不变但时序回退，源代码已回退 |
| v27 | 129.08105 | 34,574.39 | 1.12803365 | 地址预计算与保存运行许可组合，无收益 |
| v28 | 154.33308 | 34,359.61 | 1.12803365 | 仅保存运行许可，无收益 |
| v29 | 157.36899 | 34,397.02 | 1.12803365 | 缓存标签逐组并行比较，无收益 |
| v30 | 200.39139 | 34,380.05 | 1.12803365 | 内存 IQ 下一状态选择寄存；无新增周期，保留 |

v26 在内存 IQ 每项原有的准备/唤醒边界保存有效地址。准备时使用新派发立即数，等待依赖时使用当前行立即数，已就绪的活跃行保持地址。所有六项性能周期与 v25 相同，完整 RTL 定向验证通过。新增仿真绑定检查器逐周期比较就绪行的地址与基址加立即数；带检查器的六项性能也通过。

默认综合表明，去掉发射后的加法仍未解决选择与缓存控制扇出：地址读取末端单个节点扇出 100，新的最差周期为 6.90234375 ns。失败源码补丁、检查器、报告与已完成日志保存在 [v26](data/2026-10-02/timing-stage5/v26/)。完整延迟 20 正确性及带检查器的延迟 3 正确性均已完成，分别 19/19 通过。检查器的统计输出使用 stderr，保持 OJ stdout 答案协议。

v27/v28 分别测试“地址预计算 + 保存运行许可”和“仅保存运行许可”。参考 [Galuisss 的 cpu_top.sv](https://github.com/Galuisss/ACM-CPU/blob/3df298e94598e0ba0d6f478a7147039e411bbf19/designs/area_v2/rtl/cpu_top.sv#L68)，在与退出/异常状态变化相同的边界直接保存 `stopped`，以替代全局 `state!=RUN` 译码。实际周期分别为 7.7470703125 ns 和 6.4794921875 ns，都回退；说明单独复制这一结构不足以提高本设计频率。v28 完整 RTL 定向检查通过，额外验证退出、头部异常、store 响应错误及复位恢复运行许可。v27 只完成六项性能验证，不宣称完整正确性通过。

v29 把数据缓存每路的“先按组读取标签、再比较”改为“每组并行比较完整标签、按地址组选中并归约”。命中语义与周期保持不变，六项性能周期逐项相同，完整 RTL 定向检查通过，但 6.3544921875 ns 仍未超过 v25，因此回退。v28/v29 的完整延迟 20 正确性均已完成，分别 19/19 通过；报告、哈希及可重放源码补丁分别保存到 [v27](data/2026-10-02/timing-stage5/v27/)、[v28](data/2026-10-02/timing-stage5/v28/) 和 [v29](data/2026-10-02/timing-stage5/v29/)。

## 保留的 v30：内存 IQ 下一状态选择

它仍选择最老活跃内存指令，再检查该指令的两个操作数；只将队列即将在现有边界发布的 valid/owner 状态用于预计算选择，不引入新发射周期。下一状态保留旧活跃行，删除本拍已发射、恢复取消或终止取消的行，再加入本拍实际派发的新行与其包含回绕位的标签。派发/删除的优先级与 IQ 寄存器原写入逻辑一致。

新增仿真绑定检查器每拍独立遍历当前活跃队列，核对寄存选择。带检查器的 19 项正确性全部通过，六项性能周期与 v25 逐项相同；六项性能共核对 193,795 次活跃选择，覆盖 60,684 个最老指令尚未就绪的周期。完整 RTL 定向检查也通过，包括分支回绕、年轻内存操作取消与终止状态。定向测试注入 ready 内存行时同时初始化对应选择寄存器。

默认综合得到周期 **4.990234375 ns**。实际提交的 `area_v2_core.v` SHA256 为 `abb97790aa08312c82f81f75048be1a3f364015ea8b54b5f24df77b215b36fcc`，与综合输入相同。报告、输入哈希、正确性/性能明细和选择覆盖保存在 [v30](data/2026-10-02/timing-stage5/v30/)。仿真检查器通过额外 filelist 项绑定到 CPU，不进入综合。

可重放验证：

```sh
make export-verilog
make verify-rtl
frozen_list=$(python3 scripts/area_v2/freeze.py --out build/selection-check/sources)
cp "$frozen_list" build/selection-check/verification.f
# verification.f 的前三项必须使用 frozen_list 目录下文件的绝对路径，
# 再追加 tests/rtl/v2_memory_select_monitor.sv 的绝对路径。
make build FILELIST=build/selection-check/verification.f BUILD=build/selection-check/sim
python3 scripts/area_v2/verify_memory_selection.py --sim build/selection-check/sim/sim \
  --kind correctness --out build/selection-check/correctness.json
python3 scripts/area_v2/verify_memory_selection.py --sim build/selection-check/sim/sim \
  --kind perf --out build/selection-check/perf.json
make synth
```

新最差路径已通过相同综合前端导出的 ABC 前网表核对到 **`core.head[1] → core.rename_maps.checkpoint_pending[0][26]`**，起点和后续三个节点扇出分别为 246、116、118、68，累计到第四节点已是 4.6638 ns。对应证据见 [critical-path-origin.json](data/2026-10-02/timing-stage5/v30/critical-path-origin.json)。下一步要针对提交标签到检查点映射的扇出，而不是继续增加内存执行阶段。
