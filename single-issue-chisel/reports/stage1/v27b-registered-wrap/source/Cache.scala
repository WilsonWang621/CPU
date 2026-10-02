package tier2
import chisel3._
import chisel3.util._

/** Synchronous tag and data SRAMs with per-word validity.
  * One-cycle load hits, pipelined word refills, buffered write-through stores.
  * Store allocation preserves written sectors without fetching unused words.
  */
class Cache(bytes: Int, ways: Int, lineBytes: Int, writeEntries: Int = 16) extends Module {
  val io = IO(new Bundle { val cpu = Flipped(new MemPort); val mem = new MemPort; val fill = Valid(new MemReq); val loadReady = Output(Bool()) })
  val sets = bytes / ways / lineBytes
  val ob = log2Ceil(lineBytes); val sb = log2Ceil(sets); val wb = ob-2
  val tagWidth = 32-ob-sb; val lineWords = lineBytes/4
  val valid = RegInit(VecInit(Seq.fill(ways)(VecInit(Seq.fill(sets)(false.B)))))
  val replace = RegInit(VecInit(Seq.fill(sets)(false.B)))
  val dataRam = Seq.fill(ways)(Module(new Sram(bytes/ways/4)))
  val tagRam = Seq.fill(ways)(Module(new Sram(sets,tagWidth+lineWords,tagWidth+lineWords)))
  val idle :: check :: refill :: retry :: Nil = Enum(4)
  val state = RegInit(idle); val request = Reg(new MemReq)
  val victim = Reg(UInt(math.max(1,log2Ceil(ways)).W))
  val sent = RegInit(0.U((wb+1).W)); val received = RegInit(0.U((wb+1).W))
  val earlyReturned = RegInit(false.B)
  val writeQueue = Module(new Queue(new MemReq,writeEntries)); val direction = Module(new Queue(Bool(),16))
  val index = request.addr(ob+sb-1,ob); val tag = request.addr(31,ob+sb); val word = request.addr(ob-1,2)
  val tagHits = VecInit((0 until ways).map(w => valid(w)(index) && tagRam(w).io.rdata(tagWidth+lineWords-1,lineWords) === tag)).asUInt
  val hits = VecInit((0 until ways).map(w => tagHits(w) && tagRam(w).io.rdata(lineWords-1,0)(word))).asUInt
  val hit = hits.orR
  val earlyResponse = state === refill && !earlyReturned && direction.io.deq.valid && !direction.io.deq.bits && received === 0.U
  io.cpu.rsp.valid := (state === check && !request.write && hit) || (earlyResponse && io.mem.rsp.valid)
  io.cpu.rsp.bits.data := Mux1H((0 until ways).map(w => hits(w) -> dataRam(w).io.rdata))
  io.cpu.rsp.bits.error := false.B
  when(earlyResponse) { io.cpu.rsp.bits.data := io.mem.rsp.bits.data }
  io.loadReady := state === idle || (state === check && io.cpu.rsp.fire)
  io.cpu.req.ready := io.loadReady && (!io.cpu.req.bits.write || writeQueue.io.enq.ready)
  writeQueue.io.enq.valid := io.cpu.req.fire && io.cpu.req.bits.write; writeQueue.io.enq.bits := io.cpu.req.bits
  val fillReq = state === refill && sent < lineWords.U
  io.mem.req.valid := direction.io.enq.ready && (writeQueue.io.deq.valid || fillReq)
  io.mem.req.bits := writeQueue.io.deq.bits
  when(!writeQueue.io.deq.valid) {
    io.mem.req.bits.addr := Cat(request.addr(31,ob),(word+sent)(wb-1,0),0.U(2.W))
    io.mem.req.bits.data := 0.U; io.mem.req.bits.mask := 0.U; io.mem.req.bits.write := false.B
  }
  writeQueue.io.deq.ready := io.mem.req.ready && direction.io.enq.ready
  direction.io.enq.valid := io.mem.req.fire; direction.io.enq.bits := io.mem.req.bits.write
  io.mem.rsp.ready := direction.io.deq.valid && (!earlyResponse || io.cpu.rsp.ready); direction.io.deq.ready := io.mem.rsp.fire
  val filling = io.mem.rsp.fire && !direction.io.deq.bits
  io.fill.valid := (filling && !io.mem.rsp.bits.error) || (state === check && io.cpu.rsp.fire)
  io.fill.bits := 0.U.asTypeOf(new MemReq)
  io.fill.bits.addr := Mux(filling,Cat(request.addr(31,ob),(word+received)(wb-1,0),0.U(2.W)),request.addr)
  io.fill.bits.data := Mux(filling,io.mem.rsp.bits.data,io.cpu.rsp.bits.data)
  val lastFill = filling && received === (lineWords-1).U
  val storing = state === check && request.write
  val canStore = request.mask.andR || tagHits.orR
  val newWay = if(ways==1) 0.U else Mux(!valid(0)(index),0.U,Mux(!valid(1)(index),1.U,replace(index).asUInt))
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
    when(filling) { d.addr := Cat(index,(word+received)(wb-1,0)); d.wdata := io.mem.rsp.bits.data; d.wmask := 15.U }
    t.en := reading || (lastFill && victim === w.U) || (storing && canStore && storeWay === w.U)
    t.we := (lastFill && victim === w.U) || (storing && canStore && storeWay === w.U)
    val sectors = Mux(tagHits(w),t.rdata(lineWords-1,0),0.U) | Mux(request.mask.andR,UIntToOH(word,lineWords),0.U)
    t.addr := Mux(t.we,index,readAddr(ob+sb-1,ob)); t.wdata := Cat(tag,Mux(lastFill,Fill(lineWords,1.U(1.W)),sectors)); t.wmask := 1.U
    for(s <- 0 until sets) {
      when(lastFill && victim === w.U && index === s.U) { valid(w)(s) := true.B }
      when(storing && canStore && storeWay === w.U && index === s.U) {
        valid(w)(s) := true.B
      }
    }
  }
  when(io.cpu.rsp.fire && state === check) { state := idle }
  when(io.cpu.rsp.fire && earlyResponse) { earlyReturned := true.B }
  when(io.cpu.req.fire) { request := io.cpu.req.bits; state := check }
  when(storing) { state := idle; if(ways==2) { replace(index) := !storeWay.asBool } }
  when(state === check && !request.write && !hit) { state := refill; sent := 0.U; received := 0.U; earlyReturned := false.B; victim := Mux(tagHits.orR,PriorityEncoder(tagHits),newWay) }
  when(filling) { received := received+1.U; when(lastFill) { state := Mux(earlyReturned || io.cpu.rsp.fire,idle,retry); if(ways==2) { replace(index) := !victim.asBool } } }
  when(state === retry) { state := check }
}

