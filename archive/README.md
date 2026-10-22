# 历史原型归档

此目录保留已经停用的早期工程文件，便于查阅历史。当前编译和验证入口见[主 README](../README.md)。

| 目录 | 内容 |
| --- | --- |
| [rtl/](rtl/) | 早期 `pararisc_*` RTL 模块；当前默认 filelist 不使用这些模块 |
| [chisel-prototype/](chisel-prototype/) | 早期 Mill 配置及对应译码/数据通路测试，原配套 `cpu2026` 源码已不在当前工程中 |
| [planning/](planning/) | 初始开发计划，保留当时的任务和状态 |

早期原型目录用于历史查阅，其 Mill 和测试脚本依赖当时的源码布局。当前默认 Chisel 实现位于 [dual-issue-chisel/](../dual-issue-chisel/README.md)，独立单发射实现位于 [single-issue-chisel/](../single-issue-chisel/README.md)，均使用各自的 sbt 与 Makefile。生成入口和课程 filelist 对照见[仓库首页](../README.md#实现对照表)。
