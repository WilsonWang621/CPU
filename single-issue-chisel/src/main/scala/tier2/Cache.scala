package tier2
import chisel3._
import chisel3.util._
import chisel3.experimental.{annotate,ChiselAnnotation}

/** Synchronous tag and data SRAMs with per-word validity.
  * One-cycle load hits, pipelined word refills, buffered write-through stores.
  * Store allocation preserves written sectors without fetching unused words.
  */
class Cache(bytes: Int, ways: Int, lineBytes: Int, writeEntries: Int = 16, readonly: Boolean = false, readAhead: Boolean = false, preserveHierarchy: Boolean = false) extends Module {
  if(preserveHierarchy) {
    val owner = this
    annotate(new ChiselAnnotation {
      override def toFirrtl: firrtl.annotations.Annotation =
        firrtl.AttributeAnnotation(owner.toTarget,"keep_hierarchy = 1")
    })
  }
  val io = IO(new Bundle { val cpu = Flipped(new MemPort); val mem = new MemPort; val fill = Valid(new MemReq); val loadReady = Output(Bool()) })
  val sets = bytes / ways / lineBytes
  val ob = log2Ceil(lineBytes); val sb = log2Ceil(sets); val wb = ob-2
  val tagWidth = 32-ob-sb; val lineWords = lineBytes/4
  val valid = RegInit(VecInit(Seq.fill(ways)(VecInit(Seq.fill(sets)(false.B)))))
  val replace = RegInit(VecInit(Seq.fill(sets)(false.B)))
  val dataRam = Seq.fill(ways)(Module(new Sram(bytes/ways/4)))
  val tagRamWidth = tagWidth + (if(readonly) 0 else lineWords)
  val tagRam = Seq.fill(ways)(Module(new Sram(sets,tagRamWidth,tagRamWidth)))
  val idle :: check :: refill :: retry :: Nil = Enum(4)
  val state = RegInit(idle)
  // Instruction requests carry only an address. Keeping unused store fields
  // across this hierarchy would otherwise retain registers and write queues.
  val requestWord = Module(new LocalWord(if(readonly) 32 else (new MemReq).getWidth))
  val request = Wire(new MemReq)
  if(readonly) { request := 0.U.asTypeOf(new MemReq); request.addr := requestWord.io.value }
  else { request := requestWord.io.value.asTypeOf(new MemReq) }
  val victim = Reg(UInt(math.max(1,log2Ceil(ways)).W))
  val sent = RegInit(0.U((wb+1).W)); val received = RegInit(0.U((wb+1).W))
  val earlyReturned = RegInit(false.B)
  val writeEnq = Wire(Decoupled(new MemReq)); val writeDeq = Wire(Decoupled(new MemReq))
  if(readonly) { writeEnq.ready := true.B; writeDeq.valid := false.B; writeDeq.bits := 0.U.asTypeOf(new MemReq) }
  else { val writes = Module(new PreparedQueue(new MemReq,writeEntries)); writes.io.enq <> writeEnq; writeDeq <> writes.io.deq }
  val direction = Module(new Queue(Bool(),16))
  val index = request.addr(ob+sb-1,ob); val tag = request.addr(31,ob+sb); val word = request.addr(ob-1,2)
  // The course SRAM makes rdata undefined on disabled/write cycles.
  // Preserve only a completed read, with a direct first-cycle bypass so
  // pipelined hits retain their original latency.
  def readResult(ram: Sram): UInt = {
    if(!readAhead) ram.io.rdata
    else {
      val completedRead = RegNext(ram.io.en && !ram.io.we,false.B)
      val held = RegEnable(ram.io.rdata,completedRead)
      Mux(completedRead,ram.io.rdata,held)
    }
  }
  val tagRead = tagRam.map(readResult)
  val dataRead = dataRam.map(readResult)
  val tagHits = VecInit((0 until ways).map(w => valid(w)(index) && (if(readonly) tagRead(w) else tagRead(w)(tagRamWidth-1,lineWords)) === tag)).asUInt
  val hits = if(readonly) tagHits else VecInit((0 until ways).map(w => tagHits(w) && tagRead(w)(lineWords-1,0)(word))).asUInt
  val hit = hits.orR
  val earlyResponse = state === refill && !earlyReturned && direction.io.deq.valid && !direction.io.deq.bits && received === 0.U
  io.cpu.rsp.valid := (state === check && !request.write && hit) || (earlyResponse && io.mem.rsp.valid)
  io.cpu.rsp.bits.data := Mux1H((0 until ways).map(w => hits(w) -> dataRead(w)))
  io.cpu.rsp.bits.error := false.B
  when(earlyResponse) { io.cpu.rsp.bits.data := io.mem.rsp.bits.data }
  io.loadReady := state === idle || (state === check && io.cpu.rsp.fire)
  requestWord.io.prepare := io.loadReady; requestWord.io.data := (if(readonly) io.cpu.req.bits.addr else io.cpu.req.bits.asUInt)
  io.cpu.req.ready := io.loadReady && (if(readonly) true.B else !io.cpu.req.bits.write || writeEnq.ready)
  writeEnq.valid := io.cpu.req.fire && io.cpu.req.bits.write; writeEnq.bits := io.cpu.req.bits
  val fillReq = state === refill && sent < lineWords.U
  io.mem.req.valid := direction.io.enq.ready && (writeDeq.valid || fillReq)
  io.mem.req.bits := writeDeq.bits
  when(!writeDeq.valid) {
    io.mem.req.bits.addr := Cat(request.addr(31,ob),(word+sent)(wb-1,0),0.U(2.W))
    io.mem.req.bits.data := 0.U; io.mem.req.bits.mask := 0.U; io.mem.req.bits.write := false.B
  }
  writeDeq.ready := io.mem.req.ready && direction.io.enq.ready
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
    // Explicit read-result registers preserve stalled checks. Prepare the
    // next candidate address independently of admission during idle cycles.
    val reading = if(readAhead) state === idle || state === retry || (state === check && io.cpu.rsp.fire)
      else io.cpu.req.fire || state === retry || (state === check && !request.write && !io.cpu.rsp.fire)
    val readAddr = if(readAhead) Mux(state === retry,request.addr,io.cpu.req.bits.addr)
      else Mux(io.loadReady,io.cpu.req.bits.addr,request.addr)
    d.en := reading || (filling && victim === w.U) || (storing && canStore && storeWay === w.U)
    d.we := (filling && victim === w.U) || (storing && canStore && storeWay === w.U)
    d.addr := Mux(storing,request.addr(ob+sb-1,2),readAddr(ob+sb-1,2)); d.wdata := request.data; d.wmask := request.mask
    when(filling) { d.addr := Cat(index,(word+received)(wb-1,0)); d.wdata := io.mem.rsp.bits.data; d.wmask := 15.U }
    t.en := reading || (lastFill && victim === w.U) || (storing && canStore && storeWay === w.U)
    t.we := (lastFill && victim === w.U) || (storing && canStore && storeWay === w.U)
    t.addr := Mux(t.we,index,readAddr(ob+sb-1,ob)); t.wmask := 1.U
    if(readonly) { t.wdata := tag }
    else {
      val sectors = Mux(tagHits(w),tagRead(w)(lineWords-1,0),0.U) | Mux(request.mask.andR,UIntToOH(word,lineWords),0.U)
      t.wdata := Cat(tag,Mux(lastFill,Fill(lineWords,1.U(1.W)),sectors))
    }
    for(s <- 0 until sets) {
      when(lastFill && victim === w.U && index === s.U) { valid(w)(s) := true.B }
      when(storing && canStore && storeWay === w.U && index === s.U) {
        valid(w)(s) := true.B
      }
    }
  }
  when(io.cpu.rsp.fire && state === check) { state := idle }
  when(io.cpu.rsp.fire && earlyResponse) { earlyReturned := true.B }
  when(io.cpu.req.fire) { state := check }
  when(storing) { state := idle; if(ways==2) { replace(index) := !storeWay.asBool } }
  when(state === check && !request.write && !hit) { state := refill; sent := 0.U; received := 0.U; earlyReturned := false.B; victim := Mux(tagHits.orR,PriorityEncoder(tagHits),newWay) }
  when(filling) { received := received+1.U; when(lastFill) { state := Mux(earlyReturned || io.cpu.rsp.fire,idle,retry); if(ways==2) { replace(index) := !victim.asBool } } }
  when(state === retry) { state := check }
}

