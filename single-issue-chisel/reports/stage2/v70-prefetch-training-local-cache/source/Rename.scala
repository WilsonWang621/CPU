package tier2
import chisel3._
import chisel3.util._

/** One architectural register's current mapping and branch snapshots.
  * Local decode bounds the shared commit/recovery controls' fanout.
  */
class RenameEntry(p: Config, index: Int) extends LocalLogic {
  val io = IO(new Bundle {
    val dispatch = Input(Bool()); val dispatchWrites = Input(Bool()); val dispatchRd = Input(UInt(5.W)); val dispatchTag = Input(UInt(p.tagBits.W))
    val retire = Input(Bool()); val retireWrites = Input(Bool()); val retireRd = Input(UInt(5.W)); val retireTag = Input(UInt(p.tagBits.W))
    val checkpointHeads = Input(Vec(p.checkpoints,UInt(p.tagBits.W)))
    val checkpointValid = Input(UInt(p.checkpoints.W)); val freeCheckpoint = Input(UInt(p.cpBits.W))
    val restore = Input(UInt(p.checkpoints.W)); val squash = Input(Bool())
    val mapped = Output(Bool()); val tag = Output(UInt(p.tagBits.W))
  })
  val mapped = RegInit(false.B); val mapping = Reg(UInt(p.tagBits.W))
  val savedMapped = Reg(Vec(p.checkpoints,Bool())); val savedTag = Reg(Vec(p.checkpoints,UInt(p.tagBits.W)))
  val newWriter = io.dispatchWrites && io.dispatchRd === index.U
  val committing = io.retire && io.retireWrites && io.retireRd === index.U
  when(committing && mapped && mapping === io.retireTag) { mapped := false.B }
  when(io.dispatch && newWriter) { mapped := true.B; mapping := io.dispatchTag }
  when(io.squash) {
    if(p.earlyRecovery) {
      val restored = Mux1H(io.restore.asBools,savedTag.toSeq)
      mapped := Mux1H(io.restore.asBools,savedMapped.toSeq) && !(committing && restored === io.retireTag)
      mapping := restored
    } else { mapped := false.B }
  }
  for(c <- 0 until p.checkpoints) {
    when(committing && savedTag(c) === io.checkpointHeads(c)) { savedMapped(c) := false.B }
    when(!io.checkpointValid(c) && io.freeCheckpoint === c.U) {
      val tag = Mux(newWriter,io.dispatchTag,mapping)
      savedTag(c) := tag
      savedMapped(c) := (newWriter || mapped) && !(committing && tag === io.checkpointHeads(c))
    }
  }
  io.mapped := mapped; io.tag := mapping
}
