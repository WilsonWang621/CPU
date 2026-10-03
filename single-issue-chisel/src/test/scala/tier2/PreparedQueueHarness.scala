package tier2
import chisel3._

/** Compare the real cached queue with its legacy implementation. The driver
  * also checks an independent software FIFO, including the empty flow bypass.
  */
class PreparedQueueHarness(entries: Int, flow: Boolean, partial: Boolean = false) extends Module {
  val enq_valid = IO(Input(Bool())); val enq_ready = IO(Output(Bool()))
  val enq_data = IO(Input(UInt(98.W)))
  val deq_valid = IO(Output(Bool())); val deq_ready = IO(Input(Bool()))
  val deq_data = IO(Output(UInt(98.W)))
  val redirect = IO(Input(Bool()))
  val queues = withReset(reset.asBool || redirect) {
    Seq(Module(new PreparedQueue(UInt(98.W),entries,flow=flow,cachedHead=true,debugHead=true,
        cacheLow=if(partial) 34 else 0,cacheWidth=if(partial) 32 else 0)),
      Module(new PreparedQueue(UInt(98.W),entries,flow=flow)))
  }
  queues.foreach { q =>
    q.io.enq.valid := enq_valid; q.io.enq.bits := enq_data
    q.io.deq.ready := deq_ready
  }
  val cached = queues.head; val legacy = queues.last
  enq_ready := cached.io.enq.ready; deq_valid := cached.io.deq.valid; deq_data := cached.io.deq.bits
  when(!reset.asBool && !redirect) {
    assert(cached.io.enq.ready === legacy.io.enq.ready,"Cached queue changed enqueue backpressure")
    assert(cached.io.deq.valid === legacy.io.deq.valid,"Cached queue changed dequeue availability")
    when(cached.io.deq.valid) {
      assert(cached.io.deq.bits === legacy.io.deq.bits,"Cached queue changed visible payload")
    }
  }
}

object GeneratePreparedQueueHarness extends App {
  for(entries <- Seq(2,8); flow <- Seq(false,true); partial <- Seq(false,true)) {
    val name = s"entries${entries}-flow${if(flow) 1 else 0}${if(partial) "-partial34x32" else ""}"
    _root_.circt.stage.ChiselStage.emitSystemVerilogFile(new PreparedQueueHarness(entries,flow,partial),
      Array("--target-dir",s"${args(0)}/${name}"),Array("--disable-all-randomization"))
  }
}
