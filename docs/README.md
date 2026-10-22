# 项目文档

[仓库首页](../README.md)介绍三套实现和运行命令，[在线展示](https://wilsonwang621.github.io/CPU/)提供交互架构图，[报告索引](../reports/README.md)收录测量结果和测试记录。根目录默认构建 `dual-issue-chisel`；单发射 Chisel 和 Verilog 参考实现需要分别构建。

| 文档 | 内容 |
| --- | --- |
| [默认双发射架构](architecture.md) | 原生 Chisel 默认入口、模块与数据流，以及 Verilog 参考入口 |
| [默认双发射交互图](architecture/dual-issue-overview.html) / [源码盘点](architecture/dual-issue-overview.md) | 11 个核心组件、模块接口、ADD 主路径和源码位置 |
| [单发射交互图](architecture/single-issue-overview.html) | 对应 `single-issue-chisel`，与默认实现的图分开保存 |
| [图表索引与编辑说明](architecture/README.md) | 两套图源、HTML、GIF、源码快照和 Archify 验证证据 |
| [参数](parameters.md) | 顶层参数、默认容量与已测配置 |
| [Chisel 参数实验](../dual-issue-chisel/reports/requirements-2026-10-16/parameter-sensitivity.md) | 已归档的 PRF、发射宽度、ROB/IQ 与缓存容量/相联度实验 |
| [AXI4-Lite](axi4-lite.md) | 通道、握手、地址和响应约定 |
| [SRAM](sram.md) | 课程 SRAM 模型与综合约定 |
| [Agent 工程指令](../AGENTS.md) | 当前构建/验证入口、协作约束与证据要求 |
| [GitHub Actions](ci.md) | PR 检查、Chisel 生成一致性、手动完整验证和已执行的检查 |
| [实验索引](../reports/experiments/README.md) | 三套实现的基准结果、源码哈希、评测流程和原始报告 |
| [产物与实验归档规则](artifacts.md) | 跟踪文件审计、分类、可验证打包和 Release 附件迁移步骤 |
| [在线展示](https://wilsonwang621.github.io/CPU/) / [页面文件](site/index.html) | 架构图、测试方法、基准结果和详细报告 |
| [网站部署说明](pages.md) | Pages 构建、链接检查和仓库设置 |

源码和生成命令见[双发射 Chisel](../dual-issue-chisel/README.md)及[单发射 Chisel](../single-issue-chisel/README.md)。Verilog 参考构建需要指定首页列出的 filelist。完整评测规则见[课程说明](../README-ZH.md)，各项测试的执行日期和结果见对应报告。

