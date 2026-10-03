package tier2
import chisel3._
import chisel3.util._

/** Bound late readiness fanout to one payload slice. Age masks arrive from
  * registered scheduler tags; their comparison is independent of wakeup.
  */
class IssueChoice(width: Int, entries: Int, localEligibility: Boolean = false) extends LocalLogic {
  val io = IO(new Bundle {
    val eligible = Input(UInt(entries.W)); val older = Input(Vec(entries,UInt(entries.W)))
    val allowed = if(localEligibility) Some(Input(UInt(entries.W))) else None
    val readyA = if(localEligibility) Some(Input(UInt(entries.W))) else None
    val readyB = if(localEligibility) Some(Input(UInt(entries.W))) else None
    val words = Input(Vec(entries,UInt(width.W))); val fallback = Input(UInt(width.W))
    val value = Output(UInt(width.W))
  })
  // Recompute this small gate inside each preserved payload slice. The root
  // scheduler uses the same predicate, but its late eligible net no longer
  // drives every older-mask reduction in all payload choices.
  val eligible = if(localEligibility) io.allowed.get & io.readyA.get & io.readyB.get else io.eligible
  val picked = (0 until entries).map(i => eligible(i) && !(io.older(i) & eligible).orR)
  io.value := Mux1H(picked,io.words.toSeq) | (io.fallback & Fill(width,!eligible.orR))
}