/** Independent banks overlap line misses while preserving response ownership. */
class DataCache(p: Config) extends Module {
  val io = IO(new Bundle {
    val req = Flipped(Decoupled(new BankRequest(p))); val rsp = Decoupled(new BankResponse(p)); val mem = new MemPort
    val fill = Valid(new MemReq)
    val loadReady = Output(Vec(p.banks,Bool()))
    val store = Flipped(Valid(new MemReq))
  })
  val b = log2Ceil(p.banks); val o = log2Ceil(p.lineBytes)
  val bank = if(p.banks == 1) 0.U else io.req.bits.mem.addr(o+b-1,o)
  val storeBank = if(p.banks == 1) 0.U else io.store.bits.addr(o+b-1,o)
  val prefetch = Module(new Queue(UInt(32.W),4))
  val recent = Reg(Vec(4,UInt((32-o).W))); val recentValid = RegInit(VecInit(Seq.fill(4)(false.B)))
  val recentTail = RegInit(0.U(2.W)); val line = io.req.bits.mem.addr(31,o)
  val seen = (0 until 4).map(i => recentValid(i) && recent(i) === line).reduce(_ || _)
  val sequential = (0 until 4).map(i => recentValid(i) && recent(i)+1.U === line).reduce(_ || _)
  val nextLine = Cat(line+1.U,0.U(o.W))
  prefetch.io.enq.valid := p.prefetch.B && io.req.fire && !io.req.bits.mem.write && !seen && sequential && nextLine < "h10000000".U
  prefetch.io.enq.bits := nextLine
  when(io.req.fire && !io.req.bits.mem.write && !seen) { recent(recentTail) := line; recentValid(recentTail) := true.B; recentTail := recentTail+1.U }
  val prefetchBank = if(p.banks == 1) 0.U else prefetch.io.deq.bits(o+b-1,o)
  val caches = Seq.fill(p.banks)(Module(new Cache(p.dcBytes/p.banks,p.ways,p.lineBytes,math.max(2,16/p.banks))))
  val ready = Wire(Vec(p.banks,Bool()))
  val prefetchReady = Wire(Vec(p.banks,Bool()))
  val fills = Wire(Vec(p.banks,Valid(new MemReq)))
  val responses = Module(new RRArbiter(new BankResponse(p),p.banks))
  val requests = Module(new MemoryArbiter(math.max(2,p.banks)))
  io.mem <> requests.io.out; io.rsp <> responses.io.out
  for(i <- 0 until p.banks) {
    val c = caches(i); val metadata = Module(new Queue(new LoadInfo(p),8))
    val real = io.req.valid && bank === i.U && (if(p.storeEntries > 0) !io.req.bits.mem.write else true.B)
    val pendingStore = WireDefault(false.B); val storeReady = WireDefault(false.B)
    val queuedStore = WireDefault(0.U.asTypeOf(new MemReq))
    if(p.storeEntries > 0) {
      val stores = Module(new Queue(new MemReq,p.storeEntries,flow=true))
      stores.io.enq.valid := io.store.valid && storeBank === i.U
      stores.io.enq.bits := io.store.bits; storeReady := stores.io.enq.ready
      pendingStore := stores.io.deq.valid; queuedStore := stores.io.deq.bits
      stores.io.deq.ready := c.io.cpu.req.ready
    }
    val proactive = prefetch.io.deq.valid && prefetchBank === i.U && !real && !pendingStore
    val demandReady = c.io.cpu.req.ready && (io.req.bits.mem.write || metadata.io.enq.ready) && !pendingStore
    io.loadReady(i) := c.io.loadReady && metadata.io.enq.ready && !pendingStore && !(io.store.valid && storeBank === i.U)
    ready(i) := (if(p.storeEntries > 0) Mux(io.req.bits.mem.write,storeReady,demandReady) else demandReady)
    prefetchReady(i) := !real && !pendingStore && c.io.cpu.req.ready && metadata.io.enq.ready
    c.io.cpu.req.valid := pendingStore || (real && (io.req.bits.mem.write || metadata.io.enq.ready)) || (proactive && metadata.io.enq.ready)
    c.io.cpu.req.bits := Mux(pendingStore,queuedStore,Mux(real,io.req.bits.mem,0.U.asTypeOf(new MemReq)))
    val selectedAddress = Mux(pendingStore,queuedStore.addr,Mux(real,io.req.bits.mem.addr,prefetch.io.deq.bits))
    c.io.cpu.req.bits.addr := selectedAddress
    if(p.banks != 1) { c.io.cpu.req.bits.addr := Cat(0.U(b.W),selectedAddress(31,o+b),selectedAddress(o-1,0)) }
    // A retired store awaiting this bank can make an older raw refill stale.
    // Keep it out of L0; retirement itself has already updated L0's bytes.
    fills(i).valid := c.io.fill.valid && !pendingStore && !(io.req.valid && io.req.bits.mem.write && bank === i.U)
    fills(i).bits := c.io.fill.bits
    if(p.banks != 1) { fills(i).bits.addr := Cat(c.io.fill.bits.addr(31-b,o),i.U(b.W),c.io.fill.bits.addr(o-1,0)) }
    metadata.io.enq.valid := c.io.cpu.req.fire && !c.io.cpu.req.bits.write; metadata.io.enq.bits := io.req.bits.info
    when(!real) { metadata.io.enq.bits := 0.U.asTypeOf(new LoadInfo(p)); metadata.io.enq.bits.prefetch := true.B }
    c.io.cpu.rsp.ready := (responses.io.in(i).ready || metadata.io.deq.bits.prefetch) && metadata.io.deq.valid
    responses.io.in(i).valid := c.io.cpu.rsp.valid && metadata.io.deq.valid && !metadata.io.deq.bits.prefetch
    responses.io.in(i).bits.rsp := c.io.cpu.rsp.bits; responses.io.in(i).bits.info := metadata.io.deq.bits
    metadata.io.deq.ready := c.io.cpu.rsp.fire
    requests.io.clients(i) <> c.io.mem
    if(p.banks != 1) { requests.io.clients(i).req.bits.addr := Cat(c.io.mem.req.bits.addr(31-b,o),i.U(b.W),c.io.mem.req.bits.addr(o-1,0)) }
  }
  if(p.banks == 1) {
    requests.io.clients(1).req.valid := false.B; requests.io.clients(1).req.bits := 0.U.asTypeOf(new MemReq)
    requests.io.clients(1).rsp.ready := true.B
  }
  io.req.ready := Mux1H((0 until p.banks).map(i => (bank === i.U) -> ready(i)))
  io.fill.valid := fills.map(_.valid).reduce(_ || _)
  io.fill.bits := MuxCase(0.U.asTypeOf(new MemReq),fills.map(f => f.valid -> f.bits).toSeq)
  prefetch.io.deq.ready := Mux1H((0 until p.banks).map(i => (prefetchBank === i.U) -> prefetchReady(i)))
}

