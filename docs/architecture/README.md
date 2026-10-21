# single-issue-chisel 总体架构图

打开 [交互式总体架构图](single-issue-overview.html)。文件是独立 HTML，可以下载到本机后用 Chrome、Chromium、Edge 或 Firefox 打开，不需要运行 CPU 或启动服务器。

可编辑图源：[single-issue-overview.json](single-issue-overview.json)。标题、组件、坐标、连线、源码引用、导览和节点说明卡分别位于 `meta`、`components`、`connections`、`sources`、`meta.views`、`cards`。不建议直接编辑生成的 HTML。

## 阅读方法

- 总体图包含 10 个组件；选择节点可查看关联连线和源码引用，页面说明卡补充职责、输入输出、条件及源码位置。
- 通过“ADD 主路径（经 IQ）”“访存与外部接口”“提交与恢复控制”导览聚焦讨论范围。
- 青色强调实线为选定 ADD 数据路径，普通实线为其他数据和请求，虚线为提交、恢复与预测训练控制。MemPort 箭头仅标 req 方向，配对 rsp 反向返回。
- ADD 示例明确限定 `direct=false`；`direct=true` 可跳过 IQ 保留项。图中动画不是周期仿真。
- 可缩放、搜索节点、切换深浅主题，通过页面导出菜单保存图片或 SVG。

## 源码身份与边界

源码身份：`bec3010ab17a9293fa45db1f6486eb111986e1d7`，仓库标识 `git@github.com:Team-Homework/ParaRISC.git`。源码引用采用 local-only 模式；HTML 在别的机器上可阅读引用路径和行号，但不保证本地编辑器导航。此次开始检查时工作区干净；交付只新增本目录文档，没有修改 CPU 源码。

生成入口为 `tier2.Generate`（`single-issue-chisel/build.sbt:9`），它生成 `StudentTop(p)`；`StudentTop.desiredName` 为 `student_top`，实例化 `c: Core` 并展平 AXI 信号（`Core.scala:460–501`）。下表位置均相对 `single-issue-chisel/src/main/scala/tier2/`。

| 图中组件 | 实例或逻辑归属 | 定义 / 关键接线 |
|---|---|---|
| Frontend | `fetch: Frontend`；内部 I-cache、预测状态和取指队列 | `Cache.scala:250–394`；`Core.scala:8–11` |
| Decoder | `decoder: Decoder` | `Decode.scala:13–30`；`Core.scala:306–311` |
| RenameEntry / SourceOperand | `renameEntries`、`source(...)` 内实例 | `Rename.scala:8–39`；`Core.scala:312–321,419–426` |
| IQ / OperandEntry | `qvalid/qd/qtag`，`operandsA/operandsB`；IQ 是逻辑分组 | `Core.scala:51–58,248–305,335–382` |
| Execute / LocalWord | `alu: Execute`，`xdWord/xaWord/xbWord/xtWord/addressWord` | `Decode.scala:33–52`；`Core.scala:59–93,340–354` |
| ROB / LocalResultWord | `live/done/head/tail/count`、`resultWords/architecturalWords`；ROB 是逻辑分组 | `Core.scala:12–50,209–244,384–448` |
| LoadQueue / WordCache | `loadRequests`、`l0`、Core 的 Store 表和转发；不是独立 LSU 类 | `Core.scala:94–197,323–333`；`LoadQueue.scala:8–60` |
| MulDiv | `md: MulDiv` | `MulDiv.scala:6–81`；`Core.scala:197–214` |
| DataCache / Cache | `dc: DataCache`；内部 `caches/metadata/stores/requests/responses` | `Cache.scala:128–240`；`Core.scala:94–139` |
| MemoryArbiter / Bus | `arb: MemoryArbiter`、`bus: Bus` | `Common.scala:101–143`；`Core.scala:5–11,460–470` |

独立模块和 Core 内部分组在说明卡中区分。默认 `Config()` 强制 `issueWidth==1`，ROB32、IQ8、Load8、Store8、检查点4；只展示该配置启用的模块。Frontend 的 Cache 实例固定单路，DataCache 的 bank Cache 默认两路。分支预测、旁路、缓存和最老就绪选择均由实际实例、状态读写及连线确认；本次未重新运行 CPU 功能回归、综合或性能评测。

未展开外部 AXI 从机、FakeRAM 模型内部、clock/reset 分发和优化局部单元；未声称固定指令延迟或运行正确性证明。连线是总体关系摘要，不是逐根信号网表。`cdb` 与 `preparedCdb` 由 Core 组合逻辑产生，ROB 分组包含共享完成接线；唤醒不要求先写入再读出结果寄存器。

## 重新生成和验证

在仓库根目录执行（按本机路径修改 `ARCHIFY_CHROME` 和 Archify 安装位置）：

```sh
ARCHIFY_CHROME=/home/wangwenxuan/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome \
node /home/wangwenxuan/.agents/skills/archify/bin/archify.mjs finalize architecture \
  docs/architecture/single-issue-overview.json \
  docs/architecture/single-issue-overview.html \
  --repo-root . --quality showcase --json \
  --out-dir docs/architecture/review-next
```

已存在的浏览器证据绑定对应 HTML 字节；修改图源后应使用新的 `--out-dir`。如果代码版本变化，应重新阅读源码并更新引用与 `meta.repository.revision`，不能仅替换版本号。

当前交付验证见 [最终回执](review-4/single-issue-overview.finalize-summary.json)。历史 review-2/3 和 before-layout 图源仅保留布局比较证据，不是当前交付。当前版本保留两处具有跨线标记的连线交叉，不能当作信号汇合点。

本次只完成总体架构图；后续可基于同一证据补充 ADD 逐拍示意、重命名/唤醒、分支恢复和访存细图。
