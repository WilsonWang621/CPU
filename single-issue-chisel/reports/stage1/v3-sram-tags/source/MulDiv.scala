package tier2
import chisel3._
import chisel3.util._

class Completion(p: Config) extends Bundle { val tag = UInt(p.tagBits.W); val data = UInt(32.W) }
class MulDiv(p: Config) extends Module {
  val io = IO(new Bundle {
    val req = Flipped(Decoupled(new Bundle { val tag = UInt(p.tagBits.W); val a = UInt(32.W); val b = UInt(32.W); val fn = UInt(3.W) }))
    val rsp = Valid(new Completion(p)); val kill = Input(Bool())
  })
  val idle :: mulSum :: mulFinish :: divide :: divFinish :: Nil = Enum(5)
  val state = RegInit(idle); val tag = Reg(UInt(p.tagBits.W)); val fn = Reg(UInt(3.W))
  val low = Reg(UInt(32.W)); val high = Reg(UInt(32.W)); val cross0 = Reg(UInt(32.W)); val cross1 = Reg(UInt(32.W))
  val correction = Reg(UInt(32.W)); val product = Reg(UInt(64.W))
  val quotient = Reg(UInt(32.W)); val divisor = Reg(UInt(32.W)); val rem = Reg(UInt(33.W))
  val qnegative = Reg(Bool()); val rnegative = Reg(Bool()); val count = Reg(UInt(6.W))
  io.req.ready := state === idle
  io.rsp.valid := state === mulFinish || state === divFinish
  io.rsp.bits.tag := tag
  io.rsp.bits.data := Mux(state === mulFinish,Mux(fn === 0.U,product(31,0),product(63,32)-correction),
    Mux(fn(1),Mux(rnegative,(~rem(31,0))+1.U,rem(31,0)),Mux(qnegative,(~quotient)+1.U,quotient)))
  val a = io.req.bits.a; val b = io.req.bits.b
  when(io.req.fire) {
    tag := io.req.bits.tag; fn := io.req.bits.fn
    when(!io.req.bits.fn(2)) {
      state := mulSum
      low := a(15,0)*b(15,0); high := a(31,16)*b(31,16)
      cross0 := a(31,16)*b(15,0); cross1 := a(15,0)*b(31,16)
      correction := Mux(a(31) && (io.req.bits.fn === 1.U || io.req.bits.fn === 2.U),b,0.U) +
        Mux(b(31) && io.req.bits.fn === 1.U,a,0.U)
    }.otherwise {
      state := divide
      val signed = !io.req.bits.fn(0); val an = signed && a(31); val bn = signed && b(31)
      quotient := Mux(an,(~a)+1.U,a); divisor := Mux(bn,(~b)+1.U,b)
      rem := 0.U; count := 0.U; qnegative := (an ^ bn) && b.orR; rnegative := an
    }
  }
  when(state === mulSum) {
    product := Cat(high,low) + (Cat(0.U(1.W),cross0) +& cross1 << 16)
    state := mulFinish
  }
  when(state === divide) {
    val shifted = Cat(rem(31,0),quotient(31))
    val ge = shifted >= Cat(0.U(1.W),divisor)
    rem := Mux(ge,shifted-divisor,shifted)
    quotient := Cat(quotient(30,0),ge)
    count := count+1.U
    when(count === 31.U) { state := divFinish }
  }
  when(io.rsp.valid) { state := idle }
  when(io.kill) { state := idle }
}
