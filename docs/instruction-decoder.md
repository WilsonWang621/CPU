# 单指令 RV32IM 译码器

[`InstructionDecoder`](../src/InstructionDecoder.scala) 是 B3 的首个可独立验证模块：输入一条 32 位指令，组合输出 `DecodedInstruction`。它复用现有 `AluOp`、`BranchOp` 编码，支持当前课程 README 要求的 37 条 RV32I 指令与 8 条 M 扩展指令，包含 LB/LBU/LH/LHU。旧项目需求中的窄加载豁免不适用于此实现。

## 接口与使用规则

| 字段 | 含义 |
| --- | --- |
| `rs1, rs2, rd` | 原始指令的寄存器字段；是否有意义由使用标志决定 |
| `usesRs1, usesRs2` | 指令是否读取对应源；读取 x0 时仍为真，由寄存器读取逻辑返回零 |
| `writesRd` | 是否写回架构寄存器；rd=x0 时为假，load/jump 等指令仍须执行其余语义 |
| `immediate` | 已扩展的 32 位立即数；移位立即数为零扩展的 shamt，R 型为零 |
| `fu` | `DecodeFu`：ALU=0、BRANCH=1、MEMORY=2、MDU=3 |
| `aluOp, branchOp` | 现有整数通路的操作编码；只按相应执行单元解释 |
| `mduOp` | funct3 原编码 0–7：MUL、MULH、MULHSU、MULHU、DIV、DIVU、REM、REMU |
| `operandAIsPc, operandBIsImmediate` | ALU 的操作数选择；AUIPC 用 PC，LUI 用 COPY_B，OP-IMM 用立即数 |
| `isStore, accessSize, loadUnsigned` | 访存方向、字节/半字/字编码 0/1/2、窄加载零扩展标志 |
| `decodeError` | 不支持或保留编码，包括 FENCE/FENCE.I、SYSTEM、非 RV32IM 编码 |

`decodeError` 为真时，源寄存器使用标志、写回标志与 store 标志均清零；调用者仍必须用此错误标志阻止发射，其他控制字段不可用于执行。译码器严格检查寄存器运算的 funct7、移位立即数的高位、JALR 的 funct3，以及分支和访存的保留 funct3。

立即数按 I/S/B/U/J 格式拼接并符号扩展；B/J 的最低位为零。分支目标、JAL/JALR 链接地址和实际跳转方向由 `BranchUnit` 计算，地址对齐和 store lane 由 `AddressGenerator` 处理。

这是无状态组合叶模块，输出随输入变化。它不保存 PC、预测信息或 pathId，也没有 valid/ready。后续 Frontend 在寄存的译码包中封装这些信息，并在背压时保持整个包。本地 `DecodedInstruction` 尚不是 A/B 冻结后的 `DecodedPacket`；B3 的双槽输出、握手和重定向验收仍未完成，`StudentTop` 也尚未接入此模块。

## 独立生成与测试

使用仓库固定的 Mill 1.1.2、JDK 21 和 Verilator，在根目录运行：

```sh
bash tests/decoder/run.sh
```

可用 `MILL=/path/to/mill`、`VERILATOR=/path/to/verilator` 指定工具。若默认 Maven 源不可访问，可在运行前设置 `COURSIER_REPOSITORIES=https://repo.maven.apache.org/maven2`。脚本生成 `build/decoder/InstructionDecoder.sv`，编译并执行 C++ 驱动；不会更新课程提交用的 RTL 文件列表。

[`decoder_test.cpp`](../tests/decoder/decoder_test.cpp) 以独立指令表检查 45 条指令的寄存器使用、执行操作、立即数和访存属性，遍历全部 128×8×128 个 opcode/funct3/funct7 组合，另以固定随机种子变化寄存器与立即数字段，包含全零、全一和 x0 边界。共 142,607 个输入向量；测试通过说明译码叶模块符合这些检查，不代表整机通过课程测试。

也可只生成 RTL：

```sh
mill chisel.runMain cpu2026.GenerateDatapath decode build/decoder
```

## 本次验证记录（2026-09-28）

- 已通过：使用本机缓存的 Scala 2.13.12、Chisel/plugin 6.5.0、firtool 1.62.0 直接编译上述叶模块源码并生成 RTL；Verilator 5.020 执行全部 142,607 个向量，输出 `InstructionDecoder: PASS`。
- 待完成：仓库固定版本 Mill 1.1.2 / Scala 2.13.18 / Chisel 7.7.0 下的 `tests/decoder/run.sh`。本次依赖下载在 Maven Central 和镜像源出现连接超时，尚未完成固定版本验证。仓库版本配置保持原值；上述离线结果不能代替该项验收。
- 已通过：`bash -n tests/decoder/run.sh` 和 `git diff --check`。