/** Independent banks overlap line misses while preserving response ownership. */
class DataCache(p: Config) extends Module {
  val io = IO(new Bundle {
    val req = Flipped(Decoupled(new BankRequest(p))); val rsp = Decoupled(new BankResponse(p)); val mem = new MemPort
    val loadReturn = if(p.bankedReturnMatch) Some(Output(new BankedLoadReturn(p))) else None
    val fill = Valid(new MemReq)
    val candidates = Input(Vec(p.banks,Valid(new LoadRequest(p))))
    val loadReady = Output(Vec(p.banks,Bool()))
    val store = Flipped(Valid(new MemReq))
    val storeReady = Output(Bool())
    val squash = Input(Bool()); val boundary = Input(UInt(p.tagBits.W)); val wrapped = Input(UInt(p.rob.W)); val squashMask = Input(UInt(p.rob.W))
  })
  val b = log2Ceil(p.banks); val o = log2Ceil(p.lineBytes)
  val bank = if(p.banks == 1) 0.U else io.req.bits.mem.addr(o+b-1,o)
  val storeBank = if(p.banks == 1) 0.U else io.store.bits.addr(o+b-1,o)
  val prefetch = Module(new PreparedQueue(UInt(32.W),4))
  val recent = Reg(Vec(4,UInt((32-o).W))); val recentValid = RegInit(VecInit(Seq.fill(4)(false.B)))
  val recentTail = RegInit(0.U(2.W))
  val demandAccepted = (if(p.trustedLoadCredit) io.req.valid else io.req.fire) && !io.req.bits.mem.write
  val trainAddress = Wire(UInt(32.W)); val trainValid = Wire(Bool())
  if(p.prefetchTrainStages == 1 && p.bankedLoadPayload) {
    val accepted = VecInit((0 until p.banks).map(i => RegNext(demandAccepted && bank === i.U,false.B)))
    val addresses = (0 until p.banks).map { i =>
      val address = Reg(UInt(32.W)); address := io.candidates(i).bits.addr; address
    }
    trainAddress := Util.select(accepted.toSeq,addresses)
    trainValid := accepted.asUInt.orR
  } else if(p.prefetchTrainStages == 1) {
    trainAddress := RegNext(io.req.bits.mem.addr)
    trainValid := RegNext(demandAccepted,false.B)
  } else {
    trainAddress := io.req.bits.mem.addr; trainValid := demandAccepted
  }
  val line = trainAddress(31,o)
  val seen = (0 until 4).map(i => recentValid(i) && recent(i) === line).reduce(_ || _)
  val sequential = (0 until 4).map(i => recentValid(i) && recent(i)+1.U === line).reduce(_ || _)
  val nextLine = Cat(line+1.U,0.U(o.W))
  prefetch.io.enq.valid := p.prefetch.B && trainValid && !seen && sequential && nextLine < "h10000000".U
  prefetch.io.enq.bits := nextLine
  when(trainValid && !seen) { recent(recentTail) := line; recentValid(recentTail) := true.B; recentTail := recentTail+1.U }
  val prefetchBank = if(p.banks == 1) 0.U else prefetch.io.deq.bits(o+b-1,o)
  val caches = Seq.fill(p.banks)(Module(new Cache(p.dcBytes/p.banks,p.ways,p.lineBytes,2,readAhead=p.ramReadAhead,preserveHierarchy=p.cacheHierarchy)))
  val ready = Wire(Vec(p.banks,Bool()))
  val storeCredits = Wire(Vec(p.banks,Bool()))
  val prefetchReady = Wire(Vec(p.banks,Bool()))
  val fills = Wire(Vec(p.banks,Valid(new MemReq)))
  val responses = Module(new RRArbiter(new BankResponse(p),p.banks))
  val requests = Module(new MemoryArbiter(math.max(2,p.banks)))
  io.mem <> requests.io.out; io.rsp <> responses.io.out
  for(i <- 0 until p.banks) {
    val c = caches(i); val metadata = Module(new CacheOwner(p))
    metadata.io.squash := io.squash; metadata.io.boundary := io.boundary; metadata.io.wrapped := io.wrapped; metadata.io.squashMask := io.squashMask
    val real = io.req.valid && bank === i.U && (if(p.storeEntries > 0) !io.req.bits.mem.write else true.B)
    val pendingStore = WireDefault(false.B); val storeReady = WireDefault(false.B)
    val queuedStore = WireDefault(0.U.asTypeOf(new MemReq))
    if(p.storeEntries > 0) {
      val stores = Module(new PreparedQueue(new MemReq,p.storeEntries,flow=true))
      stores.io.enq.valid := io.store.valid && storeBank === i.U
      stores.io.enq.bits := io.store.bits; storeReady := stores.io.enq.ready
      pendingStore := stores.io.deq.valid; queuedStore := stores.io.deq.bits
      stores.io.deq.ready := c.io.cpu.req.ready
    }
    val candidateDemand = if(p.bankedLoadPayload) io.candidates(i).valid else real
    val proactive = prefetch.io.deq.valid && prefetchBank === i.U && !candidateDemand && !pendingStore
    val demandReady = c.io.cpu.req.ready && !pendingStore
    storeCredits(i) := (if(p.storeEntries > 0) storeReady else c.io.cpu.req.ready)
    io.loadReady(i) := c.io.loadReady && !pendingStore && !(io.store.valid && storeBank === i.U)
    ready(i) := (if(p.storeEntries > 0) Mux(io.req.bits.mem.write,storeReady,demandReady) else demandReady)
    prefetchReady(i) := !candidateDemand && !pendingStore && c.io.cpu.req.ready
    c.io.cpu.req.valid := pendingStore || real || proactive
    c.io.cpu.req.bits := Mux(pendingStore,queuedStore,Mux(real,io.req.bits.mem,0.U.asTypeOf(new MemReq)))
    val demandAddress = if(p.bankedLoadPayload) io.candidates(i).bits.addr else io.req.bits.mem.addr
    val selectedAddress = Mux(pendingStore,queuedStore.addr,Mux(candidateDemand,demandAddress,prefetch.io.deq.bits))
    c.io.cpu.req.bits.addr := selectedAddress
    if(p.debug && p.bankedLoadPayload) {
      when(io.req.fire && bank === i.U) {
        assert(io.candidates(i).valid,"Accepted load lacks a prepared bank candidate")
        assert(selectedAddress === io.req.bits.mem.addr,"Prepared bank address differs from accepted load")
      }
    }
    if(p.banks != 1) { c.io.cpu.req.bits.addr := Cat(0.U(b.W),selectedAddress(31,o+b),selectedAddress(o-1,0)) }
    // A retired store awaiting this bank can make an older raw refill stale.
    // Keep it out of L0; retirement itself has already updated L0's bytes.
    fills(i).valid := c.io.fill.valid && !pendingStore && !(io.store.valid && storeBank === i.U)
    fills(i).bits := c.io.fill.bits
    if(p.banks != 1) { fills(i).bits.addr := Cat(c.io.fill.bits.addr(31-b,o),i.U(b.W),c.io.fill.bits.addr(o-1,0)) }
    metadata.io.offer.valid := c.io.cpu.req.fire && !c.io.cpu.req.bits.write; metadata.io.offer.bits := io.req.bits.info
    when(!real) { metadata.io.offer.bits := 0.U.asTypeOf(new LoadInfo(p)); metadata.io.offer.bits.prefetch := true.B }
    c.io.cpu.rsp.ready := (responses.io.in(i).ready || metadata.io.info.prefetch || metadata.io.dead) && metadata.io.valid
    responses.io.in(i).valid := c.io.cpu.rsp.valid && metadata.io.valid && !metadata.io.info.prefetch && !metadata.io.dead
    responses.io.in(i).bits.rsp := c.io.cpu.rsp.bits; responses.io.in(i).bits.info := metadata.io.info
    if(p.earlyLoadFormat) {
      val formatted = Module(new LocalLoadValue)
      formatted.io.word := c.io.cpu.rsp.bits.data
      formatted.io.offset := metadata.io.info.offset; formatted.io.fn := metadata.io.info.fn
      responses.io.in(i).bits.rsp.data := formatted.io.value
    }
    io.loadReturn.foreach { returned =>
      returned.tags(i) := metadata.io.info.tag
      returned.selected(i) := responses.io.in(i).fire
      returned.pending.foreach(_(i) := metadata.io.valid && !metadata.io.info.prefetch && !metadata.io.dead)
    }
    metadata.io.consume := c.io.cpu.rsp.fire
    requests.io.clients(i) <> c.io.mem
    if(p.banks != 1) { requests.io.clients(i).req.bits.addr := Cat(c.io.mem.req.bits.addr(31-b,o),i.U(b.W),c.io.mem.req.bits.addr(o-1,0)) }
  }
  if(p.banks == 1) {
    requests.io.clients(1).req.valid := false.B; requests.io.clients(1).req.bits := 0.U.asTypeOf(new MemReq)
    requests.io.clients(1).rsp.ready := true.B
  }
  io.req.ready := Mux1H((0 until p.banks).map(i => (bank === i.U) -> ready(i)))
  io.storeReady := Mux1H((0 until p.banks).map(i => (storeBank === i.U) -> storeCredits(i)))
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
  val cache = Module(new Cache(p.icBytes,1,p.lineBytes,readonly=true,readAhead=p.ramReadAhead,preserveHierarchy=p.cacheHierarchy)); io.mem <> cache.io.mem
  val pc = RegInit(0.U(32.W)); val epoch = RegInit(0.U(4.W))
  val entries = p.btbEntries; val idxBits = log2Ceil(entries)
  val bvalid = RegInit(VecInit(Seq.fill(entries)(false.B)))
  val btag = Reg(Vec(entries,UInt((30-idxBits).W)))
  val btarget = Reg(Vec(entries,UInt(30.W)))
  val bcond = Reg(Vec(entries,Bool())); val bret = Reg(Vec(entries,Bool())); val bcall = Reg(Vec(entries,Bool()))
  val counterEntries = Seq.fill(256)(Module(new PredictorCounter))
  val historyEntries = Seq.fill(64)(Module(new PredictorHistory))
  val counters = VecInit(counterEntries.map(_.io.value))
  val history = VecInit(historyEntries.map(_.io.value))
  def predictionIndex(address: UInt, h: UInt): UInt = if(p.historyBits == 0) address(9,2) else Cat(address(9-p.historyBits,2),h(p.historyBits-1,0))
  val sp = RegInit(0.U(3.W)); val depth = RegInit(0.U(4.W))
  val speculativeRas = Seq.tabulate(8)(i => Module(new LocalIndexedWord(32,3,i)))
  val committedRas = Seq.tabulate(8)(i => Module(new LocalIndexedWord(32,3,i)))
  val rasValid = RegInit(VecInit(Seq.fill(8)(false.B)))
  val committedSp = RegInit(0.U(3.W)); val committedDepth = RegInit(0.U(4.W))
  // Recovery switches entry ownership instead of copying 8 wide words.
  val pendingRas = Wire(Valid(new Bundle { val index = UInt(3.W); val data = UInt(32.W) }))
  val rasTopIndex = (sp-1.U)(2,0)
  val storedRasTop = Util.choose(rasTopIndex,(0 until 8).map(i => Mux(rasValid(i),speculativeRas(i).io.value,committedRas(i).io.value)))
  val rasTop = if(p.rasWriteStages == 1) Mux(pendingRas.valid && pendingRas.bits.index === rasTopIndex &&
    rasValid(rasTopIndex),pendingRas.bits.data,storedRasTop) else storedRasTop
  val ix = pc(idxBits+1,2)
  val targetHits = VecInit((0 until entries).map(i => ix === i.U && bvalid(i) && btag(i) === pc(31,idxBits+2)))
  val bpHit = targetHits.asUInt.orR
  val conditionalPrediction = Mux1H(targetHits,bcond); val returnPrediction = Mux1H(targetHits,bret); val callPrediction = Mux1H(targetHits,bcall)
  val fetchHistory = history(pc(7,2)); val counterIndex = predictionIndex(pc,fetchHistory)
  val taken = bpHit && (!conditionalPrediction || counters(counterIndex)(1))
  val target = Mux(returnPrediction && depth =/= 0.U,rasTop,Cat(Mux1H(targetHits,btarget),0.U(2.W)))
  val predicted = Mux(taken,target,pc+4.U)
  val meta = Module(new PreparedQueue(new Bundle { val pc = UInt(32.W); val next = UInt(32.W); val epoch = UInt(4.W); val history = UInt(2.W)
    val callApplied = Bool(); val returnApplied = Bool(); val rasTop = UInt(32.W); val rasValid = Bool() }, 2))
  val fetched = withReset(reset.asBool || io.redirect.valid) {
    Module(new PreparedQueue(new FetchPacket,8,flow=true,headSliceBits=p.fetchHeadSliceBits,debugHead=p.debug,cachedHead=p.cachedFetchHead,
      cacheLow=34,cacheWidth=if(p.cachedFetchInstruction) 32 else 0))
  }
  io.out <> fetched.io.deq
  val repair = Wire(Bool())
  cache.io.cpu.req.valid := meta.io.enq.ready && !io.redirect.valid && !repair
  cache.io.cpu.req.bits := 0.U.asTypeOf(new MemReq); cache.io.cpu.req.bits.addr := pc
  meta.io.enq.valid := cache.io.cpu.req.fire
  meta.io.enq.bits.pc := pc; meta.io.enq.bits.next := predicted; meta.io.enq.bits.epoch := epoch
  meta.io.enq.bits.history := fetchHistory; meta.io.enq.bits.callApplied := taken && callPrediction
  meta.io.enq.bits.returnApplied := taken && returnPrediction; meta.io.enq.bits.rasTop := rasTop; meta.io.enq.bits.rasValid := depth =/= 0.U
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
  val responseCall = cache.io.cpu.rsp.fire && !stale && call && !meta.io.deq.bits.callApplied
  val predictionCall = cache.io.cpu.req.fire && taken && callPrediction
  if(p.rasWriteStages == 1) {
    pendingRas.valid := RegNext(responseCall || predictionCall,false.B)
    pendingRas.bits.index := RegNext(sp)
    val predictionData = RegNext(pc+4.U)
    val responseData = RegNext(incomingPC+4.U)
    val predictionSelected = RegNext(predictionCall,false.B)
    pendingRas.bits.data := Mux(predictionSelected,predictionData,responseData)
  } else {
    pendingRas.valid := responseCall || predictionCall
    pendingRas.bits.index := sp
    pendingRas.bits.data := Mux(predictionCall,pc+4.U,incomingPC+4.U)
  }
  for(i <- 0 until 8) {
    speculativeRas(i).io.index := pendingRas.bits.index; speculativeRas(i).io.write := pendingRas.valid
    speculativeRas(i).io.data := pendingRas.bits.data
    when((responseCall || predictionCall) && sp === i.U) { rasValid(i) := true.B }
  }
  when(cache.io.cpu.rsp.fire && !stale) {
    when(call && !meta.io.deq.bits.callApplied) { sp := sp+1.U; when(depth < 8.U) { depth := depth+1.U } }
    when(ret && !meta.io.deq.bits.returnApplied && depth =/= 0.U) { sp := sp-1.U; depth := depth-1.U }
  }
  when(cache.io.cpu.req.fire) {
    pc := predicted
    when(taken && callPrediction) { sp := sp+1.U; when(depth < 8.U) { depth := depth+1.U } }
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
  val counterBanks = (0 until 16).map(b => io.train.valid && t.conditional && ci(7,4) === b.U)
  val counterRows = (0 until 16).map(r => ci(3,0) === r.U)
  val counterDirections = (0 until 16).map(b => t.taken && ci(7,4) === b.U)
  for(i <- 0 until 256) {
    counterEntries(i).io.bank := counterBanks(i/16)
    counterEntries(i).io.row := counterRows(i%16)
    counterEntries(i).io.taken := counterDirections(i/16)
  }
  val historyBanks = (0 until 8).map(b => io.train.valid && t.conditional && t.pc(7,5) === b.U)
  val historyRows = (0 until 8).map(r => t.pc(4,2) === r.U)
  val historyDirections = (0 until 8).map(b => t.taken && t.pc(7,5) === b.U)
  for(i <- 0 until 64) {
    historyEntries(i).io.bank := historyBanks(i/8)
    historyEntries(i).io.row := historyRows(i%8)
    historyEntries(i).io.taken := historyDirections(i/8)
  }
  val c = io.commit.bits
  for(i <- 0 until 8) {
    committedRas(i).io.write := io.commit.valid && c.call; committedRas(i).io.index := committedSp; committedRas(i).io.data := c.pc+4.U
  }
  when(io.commit.valid && c.call) { committedSp := committedSp+1.U; when(committedDepth < 8.U) { committedDepth := committedDepth+1.U } }
  when(io.commit.valid && c.ret && committedDepth =/= 0.U) { committedSp := committedSp-1.U; committedDepth := committedDepth-1.U }
  when(io.redirect.valid) {
    pc := io.redirect.bits; epoch := epoch+1.U; rasValid.foreach(_ := false.B); sp := committedSp; depth := committedDepth
    when(io.commit.valid && c.call) { sp := committedSp+1.U; depth := Mux(committedDepth < 8.U,committedDepth+1.U,committedDepth) }
    when(io.commit.valid && c.ret && committedDepth =/= 0.U) { sp := committedSp-1.U; depth := committedDepth-1.U }
  }
}
