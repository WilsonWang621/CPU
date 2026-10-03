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
  val matchReady = if(p.separateOperandReady) CompletionReady(p,tag,io.completions,io.loadReturn) else matches.reduce(_ || _)
  if(p.debug && p.separateOperandReady) { assert(matchReady === matches.reduce(_ || _),"Independent operand readiness differs from data match") }
  io.ready := ready || matchReady
  io.data := Mux(ready,value,forwarded)
}

/** Dispatch-side bypass is separate from its architectural/ROB word reads. */
class SourceOperand(p: Config, prepareAddress: Boolean = false) extends LocalLogic {
  val io = IO(new Bundle {
    val used = Input(Bool()); val waiting = Input(Bool()); val completed = Input(Bool())
    val tag = Input(UInt(p.tagBits.W)); val architectural = Input(UInt(32.W)); val producer = Input(UInt(32.W))
    val completions = Input(Vec(3,Valid(new Completion(p))))
    val loadReturn = if(p.bankedReturnMatch) Some(Input(new BankedLoadReturn(p))) else None
    val immediate = if(prepareAddress) Some(Input(UInt(32.W))) else None
    val address = if(prepareAddress) Some(Output(UInt(32.W))) else None
    val ready = Output(Bool()); val data = Output(UInt(32.W))
  })
  val matches = (0 until 3).map(k => if(k == 1 && p.bankedReturnMatch)
    BankedLoadReturn.matches(io.loadReturn.get,io.tag) else io.completions(k).valid && io.completions(k).bits.tag === io.tag)
  if(p.debug && p.bankedReturnMatch) {
    assert(matches(1) === (io.completions(1).valid && io.completions(1).bits.tag === io.tag),"Banked dispatch bypass differs from selected completion")
  }
  val matchReady = if(p.separateOperandReady) CompletionReady(p,io.tag,io.completions,io.loadReturn) else matches.reduce(_ || _)
  if(p.debug && p.separateOperandReady) { assert(matchReady === matches.reduce(_ || _),"Independent dispatch readiness differs from data match") }
  io.ready := !io.waiting || io.completed || matchReady
  val forwarded = MuxCase(io.producer,(0 until 3).map(k => matches(k) -> io.completions(k).bits.data))
  io.data := Mux(io.used,Mux(io.waiting,forwarded,io.architectural),0.U)
  io.address.foreach { address =>
    // Preserve this CPU's first-matching completion priority. Arithmetic for
    // the stored base and all bypass candidates precedes late tag/valid muxes.
    val base = Mux(io.used,Mux(io.waiting,io.producer,io.architectural),0.U)
    val baseSum = Util.add(base,io.immediate.get)
    val sums = io.completions.map(c => Util.add(c.bits.data,io.immediate.get))
    address := MuxCase(baseSum,(0 until 3).map(k => (io.used && io.waiting && matches(k)) -> sums(k)))
  }
}
/** Readiness has its own small match cone, independent of wide data writes. */
class CompletionReady(p: Config) extends LocalLogic {
  val io = IO(new Bundle {
    val tag = Input(UInt(p.tagBits.W)); val valid = Input(UInt(3.W))
    val tags = Input(Vec(3,UInt(p.tagBits.W)))
    val loadReturn = if(p.bankedReturnMatch) Some(Input(new BankedLoadReturn(p))) else None
    val ready = Output(Bool())
  })
  io.ready := (0 until 3).map(k => if(k == 1 && p.bankedReturnMatch)
    BankedLoadReturn.matches(io.loadReturn.get,io.tag) else io.valid(k) && io.tags(k) === io.tag).reduce(_ || _)
}
object CompletionReady {
  def apply(p: Config, tag: UInt, completions: Vec[Valid[Completion]], loadReturn: Option[BankedLoadReturn]): Bool = {
    val ready = Module(new CompletionReady(p))
    ready.io.tag := tag; ready.io.valid := VecInit(completions.map(_.valid)).asUInt
    ready.io.tags := VecInit(completions.map(_.bits.tag))
    ready.io.loadReturn.foreach(_ := loadReturn.get)
    ready.io.ready
  }
}
