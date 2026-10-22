# 产物与实验归档规则

当前仓库保留课程交付和可审计摘要；大型完整输出按实验打包，不继续把每次构建目录复制进 Git。当前跟踪文件的分类和大小见[审计报告](artifact-audit.md)及[机器可读结果](artifact-audit.json)。报告由以下命令从工作树和本地 Git refs 重新生成：

```sh
python3 scripts/audit_artifacts.py --history
```

`--history` 只扫描本地 refs 能看到的 Git 历史，不推断远端是否完整。它不会改动文件。

## 分类与保留边界

| 类别 | Git 中保留 | 归档策略 |
| --- | --- | --- |
| 源码与配置 | Chisel、Verilog、脚本、Makefile、版本配置 | 必须跟踪；它们定义实验输入 |
| 课程必需生成 RTL | 当前三套入口涉及的 `rtl/`、根 filelist 和 Verilog 导出 | 必须跟踪；课程构建和入口审计依赖它们 |
| 工具包 | `cpu2026-tools-x86_64.AppImage` 及工具版本/哈希 | 当前历史输入保留；后续优先 Release 附件，Git 只保留哈希和下载信息 |
| 实验摘要 | `summary.json`、`acceptance.json`、`identity.json`、CSV、报告正文、配置和 manifest | Git 保留；每个数值必须能指向原始证据 |
| 完整日志和综合输出 | `.log`、`.rpt`、压缩报告、映射网表、巨型 JSON | 已有历史保留；新增实验放入外部归档包，Git 保留清单和关键报告 |
| 波形 | VCD/FST/FSDB 等 | 不进 Git；仅在确需复现时放入带清单的归档包 |
| 重复冻结输入 | `verified/`、`frozen-input/`、源码/RTL 快照和 `source.tar.gz` | 已有验收归档不移动；新实验只冻结一次，并在 manifest 记录源、RTL、工具和测试身份 |

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

当前脚本已用 `reports/experiments/` 做小型归档进行了还原验证；现有历史报告和链接未被移动或重写。

## 适合迁移到 Release 附件的历史文件

优先迁移体积大、可由清单定位且不是默认课程入口的对象：课程 AppImage、`reports/data/` 中阶段综合/时序完整输出、重复的候选 `report.json`、映射网表和波形。保留默认 `dual-issue-chisel/rtl/student_top.sv`、`single-issue-chisel/rtl/student_top.sv`、Verilog reference 导出、filelist、摘要 JSON/CSV、`verified` 验收清单和复现脚本。

迁移步骤：

1. 用 `audit_artifacts.py --history` 记录当前大小和对象身份，确定实验 ID 与包内容。
2. 用 `archive_experiment.py` 生成包，保存 `.manifest.json`、包 SHA-256 和对应摘要链接。
3. 在干净临时目录运行同一脚本的生成/解包校验，并用 manifest 定位源、RTL、工具和测试输入。
4. 创建带实验 ID 的 Release 附件，说明工具链、约束和不可直接比较的流程差异。
5. 先把报告链接切换到 Release 附件并保留本地 manifest；确认可访问后才考虑后续独立清理，当前任务不删除 Git 对象、不运行 `git filter-repo`。
