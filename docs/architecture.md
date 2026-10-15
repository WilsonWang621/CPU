# 默认双发射架构

默认交付由三个文件组成：[核心](../verilog/area_v2_core.v)、[AXI 适配器](../verilog/pararisc_axi_adapter.sv)及[顶层](../verilog/student_top.sv)。[结构化源描述](../verilog/area_v2/)按模块维护，导出器将记录布局和多维队列展开为普通 Verilog。

| 模块 | 职责 |
| --- | --- |
| `v2_frontend` | 取指、预测、指令缓存和取指队列 |
| `decoder` / `v2_rename` | 译码、ROB 槽号重命名、同束旁路与分支检查点 |
| `v2_select` / `v2_operand` | 三组发射队列、年龄选择、操作数准备和唤醒 |
| `alu` / `branch_unit` / `muldiv` | 整数、分支、乘除执行及恢复 |
| `v2_dcache` / `memory_controller` | 非阻塞数据缓存、访存排队及返回归属 |
| `v2_retire_read` / `v2_arch_word` | ROB 头部读取、有序双提交和架构状态 |
| `v2_distribution` / 局部选择模块 | 保留层次的控制分发、局部读取及地址选择 |
| `pararisc_axi_adapter` | 内部有序请求与独立 AXI 通道的转换 |

默认保留 32 项 ROB、三组 4 项 IQ、三个检查点、8 个 Load 槽、16 个 Store 槽、1 KiB 指令缓存和 2 KiB 两路数据缓存，数据缓存行宽 64 B，四个 MSHR。顶层允许最多 16 笔在途外部请求。容量推导见[参数说明](parameters.md)。

恢复、ROB、缓存、提交和地址选择使用普通 RTL 定义的反相器分发树，综合后单元的面积和延迟纳入默认流程。最终验收同时绑定导出文件、工具配置与输入哈希；503.69 MHz 的详细测量及功能结论见[阶段 10 报告](../reports/dual-issue/frequency-stage10.md)。

单发射实现的模块划分、SBT 生成入口和冻结基准见[独立工程](../single-issue-chisel/README.md)。