class FetchPacket extends Bundle { val pc = UInt(32.W); val inst = UInt(32.W); val next = UInt(32.W); val history = UInt(2.W) }
class Training extends Bundle {
  val pc = UInt(32.W); val target = UInt(32.W); val taken = Bool()
  val conditional = Bool(); val call = Bool(); val ret = Bool()
  val history = UInt(2.W)
}
class Frontend(p: Config) extends Module {
  val io = IO(new Bundle {
    val out = Decoupled(new FetchPacket); val mem = new MemPort
    val redirect = Flipped(Valid(UInt(32.W))); val train = Flipped(Valid(new Training))
    val commit = Flipped(Valid(new Training))
  })
  val cache = Module(new Cache(p.icBytes,1,p.lineBytes)); io.mem <> cache.io.mem
  val pc = RegInit(0.U(32.W)); val epoch = RegInit(0.U(4.W))
  val entries = p.btbEntries; val idxBits = log2Ceil(entries)
  val bvalid = RegInit(VecInit(Seq.fill(entries)(false.B)))
  val btag = Reg(Vec(entries,UInt((30-idxBits).W)))
  val btarget = Reg(Vec(entries,UInt(30.W)))
  val bcond = Reg(Vec(entries,Bool())); val bret = Reg(Vec(entries,Bool())); val bcall = Reg(Vec(entries,Bool()))
  val counters = RegInit(VecInit(Seq.fill(256)(2.U(2.W))))
  val history = RegInit(VecInit(Seq.fill(64)(0.U(2.W))))
  def predictionIndex(address: UInt, h: UInt): UInt = if(p.historyBits == 0) address(9,2) else Cat(address(9-p.historyBits,2),h(p.historyBits-1,0))
  val ras = Reg(Vec(8,UInt(32.W))); val sp = RegInit(0.U(3.W)); val depth = RegInit(0.U(4.W))
  val committedRas = Reg(Vec(8,UInt(32.W))); val committedSp = RegInit(0.U(3.W)); val committedDepth = RegInit(0.U(4.W))
  val ix = pc(idxBits+1,2)
  val targetHits = VecInit((0 until entries).map(i => ix === i.U && bvalid(i) && btag(i) === pc(31,idxBits+2)))
  val bpHit = targetHits.asUInt.orR
  val conditionalPrediction = Mux1H(targetHits,bcond); val returnPrediction = Mux1H(targetHits,bret); val callPrediction = Mux1H(targetHits,bcall)
  val fetchHistory = history(pc(7,2)); val counterIndex = predictionIndex(pc,fetchHistory)
  val taken = bpHit && (!conditionalPrediction || counters(counterIndex)(1))
  val target = Mux(returnPrediction && depth =/= 0.U,ras((sp-1.U)(2,0)),Cat(Mux1H(targetHits,btarget),0.U(2.W)))
  val predicted = Mux(taken,target,pc+4.U)
  val meta = Module(new Queue(new Bundle { val pc = UInt(32.W); val next = UInt(32.W); val epoch = UInt(4.W); val history = UInt(2.W)
    val callApplied = Bool(); val returnApplied = Bool(); val rasTop = UInt(32.W); val rasValid = Bool() }, 2))
  val fetched = withReset(reset.asBool || io.redirect.valid) { Module(new Queue(new FetchPacket, 8,flow=true)) }
  io.out <> fetched.io.deq
  val repair = Wire(Bool())
  cache.io.cpu.req.valid := meta.io.enq.ready && !io.redirect.valid && !repair
  cache.io.cpu.req.bits := 0.U.asTypeOf(new MemReq); cache.io.cpu.req.bits.addr := pc
  meta.io.enq.valid := cache.io.cpu.req.fire
  meta.io.enq.bits.pc := pc; meta.io.enq.bits.next := predicted; meta.io.enq.bits.epoch := epoch
  meta.io.enq.bits.history := fetchHistory; meta.io.enq.bits.callApplied := taken && callPrediction
  meta.io.enq.bits.returnApplied := taken && returnPrediction; meta.io.enq.bits.rasTop := ras((sp-1.U)(2,0)); meta.io.enq.bits.rasValid := depth =/= 0.U
  val stale = meta.io.deq.bits.epoch =/= epoch || io.redirect.valid
  fetched.io.enq.valid := cache.io.cpu.rsp.valid && meta.io.deq.valid && !stale
  val incoming = cache.io.cpu.rsp.bits.data; val incomingPC = meta.io.deq.bits.pc
  val isJal = incoming(6,0) === "h6f".U; val isBranch = incoming(6,0) === "h63".U; val isJalr = incoming(6,0) === "h67".U
  val call = (isJal || isJalr) && (incoming(11,7) === 1.U || incoming(11,7) === 5.U)
  val ret = isJalr && (incoming(19,15) === 1.U || incoming(19,15) === 5.U) && incoming(11,7) =/= incoming(19,15)
  val jalTarget = incomingPC + Util.sext(Cat(incoming(31),incoming(19,12),incoming(20),incoming(30,21),0.U(1.W)))
  val branchTarget = incomingPC + Util.sext(Cat(incoming(31),incoming(7),incoming(30,25),incoming(11,8),0.U(1.W)))
  val responseDirection = counters(predictionIndex(incomingPC,meta.io.deq.bits.history))(1)
  val corrected = Mux(isJal,jalTarget,Mux(isBranch,Mux(responseDirection,branchTarget,incomingPC+4.U),
    Mux(ret && meta.io.deq.bits.rasValid,meta.io.deq.bits.rasTop,meta.io.deq.bits.next)))
  fetched.io.enq.bits.pc := incomingPC; fetched.io.enq.bits.next := corrected
  fetched.io.enq.bits.history := meta.io.deq.bits.history
  fetched.io.enq.bits.inst := cache.io.cpu.rsp.bits.data
  cache.io.cpu.rsp.ready := meta.io.deq.valid && (stale || fetched.io.enq.ready)
  meta.io.deq.ready := cache.io.cpu.rsp.fire
  repair := cache.io.cpu.rsp.fire && !stale && corrected =/= meta.io.deq.bits.next
  when(cache.io.cpu.rsp.fire && !stale) {
    when(call && !meta.io.deq.bits.callApplied) { ras(sp) := incomingPC+4.U; sp := sp+1.U; when(depth < 8.U) { depth := depth+1.U } }
    when(ret && !meta.io.deq.bits.returnApplied && depth =/= 0.U) { sp := sp-1.U; depth := depth-1.U }
  }
  when(cache.io.cpu.req.fire) {
    pc := predicted
    when(taken && callPrediction) { ras(sp) := pc+4.U; sp := sp+1.U; when(depth < 8.U) { depth := depth+1.U } }
    when(taken && returnPrediction && depth =/= 0.U) { sp := sp-1.U; depth := depth-1.U }
  }
  when(repair) { pc := corrected; epoch := epoch+1.U }
  val t = io.train.bits; val ti = t.pc(idxBits+1,2); val ci = predictionIndex(t.pc,t.history)
  // Decode writes before the register boundary, and bound payload fanout to
  // eight table entries. The registered row mask publishes prepared data.
  val predictorWrites = RegNext(UIntToOH(ti,entries) & Fill(entries,io.train.valid),0.U(entries.W))
  val predictorPayload = Reg(Vec(entries/8,new Bundle {
    val tag = UInt((30-idxBits).W); val target = UInt(30.W)
    val conditional = Bool(); val ret = Bool(); val call = Bool()
  }))
  for(b <- 0 until entries/8) {
    when(ti(idxBits-1,3) === b.U) {
      predictorPayload(b).tag := t.pc(31,idxBits+2); predictorPayload(b).target := t.target(31,2)
      predictorPayload(b).conditional := t.conditional; predictorPayload(b).ret := t.ret; predictorPayload(b).call := t.call
    }
  }
  for(i <- 0 until entries) {
    when(predictorWrites(i)) {
      bvalid(i) := true.B; btag(i) := predictorPayload(i/8).tag; btarget(i) := predictorPayload(i/8).target
      bcond(i) := predictorPayload(i/8).conditional; bret(i) := predictorPayload(i/8).ret; bcall(i) := predictorPayload(i/8).call
    }
  }
  when(io.train.valid) {
    when(t.conditional) {
      history(t.pc(7,2)) := Cat(history(t.pc(7,2))(0),t.taken)
      when(t.taken && counters(ci) =/= 3.U) { counters(ci) := counters(ci)+1.U }
      when(!t.taken && counters(ci) =/= 0.U) { counters(ci) := counters(ci)-1.U }
    }
  }
  val c = io.commit.bits
  when(io.commit.valid && c.call) { committedRas(committedSp) := c.pc+4.U; committedSp := committedSp+1.U; when(committedDepth < 8.U) { committedDepth := committedDepth+1.U } }
  when(io.commit.valid && c.ret && committedDepth =/= 0.U) { committedSp := committedSp-1.U; committedDepth := committedDepth-1.U }
  when(io.redirect.valid) {
    pc := io.redirect.bits; epoch := epoch+1.U; ras := committedRas; sp := committedSp; depth := committedDepth
    when(io.commit.valid && c.call) { ras(committedSp) := c.pc+4.U; sp := committedSp+1.U; depth := Mux(committedDepth < 8.U,committedDepth+1.U,committedDepth) }
    when(io.commit.valid && c.ret && committedDepth =/= 0.U) { sp := committedSp-1.U; depth := committedDepth-1.U }
  }
}
