package tier2
import chisel3._
import chisel3.util._

class Core(p: Config) extends Module {
  val io = IO(new Bundle { val axi = new Axi })
  val bus = Module(new Bus); val arb = Module(new MemoryArbiter)
  val fetch = Module(new Frontend(p)); val dc = Module(new DataCache(p))
  val md = Module(new MulDiv(p)); val alu = Module(new Execute); val decoder = Module(new Decoder)
  io.axi <> bus.io.axi; bus.io.in <> arb.io.out
  arb.io.clients(0) <> fetch.io.mem; arb.io.clients(1) <> dc.io.mem
  val head = RegInit(0.U(p.tagBits.W)); val tail = RegInit(0.U(p.tagBits.W))
  val headSelect = RegInit(1.U(p.rob.W))
  val wrapped = RegInit(0.U(p.rob.W))
  private val headReads = scala.collection.mutable.AnyRefMap.empty[Data,Data]
  def atHead[T <: Data](xs: Vec[T]): T = headReads.getOrElseUpdate(xs,Util.select(headSelect.asBools,xs.toSeq)).asInstanceOf[T]
  val count = RegInit(0.U((p.tagBits+1).W))
  val live = RegInit(VecInit(Seq.fill(p.rob)(false.B)))
  val done = RegInit(VecInit(Seq.fill(p.rob)(false.B)))
  val fault = Reg(Vec(p.rob,Bool()))
  val resultWords = Seq.tabulate(p.rob)(i => Module(new LocalResultWord(p,i)))
  val values = VecInit(resultWords.map(_.io.value))
  val rd = Reg(Vec(p.rob,UInt(5.W))); val writes = Reg(Vec(p.rob,Bool()))
  val predicted = Reg(Vec(p.rob,UInt(32.W))); val actual = Reg(Vec(p.rob,UInt(32.W)))
  val control = Reg(Vec(p.rob,Bool())); val conditional = Reg(Vec(p.rob,Bool()))
  val taken = Reg(Vec(p.rob,Bool())); val calls = Reg(Vec(p.rob,Bool())); val returns = Reg(Vec(p.rob,Bool()))
  val stores = Reg(Vec(p.rob,Bool()))
  val storeLive = RegInit(VecInit(Seq.fill(p.storeCapacity)(false.B)))
  val storeOwner = Reg(Vec(p.storeCapacity,UInt(p.tagBits.W)))
  val storeAddr = Reg(Vec(p.storeCapacity,UInt(32.W)))
  val storeData = Reg(Vec(p.storeCapacity,UInt(32.W))); val storeMask = Reg(Vec(p.storeCapacity,UInt(4.W)))
  val storeFree = PriorityEncoder(~storeLive.asUInt)
  val storeSpace = !storeLive.asUInt.andR
  val storeHeadSelect = RegInit(0.U(p.storeCapacity.W))
  val retiredStoreAddress = Util.select(storeHeadSelect.asBools,storeAddr.toSeq)
  val retiredStoreData = Util.select(storeHeadSelect.asBools,storeData.toSeq)
  val retiredStoreMask = Util.select(storeHeadSelect.asBools,storeMask.toSeq)
  val architecturalWords = (1 until 32).map(i => Module(new LocalArchWord(i)))
  val arch = VecInit(Seq(0.U(32.W)) ++ architecturalWords.map(_.io.value))
  val renameEntries = (1 until 32).map(i => Module(new RenameEntry(p,i)))
  val mapped = VecInit(Seq(false.B) ++ renameEntries.map(_.io.mapped))
  val mapping = VecInit(Seq(0.U(p.tagBits.W)) ++ renameEntries.map(_.io.tag))
  val cpValid = RegInit(VecInit(Seq.fill(p.checkpoints)(false.B)))
  val cpOwner = Reg(Vec(p.checkpoints,UInt(p.tagBits.W)))
  val branchCheckpoint = Reg(Vec(p.rob,UInt(p.cpBits.W)))
  // Build shared payload reads in the module scope, before conditional writes.
  val retiredValue = atHead(values)
  val freeCheckpoint = PriorityEncoder(~cpValid.asUInt)
  val checkpointAvailable = !cpValid.asUInt.andR
  val halted = RegInit(false.B)
  val qvalid = RegInit(VecInit(Seq.fill(p.iq)(false.B)))
  val qd = Reg(Vec(p.iq,new Decoded)); val qpc = Reg(Vec(p.iq,UInt(32.W)))
  val qnext = Reg(Vec(p.iq,UInt(32.W))); val qhistory = Reg(Vec(p.iq,UInt(2.W)))
  val qtag = Reg(Vec(p.iq,UInt(p.tagBits.W)))
  val operandsA = Seq.fill(p.iq)(Module(new OperandEntry(p)))
  val operandsB = Seq.fill(p.iq)(Module(new OperandEntry(p)))
  val qa = VecInit(operandsA.map(_.io.data)); val qb = VecInit(operandsB.map(_.io.data))
  val qar = VecInit(operandsA.map(_.io.ready)); val qbr = VecInit(operandsB.map(_.io.ready))
  val xv = RegInit(false.B)
  val xdWord = Module(new LocalWord((new Decoded).getWidth)); val xpcWord = Module(new LocalWord(32))
  val xtWord = Module(new LocalWord(p.tagBits)); val xaWord = Module(new LocalWord(32)); val xbWord = Module(new LocalWord(32))
  val xnWord = Module(new LocalWord(32)); val xhWord = Module(new LocalWord(2))
  val addressWord = Module(new LocalAddress(p.parallelDispatchAddress,p.debug))
  val xd = xdWord.io.value.asTypeOf(new Decoded); val xpc = xpcWord.io.value
  val xt = xtWord.io.value; val xa = xaWord.io.value; val xb = xbWord.io.value
  val xnext = xnWord.io.value; val xhistory = xhWord.io.value
  alu.io.d := xd; alu.io.pc := xpc; alu.io.a := xa; alu.io.b := xb
  val retire = Wire(Bool()); val flush = Wire(Bool())
  val checkpointHeads = Seq.fill(p.checkpoints)(Module(new LocalCounter(p.tagBits)))
  checkpointHeads.foreach { c => c.io.step := retire; c.io.clear := flush && !p.earlyRecovery.B }
  val recoveryTag = Reg(UInt(p.tagBits.W)); val recoveryPC = Reg(UInt(32.W))
  val recoveryValid = RegInit(false.B)
  val recoveryCheckpoint = Reg(UInt(p.checkpoints.W))
  def before(a: UInt,b: UInt): Bool = Mux(wrapped(a) === wrapped(b),a < b,!wrapped(a))
  val recoveryMask = RegInit(0.U(p.rob.W))
  // Prepare for the boundary that recoveryTag will contain next cycle.
  // Circular distance handles free tags allocated at this same edge.
  val boundaryDistance = (xt-head)(p.tagBits-1,0)
  recoveryMask := VecInit((0 until p.rob).map(i =>
    (i.U(p.tagBits.W)-head)(p.tagBits-1,0) > boundaryDistance)).asUInt
  def younger(tag: UInt): Bool = if(p.registeredSquashMask) recoveryMask(tag) else before(recoveryTag,tag)
  if(p.debug && p.registeredSquashMask) {
    for(i <- 0 until p.rob) {
      when(flush && live(i)) {
        assert(recoveryMask(i) === before(recoveryTag,i.U(p.tagBits.W)),"Registered recovery mask disagrees with live-tag age")
      }
    }
  }
  def survives(tag: UInt): Bool = !flush || (if(p.earlyRecovery) !younger(tag) else false.B)
  val branchMiss = xv && (xd.branch || xd.jal || xd.jalr) && alu.io.next =/= xnext && survives(xt)
  recoveryValid := branchMiss
  when(xv) { recoveryTag := xt; recoveryPC := alu.io.next }
  when(xv && (xd.branch || xd.jal || xd.jalr)) { recoveryCheckpoint := UIntToOH(branchCheckpoint(xt),p.checkpoints) }
  val loadRequests = Module(new LoadQueue(p,p.loadEntries))
  dc.io.candidates := loadRequests.io.candidates
  loadRequests.io.available := dc.io.loadReady; loadRequests.io.live := live.asUInt
  loadRequests.io.head := head
  loadRequests.io.stores := stores.asUInt; loadRequests.io.wrapped := wrapped
  loadRequests.io.squash := flush; loadRequests.io.boundary := recoveryTag; loadRequests.io.squashMask := recoveryMask
  dc.io.squash := flush; dc.io.boundary := recoveryTag; dc.io.wrapped := wrapped; dc.io.squashMask := recoveryMask
  val badAddress = (addressWord.io.value >= "h10000000".U && !(xd.store && addressWord.io.value === "h80000000".U)) ||
    (xd.fn(1,0) === 2.U && addressWord.io.value(1,0) =/= 0.U) || (xd.fn(1,0) === 1.U && addressWord.io.value(0))
  val headStore = count =/= 0.U && atHead(done) && atHead(stores) && !halted
  dc.io.store.valid := headStore
  dc.io.store.bits.addr := retiredStoreAddress; dc.io.store.bits.data := retiredStoreData
  dc.io.store.bits.mask := retiredStoreMask; dc.io.store.bits.write := true.B
  val pendingLoad = loadRequests.io.deq.bits.info
  // LoadQueue owns a still-live ROB entry and filters squash on dequeue.
  if(p.storeEntries > 0) {
    dc.io.req.valid := !headStore && loadRequests.io.deq.valid
    dc.io.req.bits.mem := 0.U.asTypeOf(new MemReq); dc.io.req.bits.mem.addr := loadRequests.io.deq.bits.addr
  } else {
    dc.io.req.valid := headStore || loadRequests.io.deq.valid
    dc.io.req.bits.mem.addr := Mux(headStore,retiredStoreAddress,loadRequests.io.deq.bits.addr)
    dc.io.req.bits.mem.data := retiredStoreData; dc.io.req.bits.mem.mask := retiredStoreMask
    dc.io.req.bits.mem.write := headStore
  }
  dc.io.req.bits.info := loadRequests.io.deq.bits.info
  dc.io.rsp.ready := true.B
  val loadAccept = dc.io.req.fire && !headStore
  val loadReturn = dc.io.rsp.fire
  if(p.debug && p.bankedReturnMatch) {
    val selected = dc.io.loadReturn.get.selected.asUInt
    assert(PopCount(selected) <= 1.U,"Multiple banks selected for one completion")
    assert(selected.orR === loadReturn,"Banked wakeup and cache response handshake differ")
    for(i <- 0 until p.banks) {
      when(selected(i)) { assert(dc.io.loadReturn.get.tags(i) === dc.io.rsp.bits.info.tag,"Selected bank tag differs from response data owner") }
    }
  }
  // A valid dequeue already requires this bank's current admission credit.
  loadRequests.io.deq.ready := (if(p.trustedLoadCredit) true.B else dc.io.req.ready) && !headStore
  if(p.debug && p.trustedLoadCredit) {
    when(dc.io.req.valid) { assert(dc.io.req.ready,"Qualified load offered without cache credit") }
    assert(loadRequests.io.deq.fire === dc.io.req.fire,"Load queue and cache acceptance differ")
  }
  val returned = dc.io.rsp.bits.info
  val shiftedLoad = dc.io.rsp.bits.rsp.data >> Cat(returned.offset,0.U(3.W))
  val originalLoadValue = MuxLookup(returned.fn,shiftedLoad)(Seq(0.U -> Util.sext(shiftedLoad(7,0)),1.U -> Util.sext(shiftedLoad(15,0)),
    4.U -> Cat(0.U(24.W),shiftedLoad(7,0)),5.U -> Cat(0.U(16.W),shiftedLoad(15,0))))
  val loadValues = if(p.loadValueCopies == 1) Seq(if(p.earlyLoadFormat) dc.io.rsp.bits.rsp.data else originalLoadValue) else Seq.fill(p.loadValueCopies) {
    val value = Module(new LocalLoadValue)
    value.io.word := dc.io.rsp.bits.rsp.data; value.io.offset := returned.offset; value.io.fn := returned.fn
    value.io.value
  }
  val loadValue = loadValues.head
  val forwardingMask = Wire(UInt(4.W)); val forwardingData = Wire(UInt(32.W))
  val readMask = (MuxLookup(xd.fn(1,0),15.U(4.W))(Seq(0.U -> 1.U(4.W),1.U -> 3.U(4.W))) << addressWord.io.value(1,0))(3,0)
  val fullyForwarded = (forwardingMask & readMask) === readMask
  val l0Hit = WireDefault(false.B); val l0Word = WireDefault(0.U(32.W))
  // Keep the late retirement handshake out of L0 word update logic.
  // Loads forward from this committed-store stage until L0 catches up.
  val l0Store = Wire(Valid(new MemReq))
  val committedStore = retire && atHead(stores)
  if(p.l0StoreStages == 1) {
    l0Store.valid := RegNext(committedStore,false.B)
    l0Store.bits := RegNext(dc.io.store.bits)
  } else {
    l0Store.valid := committedStore; l0Store.bits := dc.io.store.bits
  }
  val pendingMask = if(p.l0StoreStages == 1) Mux(l0Store.valid &&
    l0Store.bits.addr(31,2) === addressWord.io.value(31,2),l0Store.bits.mask,0.U(4.W)) else 0.U(4.W)
  if(p.l0Entries > 0) {
    val l0 = Module(new WordCache(p.l0Entries,p.l0Replacement))
    l0.io.address := addressWord.io.value; l0Hit := l0.io.hit; l0Word := l0.io.data
    val fill = (0 until p.l0FillStages).foldLeft(dc.io.fill) { (previous,_) =>
      val next = Wire(Valid(new MemReq))
      next.valid := RegNext(previous.valid,false.B); next.bits := RegNext(previous.bits)
      next
    }
    l0.io.fill.valid := fill.valid
    l0.io.fill.bits.address := fill.bits.addr
    l0.io.fill.bits.data := fill.bits.data
    l0.io.store := l0Store
  }
  val bypassLoad = xv && xd.load && !badAddress && (fullyForwarded || l0Hit)
  loadRequests.io.enq.valid := xv && xd.load && !badAddress && !fullyForwarded && !l0Hit && survives(xt)
  loadRequests.io.enq.bits.addr := addressWord.io.value
  loadRequests.io.enq.bits.info.tag := xt; loadRequests.io.enq.bits.info.fn := xd.fn
  loadRequests.io.enq.bits.info.offset := addressWord.io.value(1,0)
  loadRequests.io.enq.bits.info.prefetch := false.B
  val matchingStores = (0 until p.storeCapacity).map(i => storeLive(i) && done(storeOwner(i)) && before(storeOwner(i),xt) && storeAddr(i)(31,2) === addressWord.io.value(31,2))
  val forwarding = (0 until 4).map(b => {
    val picked = Util.orderTreeWrapped((0 until p.storeCapacity).map(i => (matchingStores(i) && storeMask(i)(b),storeOwner(i),storeData(i)(8*b+7,8*b))),(0 until p.storeCapacity).map(i => wrapped(storeOwner(i))),true)
    (picked._1,picked._3)
  })
  forwardingMask := VecInit(forwarding.map(_._1)).asUInt | pendingMask
  forwardingData := Cat((0 until 4).reverse.map(b =>
    Mux(forwarding(b)._1,forwarding(b)._2,l0Store.bits.data(8*b+7,8*b))))
  // Fully forwarded/L0 loads complete here. A partial overlap on a cache
  // miss waits for older stores in the load queue, then reads coherent bytes.
  // No 32-bit speculative store snapshot travels through every cache MSHR.
  loadRequests.io.enq.bits.info.waitForStores := (forwardingMask & readMask).orR
  val bypassWord = Cat((0 until 4).reverse.map(b => Mux(forwardingMask(b),forwardingData(8*b+7,8*b),l0Word(8*b+7,8*b))))
  val forwardShifted = bypassWord >> Cat(addressWord.io.value(1,0),0.U(3.W))
  val forwardValue = MuxLookup(xd.fn,forwardShifted)(Seq(0.U -> Util.sext(forwardShifted(7,0)),1.U -> Util.sext(forwardShifted(15,0)),
    4.U -> Cat(0.U(24.W),forwardShifted(7,0)),5.U -> Cat(0.U(16.W),forwardShifted(15,0))))
  md.io.req.valid := xv && xd.muldiv && survives(xt)
  md.io.req.bits.tag := xt; md.io.req.bits.a := xa; md.io.req.bits.b := xb; md.io.req.bits.fn := xd.fn
  md.io.kill := flush && (if(p.earlyRecovery) younger(md.io.activeTag) else true.B)
  // Reserve a credit for the current execution load before issuing the next
  // one. Execution then always drains, and its wide payload needs no stall
  // feedback or late load-hit permission.
  val loadCredit = loadRequests.io.freeCount > Mux(xv && xd.load,1.U,0.U)
  val xComplete = xv; val xspace = true.B
  if(p.debug) {
    when(xv && xd.load && !badAddress && !bypassLoad && survives(xt)) { assert(loadRequests.io.enq.ready,"Execution load lacks its reserved credit") }
    when(xv && xd.muldiv && survives(xt)) { assert(md.io.req.ready,"Execution MDU lacks its issue reservation") }
  }
  val cdb = Wire(Vec(3,Valid(new Completion(p))))
  cdb(0).valid := xv && (!xd.load || badAddress || bypassLoad) && !xd.muldiv && !xd.store && survives(xt)
  cdb(0).bits.tag := xt; cdb(0).bits.data := Mux(bypassLoad,forwardValue,alu.io.result)
  cdb(1).valid := loadReturn && survives(returned.tag)
  cdb(1).bits.tag := returned.tag; cdb(1).bits.data := loadValue
  cdb(2).valid := md.io.rsp.valid && survives(md.io.rsp.bits.tag); cdb(2).bits := md.io.rsp.bits
  resultWords.zipWithIndex.foreach { case (r,index) =>
    // Match each early owner locally, including recovery permission for this
    // fixed ROB row. The selected tag need not feed a global valid gate.
    val raw = Seq(xv && (!xd.load || badAddress || bypassLoad) && !xd.muldiv && !xd.store,
      loadReturn,md.io.rsp.valid)
    r.io.valid := VecInit((0 until 3).map(k => if(k == 1 && p.bankedReturnMatch) survives(index.U(p.tagBits.W))
      else if(p.localResultQualification) raw(k) && survives(index.U(p.tagBits.W)) else cdb(k).valid)).asUInt
    r.io.tags := VecInit(cdb.map(_.bits.tag)); r.io.data := VecInit(cdb.map(_.bits.data))
    if(p.loadValueCopies > 1) { r.io.data(1) := loadValues(index % p.loadValueCopies) }
    r.io.loadReturn.foreach(_ := dc.io.loadReturn.get)
    r.io.finalized.foreach(_ := done(index))
    if(p.debug && (p.bankedReturnMatch || p.localResultQualification)) {
      assert(r.io.completed === cdb.map(c => c.valid && c.bits.tag === index.U(p.tagBits.W)).reduce(_ || _),"Banked ROB completion differs from selected completion")
    }
  }
  val preparedCdb = Wire(Vec(3,Valid(new Completion(p))))
  preparedCdb := cdb
  preparedCdb(0).valid := xv && (!xd.load || badAddress || bypassLoad) && !xd.muldiv && !xd.store
  preparedCdb(1).valid := loadReturn
  if(p.debug) { when(loadReturn) { assert(live(returned.tag),"Cache response lost its ROB owner") } }
  preparedCdb(2).valid := md.io.rsp.valid
  // Surviving instructions can depend only on older producers. Recovery
  // blocks issue/dispatch publication and kills younger entries, so operand
  // preparation need not wait for the squash boundary comparison.
  def bypass(tag: UInt, value: UInt): UInt = MuxCase(value,(0 until 3).map(k => (preparedCdb(k).valid && preparedCdb(k).bits.tag === tag) -> preparedCdb(k).bits.data))
  def wake(tag: UInt): Bool = preparedCdb.map(c => c.valid && c.bits.tag === tag).reduce(_ || _)
  for(i <- 0 until p.rob) {
    when(resultWords(i).io.completed) { done(i) := true.B }
    when(xv && xt === i.U && !xd.load && !xd.muldiv) {
      done(i) := true.B; actual(i) := alu.io.next; taken(i) := alu.io.taken
    }
    when(xv && xt === i.U && (xd.load || xd.store) && badAddress) { fault(i) := true.B }
  }
  val eligible = Wire(Vec(p.iq,Bool())); val issueAllowed = Wire(Vec(p.iq,Bool()))
  for(i <- 0 until p.iq) {
    val olderStore = (0 until p.rob).map(j => live(j) && stores(j) && !done(j) && before(j.U(p.tagBits.W),qtag(i))).reduce(_ || _)
    issueAllowed(i) := qvalid(i) &&
      (!qd(i).load || (!olderStore && loadCredit)) && (!qd(i).muldiv || (md.io.req.ready && !(xv && xd.muldiv)))
    eligible(i) := (if(p.localIssueEligibility) issueAllowed(i) && qar(i) && qbr(i) else
      qvalid(i) && qar(i) && qbr(i) &&
        (!qd(i).load || (!olderStore && loadCredit)) && (!qd(i).muldiv || (md.io.req.ready && !(xv && xd.muldiv))))
  }
  def oldest(xs: Seq[(Bool,UInt,UInt)]): (Bool,UInt,UInt) = {
    if(xs.size == 1) xs.head else {
      val (left,right) = xs.splitAt(xs.size/2); val a = oldest(left); val b = oldest(right)
      val pickA = a._1 && (!b._1 || a._2 < b._2)
      (a._1 || b._1,Mux(pickA,a._2,b._2),Mux(pickA,a._3,b._3))
    }
  }
  val olderMasks = if(p.issueAgeMatrix) {
    val ages = Module(new IssueAge(p.iq))
    ages.io.prepare := ~qvalid.asUInt & UIntToOH(PriorityEncoder(~qvalid.asUInt),p.iq)
    if(p.debug) {
      for(i <- 0 until p.iq; j <- 0 until p.iq if i != j) {
        when(qvalid(i) && qvalid(j)) {
          assert(ages.io.older(i)(j) === before(qtag(j),qtag(i)),"IQ pair age disagrees with live ROB order")
        }
      }
    }
    ages.io.older.toSeq
  } else (0 until p.iq).map(i => VecInit((0 until p.iq).map(j => if(i==j) false.B else before(qtag(j),qtag(i)))).asUInt)
  val winner = if(p.issueAgeMatrix) {
    val picked = VecInit((0 until p.iq).map(i => eligible(i) && !(olderMasks(i) & eligible.asUInt).orR))
    val selected = OHToUInt(picked.asUInt)
    if(p.debug) {
      val legacy = Util.orderTreeWrapped((0 until p.iq).map(i => (eligible(i),qtag(i),i.U(log2Ceil(p.iq).W))),(0 until p.iq).map(i => wrapped(qtag(i))),false)
      assert(PopCount(picked) <= 1.U,"IQ age matrix selected multiple instructions")
      assert(picked.asUInt.orR === legacy._1,"IQ age matrix changed issue availability")
      when(legacy._1) { assert(selected === legacy._3,"IQ age matrix changed issue order") }
    }
    (picked.asUInt.orR,Util.select(picked.toSeq,qtag.toSeq),selected)
  } else Util.orderTreeWrapped((0 until p.iq).map(i => (eligible(i),qtag(i),i.U(log2Ceil(p.iq).W))),(0 until p.iq).map(i => wrapped(qtag(i))),false)
  def scheduled(xs: Seq[UInt], fallback: UInt): UInt = {
    val width = fallback.getWidth
    Cat((0 until width by p.issueSliceBits).reverse.map(low => {
      val high = math.min(width-1,low+p.issueSliceBits-1)
      val choice = Module(new IssueChoice(high-low+1,p.iq,p.localIssueEligibility))
      choice.io.eligible := eligible.asUInt; choice.io.older := VecInit(olderMasks)
      choice.io.allowed.foreach(_ := issueAllowed.asUInt)
      choice.io.readyA.foreach(_ := qar.asUInt); choice.io.readyB.foreach(_ := qbr.asUInt)
      choice.io.words := VecInit(xs.map(_(high,low))); choice.io.fallback := fallback(high,low)
      choice.io.value
    }))
  }
  val issue = winner._1 && xspace && !flush && !halted
  val qi = winner._3
  when(xComplete) { xv := false.B }
  when(issue) {
    xv := true.B
    qvalid(qi) := false.B
  }
  val free = PriorityEncoder(~qvalid.asUInt)
  decoder.io.inst := fetch.io.out.bits.inst
  val d = decoder.io.d
  val dispatch = fetch.io.out.fire
  fetch.io.out.ready := count < p.rob.U && !qvalid.asUInt.andR && !flush && !halted &&
    (!(d.branch || d.jal || d.jalr) || checkpointAvailable) && (!d.store || storeSpace)
  def source(rs: UInt, used: Bool, prepareAddress: Boolean = false, loadCopy: Int = 0): (Bool,UInt,UInt,Option[UInt]) = {
    val tag = mapping(rs); val waiting = used && rs =/= 0.U && mapped(rs)
    val operand = Module(new SourceOperand(p,prepareAddress))
    operand.io.used := used && rs =/= 0.U; operand.io.waiting := waiting; operand.io.completed := done(tag)
    operand.io.tag := tag; operand.io.architectural := Util.choose(rs,arch.toSeq); operand.io.producer := Util.choose(tag,values.toSeq)
    operand.io.completions := preparedCdb
    if(p.loadValueCopies > 1) { operand.io.completions(1).bits.data := loadValues(loadCopy % p.loadValueCopies) }
    operand.io.loadReturn.foreach(_ := dc.io.loadReturn.get)
    operand.io.immediate.foreach(_ := d.imm)
    (operand.io.ready,operand.io.data,tag,operand.io.address)
  }
  // Only stores reserve address/data slots; unrelated ROB instructions do
  // not carry 68 unused payload bits. Squash releases only younger owners.
  for(i <- 0 until p.storeCapacity) {
    when(xv && xd.store && storeLive(i) && storeOwner(i) === xt) {
      storeAddr(i) := addressWord.io.value
      storeData(i) := (xb << Cat(addressWord.io.value(1,0),0.U(3.W)))(31,0)
      storeMask(i) := (MuxLookup(xd.fn,15.U(4.W))(Seq(0.U -> 1.U(4.W),1.U -> 3.U(4.W))) << addressWord.io.value(1,0))(3,0)
    }
    when(retire && atHead(stores) && storeOwner(i) === head) { storeLive(i) := false.B }
    when(dispatch && d.store && storeFree === i.U) { storeLive(i) := true.B; storeOwner(i) := tail }
    when(flush && storeLive(i) && (if(p.earlyRecovery) younger(storeOwner(i)) else true.B)) { storeLive(i) := false.B }
  }
  val s1 = source(d.rs1,d.use1,p.parallelDispatchAddress); val s2 = source(d.rs2,d.use2,loadCopy=1)
  val unknownStore = (0 until p.rob).map(i => live(i) && stores(i) && !done(i)).reduce(_ || _)
  val direct = dispatch && !winner._1 && xspace && s1._1 && s2._1 &&
    (!d.load || (!unknownStore && loadCredit)) && (!d.muldiv || (md.io.req.ready && !(xv && xd.muldiv)))
  when(direct) { xv := true.B }
  // Wide execution payload preparation does not depend on recovery permission.
  Seq(xdWord,xpcWord,xtWord,xaWord,xbWord,xnWord,xhWord).foreach(_.io.prepare := xspace)
  val preparedDecoded = scheduled(qd.toSeq.map(_.asUInt),d.asUInt).asTypeOf(new Decoded)
  xdWord.io.data := preparedDecoded.asUInt
  xpcWord.io.data := scheduled(qpc.toSeq,fetch.io.out.bits.pc)
  xtWord.io.data := scheduled(qtag.toSeq,tail)
  val preparedA = scheduled(qa.toSeq,s1._2)
  xaWord.io.data := preparedA
  addressWord.io.prepare := xspace; addressWord.io.base := preparedA; addressWord.io.immediate := preparedDecoded.imm
  addressWord.io.direct.foreach { direct =>
    direct.valid := !eligible.asUInt.orR; direct.bits := s1._4.get
  }
  xbWord.io.data := scheduled(qb.toSeq,s2._2)
  xnWord.io.data := scheduled(qnext.toSeq,fetch.io.out.bits.next)
  xhWord.io.data := scheduled(qhistory.toSeq,fetch.io.out.bits.history)
  when(dispatch) {
    live(tail) := true.B; done(tail) := false.B
    tail := tail+1.U
    qvalid(free) := !direct
  }
  // Prepare empty slots regardless of permission to publish their valid bit.
  for(i <- 0 until p.rob) {
    when(!live(i) && tail === i.U) {
      fault(i) := d.illegal; rd(i) := d.rd; writes(i) := d.writes && d.rd =/= 0.U
      if(!p.earlyRecovery) { predicted(i) := fetch.io.out.bits.next }
      control(i) := d.branch || d.jal || d.jalr; conditional(i) := d.branch; stores(i) := d.store
      calls(i) := (d.jal || d.jalr) && (d.rd === 1.U || d.rd === 5.U)
      returns(i) := d.jalr && (d.rs1 === 1.U || d.rs1 === 5.U) && d.rd =/= d.rs1
      branchCheckpoint(i) := freeCheckpoint
    }
  }
  for(i <- 0 until p.iq) {
    for((op,source) <- Seq((operandsA(i),s1),(operandsB(i),s2))) {
      op.io.prepare := !qvalid(i) && free === i.U
      op.io.initialData := source._2; op.io.initialTag := source._3; op.io.initialReady := source._1
      op.io.completions := preparedCdb
      if(p.loadValueCopies > 1) { op.io.completions(1).bits.data := loadValues(i % p.loadValueCopies) }
      op.io.loadReturn.foreach(_ := dc.io.loadReturn.get)
    }
    when(!qvalid(i) && free === i.U) {
      qd(i) := d; qpc(i) := fetch.io.out.bits.pc; qtag(i) := tail
      qnext(i) := fetch.io.out.bits.next; qhistory(i) := fetch.io.out.bits.history
    }
  }
  retire := count =/= 0.U && atHead(done) && !halted && (!atHead(stores) || (if(p.storeEntries > 0) dc.io.storeReady else dc.io.req.ready))
  // Refresh the owner selection for the head that will exist after this
  // edge. A newly dispatched store cannot be done before this catches up.
  val nextRetirementTag = Mux(retire,head+1.U,head)
  storeHeadSelect := VecInit((0 until p.storeCapacity).map(i => storeLive(i) && storeOwner(i) === nextRetirementTag)).asUInt
  if(p.debug) { when(headStore) { assert(PopCount(storeHeadSelect) === 1.U,"Retiring store lacks its prepared owner selection") } }
  flush := (if(p.earlyRecovery) recoveryValid else retire && atHead(control) && atHead(actual) =/= atHead(predicted))
  fetch.io.redirect.valid := (if(p.fastRedirect && p.earlyRecovery) branchMiss else flush)
  fetch.io.redirect.bits := (if(p.fastRedirect && p.earlyRecovery) alu.io.next else if(p.earlyRecovery) recoveryPC else atHead(actual))
  val committedTraining = Wire(new Training)
  // Calls already produce their return PC in the value array.
  committedTraining.pc := retiredValue-4.U; committedTraining.target := retiredStoreAddress
  committedTraining.taken := atHead(taken); committedTraining.conditional := atHead(conditional)
  committedTraining.call := atHead(calls); committedTraining.ret := atHead(returns)
  committedTraining.history := 0.U
  val trainNow = retire && atHead(control)
  fetch.io.commit.valid := RegNext(trainNow,false.B)
  fetch.io.commit.bits := RegNext(committedTraining)
  val executedTraining = Wire(new Training)
  executedTraining.pc := xpc
  executedTraining.target := Mux(xd.branch || xd.jal,alu.io.pc+xd.imm,addressWord.io.value)
  executedTraining.taken := alu.io.taken; executedTraining.conditional := xd.branch
  executedTraining.call := (xd.jal || xd.jalr) && (xd.rd === 1.U || xd.rd === 5.U)
  executedTraining.ret := xd.jalr && (xd.rs1 === 1.U || xd.rs1 === 5.U) && xd.rd =/= xd.rs1
  executedTraining.history := xhistory
  val trainExecution = xv && (xd.branch || xd.jal || xd.jalr) && survives(xt)
  fetch.io.train.valid := RegNext(trainExecution,false.B)
  fetch.io.train.bits := RegNext(executedTraining)
  when(retire) {
    assert(!atHead(fault),"Retiring faulting instruction")
    live(head) := false.B; head := head+1.U
    headSelect := Cat(headSelect(p.rob-2,0),headSelect(p.rob-1))
    wrapped := Mux(headSelect(p.rob-1),0.U,wrapped | headSelect)
    when(atHead(stores) && retiredStoreAddress === "h80000000".U) { halted := true.B }
  }
  for(r <- 1 until 32) {
    architecturalWords(r-1).io.commit := retire && atHead(writes)
    architecturalWords(r-1).io.rd := atHead(rd); architecturalWords(r-1).io.data := retiredValue
    val ren = renameEntries(r-1).io
    ren.dispatch := dispatch; ren.dispatchWrites := d.writes; ren.dispatchRd := d.rd; ren.dispatchTag := tail
    ren.retire := retire; ren.retireWrites := atHead(writes); ren.retireRd := atHead(rd); ren.retireTag := head
    ren.checkpointHeads := VecInit(checkpointHeads.map(_.io.value)); ren.checkpointValid := cpValid.asUInt
    ren.freeCheckpoint := freeCheckpoint; ren.restore := recoveryCheckpoint; ren.squash := flush
  }
  for(c <- 0 until p.checkpoints) {
    when(dispatch && (d.branch || d.jal || d.jalr) && freeCheckpoint === c.U) { cpValid(c) := true.B; cpOwner(c) := tail }
    when(xv && (xd.branch || xd.jal || xd.jalr) && alu.io.next === xnext && branchCheckpoint(xt) === c.U) { cpValid(c) := false.B }
    when(flush && (if(p.earlyRecovery) (younger(cpOwner(c)) || cpOwner(c) === recoveryTag) else true.B)) { cpValid(c) := false.B }
  }
  when(dispatch =/= retire) { count := Mux(dispatch,count+1.U,count-1.U) }
  when(flush) {
    if(p.earlyRecovery) {
      tail := recoveryTag+1.U; count := ((recoveryTag-head)(p.tagBits-1,0)+&1.U)-retire.asUInt
      when(younger(xt)) { xv := false.B }
      for(i <- 0 until p.rob) { when(younger(i.U(p.tagBits.W))) { live(i) := false.B; done(i) := false.B } }
      for(i <- 0 until p.iq) { when(younger(qtag(i))) { qvalid(i) := false.B } }
    } else {
      head := 0.U; headSelect := 1.U; wrapped := 0.U; tail := 0.U; count := 0.U; xv := false.B
      for(i <- 0 until p.rob) { live(i) := false.B; done(i) := false.B }
      for(i <- 0 until p.iq) { qvalid(i) := false.B }
    }
  }
  if(p.debug) {
  val events = Seq(retire,issue,dispatch,flush,!fetch.io.out.valid,count === p.rob.U,qvalid.asUInt.andR,
    xv && !xComplete,loadAccept,loadReturn,headStore && !dc.io.storeReady,
    direct,count =/= 0.U && !atHead(done),xspace && !winner._1 && !direct,
    loadRequests.io.deq.valid && !dc.io.req.ready,bypassLoad,
    qvalid.asUInt.orR && !eligible.asUInt.orR,retire && atHead(conditional))
  val counters = events.map(e => { val n = RegInit(0.U(32.W)); when(e) { n := n+1.U }; n })
  when(retire && atHead(stores) && retiredStoreAddress === "h80000000".U) {
    printf(p"Tier2 retired=${counters(0)} issued=${counters(1)} dispatched=${counters(2)} flush=${counters(3)} fetch_empty=${counters(4)} rob_full=${counters(5)} iq_full=${counters(6)} ex_stall=${counters(7)} loads=${counters(8)} returns=${counters(9)} store_stall=${counters(10)}\n")
    printf(p"Details direct=${counters(11)} head_wait=${counters(12)} issue_empty=${counters(13)} load_wait=${counters(14)} bypass_loads=${counters(15)} iq_wait=${counters(16)} conditional=${counters(17)}\n")
  }
  }
}

