package tier2
import chisel3._
import chisel3.util._

/** Prepare the free tail word independently of enqueue permission. Only the
  * pointers and count publish a transaction. Full queues never overwrite data.
  */
class PreparedQueue[T <: Data](gen: T, entries: Int, flow: Boolean = false, headSliceBits: Int = 0, debugHead: Boolean = false, cachedHead: Boolean = false) extends Module {
  require(entries >= 2 && isPow2(entries))
  require(headSliceBits == 0 || headSliceBits >= 1)
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
  val dequeue = Wire(Bool())
  val stored = (if(cachedHead) {
    // The next occupied head is known before the dequeue edge. When the
    // last word leaves, a simultaneous enqueue supplies its replacement.
    // Empty flow-through retains the original combinational bypass.
    val first = Module(new LocalWord(gen.getWidth))
    val nextHead = (head+1.U)(log2Ceil(entries)-1,0)
    first.io.prepare := empty || dequeue
    first.io.data := Mux(count > 1.U,Util.choose(nextHead,words.map(_.io.value)),io.enq.bits.asUInt)
    if(debugHead) {
      when(!empty) { assert(first.io.value === Util.choose(head,words.map(_.io.value)),"Cached queue head differs from occupied storage") }
    }
    first.io.value
  } else if(headSliceBits == 0) Util.choose(head,words.map(_.io.value)) else {
    val width = gen.getWidth
    Cat((0 until width by headSliceBits).reverse.map { low =>
      val high = math.min(width-1,low+headSliceBits-1)
      val selected = Module(new LocalQueueHead(entries))
      selected.io.step := dequeue
      if(debugHead) { assert(selected.io.value === UIntToOH(head,entries),"Local queue head differs from binary dequeue pointer") }
      Util.select(selected.io.value.asBools,words.map(_.io.value(high,low)))
    })
  }).asTypeOf(gen)
  if(flow) {
    io.deq.valid := !empty || io.enq.valid
    io.deq.bits := Mux(empty,io.enq.bits,stored)
  } else { io.deq.valid := !empty; io.deq.bits := stored }
  dequeue := io.deq.fire && !empty
  val enqueue = if(flow) io.enq.fire && !(empty && io.deq.ready) else io.enq.fire
  when(enqueue) { tail := tail+1.U }
  when(dequeue) { head := head+1.U }
  when(enqueue =/= dequeue) { count := Mux(enqueue,count+1.U,count-1.U) }
}
