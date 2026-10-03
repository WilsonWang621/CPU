package tier2
import chisel3._
import chisel3.util._

/** One L0 word's local lookup, allocation and byte-write logic. */
class WordCacheEntry extends LocalLogic {
  val io = IO(new Bundle {
    val address = Input(UInt(32.W)); val hit = Output(Bool()); val data = Output(UInt(32.W))
    val fill = Flipped(Valid(new MemReq)); val store = Flipped(Valid(new MemReq))
    val victim = Input(Bool()); val anyFillHit = Input(Bool()); val anyStoreHit = Input(Bool())
    val fillHit = Output(Bool()); val storeHit = Output(Bool())
  })
  val valid = RegInit(false.B); val tag = Reg(UInt(30.W)); val word = Reg(UInt(32.W))
  val hit = valid && tag === io.address(31,2)
  val fillHit = valid && tag === io.fill.bits.addr(31,2)
  val storeHit = valid && tag === io.store.bits.addr(31,2)
  val fillAt = fillHit || (!io.anyFillHit && io.victim)
  val same = io.fill.valid && io.fill.bits.addr(31,2) === io.store.bits.addr(31,2)
  val updates = storeHit || (io.store.bits.mask.andR && !io.anyStoreHit && io.victim) || (same && fillAt)
  when(io.fill.valid && fillAt) { valid := true.B; tag := io.fill.bits.addr(31,2); word := io.fill.bits.data }
  val oldWord = Mux(same,io.fill.bits.data,word)
  when(io.store.valid && updates) {
    valid := true.B; tag := io.store.bits.addr(31,2)
    word := Cat((0 until 4).reverse.map(b => Mux(io.store.bits.mask(b),io.store.bits.data(8*b+7,8*b),oldWord(8*b+7,8*b))))
  }
  io.hit := hit; io.data := word & Fill(32,hit)
  io.fillHit := fillHit; io.storeHit := storeHit
}

/** Raw cache fills and committed byte stores keep a small associative L0 coherent. */
class WordCache(entries: Int, replacement: Int = 0) extends Module {
  require(entries > 0 && isPow2(entries))
  val io = IO(new Bundle {
    val address = Input(UInt(32.W)); val hit = Output(Bool()); val data = Output(UInt(32.W))
    val fill = Flipped(Valid(new Bundle { val address = UInt(32.W); val data = UInt(32.W) }))
    val store = Flipped(Valid(new MemReq))
  })
  val rows = Seq.fill(entries)(Module(new WordCacheEntry))
  val victim = Wire(UInt(entries.W))
  val advance = Wire(Bool())
  if(replacement==0) {
    val pointer = RegInit(1.U(entries.W)); victim := pointer
    when(advance) { if(entries==1) { pointer := 1.U } else { pointer := Cat(pointer(entries-2,0),pointer(entries-1)) } }
  } else {
    // A 63-cycle LFSR keeps allocation off the commit control path.
    val random = RegInit(1.U(6.W))
    random := Cat(random(4,0),random(5)^random(4))
    victim := (if(entries==1) 1.U else UIntToOH(random(log2Ceil(entries)-1,0),entries))
  }
  val anyFill = rows.map(_.io.fillHit).reduce(_ || _); val anyStore = rows.map(_.io.storeHit).reduce(_ || _)
  for(i <- 0 until entries) {
    val row = rows(i).io
    row.address := io.address; row.store := io.store
    row.fill.valid := io.fill.valid; row.fill.bits := 0.U.asTypeOf(new MemReq)
    row.fill.bits.addr := io.fill.bits.address; row.fill.bits.data := io.fill.bits.data
    row.victim := victim(i); row.anyFillHit := anyFill; row.anyStoreHit := anyStore
  }
  io.hit := rows.map(_.io.hit).reduce(_ || _); io.data := rows.map(_.io.data).reduce(_ | _)
  advance := (io.fill.valid && !anyFill) || (io.store.valid && io.store.bits.mask.andR && !anyStore)
}
