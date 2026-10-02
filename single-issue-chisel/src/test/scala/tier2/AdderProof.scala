package tier2
import chisel3._

class AdderProof extends Module {
  val a = IO(Input(UInt(32.W))); val b = IO(Input(UInt(32.W))); val cin = IO(Input(Bool()))
  val correct = IO(Output(Bool()))
  val adder = Module(new Adder32)
  adder.io.a := a; adder.io.b := b; adder.io.cin := cin
  correct := adder.io.sum === (a+b+cin.asUInt)
}
object ProveAdder extends App {
  _root_.circt.stage.ChiselStage.emitSystemVerilogFile(new AdderProof,
    Array("--target-dir",args(0)),Array("--disable-all-randomization"))
}
