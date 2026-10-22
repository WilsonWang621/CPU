# 可参数化多发射 Chisel 总体架构

[打开交互图](dual-issue-overview.html) · [编辑 JSON 图源](dual-issue-overview.json) · [返回图表索引](README.md)

本图依据 `main` 的 `a922b00ea0db34e3bd9f73fd97703d2b43bbb984` 源码，展示 `dual-issue-chisel` 的默认 `Config()`。仓库身份为 `git@github.com:Team-Homework/ParaRISC.git`，源码引用使用 `local-only`，在其他机器上仍可读相对路径和行号。开始审计时工作区干净，当前分支跟踪 `mine/main`；已检查本地、远程分支、最近历史与测试子模块，没有切换或覆盖其他实现。

图中的 11 个节点分别代表真实模块或明确标注的 `Core` 内部逻辑分组。`StudentTop` 的两个直接实例是 `core: Core` 和 `bridge: AxiAdapter`；其他 10 个节点均属于 `Core`。`Generate` 默认生成 `StudentTop(p)`，其 RTL 名为 `student_top`，`Core` 的 RTL 名为 `cpu_top`。

## 模块与连接盘点

下表的 Scala 文件均位于 [`dual-issue-chisel/src/main/scala/tier3/`](../../dual-issue-chisel/src/main/scala/tier3/)。完整职责、输入输出和条件保留在 HTML 的同名说明卡，选中节点可查看对应源码引用。

| 图中节点 | 实际归属 / 主要接口 | 源码位置 |
| --- | --- | --- |
| `Frontend` | `frontend: Frontend`；输入 `pop_count / redirect / train_*`；输出 `packet_*`；含 I-cache、预测器和 FIFO | `Frontend.scala:16–50,76–125,134–161`；`Core.scala:116–133` |
| `Decoder ×2 / 分派` | 两个 `d: Decoder`，分派为 Core 组合逻辑；`packet_inst → decoded → dispatch_payload`，资源不足阻塞后续 lane | `Decode.scala:35–79`；`Core.scala:147–149,330–388` |
| `Rename / 操作数读` | `rename_maps: Rename` 加 Core 读数逻辑；`source_register → source_pending / source_slot`，从 PRF、ARF 或 `wb_*` 取得操作数 | `Rename.scala:7–68`；`Core.scala:158–174,367–388` |
| `IQ / Operand` | `queue(0..2)`、逐操作数 `Operand` 和选择器；输入 `dispatch_payload / wb_*`，输出 `executing(0..2)` | `Core.scala:36,193–248,528–570`；`LocalLogic.scala:217–231` |
| `Alu ×2 / BranchUnit` | 两个 `a: Alu`、`branch_i: BranchUnit`，加 Core 写回组合逻辑；`executing(0/1) → wb_*`，分支另输出 `branch_*_q` | `Decode.scala:82–103`；`Core.scala:175–191,285–311` |
| `ROB / PRF / ArchWord` | `rob / values / head / tail`、`RetireRead`、32 个 `ArchWord` 及提交恢复控制；分派分配、执行写回、队首提交、恢复年轻项 | `Core.scala:23–70,93–146,314–325,412–443,453–526`；`LocalLogic.scala:175–205` |
| `访存逻辑 / loads / stores` | Core 内部逻辑；`executing(2) / prepared_address → load_* / store_* / wb_*(2)`，含 Store 转发与 Load 取消 | `Core.scala:250–311,545–552,582–609` |
| `DCache` | `dcache: DCache`；`load_* / store_*` 与 `result_* / load_data / store_done*`，外接 `mem_req_* / mem_rsp_*` | `DCache.scala:19–143,147–224`；`Core.scala:118–133,267–306` |
| `MemoryController` | `memory_bus: MemoryController`；源 0 为 Frontend、源 1 为 DCache，`s_req_* / s_rsp_* ↔ mem_req_* / mem_rsp_*` | `Bus.scala:7–58`；`Core.scala:120–135,141–146` |
| `AxiAdapter` | `bridge: AxiAdapter`，与 Core 同级；`req_* / resp_* ↔ AR / R / AW / W / B` | `Top.scala:5–28`；`Bus.scala:60–107` |
| `MulDiv` | `mdu: MulDiv`；输入端口 0 的 `req_*`、`kill / kill_mask`，`rsp_*` 优先使用 `wb_*(0)` | `MulDiv.scala:11–53`；`Core.scala:78–83,289–297` |

`ROB`、`IQ`、`PRF`、分派和访存没有被虚构成独立 Module；`Read / GrantRead / PriorityMux / Distribution / PrefixAdder` 等局部单元在节点说明内归并。顶层 AXI 信号和退出复用关系在 `AxiAdapter`、`ROB` 说明中列出。

## 如何讨论这张图

青色强调实线为选定 ADD 数据路径，普通实线为其他数据、请求及携带结果的唤醒，虚线为提交、恢复和训练控制。图中 `mem_req_*` 箭头只表示请求方向，配对的 `mem_rsp_* / ready / error` 反向返回。交叉线不表示信号汇合。

“ADD 主路径”选择一条合法、`rd≠0`、经 `bank1` 的 ADD：

