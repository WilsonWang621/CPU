package tier2
import chisel3._
import chisel3.util._

/** Bound late readiness fanout to one payload slice. Age masks arrive from
  * registered scheduler tags; their comparison is independent of wakeup.
  */
class IssueChoice(width: Int, entries: Int) extends LocalLogic {
  val io = IO(new Bundle {
    val eligible = Input(UInt(entries.W)); val older = Input(Vec(entries,UInt(entries.W)))
    val words = Input(Vec(entries,UInt(width.W))); val fallback = Input(UInt(width.W))
    val value = Output(UInt(width.W))
  })
  val picked = (0 until entries).map(i => io.eligible(i) && !(io.older(i) & io.eligible).orR)
  io.value := Mux1H(picked,io.words.toSeq) | (io.fallback & Fill(width,!io.eligible.orR))
}
