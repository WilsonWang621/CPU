# CPU 2026：Area-v2

以 40,000 面积为约束重新实现的 RV32IM CPU：两路分派/提交、两个整数端口和一个独立访存端口，
32 项 ROB、ROB 槽号重命名、四个分支检查点、按序发出的非阻塞访存。
I-cache 为 1 KiB，D-cache 为 2 KiB、64 B 行、两路写穿透/写不分配缓存；使用单比特局部历史分支预测。
片上阵列全部计入综合面积。

完整 RTL 位于 [designs/area_v2/rtl](designs/area_v2/rtl/cpu_top.sv)。
架构取舍见 [design.md](design.md)，实际 IPC、完整面积、时序及测试证据见 [实现报告](reports/area_v2.md)。
原四路 CPU 留在 `rtl/` 作为历史基线；它的成绩不用于新设计。

**六项 IPC 已逐项达标：** 在 20 周期外存、冷缓存、包含退出排空的条件下，最低 IPC 为 1.038772。
完整面积为 35,775.54378，单元级 STA 为 324.83137 MHz；总 IPC 仅作统计。
瓶颈定位、同源码对照和逐项结果见 [IPC 修复报告](reports/area_v2_ipc.md)。

## 构建与使用

需要 Python 3、Make 和 C++17 编译器。默认使用 `clang++`，本次测量版本为 18.1.3。
固定版本的 Verilator、sv2v、Yosys/ABC、OpenSTA 和 ASAP7 库通过现有脚本安装：

```sh
git submodule update --init --recursive
python3 scripts/bootstrap_synth.py
make JOBS=4
```

默认 `make` 和 `make build-v2` 都构建新 CPU，输出为 `build/area-v2/cpu/cpu_sim`。
每次构建保留不可变源码快照、完整参数、工具版本和二进制哈希。

```sh
make test-v2 LATENCY=20 TEST_ARGS=--differential JOBS=4
make test-v2 LATENCY=3 TEST_ARGS=--differential JOBS=4
make verify-v2 JOBS=4
make synth-v2 JOBS=4
make export-verilog-v2
```

普通程序回归检查 25 个镜像的退出值、精确退休条数、逐条退休结果和完整 256 KiB RAM。
`verify-v2` 另构建带 RAT 不变量和事件监测的版本，覆盖恢复、迟到错误、标签重用、MDU 取消和缓存冲突。
运行时间以普通二进制无 trace、无昂贵监测、独立运行的结果为准。

统一外存仍为 32 位、II=1、最多 64 笔在途，性能测试读写延迟均为 20 周期。
缓存冷启动，所有 Store 响应、取消的读和填充均在退出前排空。内存契约见 [接口说明](docs/interfaces.md)。

## 参数与产物

```sh
python3 designs/area_v2/build.py --output build/area-v2/rob16 --param ROB_ENTRIES=16
python3 designs/area_v2/build.py --output build/area-v2/int1 --param INTEGER_PORTS=1
python3 designs/area_v2/build.py --output build/area-v2/gcc --cxx g++
```

ROB、队列和缓存容量使用文档规定的合法二次幂配置。分派/提交支持 1 或 2，整数端口支持 1 或 2，
另有独立访存端口。此架构没有独立 PRF，自由参数是 ROB 结果容量，有效物理结果容量为 `32+ROB_ENTRIES`。
参数测量见实现报告，不能把默认配置的成绩套用到其他参数。

`make synth-v2` 从冻结源码导出 Verilog-2005，完整映射后插入计入面积的真实缓冲树，
核对原逻辑连接，再跑完整 setup/hold 和电气检查。
报告频率是理想时钟、零 I/O 延迟、无布线寄生的单元级 STA 结果，尚无布局布线签核。
单独导出文件为 `build/area-v2/cpu/cpu.v`；保留参数化定义，非默认配置须沿用元数据中的参数。

旧 `make build/test/synth` 及旧专用监测入口继续对应四路历史实现，使用说明在
[历史 README](docs/archive/fourwide-readme.md)。
