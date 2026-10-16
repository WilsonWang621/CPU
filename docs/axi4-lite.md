# AXI4-Lite 与内存接口

默认顶层 [StudentTop](../dual-issue-chisel/src/main/scala/tier3/Top.scala) 使用 `clock` 和同步高有效 `reset`，作为 32 位地址、32 位数据的 AXI4-Lite Master。

| 通道 | Master 输出 | Master 输入 |
| --- | --- | --- |
| 读地址 AR | `araddr`、`arvalid` | `arready` |
| 读数据 R | `rready` | `rdata`、`rresp`、`rvalid` |
| 写地址 AW | `awaddr`、`awvalid` | `awready` |
| 写数据 W | `wdata`、`wstrb`、`wvalid` | `wready` |
| 写响应 B | `bready` | `bresp`、`bvalid` |

每个通道在时钟上升沿 `valid && ready` 时完成一次握手；发送方在握手前保持有效信号及载荷稳定。AW 与 W 独立握手，适配器分别保存是否已接受，只有两者均完成后才释放当前写请求。

外部 RAM 为 256 MiB 小端内存，地址范围 `0x00000000`–`0x0fffffff`，未初始化字节为零。总线读写地址按 4 B 对齐；字节和半字 Store 通过对齐地址、数据移位及四位 `wstrb` 表示写入字节。CPU 指令访存遵循课程自然对齐要求。

程序通过向 `0x80000000` 写入一个 32 位结果结束，`wstrb` 为 `4'hf`。顶层在核心结束后继续接收退出写响应，排空总线事务。完整程序和 MMIO 约定见[课程说明](../README-ZH.md)。

[原生适配器](../dual-issue-chisel/src/main/scala/tier3/Bus.scala)默认最多跟踪 16 笔请求，以方向 FIFO 恢复核心响应顺序；R 与 B 通道按队首方向接受返回。响应码 `00` 为成功，其余值转为内部错误。独立背压、读写返回和顺序行为由 [AXI 单元用例](../tests/rtl/pararisc_axi_adapter_tb.sv)覆盖，可运行 `python3 dual-issue-chisel/scripts/verify_units.py --associativity --generate`；旧 Verilog 参考模块的检查仍使用 `make verify-rtl`。
