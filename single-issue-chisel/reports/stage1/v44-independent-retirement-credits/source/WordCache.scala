package tier2
import chisel3._
import chisel3.util._

/** Small fully associative L0. SRAM L1 remains the backing cache.
  * Only raw cache responses and retired stores update the contents, so a
  * wrong-path store-to-load bypass cannot contaminate subsequent execution.
  */
class WordCache(entries: Int) extends Module {
  require(entries > 0 && isPow2(entries))
  val io = IO(new Bundle {
    val address = Input(UInt(32.W)); val hit = Output(Bool()); val data = Output(UInt(32.W))
    val fill = Flipped(Valid(new Bundle { val address = UInt(32.W); val data = UInt(32.W) }))
    val store = Flipped(Valid(new MemReq))
  })
  val valid = RegInit(VecInit(Seq.fill(entries)(false.B)))
  val tags = Reg(Vec(entries,UInt(30.W))); val words = Reg(Vec(entries,UInt(32.W)))
  val victim = RegInit(0.U(math.max(1,log2Ceil(entries)).W))
  val hits = VecInit((0 until entries).map(i => valid(i) && tags(i) === io.address(31,2)))
  io.hit := hits.asUInt.orR; io.data := Mux1H(hits,words)
  val fills = VecInit((0 until entries).map(i => valid(i) && tags(i) === io.fill.bits.address(31,2)))
  val stores = VecInit((0 until entries).map(i => valid(i) && tags(i) === io.store.bits.addr(31,2)))
  val fillAt = Mux(fills.asUInt.orR,PriorityEncoder(fills),victim)
  val storeAt = Mux(stores.asUInt.orR,PriorityEncoder(stores),victim)
  val same = io.fill.valid && io.fill.bits.address(31,2) === io.store.bits.addr(31,2)
  val allocateStore = io.store.bits.mask.andR
  for(i <- 0 until entries) {
    when(io.fill.valid && fillAt === i.U) {
      valid(i) := true.B; tags(i) := io.fill.bits.address(31,2); words(i) := io.fill.bits.data
    }
    val updates = stores(i) || (allocateStore && storeAt === i.U) || (same && fillAt === i.U)
    val oldWord = Mux(same,io.fill.bits.data,words(i))
    when(io.store.valid && updates) {
      valid(i) := true.B; tags(i) := io.store.bits.addr(31,2)
      words(i) := Cat((0 until 4).reverse.map(b => Mux(io.store.bits.mask(b),io.store.bits.data(8*b+7,8*b),oldWord(8*b+7,8*b))))
    }
  }
  when((io.fill.valid && !fills.asUInt.orR) || (io.store.valid && allocateStore && !stores.asUInt.orR)) { victim := victim+1.U }
}
