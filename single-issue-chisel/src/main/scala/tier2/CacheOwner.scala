package tier2
import chisel3._
import chisel3.util._

/** A blocking bank has one response owner, even with a pipelined refill.
  * Squash records dead ownership before a ROB tag can be reused. Dead owners
  * still drain memory, but cannot broadcast into the new instruction stream.
  */
class CacheOwner(p: Config) extends LocalLogic {
  val io = IO(new Bundle {
    val offer = Flipped(Valid(new LoadInfo(p))); val consume = Input(Bool())
    val squash = Input(Bool()); val boundary = Input(UInt(p.tagBits.W)); val wrapped = Input(UInt(p.rob.W))
    val squashMask = Input(UInt(p.rob.W))
    val valid = Output(Bool()); val dead = Output(Bool()); val info = Output(new LoadInfo(p))
  })
  val valid = RegInit(false.B); val dead = RegInit(false.B); val info = Reg(new LoadInfo(p))
  val younger = if(p.registeredSquashMask) io.squashMask(info.tag) else Mux(io.wrapped(info.tag) === io.wrapped(io.boundary),info.tag > io.boundary,io.wrapped(info.tag))
  when(io.squash && valid && !info.prefetch && (if(p.earlyRecovery) younger else true.B)) { dead := true.B }
  when(io.consume) { valid := false.B }
  when(io.offer.valid) {
    assert(!valid || io.consume,"Replacing a pending cache response owner")
    valid := true.B; dead := false.B; info := io.offer.bits
  }
  io.valid := valid; io.dead := dead; io.info := info
}
