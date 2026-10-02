# 第二阶段：宽数组读取与空闲槽预写

在现有双发射配置和课程时序预算下，带真实缓冲树的单元级 STA 从 **368.27 MHz 提升到 382.13 MHz**，
总面积从 **31,337.960 降到 30,789.782 μm²**。六项性能测试的指令数和周期数逐项保持，IPC 几何平均为 **1.17233064**。

## 同流程实测对比

| 流程 | 修改前频率 | 修改后频率 | 修改前面积 | 修改后面积 |
| --- | ---: | ---: | ---: | ---: |
| 课程默认 `make synth` | 17.47 MHz | 待最终 STA 归档 | 25,859.919 μm² | 待最终 STA 归档 |
| 直接时序映射，额外缓冲之前 | 82.87 MHz | 230.58 MHz | 31,010.639 μm² | 30,594.774 μm² |
| 完整实现，计入真实缓冲 | 368.27 MHz | **382.13 MHz** | 31,337.960 μm² | **30,789.782 μm²** |

修改前的默认流程重新综合了本轮开始时的准确源码，冻结编号为 `6d532d80b4516ed8`；
其输入哈希与第一阶段的直接映射和带缓冲基线一致。
第一阶段报告中的默认流程 20.68 MHz 对应较早的 Verilog 展开版本，本轮采用重跑的 **17.47 MHz** 作对照。

382.13 MHz 对应 `make synth-stage1` 的完整流程，最小周期 **2.61693 ns**，
3.333 ns 目标建立时间裕量 **+0.71686 ns**。
输入/输出延迟各 0.2 ns，转换时间 0.05 ns，不确定度 0.05 ns，输出负载 5 fF；库、综合脚本和时序约束保持课程配置。
结果属于无布线寄生、理想时钟的单元级 STA，默认综合和带缓冲结果须分别使用。

## 实现与选择依据

参考 [tianhangj 的频率优化提交](https://github.com/tianhangj/RISC-V-CPU-2026/commit/f3ed8dd3bbaf0caae0b245e20bdd0f5ef95477c4)，
采用逐项译码、并行比较和空闲槽数据预写：

- 新增 `v2_read`，每项共享地址译码，再用平衡 OR 树合并宽数据，替代发射队列、取指队列、指令缓存数据和 RAT 的二进制读取 mux。
- 指令缓存 tag 和 BTB tag 在条目内并行比较，再合并命中结果。
- 分派前缀与最终发布拆开。ROB 空闲尾槽准备指令元数据；IQ 空闲槽准备载荷，实际分派只发布有效位。
- RAT 源读取对准备中的第一条目的写入做同包旁路，实际 RAT 更新仍接受最终分派事件。
- 取指 FIFO 提前写空闲尾槽；满队列在同拍弹出后重新写入的槽仍要求真实 push，保护未消费数据。
- 生成器支持记录类型的 `$bits`，展开文件继续通过 Verilog-2005 编译检查。

ROB、队列、缓存和预测表容量保持；双发射、同拍写回旁路和提交宽度保持。
没有增加执行或写回流水周期。

仅做空闲槽预写时，带缓冲频率为 367.39 MHz；加入并行读取后达到 382.13 MHz。
另外测试了检查点 tag 镜像预写，频率为 378.13 MHz，因此交付选择没有该额外改动的版本。
各实验的精确值见 [experiments.csv](data/2026-10-02/timing-stage2/experiments.csv)。

额外物理缓冲从 4490 个降到 **2675 个**；直接映射的最大非时钟扇出从 5482 降到 **3164**，
插入缓冲后的上限为 8。全部 **978,953 个原始单元引脚连接**通过缓冲收缩核对，缓冲面积计入总面积。

## 验证与证据

- 交付 Verilog：内存延迟 20 和 3 周期的正确性测试均为 **19/19**，性能测试 **6/6**，高地址取指和访存通过。
- AXI 独立背压和混合响应：240 笔通过；M 扩展：2577 组算术、24 组 flush 通过。
- 重命名：5000 个随机周期，覆盖 1199 次恢复、660 次取消准备、1779 次同包源旁路、685 次检查点保存和 2467 次匹配提交清理。
- 取指：10000 个随机周期，覆盖 190 个满队列周期、749 次双路弹出、232 次重定向和 22 个错误指令包。
- 结构化源描述启用 `V2_VERIFY` 的六项性能测试通过，周期数与交付 Verilog 一致；覆盖 11436 次重定向、355 个已取消 Load 返回及 211 次仍有取消请求在途的 ROB 槽复用。

归档目录为 [timing-stage2](data/2026-10-02/timing-stage2/)。
其中 `final-sta/report.json`、`direct-raw/report.json` 和 `delivery.json` 记录准确输入、工具、库和结果；
`perf.csv` 保存完整精度 IPC。交付展开文件逐字节匹配所选综合的冻结输入 `0124be52f5be123a`。

## 复现

```sh
make export-verilog
make build BUILD=build/frequency-stage2/final-sim JOBS=8
make test SIM=build/frequency-stage2/final-sim/sim LATENCY=20 MAX_CYCLES=30000000
make test SIM=build/frequency-stage2/final-sim/sim LATENCY=3 MAX_CYCLES=30000000
make perf SIM=build/frequency-stage2/final-sim/sim LATENCY=20 MAX_CYCLES=30000000
make verify-rtl
make synth SYNTH_OUT=build/frequency-stage2/standard
make synth-stage1 STAGE1_OUT=build/frequency-stage2/frequency
```

完整实现报告位于 `build/frequency-stage2/frequency/mapped/`，对应的未加额外缓冲报告位于 `raw/opt/`。
