package tier2
import chisel3._
import chisel3.util._

/** Local wakeup and bypass for one scheduler operand. */
class OperandEntry(p: Config) extends LocalLogic {
  val io = IO(new Bundle {
    val prepare = Input(Bool()); val initialData = Input(UInt(32.W)); val initialTag = Input(UInt(p.tagBits.W)); val initialReady = Input(Bool())
    val completions = Input(Vec(3,Valid(new Completion(p))))
    val ready = Output(Bool()); val data = Output(UInt(32.W))
  })
  val value = Reg(UInt(32.W)); val tag = Reg(UInt(p.tagBits.W)); val ready = Reg(Bool())
  val matches = io.completions.map(c => c.valid && c.bits.tag === tag)
  val forwarded = MuxCase(value,(0 until 3).map(k => matches(k) -> io.completions(k).bits.data))
  when(!ready && matches.reduce(_ || _)) { value := forwarded; ready := true.B }
  when(io.prepare) { value := io.initialData; tag := io.initialTag; ready := io.initialReady }
  io.ready := ready || matches.reduce(_ || _)
  io.data := Mux(ready,value,forwarded)
}
