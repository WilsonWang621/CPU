package tier2
import chisel3._
import chisel3.util._

/** Synchronous tag and data SRAMs with per-word validity.
  * One-cycle load hits, pipelined word refills, buffered write-through stores.
  * Store allocation preserves written sectors without fetching unused words.
  */
class Cache(bytes: Int, ways: Int, lineBytes: Int) extends Module {
  val io = IO(new Bundle { val cpu = Flipped(new MemPort); val mem = new MemPort })
  val sets = bytes / ways / lineBytes
  val ob = log2Ceil(lineBytes); val sb = log2Ceil(sets); val wb = ob-2
  val tagWidth = 32-ob-sb; val lineWords = lineBytes/4
  val valid = RegInit(VecInit(Seq.fill(ways)(VecInit(Seq.fill(sets)(0.U(lineWords.W))))))
  val replace = RegInit(VecInit(Seq.fill(sets)(false.B)))
  val dataRam = Seq.fill(ways)(Module(new Sram(bytes/ways/4)))
  val tagRam = Seq.fill(ways)(Module(new Sram(sets,tagWidth,tagWidth)))
  val idle :: check :: refill :: retry :: Nil = Enum(4)
  val state = RegInit(idle); val request = Reg(new MemReq)
  val victim = Reg(UInt(math.max(1,log2Ceil(ways)).W))
  val sent = RegInit(0.U((wb+1).W)); val received = RegInit(0.U((wb+1).W))
  val writeQueue = Module(new Queue(new MemReq,16)); val direction = Module(new Queue(Bool(),32))
  val index = request.addr(ob+sb-1,ob); val tag = request.addr(31,ob+sb); val word = request.addr(ob-1,2)
  val tagHits = VecInit((0 until ways).map(w => valid(w)(index).orR && tagRam(w).io.rdata === tag)).asUInt
  val hits = VecInit((0 until ways).map(w => tagHits(w) && valid(w)(index)(word))).asUInt
  val hit = hits.orR
  io.cpu.rsp.valid := state === check && !request.write && hit
  io.cpu.rsp.bits.data := Mux1H((0 until ways).map(w => hits(w) -> dataRam(w).io.rdata))
  io.cpu.rsp.bits.error := false.B
  io.cpu.req.ready := (state === idle || io.cpu.rsp.fire) && (!io.cpu.req.bits.write || writeQueue.io.enq.ready)
  writeQueue.io.enq.valid := io.cpu.req.fire && io.cpu.req.bits.write; writeQueue.io.enq.bits := io.cpu.req.bits
  val fillReq = state === refill && sent < lineWords.U
  io.mem.req.valid := direction.io.enq.ready && (writeQueue.io.deq.valid || fillReq)
  io.mem.req.bits := writeQueue.io.deq.bits
  when(!writeQueue.io.deq.valid) {
    io.mem.req.bits.addr := Cat(request.addr(31,ob),sent(wb-1,0),0.U(2.W))
    io.mem.req.bits.data := 0.U; io.mem.req.bits.mask := 0.U; io.mem.req.bits.write := false.B
  }
  writeQueue.io.deq.ready := io.mem.req.ready && direction.io.enq.ready
  direction.io.enq.valid := io.mem.req.fire; direction.io.enq.bits := io.mem.req.bits.write
  io.mem.rsp.ready := direction.io.deq.valid; direction.io.deq.ready := io.mem.rsp.fire
  val filling = io.mem.rsp.fire && !direction.io.deq.bits
  val lastFill = filling && received === (lineWords-1).U
  val storing = state === check && request.write
  val canStore = request.mask.andR || tagHits.orR
  val newWay = if(ways==1) 0.U else Mux(!valid(0)(index).orR,0.U,Mux(!valid(1)(index).orR,1.U,replace(index).asUInt))
  val storeWay = if(ways==1) 0.U else Mux(tagHits.orR,PriorityEncoder(tagHits),newWay)
  when(io.mem.req.fire && !io.mem.req.bits.write) { sent := sent+1.U }
  when(io.mem.rsp.fire) { assert(!io.mem.rsp.bits.error,"AXI memory response error") }
  for(w <- 0 until ways) {
    val d = dataRam(w).io; val t = tagRam(w).io
    d.clk := clock; t.clk := clock
    val reading = io.cpu.req.fire || state === retry || (state === check && !request.write && !io.cpu.rsp.fire)
    val readAddr = Mux(io.cpu.req.fire,io.cpu.req.bits.addr,request.addr)
    d.en := reading || (filling && victim === w.U) || (storing && canStore && storeWay === w.U)
    d.we := (filling && victim === w.U) || (storing && canStore && storeWay === w.U)
    d.addr := readAddr(ob+sb-1,2); d.wdata := request.data; d.wmask := request.mask
    when(filling) { d.addr := Cat(index,received(wb-1,0)); d.wdata := io.mem.rsp.bits.data; d.wmask := 15.U }
    t.en := reading || (lastFill && victim === w.U) || (storing && canStore && storeWay === w.U)
    t.we := (lastFill && victim === w.U) || (storing && canStore && storeWay === w.U)
    t.addr := Mux(t.we,index,readAddr(ob+sb-1,ob)); t.wdata := tag; t.wmask := 1.U
    for(s <- 0 until sets) {
      when(lastFill && victim === w.U && index === s.U) { valid(w)(s) := Fill(lineWords,1.U(1.W)) }
      when(storing && canStore && storeWay === w.U && index === s.U) {
        valid(w)(s) := Mux(tagHits(w),valid(w)(s),0.U) | Mux(request.mask.andR,UIntToOH(word,lineWords),0.U)
      }
    }
  }
  when(io.cpu.rsp.fire) { state := idle }
  when(io.cpu.req.fire) { request := io.cpu.req.bits; state := check }
  when(storing) { state := idle; if(ways==2) { replace(index) := !storeWay.asBool } }
  when(state === check && !request.write && !hit) { state := refill; sent := 0.U; received := 0.U; victim := Mux(tagHits.orR,PriorityEncoder(tagHits),newWay) }
  when(filling) { received := received+1.U; when(lastFill) { state := retry; if(ways==2) { replace(index) := !victim.asBool } } }
  when(state === retry) { state := check }
}

