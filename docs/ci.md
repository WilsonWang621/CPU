# GitHub Actions 验证

[返回首页](../README.md) · [文档索引](README.md) · [workflow](../.github/workflows/validate-rtl.yml)

## 调整前的检查

原 `Validate RTL` 在 PR、`main` push 和手动触发时执行以下检查：

| 检查 | 覆盖内容 | 未覆盖内容 |
| --- | --- | --- |
| `make export-verilog` 后 `git diff` | Verilog 参考核心及其导出哈希清单 | 不检查 Scala 或 Chisel 生成 RTL |
| `make verify-rtl` | Verilog 参考模块的现有完整单元脚本 | 不执行原生 Chisel 模块生成与测试 |
| 根 `make build` | 默认双发射 Chisel 的已提交 RTL | 不重新生成，无法发现 Scala 与 RTL 脱节 |
| 高地址 `make run` | 上一步的默认 Chisel 模拟器 | 是定向用例，不是完整官方回归 |

原 checkout 未初始化测试子模块，也没有完整正确性、性能或综合任务。以上检查均保留，名称现在明确标注所针对的实现。

## 当前触发方式与分工

| Job | PR / main push | 手动触发 | 检查内容 |
| --- | --- | --- | --- |
| `validate`：Verilog reference | 执行 | 执行 | 导出一致性、完整现有 `make verify-rtl` |
| `chisel`：Default Chisel | 执行 | 执行 | 检查器自身测试、当前源码重生成、原生七项模块检查、默认课程入口构建和高地址用例 |
| `full`：所选实现 | 不执行 | 快速检查通过后执行 | 所选交付 RTL 的完整官方正确性和六项性能，各跑延迟 10 / 20，再做课程综合 / STA |

