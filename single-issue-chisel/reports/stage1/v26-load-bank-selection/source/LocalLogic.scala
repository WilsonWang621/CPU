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
