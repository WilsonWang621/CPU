package tier2
import chisel3._
import chisel3.util._

/** Select the oldest load whose cache bank is available, bypassing blocked
  * banks. Enqueue forwarding retains the latency of the former flow FIFO.
  */
class LoadQueue(p: Config, entries: Int = 4) extends LocalLogic {
  val io = IO(new Bundle {
    val enq = Flipped(Decoupled(new LoadRequest(p))); val deq = Decoupled(new LoadRequest(p))
    val available = Input(Vec(p.banks,Bool()))
    val live = Input(UInt(p.rob.W))
    val stores = Input(UInt(p.rob.W)); val wrapped = Input(UInt(p.rob.W))
    val head = Input(UInt(p.tagBits.W)); val squash = Input(Bool()); val boundary = Input(UInt(p.tagBits.W))
  })
  val valid = RegInit(VecInit(Seq.fill(entries)(false.B)))
  val rows = Reg(Vec(entries,new LoadRequest(p)))
  val free = PriorityEncoder(~valid.asUInt); val space = !valid.asUInt.andR
  def bank(addr: UInt): UInt = if(p.banks==1) 0.U else addr(log2Ceil(p.lineBytes)+log2Ceil(p.banks)-1,log2Ceil(p.lineBytes))
  def stale(info: LoadInfo): Bool = {
    val newer = Mux((info.tag < io.head) === (io.boundary < io.head),info.tag > io.boundary,info.tag < io.head)
    // A queued load cannot retire until this queue has issued it. Its tag
    // stays allocated, and squash clears younger rows before tag reuse.
    io.squash && (if(p.earlyRecovery) newer else true.B)
  }
  def storesReady(info: LoadInfo): Bool = {
    val olderStore = (0 until p.rob).map(i => io.live(i) && io.stores(i) &&
      Mux(io.wrapped(i) === io.wrapped(info.tag),i.U < info.tag,!io.wrapped(i))).reduce(_ || _)
    !info.waitForStores || !olderStore
  }
  val eligible = (0 until entries).map(i => valid(i) && !stale(rows(i).info) && storesReady(rows(i).info) && io.available(bank(rows(i).addr)))
  val choice = Util.orderTree((0 until entries).map(i => (eligible(i),rows(i).info.tag,i.U(log2Ceil(entries).W))),io.head,false)
  val flowReady = io.available(bank(io.enq.bits.addr)) && !stale(io.enq.bits.info) && storesReady(io.enq.bits.info)
  io.deq.valid := choice._1 || (space && io.enq.valid && flowReady)
  io.deq.bits := Mux(choice._1,Util.choose(choice._3,rows.toSeq),io.enq.bits)
  // Registered capacity is the issue credit. Cache readiness selects dequeue
  // only; it does not feed the scheduler through a full-queue flow bypass.
  io.enq.ready := space
  val flowed = io.enq.fire && !choice._1 && io.deq.fire
  for(i <- 0 until entries) {
    when(valid(i) && stale(rows(i).info)) { valid(i) := false.B }
    when(!valid(i) && free === i.U) { rows(i) := io.enq.bits }
    when(io.deq.fire && choice._1 && choice._3 === i.U) { valid(i) := false.B }
    when(io.enq.fire && !flowed && free === i.U) { valid(i) := true.B }
  }
}
