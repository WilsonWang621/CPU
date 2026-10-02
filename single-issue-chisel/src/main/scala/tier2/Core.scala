package tier2
import chisel3._
import chisel3.util._

class Core(p: Config) extends Module {
  val io = IO(new Bundle { val axi = new Axi })
  val bus = Module(new Bus); val arb = Module(new MemoryArbiter)
  val fetch = Module(new Frontend(p)); val dc = Module(new Cache(p.dcBytes,p.ways,p.lineBytes))
  val md = Module(new MulDiv(p)); val alu = Module(new Execute); val decoder = Module(new Decoder)
  io.axi <> bus.io.axi; bus.io.in <> arb.io.out
  arb.io.clients(0) <> fetch.io.mem; arb.io.clients(1) <> dc.io.mem
  val head = RegInit(0.U(p.tagBits.W)); val tail = RegInit(0.U(p.tagBits.W))
  val count = RegInit(0.U((p.tagBits+1).W))
  val live = RegInit(VecInit(Seq.fill(p.rob)(false.B)))
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
  val loadPending = RegInit(false.B); val loadKilled = RegInit(false.B)
  val loadTag = Reg(UInt(p.tagBits.W)); val loadFn = Reg(UInt(3.W)); val loadOffset = Reg(UInt(2.W))
  val retire = Wire(Bool()); val flush = Wire(Bool())
  val badAddress = (alu.io.addr >= "h10000000".U && !(xd.store && alu.io.addr === "h80000000".U)) ||
    (xd.fn(1,0) === 2.U && alu.io.addr(1,0) =/= 0.U) || (xd.fn(1,0) === 1.U && alu.io.addr(0))
  val headStore = count =/= 0.U && done(head) && stores(head) && !halted
  dc.io.cpu.req.valid := headStore || (xv && xd.load && !badAddress && !loadPending && !flush)
  dc.io.cpu.req.bits.addr := Mux(headStore,storeAddr(head),alu.io.addr)
  dc.io.cpu.req.bits.data := storeData(head); dc.io.cpu.req.bits.mask := storeMask(head)
  dc.io.cpu.req.bits.write := headStore
  dc.io.cpu.rsp.ready := true.B
  val loadAccept = dc.io.cpu.req.fire && !headStore
  val loadReturn = dc.io.cpu.rsp.fire
  when(loadAccept) { loadPending := true.B; loadKilled := false.B; loadTag := xt; loadFn := xd.fn; loadOffset := alu.io.addr(1,0) }
  when(loadReturn) { loadPending := false.B }
  when(flush && loadPending) { loadKilled := true.B }
  val shiftedLoad = dc.io.cpu.rsp.bits.data >> Cat(loadOffset,0.U(3.W))
  val loadValue = MuxLookup(loadFn,shiftedLoad)(Seq(0.U -> Util.sext(shiftedLoad(7,0)),1.U -> Util.sext(shiftedLoad(15,0)),
    4.U -> Cat(0.U(24.W),shiftedLoad(7,0)),5.U -> Cat(0.U(16.W),shiftedLoad(15,0))))
  md.io.req.valid := xv && xd.muldiv && !flush
  md.io.req.bits.tag := xt; md.io.req.bits.a := xa; md.io.req.bits.b := xb; md.io.req.bits.fn := xd.fn
  md.io.kill := flush
  val xComplete = xv && Mux(xd.load,loadAccept || badAddress,Mux(xd.muldiv,md.io.req.ready,true.B))
  val xspace = !xv || xComplete
  val cdb = Wire(Vec(3,Valid(new Completion(p))))
  cdb(0).valid := xv && (!xd.load || badAddress) && !xd.muldiv && !xd.store && !flush
  cdb(0).bits.tag := xt; cdb(0).bits.data := alu.io.result
  cdb(1).valid := loadReturn && !loadKilled && !flush
  cdb(1).bits.tag := loadTag; cdb(1).bits.data := loadValue
  cdb(2).valid := md.io.rsp.valid && !flush; cdb(2).bits := md.io.rsp.bits
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
    val olderStore = (0 until p.rob).map(j => live(j) && stores(j) && ((j.U(p.tagBits.W)-head)(p.tagBits-1,0) < (qtag(i)-head)(p.tagBits-1,0))).reduce(_ || _)
    eligible(i) := qvalid(i) && (qar(i) || wake(qat(i))) && (qbr(i) || wake(qbt(i))) &&
      (!qd(i).load || (!olderStore && !loadPending)) && (!qd(i).muldiv || md.io.req.ready)
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
  when(dispatch) {
    fault(tail) := d.illegal
    live(tail) := true.B; done(tail) := false.B; rd(tail) := d.rd; writes(tail) := d.writes && d.rd =/= 0.U
    pc(tail) := fetch.io.out.bits.pc; inst(tail) := fetch.io.out.bits.inst; predicted(tail) := fetch.io.out.bits.next
    control(tail) := d.branch || d.jal || d.jalr; conditional(tail) := d.branch; stores(tail) := d.store
    calls(tail) := (d.jal || d.jalr) && (d.rd === 1.U || d.rd === 5.U)
    returns(tail) := d.jalr && (d.rs1 === 1.U || d.rs1 === 5.U) && d.rd =/= d.rs1
    tail := tail+1.U
    qvalid(free) := true.B; qd(free) := d; qpc(free) := fetch.io.out.bits.pc; qtag(free) := tail
    qa(free) := s1._2; qar(free) := s1._1; qat(free) := s1._3
    qb(free) := s2._2; qbr(free) := s2._1; qbt(free) := s2._3
  }
  retire := count =/= 0.U && done(head) && !halted && (!stores(head) || dc.io.cpu.req.ready)
  flush := retire && control(head) && actual(head) =/= predicted(head)
  fetch.io.redirect.valid := flush; fetch.io.redirect.bits := actual(head)
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
    when(flush) { mapped(r) := false.B }
  }
  when(dispatch =/= retire) { count := Mux(dispatch,count+1.U,count-1.U) }
  when(flush) {
    head := 0.U; tail := 0.U; count := 0.U; xv := false.B
    for(i <- 0 until p.rob) { live(i) := false.B; done(i) := false.B }
    for(i <- 0 until p.iq) { qvalid(i) := false.B }
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
  _root_.circt.stage.ChiselStage.emitSystemVerilogFile(new StudentTop(Config()), Array("--target-dir", "rtl"),
    Array("--disable-all-randomization", "--strip-debug-info", "--lowering-options=disallowLocalVariables,disallowPackedArrays"))
}
