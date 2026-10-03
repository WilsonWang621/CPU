package tier2
import chisel3._
import chisel3.util._

/** In-order dispatch makes a newly prepared slot younger than all occupied
  * slots. One bit per pair records that relation until either slot is reused.
  * Adapted from Galuisss/ACM-CPU v2_age_matrix at 43e5a967828d80f73a1e1918054fbab36fc5775b.
  */
class IssueAge(entries: Int) extends LocalLogic {
  val io = IO(new Bundle {
    val prepare = Input(UInt(entries.W))
    val older = Output(Vec(entries,UInt(entries.W)))
  })
  val pairs = (for(i <- 0 until entries; j <- i+1 until entries) yield {
    val firstOlder = RegInit(false.B)
    when(io.prepare(i)) { firstOlder := false.B }
      .elsewhen(io.prepare(j)) { firstOlder := true.B }
    (i,j) -> firstOlder
  }).toMap
  for(i <- 0 until entries) {
    io.older(i) := VecInit((0 until entries).map(j =>
      if(i == j) false.B else if(j < i) pairs((j,i)) else !pairs((i,j)))).asUInt
  }
}
