package tier2
import chisel3._
import chisel3.util._

/** Each group combines adjacent generate/propagate prefixes locally. */
class CarryPrefix extends LocalLogic {
  val io = IO(new Bundle {
    val gh = Input(Bool()); val ph = Input(Bool()); val gl = Input(Bool()); val pl = Input(Bool())
    val g = Output(Bool()); val p = Output(Bool())
  })
  io.g := io.gh || (io.ph && io.gl); io.p := io.ph && io.pl
}

/** Eight four-bit groups, three prefix levels, bounded local carry paths. */
class Adder32 extends LocalLogic {
  val io = IO(new Bundle {
    val a = Input(UInt(32.W)); val b = Input(UInt(32.W)); val cin = Input(Bool())
    val sum = Output(UInt(32.W))
  })
  val propagate = io.a ^ io.b; val generate = io.a & io.b
  val groupP = (0 until 8).map(k => propagate(4*k+3,4*k).andR)
  val groupG = (0 until 8).map(k => {
    val p = propagate(4*k+3,4*k); val g = generate(4*k+3,4*k)
    g(3) || (p(3) && g(2)) || (p(3) && p(2) && g(1)) || (p(3) && p(2) && p(1) && g(0))
  })
  var prefix = groupG.zip(groupP)
  for(level <- 0 until 3) {
    val distance = 1 << level
    val previous = prefix
    prefix = (0 until 8).map(k => {
      if(k < distance) previous(k)
      else {
        val cell = Module(new CarryPrefix)
        cell.io.gh := previous(k)._1; cell.io.ph := previous(k)._2
        cell.io.gl := previous(k-distance)._1; cell.io.pl := previous(k-distance)._2
        (cell.io.g,cell.io.p)
      }
    })
  }
  val carry = Seq(io.cin) ++ (0 until 7).map(k => prefix(k)._1 || (prefix(k)._2 && io.cin))
  io.sum := Cat((0 until 8).reverse.map(k =>
    (io.a(4*k+3,4*k)+&io.b(4*k+3,4*k)+carry(k).asUInt)(3,0)))
}
