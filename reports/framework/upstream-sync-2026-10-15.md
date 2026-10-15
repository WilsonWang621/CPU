# 官方框架同步：2026-10-15

已将官方 ACMClassCourse-2025/RISC-V-CPU-2026 的综合器更新同步到当前工作树。来源为官方主分支提交 `302f0cf3cccdaa5de084a2120e0d950c663e4cf5`，提交时间 2026-10-14 05:51:59 UTC，标题为 `Enable configurable ABC buffering and cell sizing constraints`。其唯一父提交是本地原有课程框架 `54fc150ffc290f52aa024209ffb9a29d43856f6d`；核对时官方提交列表只有这两个提交。

## 同步范围

| 文件 | 同步结果 |
| --- | --- |
| `scripts/synth.py` | 与官方提交对应 Git blob 完全一致 |
| `config.mk` | 与官方提交对应 Git blob 完全一致；更新两项参数注释 |
| `README-EN.md` | 与官方提交对应 Git blob 完全一致 |
| `README-ZH.md` | 与官方提交对应 Git blob 完全一致 |
| `Makefile` | 同步官方全部更新，保留本地末尾既有 `scripts/area_v2/targets.mk` include；去除该本地后缀后与官方 blob 完全一致 |

没有覆盖现有 CPU RTL、实验、测试或 `scripts/area_v2/`。`scripts/build.py`、`scripts/timing.py`、`scripts/synth_report.py` 在该上游提交中均未变化，已与同步前快照逐字节比较确认本地也未改动。AppImage 和 ASAP7 库没有上游更新。

官方文件通过已连接的 GitHub 工具按固定 SHA 获取，逐一按 Git 的 `blob <length>\0<content>` 算法校验 SHA-1，结果记录于 [official-blobs.json](../data/2026-10-15/upstream-sync/official-blobs.json)。普通 `git fetch course` 遇到 `.git` 只读限制；获准提升权限后的 fetch 长时间无网络输出，已结束该 fetch，故 `course/main` 跟踪引用仍指向原提交。同步的是上述明确来源且内容已校验的工作树文件，没有合并提交或改写本地历史。

同步前的五个更新文件及未变化的 build/timing/report 脚本保存在 [before/](../data/2026-10-15/upstream-sync/before/)，用于区分此前测量所用旧流程。同步后的 CPU 结果须重新测量，不可将旧流程结果作为新流程结果。

## 优化内容与使用方法

新的官方默认综合调用为：

```sh
make synth ABC_DRIVING_CELL=INVx1_ASAP7_75t_R ABC_LOAD_FF=5.0
```

`ABC_DRIVING_CELL` / `--abc-driving-cell` 指定 ABC 组合逻辑输入边界的驱动单元；`ABC_LOAD_FF` / `--abc-load-ff` 指定 ABC 输出边界电容（fF）。官方示例允许使用 `ABC_DRIVING_CELL=BUFx2_ASAP7_75t_R ABC_LOAD_FF=1.0`，本次同步保留官方默认值。

`scripts/synth.py` 生成 `abc.constr`，默认内容为：

```text
set_driving_cell INVx1_ASAP7_75t_R
set_load 5
```

Yosys 的 ABC 调用增加 `-constr <abc.constr>`，使默认 ABC 流程启用 `buffer`、`upsize`、`dnsize`，以优化高扇出网络时序。`report.json` 新增 `abc_constraints` 字段，记录 `driving_cell` 和 `output_load_ff`。该字段记录参数值；官方脚本未把 `abc.constr` 另外纳入 `inputs` 哈希。

OpenSTA 的外部时序约束未改变，包括固定 5 fF 输出负载。调整 ABC 负载不会调整 OpenSTA 的评价条件。本次同步没有改动时钟目标、面积统计、SRAM 模型或正确性/IPC 测量方法。

## 可用性验证

以下检查通过：

- `python3 -m py_compile scripts/synth.py`。
- `python3 scripts/synth.py --help`，两项新参数均存在。
- `make help` / `make -n synth`，Makefile 默认值和参数传递符合官方更新。
- 使用单独的 16 寄存器小型 RTL 执行完整官方 `make synth`（不是 CPU 评分测量），返回成功并生成综合、面积及 OpenSTA 报告。
- 小型综合日志确实执行 `ABC: + buffer`、`ABC: + upsize -D 2000`、`ABC: + dnsize -D 2000`，`report.json` 记录官方默认 ABC 参数及固定的 OpenSTA 5 fF 负载。
- `git diff --check` 通过。

小型流程验证材料位于 [smoke/](../data/2026-10-15/upstream-sync/smoke/)。其中频率只验证工具链能够运行，**不代表 CPU 的频率或 Tier3 达成情况**。完整 CPU 的面积、频率、IPC 与正确性由后续独立实验报告给出。
