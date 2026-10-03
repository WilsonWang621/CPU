package tier2
import chisel3._
import chisel3.util._

/** Prove parallel sums against the actual dispatch operand plus immediate,
  * including unused operands, architectural/ROB sources and overlapping CDBs.
  */
class DispatchAddressProof extends Module {
  val p = Config()
  val used = IO(Input(Bool())); val waiting = IO(Input(Bool())); val completed = IO(Input(Bool()))
  val tag = IO(Input(UInt(p.tagBits.W)))
  val architectural = IO(Input(UInt(32.W))); val producer = IO(Input(UInt(32.W))); val immediate = IO(Input(UInt(32.W)))
  val completions = IO(Input(Vec(3,Valid(new Completion(p)))))
  val correct = IO(Output(Bool()))
  val operand = Module(new SourceOperand(p,prepareAddress=true))
  operand.io.used := used; operand.io.waiting := waiting; operand.io.completed := completed; operand.io.tag := tag
  operand.io.architectural := architectural; operand.io.producer := producer; operand.io.immediate.get := immediate
  operand.io.completions := completions
  correct := operand.io.address.get === (operand.io.data + immediate)
}
object GenerateDispatchAddressProof extends App {
  _root_.circt.stage.ChiselStage.emitSystemVerilogFile(new DispatchAddressProof,
    Array("--target-dir",args(0)),Array("--disable-all-randomization"))
}
