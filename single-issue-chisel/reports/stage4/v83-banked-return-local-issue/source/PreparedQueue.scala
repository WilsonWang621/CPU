package tier2
import chisel3._
import chisel3.util._

/** Prepare the free tail word independently of enqueue permission. Only the
  * pointers and count publish a transaction. Full queues never overwrite data.
  */
class PreparedQueue[T <: Data](gen: T, entries: Int, flow: Boolean = false) extends Module {
  require(entries >= 2 && isPow2(entries))
  val io = IO(new Bundle { val enq = Flipped(Decoupled(gen.cloneType)); val deq = Decoupled(gen.cloneType) })
  val head = RegInit(0.U(log2Ceil(entries).W)); val tail = RegInit(0.U(log2Ceil(entries).W))
  val count = RegInit(0.U(log2Ceil(entries+1).W))
  val empty = count === 0.U; val full = count === entries.U
  val words = Seq.fill(entries)(Module(new LocalWord(gen.getWidth)))
  for(i <- 0 until entries) {
    words(i).io.prepare := !full && tail === i.U
    words(i).io.data := io.enq.bits.asUInt
  }
  io.enq.ready := !full
  val stored = Util.choose(head,words.map(_.io.value)).asTypeOf(gen)
  if(flow) {
    io.deq.valid := !empty || io.enq.valid
    io.deq.bits := Mux(empty,io.enq.bits,stored)
  } else { io.deq.valid := !empty; io.deq.bits := stored }
  val dequeue = io.deq.fire && !empty
  val enqueue = if(flow) io.enq.fire && !(empty && io.deq.ready) else io.enq.fire
  when(enqueue) { tail := tail+1.U }
  when(dequeue) { head := head+1.U }
  when(enqueue =/= dequeue) { count := Mux(enqueue,count+1.U,count-1.U) }
}
