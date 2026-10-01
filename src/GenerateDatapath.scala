package cpu2026

import circt.stage.ChiselStage

/** Generate focused leaf RTL used by tests/decoder and tests/rtl. */
object GenerateDatapath {
  def main(args: Array[String]): Unit = {
    require(args.length == 2,
      "Usage: GenerateDatapath <alu|branch|agu|decode> <output-dir>")
    val stageArgs = Array("--target-dir", args(1))
    args(0) match {
      case "alu" => ChiselStage.emitSystemVerilogFile(new IntegerAlu, stageArgs)
      case "branch" => ChiselStage.emitSystemVerilogFile(new BranchUnit, stageArgs)
      case "agu" => ChiselStage.emitSystemVerilogFile(new AddressGenerator, stageArgs)
      case "decode" => ChiselStage.emitSystemVerilogFile(new InstructionDecoder, stageArgs)
      case other => throw new IllegalArgumentException(s"Unknown module: $other")
    }
  }
}