1. `Frontend.packet_inst` 进入 `Decoder`，产生 `decoded.op=ADD`。
2. 资源可用且未恢复时分派，`Rename` 查生产者 tag，Core 读 `values / architectural` 或旁路，形成 `dispatch_payload`。
3. `queue(1)` 等待 A/B 就绪，`ParallelSelect` 在该 bank 的就绪项中选最老者，送入 `executing(1)` 和 `Alu`。
4. `wb_valid(1) / wb_rid(1) / wb_value(1)` 更新 ROB 和推测值槽，同时唤醒匹配 tag 的等待操作数。
5. 进入队首连续可提交前缀后，经 `retirement_value / commit_*` 更新 `ArchWord`，清除匹配 Rename pending，并推进 `head`。

这些步骤是源码数据与控制关系；等待、背压和恢复可能改变经过的周期数。动画没有使用 CPU 运行轨迹。

## 参数和事实边界

默认 `renameWidth=2`、`commitWidth=2`、`integerPorts=2`、`issueWidth=3`；最后一项统计两个整数端口加一个 LSU 的总新发射上限。“双发射”目录名不代表全局发射上限为 2。分派与提交宽度、整数端口数只支持 1 或 2，总发射宽度支持 `1..integerPorts+1`，并非任意 N 路结构。

默认 ROB32、推测 PRF32、固定 ARF32、三组各 4 项 IQ、3 个分支检查点、Load8、Store16；I-cache 1 KiB / 1 路 / 32 B 行，D-cache 2 KiB / 2 路 / 64 B 行 / 4 MSHR，最多 16 个内存事务。默认值取自 `Common.scala:11–44`、`Generate.scala:30–42`，并与已提交的 `rtl/elaboration.json` 核对。

可以确认整数 IQ 的就绪驱动乱序选择和 ROB 的顺序提交；访存 bank2 先选最老项，再等操作数，不能据此宣称任意 Load 越过未完成访存。`wb_* → Operand`、分派旁路、Store 到 Load 的全覆盖转发均有源码实现。预测器的 BHT / BTB / local_history 有实际查询和训练。两级缓存使用 Chisel 寄存器阵列，没有 `sram_fakeram` 实例；DCache 的 Store 会发送外部写请求，不按脏行写回缓存描述。

未从 README 或旧计划推导已实现功能。当前构建为 sbt；根目录没有有效 `build.mill`，旧 Mill 原型在 `archive/chisel-prototype/`。`docs/planning/` 不存在，旧计划在 `archive/planning/`，没有作为本图的实现证据。官方要求见[课程仓库](https://github.com/ACMClassCourse-2025/RISC-V-CPU-2026)，本图接口以当前 `Top.scala / Bus.scala` 为事实依据。

已有回归、参数敏感度和面积/时序结果保留在[历史验收与参数报告](../../dual-issue-chisel/reports/requirements-2026-10-16/report.md)，组件证明与逐拍对照在 [v13 报告](../../dual-issue-chisel/reports/final/report.md)。本次只制作文档，没有重新运行 CPU 仿真、综合或性能评测；图的验证不替代这些验证。未发现绘图所需模块缺口，不修改 CPU 源码，也不新增或推断 Load 重放机制（`load_replay_count` 在 Core 中固定为 0）。

## 编辑与重新验证

下载 HTML 后用浏览器直接打开；无需编译 CPU、联网或启动服务。进入页面后点“动态 / Live”播放，点“静止 / Still”暂停；导览聚焦 ADD、访存、恢复和 MulDiv。说明卡列出各节点职责和 I/O，节点选择展示源码引用；可缩放、切换主题并导出图片或 SVG。

修改 JSON 后，在仓库根目录执行，按本机安装位置调整路径：

```sh
ARCHIFY_CHROME=/path/to/chrome \
node /path/to/archify/bin/archify.mjs finalize architecture \
  docs/architecture/dual-issue-overview.json \
  docs/architecture/dual-issue-overview.html \
  --repo-root . --quality showcase --json \
  --out-dir docs/architecture/dual-issue-review-next
```

既有浏览器证据绑定对应 HTML 字节，每次改变候选后用新的 `--out-dir`。源码变化后应重新阅读受影响模块、更新行号和版本，不能只替换 `meta.repository.revision`。

当前交付的[最终自动验证回执](dual-issue-review-2/dual-issue-overview.finalize-summary.json)包含源码引用检查、showcase 布局、交付、严格产物检查及真实浏览器检查。已另行查看 1440×900、2048×1320 两种尺寸的深浅主题截图，见[截图索引](dual-issue-visual-check/dual-issue-overview.visual-check.html)。保留 9 处有跨线标记的连接交叉；这些交叉不代表信号汇合。浏览器回执自身只记录自动测量，人工截图审阅另见[审阅记录](dual-issue-overview.review.json)。

根目录 `dual-issue-overview.finalize* / browser-check.json` 和 `before-layout.json` 保留首个通过版本的布局比较证据；当前 HTML 以 `dual-issue-review-2/` 回执为准。旧单发射图与其证据不受本次绘图影响。

本轮先完成总体图。下一张可沿现有节点与信号逐步展开重命名/唤醒，再补充分支恢复和 Load miss / Store 提交图，不预先把未完成细图列为已交付。
