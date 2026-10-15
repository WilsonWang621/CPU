# 阶段 5：再次冲击 400 MHz

最终默认采用 **v109：342.13164 MHz、17,942.62 μm²、IPC 0.84602401、正确性 19/19**。相对阶段 4 的 v94，频率提高 **3.01%**，所有六项性能周期不变；面积增加 **157.96 μm²**，距 18,000 μm² 上限余 **57.38 μm²**。**400 MHz 未达到**，未将未达标目标写成已完成。

本轮共冻结 15 个候选：13 次默认综合和 2 个 debug 验证版本。原课程 `scripts/synth.py`、ABC 流程、ASAP7 RVT TT、默认 2 ns 时序约束保持原样，面积包含 SRAM；性能使用内存延迟 20、30,000,000 周期上限。`baseline-v94` 明确复用阶段 4 已有测量，不声称新跑。

## 最终保留的改动

1. **提前保存取指队列输出**：`PreparedQueue` 在已有 dequeue 边界保存下一占用槽的数据；空队列或最后一项出队时，从当拍输入准备替代项。空队列 flow 仍当拍透传，满队列仍拒绝 enqueue，redirect 与原队列一起清空。没有新增取指、派发或执行周期。
2. **各 bank 早期归属匹配与局部发射就绪**：启用阶段 4 已有的 `banked-return-match` 和 `local-issue-eligibility`。各 bank 的寄存 owner tag 提前参与比较，实际选中/fire 才能唤醒消费者；数据沿原响应仲裁器返回。发射仍选择最老就绪指令，每拍最多一条。它们与取指头部预存组合才产生本轮收益。

ROB 32、IQ 8、4 个 D-cache bank、I/D cache 各 4 KiB、64 B line、BTB 64、history 1 位、L0 32 字、4 个分支快照等基准参数不变。新增默认仅为 `cached-fetch-head=1`、`banked-return-match=1`、`local-issue-eligibility=1`；发射 payload 仍为 16 位分片。其他本轮实验开关默认关闭。

v100 首次测得上述组合的收益并通过完整验收；v109 在包含所有可选实验的最终源码和最终缺省配置上重新生成、综合、仿真，得到相同频率、面积和性能周期。默认 `baseline.json`、缺省 `Config()`、冻结源码与发布 RTL 统一指向 v109，不能把 v100 的测量套到未测源码。

## 对照与未保留的尝试

| 候选 | 改动 | 默认频率 MHz | 总面积 μm² | 延迟 20 IPC | 完整正确性 |
| --- | --- | ---: | ---: | ---: | --- |
| [v94 对照](baseline-v94/summary.json) | 复用阶段 4 基准 | 332.14402 | 17784.66 | 0.84602401 | 19/19 |
| [v95-cached-fetch-head](v95-cached-fetch-head/summary.json) | 完整取指头部预存 | 327.99488 | 17846.61 | 0.84602401 | 未运行 |
| [v96-cached-head-result16](v96-cached-head-result16/summary.json) | 取指预存 + 16 位结果写回分片 | 322.82472 | 17875.86 | 0.84602401 | 未运行 |
| [v97-age-matrix](v97-age-matrix/summary.json) | IQ 成对年龄矩阵 | 279.85788 | 17734.25 | 0.84602401 | 未运行 |
| [v98-cached-head-local-result](v98-cached-head-local-result/summary.json) | 取指预存 + 按 ROB 行资格判定 | 261.29115 | 17845.77 | 0.84602401 | 未运行 |
| [v99-age-matrix-debug](v99-age-matrix-debug/summary.json) | 年龄矩阵逐拍断言 | — | — | 0.84602401 | 19/19 |
| [v100-cached-head-banked-match](v100-cached-head-banked-match/summary.json) | 取指预存 + bank 归属匹配 + 局部发射就绪 | 342.13164 | 17942.62 | 0.84602401 | 19/19 |
| [v101-prepared-load-result](v101-prepared-load-result/summary.json) | 待完成 Load 结果提前准备 | 336.39947 | 17909.69 | 0.84602401 | 未运行 |
| [v102-local-load-value2](v102-local-load-value2/summary.json) | 两组 Load 格式转换 | 326.32250 | 17938.63 | 0.84602401 | 未运行 |
| [v103-early-bank-load-format](v103-early-bank-load-format/summary.json) | 仲裁前逐 bank 格式转换 | 298.71645 | 17959.23 | 0.84602401 | 未运行 |
| [v104-cached-instruction](v104-cached-instruction/summary.json) | 仅预存取指指令字段 | 306.12855 | 17910.63 | 0.84602401 | 未运行 |
| [v105-cached-inst-parallel-address](v105-cached-inst-parallel-address/summary.json) | 仅预存指令 + 并行分派地址 | 314.98001 | 17999.40 | 0.84602401 | 未运行 |
| [v106-early-format-separate-ready](v106-early-format-separate-ready/summary.json) | 仲裁前格式转换 + 独立操作数就绪 | 330.74935 | 18037.06 | 0.84602401 | 未运行 |
| [v107-combined-debug](v107-combined-debug/summary.json) | 组合语义逐拍断言 | — | — | 0.84602401 | 19/19 |
| [v108-cached-head-issue32](v108-cached-head-issue32/summary.json) | 组合方案改为 32 位发射分片 | 279.09512 | 17898.24 | 0.84602401 | 未运行 |
| [v109-final-cached-banked](v109-final-cached-banked/summary.json) | 最终源码完整复测 | 342.13164 | 17942.62 | 0.84602401 | 19/19 |

