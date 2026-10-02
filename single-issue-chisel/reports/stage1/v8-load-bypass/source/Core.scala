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
  val count = RegInit(0.U((p.tagBits+1).W))
  val live = RegInit(VecInit(Seq.fill(p.rob)(false.B)))
  val generations = RegInit(VecInit(Seq.fill(p.rob)(0.U(8.W))))
  val done = RegInit(VecInit(Seq.fill(p.rob)(false.B)))
  val fault = Reg(Vec(p.rob,Bool()))
  val values = Reg(Vec(p.rob,UInt(32.W)))
  val rd = Reg(Vec(p.rob,UInt(5.W))); val writes = Reg(Vec(p.rob,Bool()))
  val pc = Reg(Vec(p.rob,UInt(32.W))); val inst = Reg(Vec(p.rob,UInt(32.W)))
  val predicted = Reg(Vec(p.rob,UInt(32.W))); val actual = Reg(Vec(p.rob,UInt(32.W)))
  val control = Reg(Vec(p.rob,Bool())); val conditional = Reg(Vec(p.rob,Bool()))
  val taken = Reg(Vec(p.rob,Bool())); val calls = Reg(Vec(p.rob,Bool())); val returns = Reg(Vec(p.rob,Bool()))
  val stores = Reg(Vec(p.rob,Bool())); val storeAddr = Reg(Vec(p.rob,UInt(32.W)))
  val storeData = Reg(Vec(p.rob,UInt(32.W))); val storeMask = Reg(Vec(p.rob,UInt(4.W)))
  val arch = RegInit(VecInit(Seq.fill(32)(0.U(32.W))))
  val mapped = RegInit(VecInit(Seq.fill(32)(false.B))); val mapping = Reg(Vec(32,UInt(p.tagBits.W)))
  val halted = RegInit(false.B)
  val qvalid = RegInit(VecInit(Seq.fill(p.iq)(false.B)))
  val qd = Reg(Vec(p.iq,new Decoded)); val qpc = Reg(Vec(p.iq,UInt(32.W)))
  val qtag = Reg(Vec(p.iq,UInt(p.tagBits.W)))
  val qa = Reg(Vec(p.iq,UInt(32.W))); val qb = Reg(Vec(p.iq,UInt(32.W)))
  val qat = Reg(Vec(p.iq,UInt(p.tagBits.W))); val qbt = Reg(Vec(p.iq,UInt(p.tagBits.W)))
  val qar = Reg(Vec(p.iq,Bool())); val qbr = Reg(Vec(p.iq,Bool()))
  val xv = RegInit(false.B); val xd = Reg(new Decoded); val xpc = Reg(UInt(32.W))
  val xt = Reg(UInt(p.tagBits.W)); val xa = Reg(UInt(32.W)); val xb = Reg(UInt(32.W))
  alu.io.d := xd; alu.io.pc := xpc; alu.io.a := xa; alu.io.b := xb
  val retire = Wire(Bool()); val flush = Wire(Bool())
  val recoveryTag = Reg(UInt(p.tagBits.W)); val recoveryPC = Reg(UInt(32.W))
  val recoveryValid = RegInit(false.B)
  def younger(tag: UInt): Bool = (tag-head)(p.tagBits-1,0) > (recoveryTag-head)(p.tagBits-1,0)
  def survives(tag: UInt): Bool = !flush || (if(p.earlyRecovery) !younger(tag) else false.B)
  recoveryValid := xv && (xd.branch || xd.jal || xd.jalr) && alu.io.next =/= predicted(xt) && survives(xt)
  when(xv) { recoveryTag := xt; recoveryPC := alu.io.next }
  val loadRequests = Module(new Queue(new LoadRequest(p),4,flow=true))
  val badAddress = (alu.io.addr >= "h10000000".U && !(xd.store && alu.io.addr === "h80000000".U)) ||
    (xd.fn(1,0) === 2.U && alu.io.addr(1,0) =/= 0.U) || (xd.fn(1,0) === 1.U && alu.io.addr(0))
  val headStore = count =/= 0.U && done(head) && stores(head) && !halted
  val pendingLoad = loadRequests.io.deq.bits.info
  val staleLoad = !live(pendingLoad.tag) || pendingLoad.epoch =/= generations(pendingLoad.tag) || !survives(pendingLoad.tag)
  dc.io.req.valid := headStore || (loadRequests.io.deq.valid && !staleLoad)
  dc.io.req.bits.mem.addr := Mux(headStore,storeAddr(head),loadRequests.io.deq.bits.addr)
  dc.io.req.bits.mem.data := storeData(head); dc.io.req.bits.mem.mask := storeMask(head)
  dc.io.req.bits.mem.write := headStore; dc.io.req.bits.info := loadRequests.io.deq.bits.info
  dc.io.rsp.ready := true.B
  val loadAccept = dc.io.req.fire && !headStore
  val loadReturn = dc.io.rsp.fire
  loadRequests.io.deq.ready := staleLoad || (dc.io.req.ready && !headStore)
  val returned = dc.io.rsp.bits.info
  val merged = Cat((0 until 4).reverse.map(b => Mux(returned.forwardMask(b),returned.forwardData(8*b+7,8*b),dc.io.rsp.bits.rsp.data(8*b+7,8*b))))
  val shiftedLoad = merged >> Cat(returned.offset,0.U(3.W))
  val loadValue = MuxLookup(returned.fn,shiftedLoad)(Seq(0.U -> Util.sext(shiftedLoad(7,0)),1.U -> Util.sext(shiftedLoad(15,0)),
    4.U -> Cat(0.U(24.W),shiftedLoad(7,0)),5.U -> Cat(0.U(16.W),shiftedLoad(15,0))))
  val forwardingMask = Wire(UInt(4.W)); val forwardingData = Wire(UInt(32.W))
  val readMask = (MuxLookup(xd.fn(1,0),15.U(4.W))(Seq(0.U -> 1.U(4.W),1.U -> 3.U(4.W))) << alu.io.addr(1,0))(3,0)
  val fullyForwarded = (forwardingMask & readMask) === readMask
  val bypassLoad = xv && xd.load && !badAddress && fullyForwarded
  loadRequests.io.enq.valid := xv && xd.load && !badAddress && !fullyForwarded && survives(xt)
  loadRequests.io.enq.bits.addr := alu.io.addr
  loadRequests.io.enq.bits.info.tag := xt; loadRequests.io.enq.bits.info.fn := xd.fn
  loadRequests.io.enq.bits.info.offset := alu.io.addr(1,0); loadRequests.io.enq.bits.info.epoch := generations(xt)
  val storeAges = (0 until p.rob).map(i => (i.U(p.tagBits.W)-head)(p.tagBits-1,0))
  val loadAge = (xt-head)(p.tagBits-1,0)
  val matchingStores = (0 until p.rob).map(i => live(i) && stores(i) && done(i) && storeAges(i) < loadAge && storeAddr(i)(31,2) === alu.io.addr(31,2))
  val forwarding = (0 until 4).map(b => {
    val picked = Util.ageTree((0 until p.rob).map(i => (matchingStores(i) && storeMask(i)(b),storeAges(i),storeData(i)(8*b+7,8*b))),true)
    (picked._1,picked._3)
  })
  forwardingMask := VecInit(forwarding.map(_._1)).asUInt
  forwardingData := Cat(forwarding.reverse.map(_._2))
  loadRequests.io.enq.bits.info.forwardMask := forwardingMask
  loadRequests.io.enq.bits.info.forwardData := forwardingData
  val forwardShifted = forwardingData >> Cat(alu.io.addr(1,0),0.U(3.W))
  val forwardValue = MuxLookup(xd.fn,forwardShifted)(Seq(0.U -> Util.sext(forwardShifted(7,0)),1.U -> Util.sext(forwardShifted(15,0)),
    4.U -> Cat(0.U(24.W),forwardShifted(7,0)),5.U -> Cat(0.U(16.W),forwardShifted(15,0))))
  md.io.req.valid := xv && xd.muldiv && survives(xt)
  md.io.req.bits.tag := xt; md.io.req.bits.a := xa; md.io.req.bits.b := xb; md.io.req.bits.fn := xd.fn
  md.io.kill := flush && (if(p.earlyRecovery) younger(md.io.activeTag) else true.B)
  val xComplete = xv && Mux(xd.load,loadRequests.io.enq.fire || bypassLoad || badAddress,Mux(xd.muldiv,md.io.req.fire,true.B))
  val xspace = !xv || xComplete
  val cdb = Wire(Vec(3,Valid(new Completion(p))))
  cdb(0).valid := xv && (!xd.load || badAddress || bypassLoad) && !xd.muldiv && !xd.store && survives(xt)
  cdb(0).bits.tag := xt; cdb(0).bits.data := Mux(bypassLoad,forwardValue,alu.io.result)
  cdb(1).valid := loadReturn && returned.epoch === generations(returned.tag) && live(returned.tag) && survives(returned.tag)
  cdb(1).bits.tag := returned.tag; cdb(1).bits.data := loadValue
  cdb(2).valid := md.io.rsp.valid && survives(md.io.rsp.bits.tag); cdb(2).bits := md.io.rsp.bits
  def bypass(tag: UInt, value: UInt): UInt = MuxCase(value,(0 until 3).map(k => (cdb(k).valid && cdb(k).bits.tag === tag) -> cdb(k).bits.data))
  def wake(tag: UInt): Bool = cdb.map(c => c.valid && c.bits.tag === tag).reduce(_ || _)
  for(i <- 0 until p.rob) {
    for(k <- 0 until 3) {
      when(cdb(k).valid && cdb(k).bits.tag === i.U) { done(i) := true.B; values(i) := cdb(k).bits.data }
    }
    when(xv && xt === i.U && !xd.load && !xd.muldiv) {
      done(i) := true.B; actual(i) := alu.io.next; taken(i) := alu.io.taken
      storeAddr(i) := Mux(xd.branch || xd.jal,xpc+xd.imm,alu.io.addr)
      storeData(i) := (xb << Cat(alu.io.addr(1,0),0.U(3.W)))(31,0)
      storeMask(i) := (MuxLookup(xd.fn,15.U(4.W))(Seq(0.U -> 1.U(4.W),1.U -> 3.U(4.W))) << alu.io.addr(1,0))(3,0)
    }
    when(xv && xt === i.U && (xd.load || xd.store) && badAddress) { fault(i) := true.B }
  }
  val eligible = Wire(Vec(p.iq,Bool()))
  for(i <- 0 until p.iq) {
    val olderStore = (0 until p.rob).map(j => live(j) && stores(j) && !done(j) && ((j.U(p.tagBits.W)-head)(p.tagBits-1,0) < (qtag(i)-head)(p.tagBits-1,0))).reduce(_ || _)
    eligible(i) := qvalid(i) && (qar(i) || wake(qat(i))) && (qbr(i) || wake(qbt(i))) &&
      (!qd(i).load || (!olderStore && loadRequests.io.enq.ready)) && (!qd(i).muldiv || (md.io.req.ready && !(xv && xd.muldiv)))
    when(!qar(i) && wake(qat(i))) { qar(i) := true.B; qa(i) := bypass(qat(i),qa(i)) }
    when(!qbr(i) && wake(qbt(i))) { qbr(i) := true.B; qb(i) := bypass(qbt(i),qb(i)) }
  }
  def oldest(xs: Seq[(Bool,UInt,UInt)]): (Bool,UInt,UInt) = {
    if(xs.size == 1) xs.head else {
      val (left,right) = xs.splitAt(xs.size/2); val a = oldest(left); val b = oldest(right)
      val pickA = a._1 && (!b._1 || a._2 < b._2)
      (a._1 || b._1,Mux(pickA,a._2,b._2),Mux(pickA,a._3,b._3))
    }
  }
  val winner = oldest((0 until p.iq).map(i => (eligible(i),(qtag(i)-head)(p.tagBits-1,0),i.U(log2Ceil(p.iq).W))))
  val issue = winner._1 && xspace && !flush && !halted
  val qi = winner._3
  when(xComplete) { xv := false.B }
  when(issue) {
    xv := true.B; xd := Util.choose(qi,qd.toSeq); xpc := Util.choose(qi,qpc.toSeq); xt := Util.choose(qi,qtag.toSeq)
    xa := Mux(qar(qi),Util.choose(qi,qa.toSeq),bypass(qat(qi),qa(qi)))
    xb := Mux(qbr(qi),Util.choose(qi,qb.toSeq),bypass(qbt(qi),qb(qi)))
    qvalid(qi) := false.B
  }
  val free = PriorityEncoder(~qvalid.asUInt)
  decoder.io.inst := fetch.io.out.bits.inst
  val d = decoder.io.d
  val dispatch = fetch.io.out.fire
  fetch.io.out.ready := count < p.rob.U && !qvalid.asUInt.andR && !flush && !halted
  def source(rs: UInt, used: Bool): (Bool,UInt,UInt) = {
    val tag = mapping(rs); val waiting = used && rs =/= 0.U && mapped(rs)
    val ready = !waiting || done(tag) || wake(tag)
    val data = Mux(!used || rs === 0.U,0.U,Mux(waiting,bypass(tag,values(tag)),arch(rs)))
    (ready,data,tag)
  }
  val s1 = source(d.rs1,d.use1); val s2 = source(d.rs2,d.use2)
  val unknownStore = (0 until p.rob).map(i => live(i) && stores(i) && !done(i)).reduce(_ || _)
  val direct = dispatch && !winner._1 && xspace && s1._1 && s2._1 &&
    (!d.load || (!unknownStore && loadRequests.io.enq.ready)) && (!d.muldiv || (md.io.req.ready && !(xv && xd.muldiv)))
  when(direct) { xv := true.B; xd := d; xpc := fetch.io.out.bits.pc; xt := tail; xa := s1._2; xb := s2._2 }
  when(dispatch) {
    generations(tail) := generations(tail)+1.U
    fault(tail) := d.illegal
    live(tail) := true.B; done(tail) := false.B; rd(tail) := d.rd; writes(tail) := d.writes && d.rd =/= 0.U
    pc(tail) := fetch.io.out.bits.pc; inst(tail) := fetch.io.out.bits.inst; predicted(tail) := fetch.io.out.bits.next
    control(tail) := d.branch || d.jal || d.jalr; conditional(tail) := d.branch; stores(tail) := d.store
    calls(tail) := (d.jal || d.jalr) && (d.rd === 1.U || d.rd === 5.U)
    returns(tail) := d.jalr && (d.rs1 === 1.U || d.rs1 === 5.U) && d.rd =/= d.rs1
    tail := tail+1.U
    qvalid(free) := !direct; qd(free) := d; qpc(free) := fetch.io.out.bits.pc; qtag(free) := tail
    qa(free) := s1._2; qar(free) := s1._1; qat(free) := s1._3
    qb(free) := s2._2; qbr(free) := s2._1; qbt(free) := s2._3
  }
  retire := count =/= 0.U && done(head) && !halted && (!stores(head) || dc.io.req.ready)
  flush := (if(p.earlyRecovery) recoveryValid else retire && control(head) && actual(head) =/= predicted(head))
  fetch.io.redirect.valid := flush; fetch.io.redirect.bits := (if(p.earlyRecovery) recoveryPC else actual(head))
  fetch.io.train.valid := retire && control(head)
  fetch.io.train.bits.pc := pc(head); fetch.io.train.bits.target := storeAddr(head)
  fetch.io.train.bits.taken := taken(head); fetch.io.train.bits.conditional := conditional(head)
  fetch.io.train.bits.call := calls(head); fetch.io.train.bits.ret := returns(head)
  when(retire) {
    assert(!fault(head),"Retiring faulting instruction")
    live(head) := false.B; head := head+1.U
    when(stores(head) && storeAddr(head) === "h80000000".U) { halted := true.B }
  }
  for(r <- 1 until 32) {
    when(retire && writes(head) && rd(head) === r.U) {
      arch(r) := values(head)
      when(mapped(r) && mapping(r) === head) { mapped(r) := false.B }
    }
    when(dispatch && d.writes && d.rd === r.U) { mapped(r) := true.B; mapping(r) := tail }
    when(flush) {
      if(p.earlyRecovery) {
        val newest = Util.ageTree((0 until p.rob).map(i =>
          (live(i) && !younger(i.U(p.tagBits.W)) && !(retire && head === i.U) && writes(i) && rd(i) === r.U,
           (i.U(p.tagBits.W)-head)(p.tagBits-1,0),i.U(p.tagBits.W))),true)
        mapped(r) := newest._1; mapping(r) := newest._3
      } else { mapped(r) := false.B }
    }
  }
  when(dispatch =/= retire) { count := Mux(dispatch,count+1.U,count-1.U) }
  when(flush) {
    if(p.earlyRecovery) {
      tail := recoveryTag+1.U; count := ((recoveryTag-head)(p.tagBits-1,0)+&1.U)-retire.asUInt
      when(younger(xt)) { xv := false.B }
      for(i <- 0 until p.rob) { when(younger(i.U(p.tagBits.W))) { live(i) := false.B; done(i) := false.B } }
      for(i <- 0 until p.iq) { when(younger(qtag(i))) { qvalid(i) := false.B } }
    } else {
      head := 0.U; tail := 0.U; count := 0.U; xv := false.B
      for(i <- 0 until p.rob) { live(i) := false.B; done(i) := false.B }
      for(i <- 0 until p.iq) { qvalid(i) := false.B }
    }
  }
  if(p.debug) {
  val events = Seq(retire,issue,dispatch,flush,!fetch.io.out.valid,count === p.rob.U,qvalid.asUInt.andR,
    xv && !xComplete,loadAccept,loadReturn,headStore && !dc.io.req.ready)
  val counters = events.map(e => { val n = RegInit(0.U(32.W)); when(e) { n := n+1.U }; n })
  when(retire && stores(head) && storeAddr(head) === "h80000000".U) {
    printf(p"Tier2 retired=${counters(0)} issued=${counters(1)} dispatched=${counters(2)} flush=${counters(3)} fetch_empty=${counters(4)} rob_full=${counters(5)} iq_full=${counters(6)} ex_stall=${counters(7)} loads=${counters(8)} returns=${counters(9)} store_stall=${counters(10)}\n")
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
  val p = Config(rob=n("--rob",16),iq=n("--iq",8),icBytes=n("--ic-bytes",4096),dcBytes=n("--dc-bytes",4096),
    lineBytes=n("--line-bytes",32),ways=n("--ways",2),debug=n("--debug",0) != 0,banks=n("--banks",4),earlyRecovery=n("--early-recovery",1) != 0)
  _root_.circt.stage.ChiselStage.emitSystemVerilogFile(new StudentTop(p), Array("--target-dir", options.getOrElse("--out","rtl")),
    Array("--disable-all-randomization", "--lowering-options=disallowLocalVariables,disallowPackedArrays"))
}
