package tier2
import chisel3._

/** Flat unit interface for an independent RV32IM arithmetic/protocol oracle. */
class MulDivHarness(p: Config) extends Module {
  val req_valid = IO(Input(Bool())); val req_ready = IO(Output(Bool()))
  val req_tag = IO(Input(UInt(p.tagBits.W))); val req_a = IO(Input(UInt(32.W))); val req_b = IO(Input(UInt(32.W))); val req_fn = IO(Input(UInt(3.W)))
  val rsp_valid = IO(Output(Bool())); val rsp_tag = IO(Output(UInt(p.tagBits.W))); val rsp_data = IO(Output(UInt(32.W)))
  val kill = IO(Input(Bool())); val active_tag = IO(Output(UInt(p.tagBits.W)))
  val unit = Module(new MulDiv(p))
  unit.io.req.valid := req_valid; req_ready := unit.io.req.ready
  unit.io.req.bits.tag := req_tag; unit.io.req.bits.a := req_a; unit.io.req.bits.b := req_b; unit.io.req.bits.fn := req_fn
  rsp_valid := unit.io.rsp.valid; rsp_tag := unit.io.rsp.bits.tag; rsp_data := unit.io.rsp.bits.data
  unit.io.kill := kill; active_tag := unit.io.activeTag
}
object GenerateMulDivHarness extends App {
  val p = Config(divStepBits=args(1).toInt,divResultCache=args(2).toInt != 0)
  _root_.circt.stage.ChiselStage.emitSystemVerilogFile(new MulDivHarness(p),
    Array("--target-dir",args(0)),Array("--disable-all-randomization"))
}