class FetchPacket extends Bundle { val pc = UInt(32.W); val inst = UInt(32.W); val next = UInt(32.W) }
class Training extends Bundle {
  val pc = UInt(32.W); val target = UInt(32.W); val taken = Bool()
  val conditional = Bool(); val call = Bool(); val ret = Bool()
}
class Frontend(p: Config) extends Module {
  val io = IO(new Bundle {
    val out = Decoupled(new FetchPacket); val mem = new MemPort
    val redirect = Flipped(Valid(UInt(32.W))); val train = Flipped(Valid(new Training))
  })
  val cache = Module(new Cache(p.icBytes,1,p.lineBytes)); io.mem <> cache.io.mem
  val pc = RegInit(0.U(32.W)); val epoch = RegInit(0.U(4.W))
  val entries = 64; val idxBits = log2Ceil(entries)
  val bvalid = RegInit(VecInit(Seq.fill(entries)(false.B)))
  val btag = Reg(Vec(entries,UInt((30-idxBits).W)))
  val btarget = Reg(Vec(entries,UInt(30.W)))
  val bcond = Reg(Vec(entries,Bool())); val bret = Reg(Vec(entries,Bool())); val bcall = Reg(Vec(entries,Bool()))
  val counters = RegInit(VecInit(Seq.fill(256)(2.U(2.W))))
  val ras = Reg(Vec(8,UInt(32.W))); val sp = RegInit(0.U(3.W)); val depth = RegInit(0.U(4.W))
  val committedRas = Reg(Vec(8,UInt(32.W))); val committedSp = RegInit(0.U(3.W)); val committedDepth = RegInit(0.U(4.W))
  val ix = pc(idxBits+1,2); val bpHit = bvalid(ix) && btag(ix) === pc(31,idxBits+2)
  val taken = bpHit && (!bcond(ix) || counters(pc(9,2))(1))
  val target = Mux(bret(ix) && depth =/= 0.U,ras((sp-1.U)(2,0)),Cat(btarget(ix),0.U(2.W)))
  val predicted = Mux(taken,target,pc+4.U)
  val meta = Module(new Queue(new Bundle { val pc = UInt(32.W); val next = UInt(32.W); val epoch = UInt(4.W) }, 2))
  val fetched = withReset(reset.asBool || io.redirect.valid) { Module(new Queue(new FetchPacket, 8)) }
  io.out <> fetched.io.deq
  cache.io.cpu.req.valid := meta.io.enq.ready && !io.redirect.valid
  cache.io.cpu.req.bits := 0.U.asTypeOf(new MemReq); cache.io.cpu.req.bits.addr := pc
  meta.io.enq.valid := cache.io.cpu.req.fire
  meta.io.enq.bits.pc := pc; meta.io.enq.bits.next := predicted; meta.io.enq.bits.epoch := epoch
  val stale = meta.io.deq.bits.epoch =/= epoch || io.redirect.valid
  fetched.io.enq.valid := cache.io.cpu.rsp.valid && meta.io.deq.valid && !stale
  fetched.io.enq.bits.pc := meta.io.deq.bits.pc; fetched.io.enq.bits.next := meta.io.deq.bits.next
  fetched.io.enq.bits.inst := cache.io.cpu.rsp.bits.data
  cache.io.cpu.rsp.ready := meta.io.deq.valid && (stale || fetched.io.enq.ready)
  meta.io.deq.ready := cache.io.cpu.rsp.fire
  when(cache.io.cpu.req.fire) {
    pc := predicted
    when(taken && bcall(ix)) { ras(sp) := pc+4.U; sp := sp+1.U; when(depth < 8.U) { depth := depth+1.U } }
    when(taken && bret(ix) && depth =/= 0.U) { sp := sp-1.U; depth := depth-1.U }
  }
  val t = io.train.bits; val ti = t.pc(idxBits+1,2); val ci = t.pc(9,2)
  when(io.train.valid) {
    bvalid(ti) := true.B; btag(ti) := t.pc(31,idxBits+2); btarget(ti) := t.target(31,2)
    bcond(ti) := t.conditional; bret(ti) := t.ret; bcall(ti) := t.call
    when(t.conditional) {
      when(t.taken && counters(ci) =/= 3.U) { counters(ci) := counters(ci)+1.U }
      when(!t.taken && counters(ci) =/= 0.U) { counters(ci) := counters(ci)-1.U }
    }
    when(t.call) { committedRas(committedSp) := t.pc+4.U; committedSp := committedSp+1.U; when(committedDepth < 8.U) { committedDepth := committedDepth+1.U } }
    when(t.ret && committedDepth =/= 0.U) { committedSp := committedSp-1.U; committedDepth := committedDepth-1.U }
  }
  when(io.redirect.valid) {
    pc := io.redirect.bits; epoch := epoch+1.U; ras := committedRas; sp := committedSp; depth := committedDepth
    when(io.train.valid && t.call) { ras(committedSp) := t.pc+4.U; sp := committedSp+1.U; depth := Mux(committedDepth < 8.U,committedDepth+1.U,committedDepth) }
    when(io.train.valid && t.ret && committedDepth =/= 0.U) { sp := committedSp-1.U; depth := committedDepth-1.U }
  }
}
