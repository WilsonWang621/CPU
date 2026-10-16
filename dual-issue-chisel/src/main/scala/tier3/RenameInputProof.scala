package tier3

import chisel3._
import chisel3.util._
import tier3.Bits._

/** Prove the RAT input factoring for every instruction and all reservation,
  * publication and source-register inputs. Register state and tag data are
  * shared: only the per-row write and forwarding controls can change.
  */
class RenameInputProof extends Logic {
  override def desiredName = "rename_input_proof"
  val instructions = in(64); val reserve = in(2); val publish = in(2)
  val source_register = in(20); val correct = outBool()
  val decoders = (0 until 2).map { lane =>
    val m = Module(new Decoder); m.inst := word(instructions, lane, 32)
    m.dec.asTypeOf(new Decoded)
  }
  val prepared = (0 until 2).map(l => reserve(l) && decoders(l).writes_rd)
  val oldRd = (0 until 2).map(l => Mux(prepared(l), decoders(l).rd, 0.U(5.W)))
  val newRd = decoders.map(_.rd)
  val writes = for (lane <- 0 until 2; row <- 0 until 32) yield {
    val accepted = prepared(lane) && publish(lane)
    val oldWrite = accepted && oldRd(lane) =/= 0.U && oldRd(lane) === row.U(5.W)
    val newWrite = accepted && newRd(lane) =/= 0.U && newRd(lane) === row.U(5.W)
    oldWrite === newWrite
  }
  val forwarding = (0 until 4).map { port =>
    val register = word(source_register, port, 5)
    val oldHit = (port >= 2).B && prepared(0) && oldRd(0) =/= 0.U && oldRd(0) === register
    val newHit = (port >= 2).B && prepared(0) && newRd(0) =/= 0.U && newRd(0) === register
    oldHit === newHit
  }
  correct := (writes ++ forwarding).reduce(_ && _)
}