所有 checkout 均设置 `submodules: recursive`，检出仓库记录的 `testcases` 提交。[checkout v4 文档](https://github.com/actions/checkout/blob/v4/README.md#usage)说明未配置 SSH key 时会把 `git@github.com:` 子模块 URL 转为 HTTPS，因此公开课程子模块不需要另配 SSH 私钥。

在 Actions → **Validate RTL** → **Run workflow** 中选择 `dual-issue-chisel`（默认）、`single-issue-chisel` 或 `verilog-reference`，即可运行完整评测。任务使用 [Dockerfile](../Dockerfile) 中的课程工具链，调用 `make build/test/perf/synth`，并通过 filelist 选择实现。默认使用根目录的 `verilog/filelist.f`。单发射的测试上限为 30,000,000 周期，另外两套为 20,000,000 周期。

综合参数沿用课程 Makefile：2.0 ns、`INVx1_ASAP7_75t_R` 驱动和 5 fF ABC 负载。Dockerfile 固定了 Yosys、OpenSTA、CUDD 和 ASAP7 的源码版本，构建日志保存工具版本和库文件哈希。实际 Fmax、面积和 IPC 以运行报告为准；2.0 ns 是综合目标，是否满足时序需要查看 STA 结果。

## 默认 Chisel 生成一致性

[check_generated_rtl.py](../.github/scripts/check_generated_rtl.py) 使用现有 `tier3.Generate`，执行等价于在 `dual-issue-chisel/` 下运行的 `sbt -batch 'run --out <临时目录>/rtl'`，不覆盖已提交 RTL。

CI 使用 Temurin **17.0.12+7**、sbt **1.10.2**、Scala **2.13.12** 和 Chisel **6.5.0**，并核对项目配置中的版本。Chisel 6.5.0 对应 firtool **1.62.0**，见[版本对应表](https://www.chisel-lang.org/chisel3/docs/appendix/versioning.html)。检查脚本会移除子进程中的 `CHISEL_FIRTOOL_PATH`，由 Chisel 下载对应版本，再核对新 RTL 的 firtool 版本头。

检查范围：

1. 复用课程 `scripts/build.py` 的 `read_sources`，解析根 `verilog/filelist.f` 和 `dual-issue-chisel/rtl/filelist.f`。二者必须指向相同、位于默认 Chisel 交付目录内的 RTL。
2. 在新临时目录生成，逐字节比较课程 filelist 选中的全部 RTL，以及记录默认配置的 `elaboration.json`。`filelist.f` 不是该生成器输出，检查的是它实际选择的源文件。
3. 发现差异时失败，控制台显示前 100 行 unified diff，artifact 保留完整 diff、不同的重生成文件、生成日志及含双方 SHA-256 的 `result.json`。生成器失败、产物缺失、版本错误或 filelist 改道也会失败。

在不同临时目录和源码副本中的验证结果一致：`student_top.sv` 和 `elaboration.json` 都能逐字节复现。因此比较时保留全部内容，包括注释、空白、源码行号和断言字符串。`verify_default_identity.py` 用于历史 v13 的 token 等价检查；这里的脚本用于检查当前源码与已提交 RTL 是否同步。

本地复用命令（仓库根目录，需要项目工具链与现有 RTL 工具）：

```sh
python3 -m unittest discover -s .github/tests -v
python3 .github/scripts/check_generated_rtl.py
make export-verilog
git diff --exit-code -- verilog/area_v2_core.v verilog/area_v2_core.json
make verify-rtl
make -C dual-issue-chisel verify-units
make build CONFIG=/dev/null APPIMAGE= VERILATOR=verilator BUILD=build/ci/chisel/sim JOBS=2
make run CONFIG=/dev/null SIM=build/ci/chisel/sim/sim PROGRAM=tests/rtl/high_address.data EXPECTED=0x40100 LATENCY=20 MAX_CYCLES=100000
```

修改 Scala 后，使用 `make -C dual-issue-chisel generate` 更新 RTL，并一并检查 RTL 和配置差异。遗漏生成文件时，CI 的一致性检查会失败。

## 查看失败日志

快速任务上传 `verilog-reference-checks`、`default-chisel-checks`；原生单元失败时还在控制台打印编译/仿真日志末尾。手动完整任务上传实现名和 run ID 命名的 artifact，包含正确性、性能、工具链、综合日志与官方面积/STA 报告。artifact 保留 14 天；长期测量仍按现有报告归档规范冻结输入和原始证据，CI 不覆盖历史报告。

## 已有验证记录

2026-10-23 的本地检查记录如下：

- Verilog 参考导出检查及原有完整 `make verify-rtl` 通过；未跳过或修改原检查。
- 原生 Chisel 七项模块检查通过；默认课程 RTL 使用 Verilator 5.020 构建通过，高地址用例为 116 周期、结果 `0x40100`。
- 12 项检查器测试通过，包括真实 RTL、配置、版本、入口变化和缺失产物等失败边界；注释、空白和路径字符串变化也会被发现。
- 当前源码重生成一致性通过。本地使用 OpenJDK 17.0.20.1、sbt 1.10.2、Scala 2.13.12、Chisel 6.5.0、firtool 1.62.0；另一次 OpenJDK 21 的初始审查生成也字节一致。
- 在 `/tmp` 的独立源码副本中，仅修改 ADD 的 Scala 计算表达式、保留原 RTL：生成成功，但 RTL 比较失败（exit 1），配置仍一致；恢复源码后重新生成，RTL 和配置均通过（exit 0）。仓库 CPU 源码未变。两次回执分别保存在本地 `build/ci/stale-scala/` 和 `build/ci/restored-scala/`，不混入历史测量。
- actionlint 1.7.7、workflow 全部 shell 块的 `bash -n` 和 `git diff --check` 通过。

随后，提交 `ca7d3fd` 的 [PR 检查](https://github.com/WilsonWang621/CPU/actions/runs/39821647128)和合并到 `main` 后的[检查](https://github.com/WilsonWang621/CPU/actions/runs/39822056645)均已通过，包括固定 JDK/sbt 安装、子模块检出、RTL 重新生成、模块测试、高地址测试和日志上传。高地址用例结果为 `0x40100`，耗时 116 周期。

Docker 完整评测尚未执行，因此还没有这套手动任务的完整回归、性能、综合或 STA 结果。
