package tier3

import chisel3._
import chisel3.util._
import tier3.Bits._

class Rename(slotBits: Int = 5, checkpoints: Int = 3, commitTree: Boolean = true) extends ClockedLogic {
  override def desiredName = "v2_rename"
  val cpw = log2Ceil(checkpoints)
  val dispatch_valid = in(2); val prepare_valid = in(2); val dispatch_rd = in(10)
  val dispatch_slot = in(2 * slotBits); val source_register = in(20)
  val source_pending = out(4); val source_slot = out(4 * slotBits)
  val commit_valid = in(2); val commit_rd = in(10); val commit_slot = in(2 * slotBits)
  val save_valid = inBool(); val save_after_lane = inBool(); val save_index = in(cpw)
  val restore_valid = inBool(); val restore_index = in(cpw)
  val pending_q = flags(32); val tag_q = regs(32, slotBits)
  val checkpoint_pending = withClock(clk) { Reg(Vec(checkpoints, Vec(32, Bool()))) }
  val checkpoint_tag = withClock(clk) { Reg(Vec(checkpoints, Vec(32, UInt(slotBits.W)))) }
  val commitBits = 12 + 2 * slotBits; val commitGroups = 4 * (checkpoints + 1)
  val commitControl = Cat(commit_valid, commit_rd, commit_slot)
  val commitControls = if (commitTree) Distribution(commitControl, commitGroups) else Seq.fill(commitGroups)(commitControl)
  val pending_next = Wire(Vec(32, Bool())); val tag_next = Wire(Vec(32, UInt(slotBits.W)))
  val save_pending = Wire(Vec(32, Bool())); val save_tag = Wire(Vec(32, UInt(slotBits.W)))
  for (r <- 0 until 32) {
    // Unroll the two procedural dispatch writes into immutable prefixes.
    val prefixes = (0 until 2).scanLeft((pending_q(r), tag_q(r))) { case ((pending, tag), lane) =>
      val hit = dispatch_valid(lane) && word(dispatch_rd, lane, 5) =/= 0.U && word(dispatch_rd, lane, 5) === r.U
      (Mux(hit, true.B, pending), Mux(hit, word(dispatch_slot, lane, slotBits), tag))
    }
    val p = Mux(restore_valid, checkpoint_pending(restore_index)(r), prefixes(2)._1)
    val t = Mux(restore_valid, checkpoint_tag(restore_index)(r), prefixes(2)._2)
    val sp = Mux(save_after_lane, prefixes(2)._1, prefixes(1)._1)
    val st = Mux(save_after_lane, prefixes(2)._2, prefixes(1)._2)
    val cc = commitControls(r / 8)
    def retired(tag: UInt): Bool = (0 until 2).map(c =>
      cc(2 * slotBits + 10 + c) && word(cc >> (2 * slotBits), c, 5) === r.U(5.W) &&
        tag === word(cc, c, slotBits)).reduce(_ || _)
    pending_next(r) := (if (r == 0) false.B else p && !retired(t))
    tag_next(r) := t
    save_pending(r) := (if (r == 0) false.B else sp && !retired(st))
    save_tag(r) := st
    when(rst) { pending_q(r) := false.B }.otherwise { pending_q(r) := pending_next(r) }
    tag_q(r) := tag_next(r)
  }
  val lookup = (0 until 4).map { port =>
    val registerId = word(source_register, port, 5)
    val bypass = (port >= 2).B && prepare_valid(0) && dispatch_rd(4, 0) =/= 0.U && dispatch_rd(4, 0) === registerId
    val mapping = Read((0 until 32).map(r => Cat(pending_q(r), tag_q(r))), registerId)
    (bypass || mapping(slotBits), Mux(bypass, dispatch_slot(slotBits - 1, 0), mapping(slotBits - 1, 0)))
  }
  source_pending := VecInit(lookup.map(_._1)).asUInt; source_slot := pack(lookup.map(_._2))
  for (cp <- 0 until checkpoints) {
    val savePulse = save_valid && save_index === cp.U(cpw.W) && !restore_valid
    val saves = if (commitTree) Distribution(savePulse.asUInt, 32).map(_.asBool) else Seq.fill(32)(savePulse)
    for (r <- 0 until 32) {
      val cc = commitControls((cp + 1) * 4 + r / 8)
      when(rst) { checkpoint_pending(cp)(r) := false.B }.otherwise {
        for (c <- 0 until 2) {
          when(cc(2 * slotBits + 10 + c) && word(cc >> (2 * slotBits), c, 5) === r.U(5.W) &&
            checkpoint_tag(cp)(r) === word(cc, c, slotBits)) { checkpoint_pending(cp)(r) := false.B }
        }
        when(saves(r)) {
          checkpoint_pending(cp)(r) := save_pending(r); checkpoint_tag(cp)(r) := save_tag(r)
        }
      }
    }
  }
}