所有候选的六项性能答案均通过，周期逐项与 v94 相同。频率回退或面积超限的候选没有补跑完整正确性，`summary.json` 如实标记 `not_run`，不宣称其满足 Tier2。v99、v107 完成 19/19 和六项性能，并启用年龄、返回归属、队列头部、并行地址、临时结果及独立就绪的逐拍一致性断言；debug 没有综合，不作为频率成绩。

年龄矩阵以每对 IQ 槽的一位状态保存先后关系，新派发槽总比旧活跃槽年轻，避免当拍重复比较 ROB tag；语义验证通过但频率下降。写回分片增加了返回 tag 的负载：v96 实测相应节点扇出从 v95 的 111 增至 144，虽减少局部写使能负载，整核频率仍回退。提前准备未完成 Load 的结果，用有效且非 dead/prefetch 的 bank owner 允许临时数据更新，实际完成才发布 done，done 后冻结；减少面积但不改善频率。逐 bank 提前格式转换、局部 Load 数据副本、仅缓存指令字段、并行地址和独立就绪也未超过保留组合。独立就绪组合 v106 面积 18,037.06 μm²，明确排除。

## 性能与验证

| 性能项 | 动态指令 | v94 周期 | v109 周期 | v109 IPC |
| --- | ---: | ---: | ---: | ---: |
| median | 6,961 | 8,527 | 8,527 | 0.81634807 |
| multiply | 21,722 | 23,421 | 23,421 | 0.92745826 |
| qsort | 139,900 | 170,728 | 170,728 | 0.81943208 |
| rsort | 195,719 | 234,842 | 234,842 | 0.83340714 |
| towers | 5,278 | 6,291 | 6,291 | 0.83897632 |
| vvadd | 4,524 | 5,352 | 5,352 | 0.84529148 |

IPC 几何平均为 **0.8460240059**，超过 0.845 门槛。完整正确性、性能、综合记录见 [最终 summary](v109-final-cached-banked/summary.json)、[manifest](v109-final-cached-banked/manifest.json)、[默认综合报告](v109-final-cached-banked/report.json) 和 [时序报告](v109-final-cached-banked/timing.rpt)。参数与六项 IPC 的机器可读对照见 [comparison.csv](comparison.csv)。

- [取指队列独立验证](../validation/prepared-queue/result.json)：8/8 配置，2/8 项队列 × flow 关闭/开启 × 完整/部分头部缓存，1,613,830 周期、1,369,396 次完整 98 位 FIFO 数据核对；覆盖空满、同时入出队、回绕、随机背压、每种占用下的 reset/redirect 和全部合法占用/事务组合。当前 `PreparedQueue.scala` 与冻结验证哈希一致。
- [临时结果独立验证](../validation/prepared-result/result.json)：真实 LocalResultWord 与 CacheOwner，8/16/32 位分片共 184,527 周期、7,565,630 次已发布结果核对；覆盖所有 32 个 ROB 行、垃圾数据准备、完成后冻结、并发不同生产者、分支取消、dead owner、tag 复用及 prefetch。该选项默认关闭，测试不声称覆盖整个缓存 SRAM 或整核。

## 剩余瓶颈

v94 的最差路径起于取指队列 head，经寄存器索引、重命名和 ROB 数据选择到地址加法。取指预存去掉该选择边界后，v95 暴露返回 tag 的扇出和 ROB 完成路径；组合 bank 归属匹配后，v109 的最差终点仍为地址寄存器，路径经过 Load 返回数据、SourceOperand 旁路和地址加法。原默认 STA 最小周期为 **2.9228515625 ns**，距 400 MHz 的 2.5 ns 仍需约 **14.47%** 的压缩。时钟仍为理想模型、无布线寄生，频率为课程综合/STA 流程的结果。

可复现：

```sh
make -C single-issue-chisel generate
make -C single-issue-chisel build
make -C single-issue-chisel test
make -C single-issue-chisel perf
make -C single-issue-chisel synth
python3 single-issue-chisel/scripts/verify_prepared_queue.py
```

最终默认发布前再次运行 `make generate`，核对冻结源码重新生成的电路与已测 RTL 相同，再发布字节一致的实测文件。根目录封存的双发射 v42 不属于本轮改动。
