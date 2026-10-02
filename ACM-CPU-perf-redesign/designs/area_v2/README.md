# Area-v2 完整 CPU

新设计已经实现。默认 32 ROB、两路分派/提交、两个整数端口加独立访存端口；
1 KiB I-cache、2 KiB / 64 B 行的两路写穿透/写不分配 D-cache，单比特局部历史预测。完整规格见 [design.md](../../design.md)。

默认配置六项 IPC **6/6 通过**，最低 **1.038771895**，完整映射面积 **35,775.54378**，单元级 STA **324.83137 MHz**。
优化与同源码参数对照见 [IPC 修复报告](../../reports/area_v2_ipc.md)。
总 IPC 和平均 IPC 仅作统计，不能替代逐项验收。
时序为理想时钟、零 I/O 延迟、无布线寄生的 ASAP7 RVT TT 结果，尚无布局布线签核。
全部来源和限制见 [实现报告](../../reports/area_v2.md)及 [原始记录](../../reports/data/area_v2_implementation.json)。

## 实现文件

- `rtl/cpu_top.sv`：ROB、操作数队列、RAT 集成、固定结果通道、访存顺序、Store Buffer、Load 标签、退出和差分端口。
- `rtl/v2_frontend.sv`：双 bank I-cache、取指 FIFO、局部历史预测/BTB 和恢复。
- `rtl/v2_dcache.sv`：完整 1R1W 数据缓存、MSHR、等待者、写穿透与响应归属。
- `rtl/v2_rename.sv`：四个分支检查点及提交失效，避免恢复到已重用的 ROB 标签。
- `rtl/v2_select.sv`：平衡年龄树，支持最老和最近 Store 选择。

译码、ALU、分支、乘除法及统一内存控制器复用根目录 `rtl/` 中的相应模块。
新构建不包含旧四路 `core.sv`、`frontend.sv` 或通用 `cache.sv`。

## 构建与验证

在仓库根目录执行，默认编译器为 Clang，工具来自固定版本 `build/tools`：

```sh
make JOBS=4
make test-v2 LATENCY=20 TEST_ARGS=--differential
make test-v2 LATENCY=3 TEST_ARGS=--differential
make verify-v2 JOBS=4
make synth-v2 JOBS=4
make export-verilog-v2
python3 designs/area_v2/validate_export.py
python3 designs/area_v2/tests/prove_selection.py
```

默认二进制 `build/area-v2/cpu/cpu_sim`，Verilog-2005 源码 `build/area-v2/cpu/cpu.v`。
`build.json` 保存完整参数和不可变源码快照；其他工具从该快照读取输入。
非默认参数的导出仍保留参数化定义，仿真/综合须沿用元数据中的覆盖值。

`verify-v2` 在四组内存设置下运行 180 项差分，并要求关键机制实际触发。
监测包括 RAT 最年轻写者不变量、重复写回所有权、迟到错误、ROB 重用、MDU 取消和缓存冲突。
监测计数表示发生相应事件的周期数，同拍多个同类事件可能只计一次。

综合采用 Verilog-2005 → Yosys/ASAP7 → 真实缓冲树 → OpenSTA。
`buffer_netlist.py` 核对新增单元在 Liberty 中确为 `Y=A`，收缩缓冲后检查原有全部引脚连接。
缓冲计入面积，不改时钟，不放宽时序约束。`synthesize.py` 对面积、setup、hold 和电气检查联合判定。

## 参数与历史原型

```sh
python3 designs/area_v2/build.py --output build/area-v2/rob16 --param ROB_ENTRIES=16
python3 designs/area_v2/build.py --output build/area-v2/int1 --param INTEGER_PORTS=1
```

默认 / ROB16 / 单整数端口的总 IPC 分别为 1.368460 / 1.335084 / 1.150459；后两点只做性能对照，
不能复用默认配置的面积和频率。物理结果容量为 `32+ROB_ENTRIES`，没有独立 PRF 参数。
`DCACHE_LINE_BYTES` 支持二次幂行长（至少 16 B，缓存至少四行），`LOCAL_HISTORY_BITS=0` 可关闭局部历史。
行长与预测器的对照点同样仅用于性能敏感度，不能复用默认配置的物理结果。

`model.py`、`configs.json`、`measure_area.py`、`rtl/storage.sv` 和 `rtl/v2_load_hit.sv`
保留早期设计模型和结构原型，不参与完整 CPU 构建，也不代替上述实测验收。
历史可行性记录为 [area_v2_feasibility.json](../../reports/data/area_v2_feasibility.json)。
