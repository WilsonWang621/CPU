package tier2
import chisel3._
import chisel3.util.Fill
import chisel3.experimental.{annotate,ChiselAnnotation}

/** Preserve local decode/feedback boundaries through the ordinary course flow.
  * These are mapped, counted Chisel logic, with no timing or area exclusions.
  */
abstract class LocalLogic extends Module {
  private val owner = this
  annotate(new ChiselAnnotation {
    override def toFirrtl: firrtl.annotations.Annotation =
      firrtl.AttributeAnnotation(owner.toTarget,"keep_hierarchy = 1")
  })
}
class LocalMask(width: Int) extends Module {
  val io = IO(new Bundle {
    val selected = Input(Bool()); val word = Input(UInt(width.W)); val value = Output(UInt(width.W))
  })
  io.value := io.word & Fill(width,io.selected)
}
class LocalWord(width: Int) extends Module {
  val io = IO(new Bundle {
    val prepare = Input(Bool()); val data = Input(UInt(width.W)); val value = Output(UInt(width.W))
  })
  val value = Reg(UInt(width.W))
  when(io.prepare) { value := io.data }
  io.value := value
}
/** Prepare address alongside operands, before the load lookup stage. */
class LocalAddress(directBypass: Boolean = false, debug: Boolean = false) extends LocalLogic {
  val io = IO(new Bundle {
    val prepare = Input(Bool()); val base = Input(UInt(32.W)); val immediate = Input(UInt(32.W))
    val direct = if(directBypass) Some(Input(chisel3.util.Valid(UInt(32.W)))) else None
    val value = Output(UInt(32.W))
  })
  val value = Reg(UInt(32.W))
  val address = Util.add(io.base,io.immediate)
  val prepared = if(directBypass) chisel3.util.MuxCase(address,Seq(io.direct.get.valid -> io.direct.get.bits)) else address
  when(io.prepare) { value := prepared }
  if(debug && directBypass) {
    when(io.prepare && io.direct.get.valid) { assert(io.direct.get.bits === address,"Parallel dispatch address differs from selected base plus immediate") }
  }
  io.value := value
}
class LocalCounter(width: Int) extends LocalLogic {
  val io = IO(new Bundle { val step = Input(Bool()); val clear = Input(Bool()); val value = Output(UInt(width.W)) })
  val value = RegInit(0.U(width.W))
  when(io.step) { value := value+1.U }
  when(io.clear) { value := 0.U }
  io.value := value
}
/** A local ring pointer keeps a queue's read select near one payload slice. */
class LocalQueueHead(entries: Int) extends LocalLogic {
  require(entries >= 2)
  val io = IO(new Bundle { val step = Input(Bool()); val value = Output(UInt(entries.W)) })
  val value = RegInit(1.U(entries.W))
  when(io.step) { value := chisel3.util.Cat(value(entries-2,0),value(entries-1)) }
  io.value := value
}
class LocalIndexedWord(width: Int, indexBits: Int, index: Int) extends LocalLogic {
  val io = IO(new Bundle {
    val write = Input(Bool()); val index = Input(UInt(indexBits.W)); val data = Input(UInt(width.W)); val value = Output(UInt(width.W))
  })
  val value = Reg(UInt(width.W))
  when(io.write && io.index === index.U) { value := io.data }
  io.value := value
}
class LocalResultWord(p: Config, index: Int) extends LocalLogic {
  val io = IO(new Bundle {
    val valid = Input(UInt(3.W)); val tags = Input(Vec(3,UInt(p.tagBits.W))); val data = Input(Vec(3,UInt(32.W)))
    val loadReturn = if(p.bankedReturnMatch) Some(Input(new BankedLoadReturn(p))) else None
    val finalized = if(p.preparedLoadResult) Some(Input(Bool())) else None
    val completed = Output(Bool()); val value = Output(UInt(32.W))
  })
  if(p.resultSliceBits < 32) {
    val slices = (0 until 32 by p.resultSliceBits).map { low =>
      val slice = Module(new LocalResultSlice(p,index,p.resultSliceBits))
      slice.io.valid := io.valid; slice.io.tags := io.tags
      slice.io.data := VecInit(io.data.map(_(low+p.resultSliceBits-1,low)))
      slice.io.loadReturn.foreach(_ := io.loadReturn.get)
      slice.io.finalized.foreach(_ := io.finalized.get)
      slice
    }
    io.value := chisel3.util.Cat(slices.reverse.map(_.io.value))
    io.completed := slices.head.io.completed
  } else {
  val value = Reg(UInt(32.W))
  val matches = (0 until 3).map(k => io.valid(k) && (if(k == 1 && p.bankedReturnMatch)
    BankedLoadReturn.matches(io.loadReturn.get,index.U) else io.tags(k) === index.U))
  if(p.preparedLoadResult) {
    // An unfinished load may prepare its payload before hit/arbitration is
    // known. The actual response writes the final word at the completion
    // edge; completed words then freeze. Dead owners cannot prepare a reused
    // ROB tag, and actual execution/MDU completions have priority.
    val pending = BankedLoadReturn.pendingMatches(io.loadReturn.get,index.U) && !io.finalized.get
    when(pending) { value := io.data(1) }
    when(matches(0)) { value := io.data(0) }
    when(matches(2)) { value := io.data(2) }
    if(p.debug) {
      when(matches(1)) { assert(pending,"Selected load lacks an unfinished pending result owner") }
      assert(chisel3.util.PopCount(VecInit(matches)) <= 1.U,"Multiple producers completed one ROB result")
    }
  } else {
    for(k <- 0 until 3) { when(matches(k)) { value := io.data(k) } }
  }
  io.completed := matches.reduce(_ || _); io.value := value
  }
}
/** A completion match drives only a bounded group of result bits. */
class LocalResultSlice(p: Config, index: Int, width: Int) extends LocalLogic {
  val io = IO(new Bundle {
    val valid = Input(UInt(3.W)); val tags = Input(Vec(3,UInt(p.tagBits.W))); val data = Input(Vec(3,UInt(width.W)))
    val loadReturn = if(p.bankedReturnMatch) Some(Input(new BankedLoadReturn(p))) else None
    val finalized = if(p.preparedLoadResult) Some(Input(Bool())) else None
    val completed = Output(Bool()); val value = Output(UInt(width.W))
  })
  val value = Reg(UInt(width.W))
  val matches = (0 until 3).map(k => io.valid(k) && (if(k == 1 && p.bankedReturnMatch)
    BankedLoadReturn.matches(io.loadReturn.get,index.U) else io.tags(k) === index.U))
  if(p.preparedLoadResult) {
    val pending = BankedLoadReturn.pendingMatches(io.loadReturn.get,index.U) && !io.finalized.get
    when(pending) { value := io.data(1) }
    when(matches(0)) { value := io.data(0) }
    when(matches(2)) { value := io.data(2) }
    if(p.debug) {
      when(matches(1)) { assert(pending,"Selected load lacks an unfinished pending result owner") }
      assert(chisel3.util.PopCount(VecInit(matches)) <= 1.U,"Multiple producers completed one ROB result")
    }
  } else {
    for(k <- 0 until 3) { when(matches(k)) { value := io.data(k) } }
  }
  io.completed := matches.reduce(_ || _); io.value := value
}
class LocalArchWord(index: Int) extends LocalLogic {
  val io = IO(new Bundle {
    val commit = Input(Bool()); val rd = Input(UInt(5.W)); val data = Input(UInt(32.W)); val value = Output(UInt(32.W))
  })
  val value = RegInit(0.U(32.W))
  when(io.commit && io.rd === index.U) { value := io.data }
  io.value := value
}
/** Keep byte alignment/sign extension local to a group of CDB consumers. */
class LocalLoadValue extends LocalLogic {
  val io = IO(new Bundle {
    val word = Input(UInt(32.W)); val offset = Input(UInt(2.W)); val fn = Input(UInt(3.W))
    val value = Output(UInt(32.W))
  })
  val shifted = io.word >> chisel3.util.Cat(io.offset,0.U(3.W))
  io.value := chisel3.util.MuxLookup(io.fn,shifted)(Seq(
    0.U -> Util.sext(shifted(7,0)),1.U -> Util.sext(shifted(15,0)),
    4.U -> chisel3.util.Cat(0.U(24.W),shifted(7,0)),5.U -> chisel3.util.Cat(0.U(16.W),shifted(15,0))))
}
