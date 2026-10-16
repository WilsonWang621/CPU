package tier3

import chisel3._
import chisel3.util._
import tier3.Bits._

class CacheMiss(lb: Int, rb: Int, offset: Int, words: Int) extends Bundle {
  val valid = Bool(); val physical = UInt(lb.W); val address = UInt((rb - offset).W)
  val critical = UInt((offset - 2).W); val issued = UInt((offset - 1).W); val returned = UInt((offset - 1).W)
  val failed = UInt(words.W)
}
class CacheWaiter(lb: Int, ww: Int) extends Bundle {
  val valid = Bool(); val error = Bool(); val physical = UInt(lb.W); val word_index = UInt(ww.W)
}
class CacheOwner(st: Int, mb: Int, ww: Int) extends Bundle {
  val write = Bool(); val tag = UInt(st.W); val slot = UInt(mb.W); val word_index = UInt(ww.W)
}

class DCache(cacheBytes: Int = 2048, lineBytes: Int = 64, mshrs: Int = 4,
  loadSlots: Int = 8, storeSlots: Int = 16, credits: Int = 16, ramBytes: Int = 268435456,
  cacheTree: Boolean = true, ways: Int = 2) extends ClockedLogic {
  override def desiredName = "v2_dcache"
  require(lineBytes >= 16 && isPow2(lineBytes) && cacheBytes >= 4 * lineBytes && isPow2(cacheBytes))
  require(mshrs >= 2 && isPow2(mshrs) && credits >= 2 && isPow2(credits))
  require(Set(1, 2, 4)(ways) && cacheBytes >= 2 * ways * lineBytes)
  val offset = log2Ceil(lineBytes); val words = lineBytes / 4; val ww = offset - 2
  val sets = cacheBytes / (ways * lineBytes); val sb = log2Ceil(sets); val wayBits = log2Ceil(ways)
  val lb = sb + wayBits; val lines = ways * sets
  val rb = log2Ceil(ramBytes); val tb = rb - sb - offset; val mb = log2Ceil(mshrs); val fw = log2Ceil(credits)
  val lt = log2Ceil(loadSlots); val st = log2Ceil(storeSlots)
  val writeBanks = if (cacheBytes / 4 >= 128) 8 else 2
  val bankWords = cacheBytes / (4 * writeBanks); val bankBits = log2Ceil(writeBanks); val bankWordBits = log2Ceil(bankWords)
  val pendingBits = 37 + bankWordBits; val writeGroupWords = if (cacheTree) 16 else bankWords
  val writeGroups = (bankWords + writeGroupWords - 1) / writeGroupWords
  val load_valid = inBool(); val load_address = in(32); val load_tag = in(lt)
  val load_ready = outBool(); val load_hit = outBool(); val load_data = out(32)
  val result_valid = outBool(); val result_ready = inBool(); val result_tag = out(lt); val result_data = out(32); val result_error = outBool()
  val store_valid = inBool(); val store_ready = outBool(); val store_address = in(32); val store_data = in(32)
  val store_mask = in(4); val store_tag = in(st); val store_done = outBool(); val store_error = outBool(); val store_done_tag = out(st)
  val mem_req_valid = outBool(); val mem_req_write = outBool(); val mem_req_ready = inBool()
  val mem_req_addr = out(32); val mem_req_data = out(32); val mem_req_mask = out(4)
  val mem_rsp_valid = inBool(); val mem_rsp_ready = outBool(); val mem_rsp_data = in(32); val mem_rsp_error = inBool()
  val idle = outBool(); val miss_count = out(64)
  val misses = withClock(clk) { Reg(Vec(mshrs, new CacheMiss(lb, rb, offset, words))) }
  val waiters = withClock(clk) { Reg(Vec(loadSlots, new CacheWaiter(lb, ww))) }
  val owners = withClock(clk) { Reg(Vec(credits, new CacheOwner(st, mb, ww))) }
  val out_owner = withClock(clk) { Reg(new CacheOwner(st, mb, ww)) }
  val head = reg(fw); val tail = reg(fw); val count = reg(fw + 1); val out_valid = flag()
  val out_address = reg(32); val out_data = reg(32); val out_mask = reg(4)
  val data = withClock(clk) { Reg(Vec(cacheBytes / 4, Vec(4, UInt(8.W)))) }
  val tags = regs(lines, tb); val tag_valid = flags(lines)
  val word_valid = withClock(clk) { Reg(Vec(lines, Vec(words, Bool()))) }
  val replacement = flags(sets); val round_robin = reg(mb); val missCount = reg(64)
  val replacementWay = if (ways == 2) None else Some(regs(sets, wayBits max 1))
  val return_pending = flag(); val resultTag = reg(lt); val resultError = flag(); val return_address = reg(lb + ww)
  val pending_valid = flags(writeBanks); val pending_address = regs(writeBanks, bankWordBits)
  val pending_data = regs(writeBanks, 32); val pending_mask = regs(writeBanks, 4)
  val selectedLine = Wire(UInt(lb.W)); val mergeValid = Wire(Bool()); val mergeSlot = Wire(UInt(mb.W))
  val freeValid = Wire(Bool()); val freeSlot = Wire(UInt(mb.W)); val victimValid = Wire(Bool())
  val allocate = Wire(Bool()); val loadAccept = Wire(Bool()); val storeAccept = Wire(Bool())
  val loadSet = load_address(sb + offset - 1, offset); val storeSet = store_address(sb + offset - 1, offset)
  val loadWord = load_address(offset - 1, 2); val storeWord = store_address(offset - 1, 2)
  def physicalLine(set: UInt, way: UInt): UInt = if (ways == 1) set else Cat(set, way(wayBits - 1, 0))
  val storeMatches = VecInit((0 until ways).map { way =>
    val line = physicalLine(storeSet, way.U((wayBits max 1).W))
    tag_valid(line) && tags(line) === store_address(rb - 1, sb + offset)
  }).asUInt
  val lookup = Module(new CacheLookup(sets, tb, words, ways))
  lookup.address := load_address(rb - 1, 2); lookup.tags := pack((0 until lines).map(tags(_)))
  lookup.valid := tag_valid.asUInt; lookup.word_valid := pack((0 until lines).map(word_valid(_).asUInt))
  val loadTagHit = lookup.match_bits.orR; val storeTagHit = storeMatches.orR
  val loadLine = if (ways == 2) Cat(loadSet, !lookup.match_bits(0)) else physicalLine(loadSet, PriorityEncoder(lookup.match_bits).pad(1))
  val storeLine = if (ways == 2) Cat(storeSet, !storeMatches(0)) else physicalLine(storeSet, PriorityEncoder(storeMatches).pad(1))
  load_hit := lookup.hit
  mem_req_valid := !rst && out_valid && count < credits.U
  mem_req_write := out_owner.write; mem_req_addr := out_address; mem_req_data := out_data; mem_req_mask := out_mask
  val requestFire = mem_req_valid && mem_req_ready
  mem_rsp_ready := true.B
  val responseFire = mem_rsp_valid && count =/= 0.U
  val responseLine = misses(owners(head).slot).physical; val responseWord = owners(head).word_index
  val fillFire = responseFire && !owners(head).write
  store_done := responseFire && owners(head).write; store_done_tag := owners(head).tag
  store_error := store_done && mem_rsp_error
  val outSpace = !out_valid || requestFire
  result_valid := !rst && return_pending; result_tag := resultTag; result_error := resultError
  val locked = VecInit((0 until lines).map(l => (0 until mshrs).map(m => misses(m).valid && misses(m).physical === l.U(lb.W)).reduce(_ | _)))
  val freeCandidates = VecInit((0 until mshrs).map(m => !misses(m).valid)).asUInt
  freeValid := freeCandidates.orR; freeSlot := PriorityEncoder(freeCandidates)
  val mergeCandidates = VecInit((0 until mshrs).map(m => misses(m).valid && loadTagHit && misses(m).physical === loadLine)).asUInt
  mergeValid := mergeCandidates.orR; mergeSlot := 0.U
  for (m <- 0 until mshrs) { when(mergeCandidates(m)) { mergeSlot := m.U(mb.W) } }
  val releaseMiss = (0 until mshrs).map(m => misses(m).valid && misses(m).returned === words.U &&
    !(0 until loadSlots).map(w => waiters(w).valid && waiters(w).physical === misses(m).physical).reduce(_ | _))
  selectedLine := loadLine; victimValid := loadTagHit
  if (ways == 2) {
    val way0 = Cat(loadSet, 0.U(1.W)); val way1 = Cat(loadSet, 1.U(1.W))
    val replacementLine = Cat(loadSet, replacement(loadSet)); val alternateLine = Cat(loadSet, !replacement(loadSet))
    when(!loadTagHit) {
      when(!tag_valid(way0) && !locked(way0)) { selectedLine := way0; victimValid := true.B }
        .elsewhen(!tag_valid(way1) && !locked(way1)) { selectedLine := way1; victimValid := true.B }
        .elsewhen(!locked(replacementLine)) { selectedLine := replacementLine; victimValid := true.B }
        .elsewhen(!locked(alternateLine)) { selectedLine := alternateLine; victimValid := true.B }
    }
  } else {
    val candidates = (0 until ways).map(w => physicalLine(loadSet, w.U((wayBits max 1).W)))
    val invalid = VecInit(candidates.map(line => !tag_valid(line) && !locked(line))).asUInt
    val rotating = (0 until ways).map { step =>
      val way = (replacementWay.get(loadSet) + step.U)((wayBits max 1) - 1, 0)
      val line = physicalLine(loadSet, way)
      !locked(line) -> line
    }
    when(!loadTagHit) {
      victimValid := invalid.orR || rotating.map(_._1).reduce(_ | _)
      selectedLine := Mux(invalid.orR, physicalLine(loadSet, PriorityEncoder(invalid).pad(1)),
        PriorityMux(rotating :+ (true.B -> candidates.head)))
    }
  }
  load_ready := !rst && !result_valid && (load_hit || (!waiters(load_tag).valid && (mergeValid || (freeValid && victimValid))))
  loadAccept := load_valid && load_ready
  allocate := loadAccept && !load_hit && !mergeValid
  store_ready := !rst && outSpace && count < (credits - 1).U && !fillFire &&
    (!storeTagHit || !locked(storeLine)) && !(allocate && storeTagHit && selectedLine === storeLine)
  storeAccept := store_valid && store_ready
  val sendCandidates = (0 until mshrs).map { i =>
    val slot = (round_robin + i.U(mb.W))(mb - 1, 0)
    (misses(slot).valid && misses(slot).issued < words.U, slot)
  }
  val sendValid = sendCandidates.map(_._1).reduce(_ | _)
  val sendSlot = PriorityMux(sendCandidates.map { case (e, s) => e -> s } :+ (true.B -> 0.U(mb.W)))
  val sendFill = !rst && outSpace && count < (credits - 1).U && !storeAccept && sendValid
  val sendWord = (misses(sendSlot).critical + misses(sendSlot).issued(ww - 1, 0))(ww - 1, 0)
  val dataWriteValid = (fillFire && !mem_rsp_error) || (!fillFire && storeAccept && storeTagHit)
  val dataWriteAddress = Mux(fillFire, Cat(responseLine, responseWord), Cat(storeLine, storeWord))
  val dataWriteValue = Mux(fillFire, mem_rsp_data, store_data)
  val dataWriteMask = Mux(fillFire, 15.U(4.W), store_mask)
  val dataReadAddress = Mux(result_valid, return_address, Cat(loadLine, loadWord))
  val incomingError = (mergeValid && misses(mergeSlot).failed(loadWord)) ||
    (fillFire && mem_rsp_error && responseLine === selectedLine && responseWord === loadWord)
  def readyAfter(line: UInt, w: UInt): Bool = {
    val ready = WireDefault(word_valid(line)(w))
    when(allocate && !loadTagHit && selectedLine === line) { ready := false.B }
    when(fillFire && responseLine === line && responseWord === w) { ready := !mem_rsp_error }
    when(storeAccept && storeTagHit && storeLine === line && store_mask === 15.U && storeWord === w) { ready := true.B }
    ready
  }
  val incomingWordReady = readyAfter(selectedLine, loadWord)
  val waiterNext = Wire(Vec(loadSlots, new CacheWaiter(lb, ww)))
  val returnCandidates = (0 until loadSlots).map { w =>
    val resident = waiters(w)
    val publish = loadAccept && !load_hit && load_tag === w.U(lt.W)
    val consumed = result_valid && result_ready && resultTag === w.U(lt.W)
    val residentError = resident.error || (fillFire && mem_rsp_error && resident.valid &&
      resident.physical === responseLine && resident.word_index === responseWord)
    waiterNext(w) := resident
    when(consumed) { waiterNext(w).valid := false.B }
    when(fillFire && mem_rsp_error && resident.valid && resident.physical === responseLine && resident.word_index === responseWord) {
      waiterNext(w).error := true.B
    }
    when(publish) {
      waiterNext(w).valid := true.B; waiterNext(w).physical := selectedLine
      waiterNext(w).word_index := loadWord; waiterNext(w).error := incomingError
    }
    Mux(publish, incomingError || incomingWordReady,
      resident.valid && !consumed && (residentError || readyAfter(resident.physical, resident.word_index)))
  }
  val returnEligibles = (0 until loadSlots).map(w => waiterNext(w).valid && returnCandidates(w))
  val returnValidNext = returnEligibles.reduce(_ | _)
  val returnTagNext = PriorityMux(returnEligibles.zipWithIndex.map { case (e, w) => e -> w.U(lt.W) } :+ (true.B -> 0.U(lt.W)))
  val returnErrorNext = PriorityMux(returnEligibles.zipWithIndex.map { case (e, w) => e -> waiterNext(w).error } :+ (true.B -> false.B))
  val returnAddressNext = PriorityMux(returnEligibles.zipWithIndex.map { case (e, w) =>
    e -> Cat(waiterNext(w).physical, waiterNext(w).word_index) } :+ (true.B -> 0.U((lb + ww).W)))
  when(rst) { return_pending := false.B; resultTag := 0.U; resultError := false.B; return_address := 0.U }
    .otherwise { return_pending := returnValidNext; resultTag := returnTagNext; resultError := returnErrorNext; return_address := returnAddressNext }

  val bankReads = (0 until writeBanks).map { bank =>
    val read = Module(new CacheRead(bankWords, indexGroup = if (cacheTree) 16 else 0))
    read.index := dataReadAddress(bankWordBits - 1, 0)
    read.words := pack((0 until bankWords).map(w => data(bank * bankWords + w).asUInt))
    val selectBank = dataWriteAddress(lb + ww - 1, bankWordBits) === bank.U(bankBits.W)
    when(rst) { pending_valid(bank) := false.B }.otherwise {
      pending_valid(bank) := dataWriteValid && selectBank
      when(selectBank) {
        pending_address(bank) := dataWriteAddress(bankWordBits - 1, 0)
        pending_data(bank) := dataWriteValue; pending_mask(bank) := dataWriteMask
      }
    }
    val distributedWrites = Distribution(Cat(pending_mask(bank) & Fill(4, pending_valid(bank)), pending_address(bank), pending_data(bank)), writeGroups)
    for (w <- 0 until bankWords; byte <- 0 until 4) {
      val localWrite = distributedWrites(w / writeGroupWords)
      when(!rst && localWrite(32 + bankWordBits + byte) && localWrite(32 + bankWordBits - 1, 32) === w.U(bankWordBits.W)) {
        data(bank * bankWords + w)(byte) := word(localWrite, byte, 8)
      }
    }
    read.value
  }
  val readData = Module(new CacheRead(writeBanks))
  readData.index := dataReadAddress(lb + ww - 1, bankWordBits); readData.words := pack(bankReads)
  val readPending = Read((0 until writeBanks).map(b => Cat(pending_valid(b), pending_address(b), pending_mask(b), pending_data(b))),
    dataReadAddress(lb + ww - 1, bankWordBits))
  load_data := pack((0 until 4).map { byte =>
    val bypass = readPending(pendingBits - 1) && readPending(32 + byte) &&
      readPending(36 + bankWordBits - 1, 36) === dataReadAddress(bankWordBits - 1, 0)
    Mux(bypass, word(readPending, byte, 8), word(readData.value, byte, 8))
  })
  result_data := load_data
  idle := !out_valid && count === 0.U && !misses.map(_.valid).reduce(_ | _) && !waiters.map(_.valid).reduce(_ | _)
  miss_count := missCount
  when(rst) {
    head := 0.U; tail := 0.U; count := 0.U; out_valid := false.B; out_owner := 0.U.asTypeOf(out_owner)
    out_address := 0.U; out_data := 0.U; out_mask := 0.U; round_robin := 0.U; missCount := 0.U
  }.otherwise {
    when(requestFire =/= responseFire) { count := Mux(requestFire, count + 1.U, count - 1.U) }
    when(requestFire) { owners(tail) := out_owner; tail := tail + 1.U; out_valid := false.B }
    when(responseFire) { head := head + 1.U }
    when(storeAccept) {
      out_valid := true.B; out_owner := 0.U.asTypeOf(out_owner); out_owner.write := true.B; out_owner.tag := store_tag
      out_address := store_address; out_data := store_data; out_mask := store_mask
    }.elsewhen(sendFill) {
      out_valid := true.B; out_owner := 0.U.asTypeOf(out_owner); out_owner.slot := sendSlot; out_owner.word_index := sendWord
      out_address := Cat(0.U((32 - rb).W), misses(sendSlot).address, sendWord, 0.U(2.W))
      out_data := 0.U; out_mask := 0.U; round_robin := sendSlot + 1.U
    }
    when(allocate && !loadTagHit) { missCount := missCount + 1.U }
  }
  for (m <- 0 until mshrs) {
    when(rst) { misses(m) := 0.U.asTypeOf(misses(m)) }.otherwise {
      when(releaseMiss(m)) { misses(m).valid := false.B }
      when(sendFill && sendSlot === m.U(mb.W)) { misses(m).issued := misses(m).issued + 1.U }
      when(fillFire && owners(head).slot === m.U(mb.W)) {
        misses(m).returned := misses(m).returned + 1.U
        when(mem_rsp_error) { misses(m).failed := misses(m).failed | (1.U(words.W) << responseWord) }
      }
      when(allocate && freeSlot === m.U(mb.W)) {
        misses(m).valid := true.B; misses(m).physical := selectedLine
        misses(m).address := load_address(rb - 1, offset); misses(m).critical := loadWord
        misses(m).issued := 0.U; misses(m).returned := 0.U; misses(m).failed := 0.U
      }
    }
  }
  for (w <- 0 until loadSlots) {
    when(rst) { waiters(w) := 0.U.asTypeOf(waiters(w)) }.otherwise { waiters(w) := waiterNext(w) }
  }
  for (l <- 0 until lines) {
    when(rst) { tag_valid(l) := false.B; for (w <- 0 until words) word_valid(l)(w) := false.B }.otherwise {
      when(allocate && !loadTagHit && selectedLine === l.U(lb.W)) {
        for (w <- 0 until words) word_valid(l)(w) := false.B
        tag_valid(l) := true.B; tags(l) := load_address(rb - 1, sb + offset)
      }
      when(fillFire && responseLine === l.U(lb.W)) { word_valid(l)(responseWord) := !mem_rsp_error }
      when(storeAccept && storeTagHit && storeLine === l.U(lb.W) && store_mask === 15.U) { word_valid(l)(storeWord) := true.B }
    }
  }
  for (s <- 0 until sets) {
    if (ways == 2) {
      when(rst) { replacement(s) := false.B }.otherwise {
        when(loadAccept && loadSet === s.U(sb.W)) { replacement(s) := !selectedLine(0) }
        when(storeAccept && storeTagHit && storeSet === s.U(sb.W)) { replacement(s) := !storeLine(0) }
      }
    } else {
      when(rst) { replacementWay.get(s) := 0.U }.otherwise {
        when(loadAccept && loadSet === s.U(sb.W)) { replacementWay.get(s) := (if (ways == 1) 0.U else selectedLine(wayBits - 1, 0) + 1.U) }
        when(storeAccept && storeTagHit && storeSet === s.U(sb.W)) { replacementWay.get(s) := (if (ways == 1) 0.U else storeLine(wayBits - 1, 0) + 1.U) }
      }
    }
  }
}
