# ParaRisc

RV32IM CPU 工程。根目录为双发射 Verilog 实现，[single-issue-chisel/](single-issue-chisel/README.md) 独立保留单发射 Chisel 实现及其复现实验。

## 当前默认版本

默认顶层为 [verilog/student_top.sv](verilog/student_top.sv)，交付核心为 [verilog/area_v2_core.v](verilog/area_v2_core.v)，使用 [verilog/filelist.f](verilog/filelist.f)。

| 指标 | 最终验收结果 |
| --- | ---: |
| 默认综合频率 | **503.69 MHz** |
| 总面积 | **35,900.33 μm²** |
| IPC 几何平均，内存延迟 10 / 20 | **1.222171 / 1.113846** |
| 完整正确性 | **19/19** |
| 性能、RTL 单元及高地址检查 | 全部通过 |

配置为 32 项 ROB、双分派/双提交、两个整数端口及独立访存端口、三组 4 项 IQ、三个分支检查点、8 个 Load 槽和 16 个 Store 槽，I-cache 1 KiB、D-cache 2 KiB。已完成本地 Tier3 和 500 MHz 目标验收。

实测条件、精确值及输入哈希见 [最终验收报告](reports/dual-issue/frequency-stage10.md)，原始证据见 [最终测量归档](reports/data/2026-10-16/timing-stage10/clean-default/)。单发射最终版本为 v109：342.13 MHz、17,942.62 μm²、延迟 20 IPC 0.84602、正确性 19/19，满足 Tier2。

## 编译与验证

在仓库根目录执行；工具配置见 [config.mk](config.mk) 和[课程框架说明](README-ZH.md)。默认交付文件不需要 Chisel 或外部 SystemVerilog 转换工具。

```sh
make build BUILD=build/default JOBS=8
make test SIM=build/default/sim LATENCY=20 MAX_CYCLES=20000000
make perf SIM=build/default/sim LATENCY=10 MAX_CYCLES=20000000
make perf SIM=build/default/sim LATENCY=20 MAX_CYCLES=20000000
make verify-rtl
make run SIM=build/default/sim PROGRAM=tests/rtl/high_address.data EXPECTED=0x40100 LATENCY=20
make synth
```

AppImage 所在环境无法使用 FUSE 时，在编译或综合命令前加 `APPIMAGE_EXTRACT_AND_RUN=1`。结构化源描述位于 [verilog/area_v2/](verilog/area_v2/)，`make export-verilog` 确定性地生成交付 Verilog 及 SHA-256 清单。

单发射工程使用 `make -C single-issue-chisel generate`、`build`、`test`、`perf`、`synth`；工具版本和参数见[独立说明](single-issue-chisel/README.md)。

## 仓库目录

| 目录 / 入口 | 内容 |
| --- | --- |
| [verilog/](verilog/) | 当前双发射 RTL、顶层、AXI 适配器及 filelist |
| [single-issue-chisel/](single-issue-chisel/) | 独立单发射 Chisel 工程、冻结基准及报告 |
| [scripts/](scripts/) | 课程工具；`area_v2/` 为导出与定向验证工具 |
| [tests/rtl/](tests/rtl/) | 当前 RTL 单元与高地址用例 |
| [docs/](docs/README.md) | 架构、参数、AXI 和 SRAM 说明 |
| [reports/](reports/README.md) | 各阶段报告、框架同步记录及原始测量索引 |
| [archive/](archive/README.md) | 停用的早期 RTL、Chisel 原型入口和初始计划 |
| [packaging/appimage/](packaging/appimage/README.md) | 课程工具打包 |
| `testcases/` | 课程测试子模块 |
| `build/` | 本地构建与实验输出，已忽略 |

课程接口和评测规则见 [中文说明](README-ZH.md) / [English](README-EN.md)。历史测量按阶段保留，最新结论以最终验收报告为准。
