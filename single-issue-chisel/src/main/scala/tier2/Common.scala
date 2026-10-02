package tier2

import chisel3._
import chisel3.util._

case class Config(rob: Int = 16, iq: Int = 8, icBytes: Int = 4096,
                  dcBytes: Int = 4096, lineBytes: Int = 32, ways: Int = 2,
                  issueWidth: Int = 1, debug: Boolean = false, banks: Int = 4, earlyRecovery: Boolean = true,
                  prefetch: Boolean = true, btbEntries: Int = 128, historyBits: Int = 1, l0Entries: Int = 0,
                  storeEntries: Int = 0, checkpoints: Int = 4, fastRedirect: Boolean = false, storeSlots: Int = 16,
                  loadEntries: Int = 8, l0FillStages: Int = 0, l0Replacement: Int = 0, ramReadAhead: Boolean = false, l0StoreStages: Int = 0, bankedLoadPayload: Boolean = false, cacheHierarchy: Boolean = false, prefetchTrainStages: Int = 0, trustedLoadCredit: Boolean = false, rasWriteStages: Int = 0) {
  require(issueWidth == 1, "This architecture has one issue port")
  require(rob >= 8 && isPow2(rob) && iq >= 2 && isPow2(iq))
  require(isPow2(icBytes) && isPow2(dcBytes) && isPow2(lineBytes))
  require(ways == 1 || ways == 2)
  require(isPow2(banks) && banks <= 4)
  require(isPow2(btbEntries) && historyBits >= 0 && historyBits <= 2)
  require(l0Entries == 0 || isPow2(l0Entries))
  require(prefetchTrainStages == 0 || prefetchTrainStages == 1)
  require(rasWriteStages == 0 || rasWriteStages == 1)
  require(storeEntries >= 0)
  require(!bankedLoadPayload || storeEntries > 0)
  require(!trustedLoadCredit || bankedLoadPayload)
  require(storeSlots >= 2 && isPow2(storeSlots))
  require(loadEntries >= 2 && isPow2(loadEntries))
  require(l0FillStages >= 0 && l0FillStages <= 2)
  require(l0StoreStages == 0 || l0StoreStages == 1)
  require(l0Replacement == 0 || l0Replacement == 1)
  require(l0Replacement == 0 || l0Entries <= 64)
  require(isPow2(checkpoints) && checkpoints >= 2)
  val tagBits = log2Ceil(rob)
  val cpBits = log2Ceil(checkpoints)
  val storeCapacity = math.min(rob,storeSlots)
  val prfSize = 32 + rob // architectural words plus ROB value words
}

class Axi extends Bundle {
  val araddr = Output(UInt(32.W)); val arvalid = Output(Bool()); val arready = Input(Bool())
  val rdata = Input(UInt(32.W)); val rresp = Input(UInt(2.W)); val rvalid = Input(Bool()); val rready = Output(Bool())
  val awaddr = Output(UInt(32.W)); val awvalid = Output(Bool()); val awready = Input(Bool())
  val wdata = Output(UInt(32.W)); val wstrb = Output(UInt(4.W)); val wvalid = Output(Bool()); val wready = Input(Bool())
  val bresp = Input(UInt(2.W)); val bvalid = Input(Bool()); val bready = Output(Bool())
}
class MemReq extends Bundle {
  val addr = UInt(32.W); val data = UInt(32.W); val mask = UInt(4.W); val write = Bool()
}
class MemRsp extends Bundle { val data = UInt(32.W); val error = Bool() }
class LoadInfo(p: Config) extends Bundle {
  val tag = UInt(p.tagBits.W); val fn = UInt(3.W); val offset = UInt(2.W)
  val waitForStores = Bool()
  val prefetch = Bool()
}
class LoadRequest(p: Config) extends Bundle { val addr = UInt(32.W); val info = new LoadInfo(p) }
class BankRequest(p: Config) extends Bundle { val mem = new MemReq; val info = new LoadInfo(p) }
class BankResponse(p: Config) extends Bundle { val rsp = new MemRsp; val info = new LoadInfo(p) }
class MemPort extends Bundle {
  val req = Decoupled(new MemReq)
  val rsp = Flipped(Decoupled(new MemRsp))
}

/** The course supplies both the behavioral model and the counted SRAM Liberty. */
class Sram(depth: Int, width: Int = 32, granularity: Int = 8)
  extends BlackBox(Map("DEPTH" -> depth, "WIDTH" -> width, "WRITE_GRANULARITY" -> granularity)) {
  override def desiredName = "sram_fakeram"
  val io = IO(new Bundle {
    val clk = Input(Clock()); val en = Input(Bool()); val we = Input(Bool())
    val wmask = Input(UInt((width / granularity).W))
    val addr = Input(UInt(log2Ceil(depth).W)); val wdata = Input(UInt(width.W)); val rdata = Output(UInt(width.W))
  })
}