class StudentTop(p: Config) extends Module {
  override def desiredName = "student_top"
  val araddr = IO(Output(UInt(32.W))); val arvalid = IO(Output(Bool())); val arready = IO(Input(Bool()))
  val rdata = IO(Input(UInt(32.W))); val rresp = IO(Input(UInt(2.W))); val rvalid = IO(Input(Bool())); val rready = IO(Output(Bool()))
  val awaddr = IO(Output(UInt(32.W))); val awvalid = IO(Output(Bool())); val awready = IO(Input(Bool()))
  val wdata = IO(Output(UInt(32.W))); val wstrb = IO(Output(UInt(4.W))); val wvalid = IO(Output(Bool())); val wready = IO(Input(Bool()))
  val bresp = IO(Input(UInt(2.W))); val bvalid = IO(Input(Bool())); val bready = IO(Output(Bool()))
  val c = Module(new Core(p)); val a = c.io.axi
  araddr := a.araddr; arvalid := a.arvalid; a.arready := arready; a.rdata := rdata; a.rresp := rresp; a.rvalid := rvalid; rready := a.rready
  awaddr := a.awaddr; awvalid := a.awvalid; a.awready := awready; wdata := a.wdata; wstrb := a.wstrb; wvalid := a.wvalid; a.wready := wready
  a.bresp := bresp; a.bvalid := bvalid; bready := a.bready
}

