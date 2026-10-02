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
class LocalMask(width: Int) extends LocalLogic {
  val io = IO(new Bundle {
    val selected = Input(Bool()); val word = Input(UInt(width.W)); val value = Output(UInt(width.W))
  })
  io.value := io.word & Fill(width,io.selected)
}
class LocalWord(width: Int) extends LocalLogic {
  val io = IO(new Bundle {
    val prepare = Input(Bool()); val data = Input(UInt(width.W)); val value = Output(UInt(width.W))
  })
  val value = Reg(UInt(width.W))
  when(io.prepare) { value := io.data }
  io.value := value
}
/** Prepare address alongside operands, before the load lookup stage. */
class LocalAddress extends LocalLogic {
  val io = IO(new Bundle {
    val prepare = Input(Bool()); val base = Input(UInt(32.W)); val immediate = Input(UInt(32.W))
    val value = Output(UInt(32.W))
  })
  val value = Reg(UInt(32.W))
  val address = Util.add(io.base,io.immediate)
  when(io.prepare) { value := address }
  io.value := value
}
class LocalCounter(width: Int) extends LocalLogic {
  val io = IO(new Bundle { val step = Input(Bool()); val clear = Input(Bool()); val value = Output(UInt(width.W)) })
  val value = RegInit(0.U(width.W))
  when(io.step) { value := value+1.U }
  when(io.clear) { value := 0.U }
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
class LocalResultWord(tagBits: Int, index: Int) extends LocalLogic {
  val io = IO(new Bundle {
    val valid = Input(UInt(3.W)); val tags = Input(Vec(3,UInt(tagBits.W))); val data = Input(Vec(3,UInt(32.W)))
    val completed = Output(Bool()); val value = Output(UInt(32.W))
  })
  val value = Reg(UInt(32.W))
  val matches = (0 until 3).map(k => io.valid(k) && io.tags(k) === index.U)
  for(k <- 0 until 3) { when(matches(k)) { value := io.data(k) } }
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
