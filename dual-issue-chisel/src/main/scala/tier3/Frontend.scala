package tier3

import chisel3._
import chisel3.util._
import tier3.Bits._
import ISA._

class FetchPacket(hb: Int) extends Bundle {
  val fault = UInt(4.W); val iv = Bool(); val history = UInt(hb.W)
  val pc = UInt(32.W); val inst = UInt(32.W); val pred = UInt(32.W)
}

/** Two instructions per fetch, critical-word-first eight-word fills, prepared
  * free FIFO rows and fill-time direct targets, as in v2_frontend.sv.
  */
class Frontend(cacheBytes: Int = 1024, queueEntries: Int = 8, bhtEntries: Int = 256,
  btbEntries: Int = 32, localHistoryBits: Int = 1, historyEntries: Int = 64,
  ramBytes: Int = 268435456, cacheTree: Boolean = true) extends ClockedLogic {
  override def desiredName = "v2_frontend"
  val cb = log2Ceil(cacheBytes); val lines = cacheBytes / 32; val lb = log2Ceil(lines)
  val qw = log2Ceil(queueEntries); val bw = log2Ceil(bhtEntries); val tw = log2Ceil(btbEntries)
  val hi = log2Ceil(historyEntries); val hb = localHistoryBits max 1
  require(localHistoryBits >= 0 && localHistoryBits < bw)
  require(historyEntries >= 2 && isPow2(historyEntries) && cacheBytes >= 64 && isPow2(cacheBytes))
  require(queueEntries >= 2 && isPow2(queueEntries))
  val stop = inBool(); val redirect = inBool(); val redirect_pc = in(32); val pop_count = in(2)
  val packet_valid = out(2); val packet_pc = out(64); val packet_inst = out(64); val packet_prediction = out(64)
  val packet_fault = out(8); val packet_inst_valid = out(2); val packet_history = out(2 * hb)
  val train_history = in(hb); val train_valid = inBool(); val train_taken = inBool(); val train_op = in(6)
  val train_pc = in(32); val train_target = in(32)
  val mem_req_valid = outBool(); val mem_req_ready = inBool(); val mem_req_addr = out(32)
  val mem_rsp_valid = inBool(); val mem_rsp_ready = outBool(); val mem_rsp_data = in(32); val mem_rsp_error = inBool()
  val idle = outBool(); val miss_count = out(64)
  val fifo = withClock(clk) { Reg(Vec(queueEntries, new FetchPacket(hb))) }
  val head = reg(qw); val tail = reg(qw); val count = reg(qw + 1); val pc = reg(32); val blocked = flag()
  val even_data = regs(cacheBytes / 8, 32); val odd_data = regs(cacheBytes / 8, 32)
  val even_target = regs(cacheBytes / 8, 32); val odd_target = regs(cacheBytes / 8, 32)
  val tags = regs(lines, 32 - cb); val tag_valid = flags(lines)
  val valid_words = withClock(clk) { Reg(Vec(lines, Vec(8, Bool()))) }
  val failed_words = withClock(clk) { Reg(Vec(lines, Vec(8, Bool()))) }
  val busy = flag(); val fill_line = reg(32); val critical = reg(3); val issued = reg(4); val returned = reg(4)
  val bht = regs(bhtEntries, 2); val bht_valid = flags(bhtEntries)
  val btb_tag = regs(btbEntries, 30 - tw); val btb_target = regs(btbEntries, 30); val btb_valid = flags(btbEntries)
  val local_history = regs(historyEntries, hb); val missCount = reg(64)
  val nextWord = Module(new Increment(30)); nextWord.value := pc(31, 2)
  val nextPair = Module(new Increment(29)); nextPair.value := pc(31, 3)
  val sequentialPc = Seq(Cat(nextWord.result, pc(1, 0)), Cat(nextPair.result, pc(2, 0)))
  val fetchPc = Seq(pc, sequentialPc(0))
  val evenIndex = Mux(pc(2), fetchPc(1)(cb - 1, 3), pc(cb - 1, 3))
  val oddIndex = pc(cb - 1, 3)
  val evenRead = Read((0 until cacheBytes / 8).map(r => Cat(even_target(r), even_data(r))), evenIndex, if (cacheTree) 16 else 0)
  val oddRead = Read((0 until cacheBytes / 8).map(r => Cat(odd_target(r), odd_data(r))), oddIndex, if (cacheTree) 16 else 0)
  val fetchInst = Seq(Mux(pc(2), oddRead(31, 0), evenRead(31, 0)), Mux(pc(2), evenRead(31, 0), oddRead(31, 0)))
  val fetchTarget = Seq(Mux(pc(2), oddRead(63, 32), evenRead(63, 32)), Mux(pc(2), evenRead(63, 32), oddRead(63, 32)))
  val fetchLine = pc(cb - 1, 5)
  val lineHit = (0 until lines).map(r => fetchLine === r.U(lb.W) && tag_valid(r) && tags(r) === pc(31, cb)).reduce(_ | _)
  val trainBht = Wire(UInt(bw.W))
  trainBht := (if (localHistoryBits == 0) train_pc(bw + 1, 2)
    else (train_pc(bw + 1, 2) << localHistoryBits) | train_history.pad(bw))
  val trainBtb = train_pc(tw + 1, 2)
  val trainCounter = Mux(bht_valid(trainBht), bht(trainBht), 1.U(2.W))
  val fetchHistory = fetchPc.map(f => if (localHistoryBits == 0) 0.U(hb.W) else local_history(f(hi + 1, 2)))
  val wordReady = fetchPc.map(f => lineHit && (valid_words(fetchLine)(f(4, 2)) || failed_words(fetchLine)(f(4, 2))))
  val wordError = fetchPc.map(f => failed_words(fetchLine)(f(4, 2)))
  val prediction = (0 until 2).map { p =>
    val f = fetchPc(p)
    val targetHits = (0 until btbEntries).map(r => f(tw + 1, 2) === r.U(tw.W) && btb_valid(r) && btb_tag(r) === f(31, tw + 2))
    val target = Read((0 until btbEntries).map(btb_target(_)), f(tw + 1, 2))
    val fetchBht = Wire(UInt(bw.W))
    fetchBht := (if (localHistoryBits == 0) f(bw + 1, 2) else (f(bw + 1, 2) << localHistoryBits) | fetchHistory(p).pad(bw))
    val counter = Mux(bht_valid(fetchBht), bht(fetchBht), 1.U(2.W))
    MuxLookup(fetchInst(p)(6, 0), sequentialPc(p))(Seq(
      "h6f".U -> fetchTarget(p), "h63".U -> Mux(counter(1), fetchTarget(p), sequentialPc(p)),
      "h67".U -> Mux(targetHits.reduce(_ | _), Cat(target, 0.U(2.W)), sequentialPc(p))))
  }
  val readPackets = (0 until 2).map { p =>
    val index = Wire(UInt(qw.W)); index := head + p.U(qw.W)
    Read((0 until queueEntries).map(fifo(_).asUInt), index).asTypeOf(new FetchPacket(hb))
  }
  packet_valid := VecInit((0 until 2).map(p => count > p.U)).asUInt
  packet_pc := pack(readPackets.map(_.pc)); packet_inst := pack(readPackets.map(_.inst))
  packet_prediction := pack(readPackets.map(_.pred)); packet_fault := pack(readPackets.map(_.fault))
  packet_inst_valid := VecInit(readPackets.map(_.iv)).asUInt; packet_history := pack(readPackets.map(_.history))
  val push = WireDefault(0.U(2.W)); val nextPc = WireDefault(pc); val nextBlocked = WireDefault(blocked)
  val allocate = WireDefault(false.B)
  val incoming = Wire(Vec(2, new FetchPacket(hb)))
  for (p <- 0 until 2) {
    incoming(p) := 0.U.asTypeOf(new FetchPacket(hb))
    incoming(p).pc := fetchPc(p); incoming(p).pred := prediction(p); incoming(p).history := fetchHistory(p)
    incoming(p).inst := fetchInst(p); incoming(p).iv := true.B
  }
  when(!stop && !redirect && !blocked && count < queueEntries.U) {
    when(pc(1, 0) =/= 0.U || pc >= ramBytes.U) {
      incoming(0).fault := Mux(pc(1, 0) =/= 0.U, FETCH_ALIGN, FETCH_RANGE)
      incoming(0).iv := false.B; incoming(0).inst := 0.U; push := 1.U; nextBlocked := true.B
    }.elsewhen(wordReady(0)) {
      push := 1.U; nextPc := prediction(0)
      when(wordError(0)) {
        incoming(0).fault := FETCH_BUS; incoming(0).iv := false.B; incoming(0).inst := 0.U; nextBlocked := true.B
      }.elsewhen(prediction(0) === sequentialPc(0) && pc(4, 2) =/= 7.U && wordReady(1) && count < (queueEntries - 1).U) {
        push := 2.U; nextPc := prediction(1)
        when(wordError(1)) {
          incoming(1).fault := FETCH_BUS; incoming(1).iv := false.B; incoming(1).inst := 0.U; nextBlocked := true.B
        }
      }
    }.elsewhen(!busy) { allocate := true.B }
  }
  val sendWord = (critical + issued(2, 0))(2, 0)
  val returnWord = (critical + returned(2, 0))(2, 0)
  val returnAddress = fill_line + Cat(0.U(27.W), returnWord, 0.U(2.W))
  val fillImmediate = MuxLookup(mem_rsp_data(6, 0), 0.U(32.W))(Seq(
    "h6f".U -> sext(Cat(mem_rsp_data(31), mem_rsp_data(19, 12), mem_rsp_data(20), mem_rsp_data(30, 21), 0.U(1.W))),
    "h63".U -> sext(Cat(mem_rsp_data(31), mem_rsp_data(7), mem_rsp_data(30, 25), mem_rsp_data(11, 8), 0.U(1.W)))))
  val fillTarget = returnAddress + fillImmediate
  mem_req_valid := !rst && busy && issued < 8.U
  mem_req_addr := fill_line + Cat(0.U(27.W), sendWord, 0.U(2.W))
  mem_rsp_ready := true.B; idle := !busy; miss_count := missCount
  when(rst) {
    head := 0.U; tail := 0.U; count := 0.U; pc := 0.U; blocked := false.B
    busy := false.B; issued := 0.U; returned := 0.U; critical := 0.U; fill_line := 0.U; missCount := 0.U
    for (r <- 0 until bhtEntries) bht_valid(r) := false.B
    for (r <- 0 until btbEntries) btb_valid(r) := false.B
  }.otherwise {
    when(redirect) { head := 0.U; tail := 0.U; count := 0.U; pc := redirect_pc; blocked := false.B }
      .otherwise {
        head := head + pop_count; tail := tail + push; count := count + push - pop_count
        pc := nextPc; blocked := nextBlocked
      }
    when(allocate) {
      busy := true.B; fill_line := Cat(pc(31, 5), 0.U(5.W)); critical := pc(4, 2)
      issued := 0.U; returned := 0.U; missCount := missCount + 1.U
    }
    when(mem_req_valid && mem_req_ready) { issued := issued + 1.U }
    when(mem_rsp_valid) { returned := returned + 1.U; when(returned === 7.U) { busy := false.B } }
    when(train_valid && train_op >= BEQ && train_op <= BGEU) {
      bht_valid(trainBht) := true.B
      bht(trainBht) := Mux(train_taken, Mux(trainCounter === 3.U, 3.U, trainCounter + 1.U),
        Mux(trainCounter === 0.U, 0.U, trainCounter - 1.U))
    }
    when(train_valid && train_op === JALR && train_target < ramBytes.U && train_target(1, 0) === 0.U) {
      btb_valid(trainBtb) := true.B; btb_tag(trainBtb) := train_pc(31, tw + 2); btb_target(trainBtb) := train_target(31, 2)
    }
  }
  for (r <- 0 until cacheBytes / 8) {
    when(!rst && mem_rsp_valid && !mem_rsp_error && returnAddress(cb - 1, 3) === r.U((cb - 3).W)) {
      when(returnAddress(2)) { odd_data(r) := mem_rsp_data; odd_target(r) := fillTarget }
        .otherwise { even_data(r) := mem_rsp_data; even_target(r) := fillTarget }
    }
  }
  for (r <- 0 until queueEntries; p <- 0 until 2) {
    val index = (tail + p.U(qw.W))(qw - 1, 0)
    // Preparation remains unconditional on reset, stop and publication.
    when(count +& p.U < queueEntries.U && index === r.U(qw.W)) { fifo(r) := incoming(p) }
  }
  for (r <- 0 until lines) {
    when(rst) { tag_valid(r) := false.B }.otherwise {
      when(allocate && fetchLine === r.U(lb.W)) {
        for (w <- 0 until 8) { valid_words(r)(w) := false.B; failed_words(r)(w) := false.B }
        tag_valid(r) := true.B; tags(r) := pc(31, cb)
      }
      when(mem_rsp_valid && fill_line(cb - 1, 5) === r.U(lb.W)) {
        valid_words(r)(returnWord) := !mem_rsp_error; failed_words(r)(returnWord) := mem_rsp_error
      }
    }
  }
  for (h <- 0 until historyEntries) {
    when(rst) { local_history(h) := 0.U }.elsewhen((localHistoryBits > 0).B && train_valid &&
      train_op >= BEQ && train_op <= BGEU && train_pc(hi + 1, 2) === h.U(hi.W)) {
      local_history(h) := (local_history(h) << 1) | train_taken.asUInt
    }
  }
}
