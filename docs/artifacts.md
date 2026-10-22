# 产物与实验归档规则

Git 保存课程需要的文件、实验摘要、配置和关键日志。较大的完整输出按实验打包保存，避免反复提交整个构建目录。已跟踪文件的大小见[统计报告](artifact-audit.md)和 [JSON](artifact-audit.json)，可用以下命令更新：

```sh
python3 scripts/audit_artifacts.py --history
```

该命令更新统计报告，不会移动或删除已有产物。`--history` 只统计本地已有的 Git 历史；若本地历史不完整，结果也不包含缺失的部分。

## 各类文件如何保存

| 类别 | Git 中保留 | 归档策略 |
| --- | --- | --- |
| 源码与配置 | Chisel、Verilog、脚本、Makefile、版本配置 | 必须跟踪；它们定义实验输入 |
| 课程必需生成 RTL | 当前三套入口涉及的 `rtl/`、根 filelist 和 Verilog 导出 | 必须跟踪；课程构建和入口审计依赖它们 |
| 工具包 | `cpu2026-tools-x86_64.AppImage` 及工具版本/哈希 | 当前历史输入保留；后续优先 Release 附件，Git 只保留哈希和下载信息 |
| 实验摘要 | `summary.json`、`acceptance.json`、`identity.json`、CSV、报告正文、配置和 manifest | 提交到 Git，注明各项数值对应的原始记录 |
| 完整日志和综合输出 | `.log`、`.rpt`、压缩报告、映射网表、巨型 JSON | 已有历史保留；新增实验放入外部归档包，Git 保留清单和关键报告 |
| 波形 | VCD/FST/FSDB 等 | 不进 Git；仅在确需复现时放入带清单的归档包 |
| 冻结输入 | `verified/`、`frozen-input/`、源码/RTL 快照和 `source.tar.gz` | 已有归档保留；新实验保存一份输入，并在 manifest 记录源码、RTL、工具和测试集的哈希或版本 |

`.gitignore` 只忽略可重新生成的 `build/`、`target/`、`out/` 和缓存目录；没有忽略 `testcases/`，也没有用 `*.json`、`*.log` 等宽泛规则隐藏证据。

## 新实验的归档流程

先在独立目录完成实验，目录至少包含摘要、参数、源码/RTL SHA-256、评测流程版本、正确性/性能摘要和报告路径。完整日志、波形、综合中间物放在该目录的 `full/` 子目录。生成归档包并验证还原：

```sh
python3 scripts/archive_experiment.py \
  --experiment-id <id> \
  --input-dir <experiment-directory> \
  --output-dir <archive-directory>
```

命令生成 `<id>.tar.gz` 与 `<id>.manifest.json`，manifest 为每个成员记录路径、大小和 SHA-256，并记录归档包 SHA-256；创建后会自动解包到临时目录逐文件核对。归档包不应包含 `.git/`、未声明的绝对路径或符号链接。Git 中提交摘要、配置、manifest、包 SHA-256 和关键报告；完整包可以留在受控对象存储或 Release 附件。

脚本已用 `reports/experiments/` 验证过打包和还原。现有历史报告仍保存在原位置。

## 适合迁移到 Release 附件的历史文件

优先迁移体积大、可由清单定位且不是默认课程入口的对象：课程 AppImage、`reports/data/` 中阶段综合/时序完整输出、重复的候选 `report.json`、映射网表和波形。保留默认 `dual-issue-chisel/rtl/student_top.sv`、`single-issue-chisel/rtl/student_top.sv`、Verilog reference 导出、filelist、摘要 JSON/CSV、`verified` 验收清单和复现脚本。

迁移步骤：

1. 用 `audit_artifacts.py --history` 统计大小和 Git 对象哈希，确定实验 ID 与打包内容。
2. 用 `archive_experiment.py` 生成包，保存 `.manifest.json`、包 SHA-256 和对应摘要链接。
3. 在临时目录解包并校验哈希，确认能根据 manifest 找到源码、RTL、工具和测试输入。
4. 创建带实验 ID 的 Release 附件，说明工具链、约束和不可直接比较的流程差异。
5. 确认附件可以下载后，更新报告中的链接并保留 manifest。删除旧文件或清理 Git 历史应另行安排。
