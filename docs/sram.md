# SRAM 与面积计数

课程允许使用其提供的 `sram_fakeram`，不要求 CPU 必须实例化 SRAM。当前默认 Chisel 的缓存及预测表采用触发器实现，官方综合报告中的 SRAM 面积为 0，所有触发器和组合逻辑均计入总面积 35,930.96658000839 µm²。

以后使用 FakeRAM 时，应遵守[官方 SRAM 规范](../dual-issue-chisel/reports/requirements-2026-10-16/upstream/docs/sram.md)：同步单端口 1RW、读延迟一拍、按掩码写入、无全局复位；禁用或写周期的输出未定义。不得依赖未初始化内容，也不能把它当作异步读寄存器堆。

课程构建和综合脚本自动引入 `scripts/ram/sram_fakeram.sv`，不要将它加入交付 filelist，也不要自行声明保留名称的空桩。总面积须包含官方模型计入的 SRAM 面积；FakeRAM 与外部 256 MiB AXI RAM 是不同的存储结构。

