# GitHub Actions：实现范围与验证方法

[返回首页](../README.md) · [文档索引](README.md) · [workflow](../.github/workflows/validate-rtl.yml)

## 审查时已有的检查

原 `Validate RTL` 在 PR、`main` push 和手动触发时执行以下检查：

| 原检查 | 实际覆盖 | 原边界 |
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

手动入口为 Actions → **Validate RTL** → **Run workflow**，选择实现 `dual-issue-chisel`（默认）、`single-issue-chisel` 或 `verilog-reference`。完整任务复用现有 [Dockerfile](../Dockerfile) 构建课程工具链，不引入另一套综合流程；随后调用现有 `make build/test/perf/synth`，通过 filelist 选择实现。默认选择仍是根 `verilog/filelist.f`，单发射的测试上限为 30,000,000 周期，另外两套为 20,000,000。

完整任务综合参数沿用课程 Makefile：2.0 ns、`INVx1_ASAP7_75t_R` 驱动和 5 fF ABC 负载。Dockerfile 已固定 Yosys、OpenSTA、CUDD 和 ASAP7 的源码提交；构建日志同时保存工具身份与库哈希。流程完成不等于自动满足某个分数档，Fmax、面积、IPC 与测量边界须阅读该次报告，不能用目标周期代替时序结果。

## 默认 Chisel 生成一致性

[check_generated_rtl.py](../.github/scripts/check_generated_rtl.py) 使用现有 `tier3.Generate`，执行等价于在 `dual-issue-chisel/` 下运行的 `sbt -batch 'run --out <临时目录>/rtl'`，不覆盖已提交 RTL。

CI 固定 Temurin **17.0.12+7**、sbt runner / engine **1.10.2**、Scala **2.13.12**、Chisel **6.5.0**。sbt / Scala / Chisel 的 pin 会与 `project/build.properties` 和 `build.sbt` 核对，不匹配时明确失败。Chisel 6.5.0 自带解析的 firtool 版本为 **1.62.0**，见[官方版本对应表](https://www.chisel-lang.org/chisel3/docs/appendix/versioning.html)；检查器清除子进程中的宿主 `CHISEL_FIRTOOL_PATH` 覆盖，让 Chisel 解析其匹配版本，并检查新 RTL 的 firtool 版本头。

检查范围：

1. 复用课程 `scripts/build.py` 的 `read_sources`，解析根 `verilog/filelist.f` 和 `dual-issue-chisel/rtl/filelist.f`。二者必须指向相同、位于默认 Chisel 交付目录内的 RTL。
2. 在新临时目录生成，逐字节比较课程 filelist 选中的全部 RTL，以及记录默认配置的 `elaboration.json`。`filelist.f` 不是该生成器输出，检查的是它实际选择的源文件。
3. 发现差异时失败，控制台显示前 100 行 unified diff，artifact 保留完整 diff、不同的重生成文件、生成日志及含双方 SHA-256 的 `result.json`。生成器失败、产物缺失、版本错误或 filelist 改道也会失败。

本地检查了临时输出目录及不同路径的全新源码副本：匹配源码时 `student_top.sv` 和 `elaboration.json` 均字节一致。当前没有需要清洗的路径非确定性，**没有过滤注释、空白、源码行号或断言字符串**。现有 `verify_default_identity.py` 是针对历史 v13 的 token 等价检查；本检查核对当前源码与交付文件，职责不同，不改写那个历史验证脚本。

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

若 Scala 的有效改动尚未同步，检查应失败。需要更新交付时，仍使用 `make -C dual-issue-chisel generate` 并审阅 RTL 和配置差异；不要为了通过 CI 清洗或忽略真实变化。

## 失败诊断与证据

快速任务上传 `verilog-reference-checks`、`default-chisel-checks`；原生单元失败时还在控制台打印编译/仿真日志末尾。手动完整任务上传实现名和 run ID 命名的 artifact，包含正确性、性能、工具链、综合日志与官方面积/STA 报告。artifact 保留 14 天；长期测量仍按现有报告归档规范冻结输入和原始证据，CI 不覆盖历史报告。

## 本次本地验证及 runner 边界

2026-10-23 在本地实际执行：

- Verilog 参考导出检查及原有完整 `make verify-rtl` 通过；未跳过或修改原检查。
- 原生 Chisel 七项模块检查通过；默认课程 RTL 使用 Verilator 5.020 构建通过，高地址用例为 116 周期、结果 `0x40100`。
- 12 项检查器测试通过，包括真实 RTL、配置、版本、入口变化和缺失产物等失败边界；注释、空白和路径字符串变化也会被发现。
- 当前源码重生成一致性通过。本地使用 OpenJDK 17.0.20.1、sbt 1.10.2、Scala 2.13.12、Chisel 6.5.0、firtool 1.62.0；另一次 OpenJDK 21 的初始审查生成也字节一致。
- 在 `/tmp` 的独立源码副本中，仅修改 ADD 的 Scala 计算表达式、保留原 RTL：生成成功，但 RTL 比较失败（exit 1），配置仍一致；恢复源码后重新生成，RTL 和配置均通过（exit 0）。仓库 CPU 源码未变。两次回执分别保存在本地 `build/ci/stale-scala/` 和 `build/ci/restored-scala/`，不混入历史测量。
- actionlint 1.7.7、workflow 全部 shell 块的 `bash -n` 和 `git diff --check` 通过。

尚需 GitHub runner 验证：全新 runner 上的固定 Temurin patch、Actions 安装与缓存、公开子模块检出、artifact 上传，以及 Docker 完整工具链构建和手动全量运行。本机没有 Docker，本次没有重新运行完整官方回归、性能或综合，以上本地通过项不代表手动流程已在 GitHub 成功。本分支改动只做本地验证，未触发远程 workflow。
