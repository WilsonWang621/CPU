package tier2
import chisel3._
import chisel3.util._

/** Local wakeup and bypass for one scheduler operand. */
class OperandEntry(p: Config) extends LocalLogic {
  val io = IO(new Bundle {
    val prepare = Input(Bool()); val initialData = Input(UInt(32.W)); val initialTag = Input(UInt(p.tagBits.W)); val initialReady = Input(Bool())
    val completions = Input(Vec(3,Valid(new Completion(p))))
    val loadReturn = if(p.bankedReturnMatch) Some(Input(new BankedLoadReturn(p))) else None
    val ready = Output(Bool()); val data = Output(UInt(32.W))
  })
  val value = Reg(UInt(32.W)); val tag = Reg(UInt(p.tagBits.W)); val ready = Reg(Bool())
  val matches = (0 until 3).map(k => if(k == 1 && p.bankedReturnMatch)
    BankedLoadReturn.matches(io.loadReturn.get,tag) else io.completions(k).valid && io.completions(k).bits.tag === tag)
  if(p.debug && p.bankedReturnMatch) {
    assert(matches(1) === (io.completions(1).valid && io.completions(1).bits.tag === tag),"Banked operand wakeup differs from selected completion")
  }
  val forwarded = MuxCase(value,(0 until 3).map(k => matches(k) -> io.completions(k).bits.data))
  when(!ready && matches.reduce(_ || _)) { value := forwarded; ready := true.B }
  when(io.prepare) { value := io.initialData; tag := io.initialTag; ready := io.initialReady }
  io.ready := ready || matches.reduce(_ || _)
  io.data := Mux(ready,value,forwarded)
}

/** Dispatch-side bypass is separate from its architectural/ROB word reads. */
class SourceOperand(p: Config) extends LocalLogic {
  val io = IO(new Bundle {
    val used = Input(Bool()); val waiting = Input(Bool()); val completed = Input(Bool())
    val tag = Input(UInt(p.tagBits.W)); val architectural = Input(UInt(32.W)); val producer = Input(UInt(32.W))
    val completions = Input(Vec(3,Valid(new Completion(p))))
    val loadReturn = if(p.bankedReturnMatch) Some(Input(new BankedLoadReturn(p))) else None
    val ready = Output(Bool()); val data = Output(UInt(32.W))
  })
  val matches = (0 until 3).map(k => if(k == 1 && p.bankedReturnMatch)
    BankedLoadReturn.matches(io.loadReturn.get,io.tag) else io.completions(k).valid && io.completions(k).bits.tag === io.tag)
  if(p.debug && p.bankedReturnMatch) {
    assert(matches(1) === (io.completions(1).valid && io.completions(1).bits.tag === io.tag),"Banked dispatch bypass differs from selected completion")
  }
  io.ready := !io.waiting || io.completed || matches.reduce(_ || _)
  val forwarded = MuxCase(io.producer,(0 until 3).map(k => matches(k) -> io.completions(k).bits.data))
  io.data := Mux(io.used,Mux(io.waiting,forwarded,io.architectural),0.U)
}