object Generate extends App {
  val options = args.grouped(2).map { case Array(k,v) => k -> v }.toMap
  def n(key: String, default: Int): Int = options.get(key).map(_.toInt).getOrElse(default)
  val supported = Set("--banked-load-payload","--banked-return-match","--banks","--btb-entries","--cache-hierarchy","--checkpoints","--dc-bytes","--debug","--div-step-bits","--div-result-cache","--early-recovery","--fast-redirect","--fetch-head-slice-bits","--history-bits","--ic-bytes","--iq","--issue-width","--issue-slice-bits","--l0-entries","--l0-fill-stages","--l0-replacement","--l0-store-stages","--line-bytes","--load-entries","--local-issue-eligibility","--parallel-dispatch-address","--prefetch","--prefetch-train-stages","--ram-read-ahead","--ras-write-stages","--registered-squash-mask","--rob","--store-entries","--store-slots","--trusted-load-credit","--ways","--out")
  val supportedExtra = supported ++ Set("--cached-fetch-head","--result-slice-bits","--issue-age-matrix","--local-result-qualification","--prepared-load-result","--load-value-copies","--early-load-format","--cached-fetch-instruction","--separate-operand-ready")
  require(options.keySet.subsetOf(supportedExtra),"Unknown CPU parameter: " + (options.keySet -- supportedExtra).mkString(", "))
  require(n("--issue-width",1) == 1,"Only single issue is supported")
  val defaults = Config()
  val p = Config(rob=n("--rob",defaults.rob),iq=n("--iq",defaults.iq),icBytes=n("--ic-bytes",defaults.icBytes),dcBytes=n("--dc-bytes",defaults.dcBytes),
    lineBytes=n("--line-bytes",defaults.lineBytes),ways=n("--ways",defaults.ways),debug=n("--debug",if(defaults.debug) 1 else 0) != 0,banks=n("--banks",defaults.banks),earlyRecovery=n("--early-recovery",if(defaults.earlyRecovery) 1 else 0) != 0,
    prefetch=n("--prefetch",if(defaults.prefetch) 1 else 0) != 0,btbEntries=n("--btb-entries",defaults.btbEntries),historyBits=n("--history-bits",defaults.historyBits),l0Entries=n("--l0-entries",defaults.l0Entries),
    storeEntries=n("--store-entries",defaults.storeEntries),checkpoints=n("--checkpoints",defaults.checkpoints),fastRedirect=n("--fast-redirect",if(defaults.fastRedirect) 1 else 0) != 0,storeSlots=n("--store-slots",defaults.storeSlots),loadEntries=n("--load-entries",defaults.loadEntries),l0FillStages=n("--l0-fill-stages",defaults.l0FillStages),l0Replacement=n("--l0-replacement",defaults.l0Replacement),ramReadAhead=n("--ram-read-ahead",if(defaults.ramReadAhead) 1 else 0) != 0,l0StoreStages=n("--l0-store-stages",defaults.l0StoreStages),bankedLoadPayload=n("--banked-load-payload",if(defaults.bankedLoadPayload) 1 else 0) != 0,cacheHierarchy=n("--cache-hierarchy",if(defaults.cacheHierarchy) 1 else 0) != 0,prefetchTrainStages=n("--prefetch-train-stages",defaults.prefetchTrainStages),trustedLoadCredit=n("--trusted-load-credit",if(defaults.trustedLoadCredit) 1 else 0) != 0,rasWriteStages=n("--ras-write-stages",defaults.rasWriteStages),registeredSquashMask=n("--registered-squash-mask",if(defaults.registeredSquashMask) 1 else 0) != 0,
    issueSliceBits=n("--issue-slice-bits",defaults.issueSliceBits),bankedReturnMatch=n("--banked-return-match",if(defaults.bankedReturnMatch) 1 else 0) != 0,
    localIssueEligibility=n("--local-issue-eligibility",if(defaults.localIssueEligibility) 1 else 0) != 0,
    fetchHeadSliceBits=n("--fetch-head-slice-bits",defaults.fetchHeadSliceBits),divStepBits=n("--div-step-bits",defaults.divStepBits),
    divResultCache=n("--div-result-cache",if(defaults.divResultCache) 1 else 0) != 0,
    parallelDispatchAddress=n("--parallel-dispatch-address",if(defaults.parallelDispatchAddress) 1 else 0) != 0,
    cachedFetchHead=n("--cached-fetch-head",if(defaults.cachedFetchHead) 1 else 0) != 0,
    resultSliceBits=n("--result-slice-bits",defaults.resultSliceBits),
    issueAgeMatrix=n("--issue-age-matrix",if(defaults.issueAgeMatrix) 1 else 0) != 0,
    localResultQualification=n("--local-result-qualification",if(defaults.localResultQualification) 1 else 0) != 0,
    preparedLoadResult=n("--prepared-load-result",if(defaults.preparedLoadResult) 1 else 0) != 0,
    loadValueCopies=n("--load-value-copies",defaults.loadValueCopies),
    earlyLoadFormat=n("--early-load-format",if(defaults.earlyLoadFormat) 1 else 0) != 0,
    cachedFetchInstruction=n("--cached-fetch-instruction",if(defaults.cachedFetchInstruction) 1 else 0) != 0,
    separateOperandReady=n("--separate-operand-ready",if(defaults.separateOperandReady) 1 else 0) != 0)
  _root_.circt.stage.ChiselStage.emitSystemVerilogFile(new StudentTop(p), Array("--target-dir", options.getOrElse("--out","rtl")),
    Array("--disable-all-randomization", "--lowering-options=disallowLocalVariables,disallowPackedArrays"))
}