/** Registered requests, independently backpressured AW and W, ordered responses. */
class Bus extends Module {
  val io = IO(new Bundle { val in = Flipped(new MemPort); val axi = new Axi })
  val directions = Module(new Queue(Bool(), 32))
  val pending = RegInit(false.B); val req = Reg(new MemReq)
  val awSent = RegInit(false.B); val wSent = RegInit(false.B)
  io.axi.araddr := Cat(req.addr(31,2),0.U(2.W)); io.axi.awaddr := Cat(req.addr(31,2),0.U(2.W))
  io.axi.wdata := req.data; io.axi.wstrb := req.mask
  io.axi.arvalid := pending && !req.write && !reset.asBool
  io.axi.awvalid := pending && req.write && !awSent && !reset.asBool
  io.axi.wvalid := pending && req.write && !wSent && !reset.asBool
  val launched = pending && Mux(req.write, (awSent || io.axi.awready) && (wSent || io.axi.wready), io.axi.arready)
  io.in.req.ready := (!pending || launched) && directions.io.enq.ready && !reset.asBool
  directions.io.enq.valid := io.in.req.fire
  directions.io.enq.bits := io.in.req.bits.write
  when(io.axi.awvalid && io.axi.awready) { awSent := true.B }
  when(io.axi.wvalid && io.axi.wready) { wSent := true.B }
  when(launched) { pending := false.B; awSent := false.B; wSent := false.B }
  when(io.in.req.fire) { pending := true.B; req := io.in.req.bits; awSent := false.B; wSent := false.B }
  val writing = directions.io.deq.bits
  io.in.rsp.valid := directions.io.deq.valid && Mux(writing, io.axi.bvalid, io.axi.rvalid) && !reset.asBool
  io.in.rsp.bits.data := io.axi.rdata
  io.in.rsp.bits.error := Mux(writing, io.axi.bresp.orR, io.axi.rresp.orR)
  directions.io.deq.ready := io.in.rsp.fire
  io.axi.rready := directions.io.deq.valid && !writing && io.in.rsp.ready && !reset.asBool
  io.axi.bready := directions.io.deq.valid && writing && io.in.rsp.ready && !reset.asBool
}

class MemoryArbiter(nClients: Int = 2) extends Module {
  val io = IO(new Bundle { val clients = Vec(nClients, Flipped(new MemPort)); val out = new MemPort })
  val owners = Module(new Queue(UInt(log2Ceil(nClients).W), 32))
  val arb = Module(new RRArbiter(new MemReq, nClients))
  for (i <- 0 until nClients) { arb.io.in(i) <> io.clients(i).req }
  io.out.req.valid := arb.io.out.valid && owners.io.enq.ready
  io.out.req.bits := arb.io.out.bits
  arb.io.out.ready := io.out.req.ready && owners.io.enq.ready
  owners.io.enq.valid := io.out.req.fire; owners.io.enq.bits := arb.io.chosen
  for(i <- 0 until nClients) {
    io.clients(i).rsp.valid := io.out.rsp.valid && owners.io.deq.valid && owners.io.deq.bits === i.U
    io.clients(i).rsp.bits := io.out.rsp.bits
  }
  io.out.rsp.ready := owners.io.deq.valid && Mux1H((0 until nClients).map(i => (owners.io.deq.bits === i.U) -> io.clients(i).rsp.ready))
  owners.io.deq.ready := io.out.rsp.fire
}

object Util {
  def sext(x: UInt, width: Int = 32): UInt = Cat(Fill(width - x.getWidth, x(x.getWidth - 1)), x)
  def select[T <: Data](selects: Seq[Bool], values: Seq[T]): T = {
    val width = values.head.getWidth
    val masked = selects.zip(values).map { case (s,v) =>
      val word = Module(new LocalMask(width)); word.io.selected := s; word.io.word := v.asUInt; word.io.value
    }
    masked.reduce(_ | _).asTypeOf(values.head)
  }
  def choose[T <: Data](index: UInt, values: Seq[T]): T = select(values.indices.map(i => index === i.U),values)
  def add(a: UInt, b: UInt): UInt = addCarry(a,b,false.B)
  def addCarry(a: UInt, b: UInt, cin: Bool): UInt = {
    val adder = Module(new Adder32); adder.io.a := a; adder.io.b := b; adder.io.cin := cin; adder.io.sum
  }
  def ageTree(xs: Seq[(Bool,UInt,UInt)], youngest: Boolean): (Bool,UInt,UInt) = {
    if(xs.size == 1) xs.head else {
      val (left,right) = xs.splitAt(xs.size/2); val a = ageTree(left,youngest); val b = ageTree(right,youngest)
      val better = if(youngest) a._2 > b._2 else a._2 < b._2
      val pickA = a._1 && (!b._1 || better)
      (a._1 || b._1,Mux(pickA,a._2,b._2),Mux(pickA,a._3,b._3))
    }
  }
  /** Circular ROB order without distributing head through N subtractors. */
  def orderTree(xs: Seq[(Bool,UInt,UInt)], head: UInt, youngest: Boolean): (Bool,UInt,UInt) = {
    orderTreeWrapped(xs,xs.map(_._2 < head),youngest)
  }
  def orderTreeWrapped(xs: Seq[(Bool,UInt,UInt)], wrapped: Seq[Bool], youngest: Boolean): (Bool,UInt,UInt) = {
    def tree(items: Seq[(Bool,UInt,UInt,Bool)]): (Bool,UInt,UInt,Bool) = {
      if(items.size == 1) items.head else {
        val (left,right) = items.splitAt(items.size/2); val a = tree(left); val b = tree(right)
        val same = a._4 === b._4
        val better = if(youngest) Mux(same,a._2 > b._2,a._4) else Mux(same,a._2 < b._2,!a._4)
        val pickA = a._1 && (!b._1 || better)
        (a._1 || b._1,Mux(pickA,a._2,b._2),Mux(pickA,a._3,b._3),Mux(pickA,a._4,b._4))
      }
    }
    val r = tree(xs.zip(wrapped).map { case (x,w) => (x._1,x._2,x._3,w) })
    (r._1,r._2,r._3)
  }
}
