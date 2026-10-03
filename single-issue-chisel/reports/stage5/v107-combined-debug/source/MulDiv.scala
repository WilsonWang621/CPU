package tier2
import chisel3._
import chisel3.util._

class Completion(p: Config) extends Bundle { val tag = UInt(p.tagBits.W); val data = UInt(32.W) }
class MulDiv(p: Config) extends Module {
  val io = IO(new Bundle {
    val req = Flipped(Decoupled(new Bundle { val tag = UInt(p.tagBits.W); val a = UInt(32.W); val b = UInt(32.W); val fn = UInt(3.W) }))
    val rsp = Valid(new Completion(p)); val kill = Input(Bool()); val activeTag = Output(UInt(p.tagBits.W))
  })
  val idle :: mulSum :: mulFinish :: divide :: divFinish :: cachedFinish :: Nil = Enum(6)
  val state = RegInit(idle); val tag = Reg(UInt(p.tagBits.W)); val fn = Reg(UInt(3.W))
  io.activeTag := tag
  val low = Reg(UInt(32.W)); val high = Reg(UInt(32.W)); val cross0 = Reg(UInt(32.W)); val cross1 = Reg(UInt(32.W))
  val correction = Reg(UInt(32.W)); val product = Reg(UInt(64.W))
  val quotient = Reg(UInt(32.W)); val divisor = Reg(UInt(32.W)); val rem = Reg(UInt(33.W))
  val qnegative = Reg(Bool()); val rnegative = Reg(Bool()); val count = Reg(UInt(6.W))
  io.req.ready := state === idle
  io.rsp.valid := state === mulFinish || state === divFinish || (if(p.divResultCache) state === cachedFinish else false.B)
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
    var nextRem = rem; var nextQuotient = quotient
    for(_ <- 0 until p.divStepBits) {
      val shifted = Cat(nextRem(31,0),nextQuotient(31))
      val ge = shifted >= Cat(0.U(1.W),divisor)
      nextRem = Mux(ge,shifted-divisor,shifted)
      nextQuotient = Cat(nextQuotient(30,0),ge)
    }
    rem := nextRem; quotient := nextQuotient
    count := count+p.divStepBits.U
    when(count === (32-p.divStepBits).U) { state := divFinish }
  }
  if(p.divResultCache) {
    // Pure arithmetic cache: signedness distinguishes DIV/REM from DIVU/REMU,
    // while quotient and remainder share one completed operand pair.
    val valid = RegInit(false.B); val signed = Reg(Bool())
    val cachedA = Reg(UInt(32.W)); val cachedB = Reg(UInt(32.W))
    val cachedQuotient = Reg(UInt(32.W)); val cachedRemainder = Reg(UInt(32.W))
    val pendingA = Reg(UInt(32.W)); val pendingB = Reg(UInt(32.W)); val pendingSigned = Reg(Bool())
    val cachedResult = Reg(UInt(32.W))
    val hit = valid && signed === !io.req.bits.fn(0) && cachedA === a && cachedB === b
    when(io.req.fire && io.req.bits.fn(2)) {
      pendingA := a; pendingB := b; pendingSigned := !io.req.bits.fn(0)
      when(hit) {
        state := cachedFinish
        cachedResult := Mux(io.req.bits.fn(1),cachedRemainder,cachedQuotient)
      }
    }
    when(state === divFinish && !io.kill) {
      valid := true.B; signed := pendingSigned; cachedA := pendingA; cachedB := pendingB
      cachedQuotient := Mux(qnegative,(~quotient)+1.U,quotient)
      cachedRemainder := Mux(rnegative,(~rem(31,0))+1.U,rem(31,0))
    }
    when(state === cachedFinish) { io.rsp.bits.data := cachedResult }
    when(io.kill) { valid := false.B }
  }
  when(io.rsp.valid) { state := idle }
  when(io.kill) { state := idle }
}
