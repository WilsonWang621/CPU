package tier3

import chisel3._
import chisel3.util._
import tier3.Bits._
import ISA._

/** Cycle-preserving port of area_v2/cpu_top.sv. Preparation of free entries
  * is deliberately independent of the valid bit that publishes an entry.
  */
class Core(p: Config = Config()) extends ClockedLogic {
  override def desiredName = "cpu_top"
  val rw = p.rw; val qw = p.qw; val lt = p.lt; val st = p.st; val cpw = p.cpw; val hb = p.hb
  val mem_req_valid = outBool(); val mem_req_write = outBool(); val mem_req_addr = out(32)
  val mem_req_wdata = out(32); val mem_req_wstrb = out(4); val mem_req_ready = inBool()
  val mem_rsp_valid = inBool(); val mem_rsp_rdata = in(32); val mem_rsp_error = inBool(); val mem_rsp_ready = outBool()
  val halted = outBool(); val faulted = outBool(); val fault_pc = out(32); val fault_inst = out(32)
  val fault_inst_valid = outBool(); val fault_cause = out(4); val fault_addr = out(32)
  val retire_valid = out(4); val retire_pc = out(128); val retire_inst = out(128); val retire_rd = out(20)
  val retire_value = out(128); val retire_store = out(4); val retire_addr = out(128); val retire_wdata = out(128); val retire_wstrb = out(16)
  val cycle_count = out(64); val retired_count = out(64); val branch_miss_count = out(64)
  val load_replay_count = out(64); val icache_miss_count = out(64); val dcache_miss_count = out(64)
  val rob = withClock(clk) { Reg(Vec(p.robEntries, new RobEntry(p))) }
  val values = withClock(clk) { Reg(Vec(p.prfEntries, Vec(4, UInt(8.W)))) }
  // The equal-capacity specialization keeps the measured ROB-indexed result
  // file. Other capacities use independently allocated physical value slots.
  // The committed 32-word ARF is separate from this speculative PRF.
  val prfOwner = if (p.prfEntries == p.robEntries) None else Some(regs(p.robEntries, log2Ceil(p.prfEntries)))
  val physicalAllocation = prfOwner.map { owners =>
    val used = (0 until p.robEntries).map(r => Mux(rob(r).valid, UIntToOH(owners(r), p.prfEntries), 0.U(p.prfEntries.W))).reduce(_ | _)
    val free = ~used
    val first = PriorityEncoder(free)
    val second = PriorityEncoder(free & ~UIntToOH(first, p.prfEntries))
    (Seq(first, second), Seq(free.orR, PopCount(free) >= 2.U))
  }
  val queue = withClock(clk) { Reg(Vec(3, Vec(p.iqEntries, new IssueEntry(p)))) }
  val stores = withClock(clk) { Reg(Vec(p.storeSlots, new StoreEntry(p))) }
  val loads = withClock(clk) { Reg(Vec(p.loadSlots, new LoadEntry(p))) }
  val state = reg(2); val run = 0.U(2.W); val drain = 1.U(2.W); val done = 2.U(2.W); val fault = 3.U(2.W)
  val head = reg(rw); val tail = reg(rw); val tail_generation = flag(); val rob_count = reg(rw + 1)
  val store_head = reg(st); val store_tail = reg(st); val store_count = reg(st + 1); val steer = flag()
  val checkpoint_valid = flags(p.checkpoints); val checkpoint_owner = regs(p.checkpoints, rw)
  val prepared_address = regs(p.iqEntries, 32)
  val branch_pending = flag(); val branch_bad_q = flag(); val branch_taken_q = flag(); val branch_recovery_q = flag()
  val branch_next_q = reg(32); val branch_pc_q = reg(32); val branch_prediction_q = reg(30)
  val branch_history_q = reg(hb); val branch_rid_q = reg(rw); val branch_generation_q = flag()
  val branch_checkpoint_q = reg(cpw); val branch_op_q = reg(6)
  val dispatch_payload = Wire(Vec(2, new IssueEntry(p))); val executing = Wire(Vec(3, new IssueEntry(p)))
  val dispatch_prepare = Wire(Vec(2, Bool())); val dispatch_valid = Wire(Vec(2, Bool()))
  val rename_prepare = Wire(Vec(2, Bool())); val rename_valid = Wire(Vec(2, Bool())); val rename_rd = Wire(Vec(2, UInt(5.W)))
  val dispatch_rid = Wire(Vec(2, UInt(rw.W))); val dispatch_bank = Wire(Vec(2, UInt(2.W)))
  val dispatch_index = Wire(Vec(2, UInt(qw.W))); val dispatch_count = Wire(UInt(2.W))
  val commit_count = Wire(UInt(2.W)); val commit_valid = Wire(Vec(2, Bool())); val commit_rd = Wire(Vec(2, UInt(5.W)))
  val commit_rid = Wire(Vec(2, UInt(rw.W)))
  val selected_valid = Wire(Vec(3, Bool())); val selected = Wire(Vec(3, UInt(qw.W)))
  val select_valid = Wire(Vec(3, Bool())); val issue_fire = Wire(Vec(3, Bool()))
  val wb_valid = Wire(Vec(3, Bool())); val wb_rid = Wire(Vec(3, UInt(rw.W)))
  val wb_value = Wire(Vec(3, UInt(32.W))); val wb_fault = Wire(Vec(3, UInt(4.W))); val wb_address = Wire(Vec(3, UInt(32.W)))
  val save_checkpoint = Wire(Bool()); val save_after_lane = Wire(Bool())
  val flush_all = state =/= run
  val branch_fire = branch_pending && !flush_all
  val redirect = if (p.registerRedirect) branch_recovery_q && !flush_all
    else branch_fire && !branch_bad_q && branch_next_q =/= Cat(branch_prediction_q, 0.U(2.W))
  val redirect_rid = branch_rid_q
  def age(rid: UInt): UInt = (rid - head)(rw - 1, 0)
  def younger(rid: UInt): Bool = redirect && Mux((rid < head) === (redirect_rid < head), rid > redirect_rid, rid < head)
  val robRecGroups = (p.robEntries + 3) / 4; val storeRecGroups = (p.storeSlots + 3) / 4; val loadRecGroups = (p.loadSlots + 3) / 4
  val recLeaves = robRecGroups + 3 + storeRecGroups + loadRecGroups + 1
  val recoveryControl = Cat(flush_all, redirect, redirect_rid < head, redirect_rid, head)
  val recoveryCopies = if (p.controlTree) Distribution(recoveryControl, recLeaves) else Seq.fill(recLeaves)(recoveryControl)
  def recoveryYounger(rid: UInt, c: UInt): Bool = c(2 * rw + 1) &&
    Mux((rid < c(rw - 1, 0)) === c(2 * rw), rid > c(2 * rw - 1, rw), rid < c(rw - 1, 0))
  def extendLoad(value: UInt, offset: UInt, size: UInt, sign: Bool): UInt = {
    val shifted = value >> Cat(offset, 0.U(3.W))
    MuxLookup(size, shifted)(Seq(0.U -> Cat(Fill(24, sign && shifted(7)), shifted(7, 0)),
      1.U -> Cat(Fill(16, sign && shifted(15)), shifted(15, 0))))
  }
  val mdu = Module(new MulDiv); connectClock(mdu)
  mdu.kill := flush_all
  mdu.kill_mask := pack((0 until 256).map(r => (if (r < p.robEntries) !rob(r).valid else true.B).asUInt))
  mdu.req_op := executing(0).op; mdu.req_a := executing(0).a; mdu.req_b := executing(0).b; mdu.req_tag := executing(0).rid
  mdu.req_valid := select_valid(0) && isMdu(executing(0).op) && !flush_all && !mdu.rsp_valid && !younger(executing(0).rid)
  mdu.rsp_ready := !flush_all
  val wb_good = VecInit((0 until 3).map { w =>
    wb_valid(w) && rob(wb_rid(w)).rd =/= 0.U && (if (w != 0) wb_fault(w) === 0.U else
      mdu.rsp_valid || isAlu(executing(0).op) || (executing(0).op === JAL && executing(0).imm(1, 0) === 0.U) ||
        (executing(0).op === JALR && !(executing(0).a(1) ^ executing(0).imm(1) ^ (executing(0).a(0) & executing(0).imm(0)))))
  }).asUInt
  val loadValueCopies = Distribution(wb_value(2), 6)
  val wakeCopies = Distribution(Cat(wb_good, pack(wb_rid)), 6)
  val dispatch_order = (0 until 2).map(l => (Cat(tail_generation, tail) + l.U((rw + 1).W))(rw, 0))
  val dispatch_address = (0 until 2).map(l => PrefixAdder(dispatch_payload(l).a, dispatch_payload(l).imm)._1)
  val retirementWords = (0 until p.robEntries).map(r => Cat(rob(r).done, rob(r).exiting, rob(r).store, rob(r).fault, rob(r).rd, rob(r).store_slot))
  val retirement_meta = (0 until 2).map { l =>
    commit_rid(l) := head + l.U(rw.W)
    val m = Module(new RetireRead(p.robEntries, (new RetireMeta(p)).getWidth, l, p.commitTree)); connectClock(m)
    m.advance := commit_count; m.words := pack(retirementWords); m.value.asTypeOf(new RetireMeta(p))
  }
  val retirement_value = (0 until 2).map { l =>
    if (prfOwner.isEmpty) {
      val m = Module(new RetireRead(p.robEntries, 32, l, p.commitTree)); connectClock(m)
      m.advance := commit_count; m.words := pack((0 until p.robEntries).map(values(_).asUInt)); m.value
    } else {
      Read(values.map(_.asUInt).toSeq, Read(prfOwner.get.toSeq, commit_rid(l)))
    }
  }
  val architecturalControls = Cat(commit_valid.asUInt, pack(commit_rd), retirement_value(1), retirement_value(0))
  val architecturalCommits = if (p.commitTree) Distribution(architecturalControls, 8) else Distribution(architecturalControls, 1) match {
    case s => Seq.fill(8)(s.head)
  }
  val architectural = (0 until 32).map { r =>
    val m = Module(new ArchWord(r, p.commitTree)); connectClock(m)
    val cc = architecturalCommits(r / 4)
    m.commit_valid := cc(75, 74); m.commit_rd := cc(73, 64); m.commit_values := cc(63, 0); m.value
  }
  val frontend = Module(new Frontend(p.icacheBytes, p.fetchQueueEntries, p.bhtEntries, p.btbEntries,
    p.localHistoryBits, p.historyEntries, p.ramBytes, p.cacheTree, p.icacheWays)); connectClock(frontend)
  val dcache = Module(new DCache(p.dcacheBytes, p.dcacheLineBytes, p.dMshrs, p.loadSlots, p.storeSlots,
    p.maxMemOutstanding, p.ramBytes, p.cacheTree, p.dcacheWays)); connectClock(dcache)
  val memory_bus = Module(new MemoryController(p.maxMemOutstanding)); connectClock(memory_bus)
  frontend.stop := flush_all; frontend.redirect := redirect; frontend.redirect_pc := branch_next_q; frontend.pop_count := dispatch_count
  frontend.train_history := branch_history_q; frontend.train_valid := branch_fire && !branch_bad_q
  frontend.train_taken := branch_taken_q; frontend.train_op := branch_op_q; frontend.train_pc := branch_pc_q; frontend.train_target := branch_next_q
  icache_miss_count := frontend.miss_count; dcache_miss_count := dcache.miss_count
  memory_bus.s_req_valid := Cat(dcache.mem_req_valid, frontend.mem_req_valid)
  memory_bus.s_req_write := Cat(dcache.mem_req_write, false.B)
  memory_bus.s_req_addr := Cat(dcache.mem_req_addr, frontend.mem_req_addr)
  memory_bus.s_req_wdata := Cat(dcache.mem_req_data, 0.U(32.W)); memory_bus.s_req_wstrb := Cat(dcache.mem_req_mask, 0.U(4.W))
  frontend.mem_req_ready := memory_bus.s_req_ready(0); dcache.mem_req_ready := memory_bus.s_req_ready(1)
  frontend.mem_rsp_valid := memory_bus.s_rsp_valid(0); dcache.mem_rsp_valid := memory_bus.s_rsp_valid(1)
  frontend.mem_rsp_data := memory_bus.s_rsp_rdata(31, 0); dcache.mem_rsp_data := memory_bus.s_rsp_rdata(63, 32)
  frontend.mem_rsp_error := memory_bus.s_rsp_error(0); dcache.mem_rsp_error := memory_bus.s_rsp_error(1)
  memory_bus.s_rsp_ready := Cat(dcache.mem_rsp_ready, frontend.mem_rsp_ready)
  memory_bus.mem_rsp_valid := mem_rsp_valid; memory_bus.mem_rsp_rdata := mem_rsp_rdata; memory_bus.mem_rsp_error := mem_rsp_error
  mem_rsp_ready := memory_bus.mem_rsp_ready
  val exit_head = state === run && rob_count =/= 0.U && retirement_meta(0).done && retirement_meta(0).exiting && retirement_meta(0).fault === 0.U
  val fault_head = state === run && rob_count =/= 0.U && retirement_meta(0).done && retirement_meta(0).fault =/= 0.U
  val exit_send = state === drain && store_count === 0.U && dcache.idle && frontend.idle && memory_bus.idle
  val exit_accept = exit_send && mem_req_ready
  halted := state === done; faulted := state === fault; load_replay_count := 0.U
  mem_req_valid := state =/= done && (exit_send || memory_bus.mem_req_valid)
  mem_req_write := exit_send || memory_bus.mem_req_write
  mem_req_addr := Mux(exit_send, "h80000000".U, memory_bus.mem_req_addr)
  mem_req_wdata := Mux(exit_send, retirement_value(0), memory_bus.mem_req_wdata)
  mem_req_wstrb := Mux(exit_send, 15.U, memory_bus.mem_req_wstrb)
  memory_bus.mem_req_ready := mem_req_ready && !exit_send && state =/= done
  val decoded = (0 until 2).map { l =>
    val d = Module(new Decoder); d.inst := word(frontend.packet_inst, l, 32); d.dec.asTypeOf(new Decoded)
  }
  val source_register = decoded.flatMap(d => Seq(d.rs1, d.rs2))
  val freeCheckpointBits = VecInit(checkpoint_valid.map(!_)).asUInt
  val checkpoint_available = freeCheckpointBits.orR; val free_checkpoint = PriorityEncoder(freeCheckpointBits)
  val freeLoadBits = VecInit(loads.map(l => !l.valid)).asUInt
  val load_available = freeLoadBits.orR; val free_load = PriorityEncoder(freeLoadBits)
  val freeQueueBits = (0 until 3).map(b => VecInit(queue(b).map(q => !q.valid)).asUInt)
  val free_queue_valid = VecInit(freeQueueBits.map(_.orR)); val free_queue = VecInit(freeQueueBits.map(PriorityEncoder(_)))
  val occupancy = (0 until 3).map(b => PopCount(queue(b).map(_.valid)))
  val rename_maps = Module(new Rename(rw, p.checkpoints, p.commitTree)); connectClock(rename_maps)
  rename_maps.dispatch_valid := rename_valid.asUInt; rename_maps.prepare_valid := rename_prepare.asUInt
  // RAT publication/lookup already carries rename_valid/rename_prepare. Its
  // register comparison can use the raw destination while the ROB continues
  // to capture rename_rd. RenameInputProof checks all write/bypass controls.
  rename_maps.dispatch_rd := pack(decoded.map(_.rd)); rename_maps.dispatch_slot := pack(dispatch_rid)
  rename_maps.source_register := pack(source_register)
  rename_maps.commit_valid := commit_valid.asUInt; rename_maps.commit_rd := pack(commit_rd); rename_maps.commit_slot := pack(commit_rid)
  rename_maps.save_valid := save_checkpoint; rename_maps.save_after_lane := save_after_lane; rename_maps.save_index := free_checkpoint
  rename_maps.restore_valid := redirect; rename_maps.restore_index := branch_checkpoint_q
  val source_result = (0 until 4).map { s =>
    val source = word(rename_maps.source_slot, s, rw)
    if (prfOwner.isEmpty) Read((0 until p.robEntries).map(values(_).asUInt), source)
    else Read(values.map(_.asUInt).toSeq, Read(prfOwner.get.toSeq, source))
  }
  val source_status = (0 until 4).map(s => Read((0 until p.robEntries).map(r => Cat(rob(r).valid, rob(r).done, rob(r).fault)), word(rename_maps.source_slot, s, rw)))
  val source_architectural = source_register.map(r => Read(architectural, r))
  val alu_result = (0 until 2).map { i =>
    val a = Module(new Alu); a.op := executing(i).op; a.a := executing(i).a
    a.b := Mux(executing(i).use_imm, executing(i).imm, executing(i).b)
    a.pc := Cat(executing(i).pc, 0.U(2.W)); a.imm := executing(i).imm; a.result
  }
  val branch_i = Module(new BranchUnit)
  branch_i.op := executing(0).op; branch_i.a := executing(0).a; branch_i.b := executing(0).b
  branch_i.pc := Cat(executing(0).pc, 0.U(2.W)); branch_i.imm := executing(0).imm
  val branch_capture = select_valid(0) && isBranch(executing(0).op) && !flush_all && !mdu.rsp_valid && !younger(executing(0).rid)
  when(rst) { branch_pending := false.B; branch_recovery_q := false.B }.otherwise {
    branch_pending := branch_capture
    branch_recovery_q := branch_capture && !branch_i.misaligned && branch_i.next_pc =/= Cat(executing(0).prediction, 0.U(2.W))
  }
  branch_bad_q := branch_i.misaligned; branch_taken_q := branch_i.taken; branch_next_q := branch_i.next_pc
  branch_pc_q := Cat(executing(0).pc, 0.U(2.W)); branch_prediction_q := executing(0).prediction
  branch_history_q := executing(0).history; branch_rid_q := executing(0).rid; branch_checkpoint_q := executing(0).checkpoint
  branch_generation_q := executing(0).generation; branch_op_q := executing(0).op

  val issueBits = (new IssueEntry(p)).getWidth; val issueGroups = (issueBits + 31) / 32
  val memoryAddressGrant = Wire(UInt(p.iqEntries.W))
  for (b <- 0 until 3) {
    val selectReady = VecInit(queue(b).map(q => q.valid && (if (b == 2) true.B else q.ready_a && q.ready_b))).asUInt
    val selectOwner = pack(queue(b).map(q => Cat(q.generation, q.rid)))
    val payloadGrants = if (b == 2) {
      val controls = recoveryCopies(robRecGroups + 2)
      val nextCandidates = (0 until p.iqEntries).map { q =>
        val lane0 = dispatch_valid(0) && dispatch_bank(0) === 2.U && dispatch_index(0) === q.U(qw.W)
        val lane1 = dispatch_valid(1) && dispatch_bank(1) === 2.U && dispatch_index(1) === q.U(qw.W)
        val removed = (issue_fire(2) && selected(2) === q.U(qw.W)) || recoveryYounger(queue(2)(q).rid, controls) || controls(2 * rw + 2)
        ((queue(2)(q).valid && !removed) || lane0 || lane1,
          Mux(lane1, dispatch_order(1), Mux(lane0, dispatch_order(0), Cat(queue(2)(q).generation, queue(2)(q).rid))))
      }
      val choose = Module(new Select(p.iqEntries, rw + 1, extendedOrder = true))
      choose.ready := VecInit(nextCandidates.map(_._1)).asUInt; choose.owner := pack(nextCandidates.map(_._2)); choose.rob_head := 0.U
      val grantValid = flag(); val grantIndex = reg(qw)
      when(rst) { grantValid := false.B; grantIndex := 0.U }.otherwise { grantValid := choose.valid; grantIndex := choose.index }
      selected_valid(b) := grantValid; selected(b) := grantIndex
      val nextControls = Distribution(Cat(choose.valid, choose.index), issueGroups + 1)
      val copies = nextControls.map { c =>
        val m = Module(new RegisteredGrant(p.iqEntries)); connectClock(m)
        m.valid := c(qw); m.index := c(qw - 1, 0); m.grant
      }
      memoryAddressGrant := copies.last
      copies.dropRight(1)
    } else {
      val choose = Module(new ParallelSelect(p.iqEntries, rw + 1))
      choose.ready := selectReady; choose.owner := selectOwner; choose.rob_head := 0.U
      selected_valid(b) := choose.valid; selected(b) := choose.index
      Distribution(choose.grant, issueGroups)
    }
    val slices = (0 until issueBits by 32).map { first =>
      val width = 32 min (issueBits - first)
      val read = Module(new GrantRead(p.iqEntries, width))
      read.grant := payloadGrants(first / 32)
      read.words := pack(queue(b).map(q => q.asUInt(first + width - 1, first)))
      read.value
    }
    executing(b) := pack(slices).asTypeOf(new IssueEntry(p))
    if (p.issueWidth == 3 && p.integerPorts == 2) {
      select_valid(b) := selected_valid(b) && (if (b == 2) executing(b).ready_a && executing(b).ready_b else true.B)
    }
  }
  if (p.issueWidth != 3 || p.integerPorts != 2) {
    val eligible = (0 until 3).map { b =>
      selected_valid(b) && !younger(executing(b).rid) && (if (b == 0) !mdu.rsp_valid && (!isMdu(executing(0).op) || mdu.req_ready)
        else if (b == 1) (p.integerPorts == 2).B else executing(b).ready_a && executing(b).ready_b && !dcache.result_valid)
    }
    for (b <- 0 until 3) {
      val older = (0 until 3).filter(_ != b).map { other =>
        eligible(other) && (age(executing(other).rid) < age(executing(b).rid) ||
          (age(executing(other).rid) === age(executing(b).rid) && (other < b).B))
      }
      select_valid(b) := eligible(b) && PopCount(older) < p.issueWidth.U
    }
  }
  val addressRead = Module(new GrantRead(p.iqEntries, 32))
  addressRead.grant := memoryAddressGrant; addressRead.words := pack(prepared_address)
  val memory_address = addressRead.value
  val memory_data = (executing(2).b << Cat(memory_address(1, 0), 0.U(3.W)))(31, 0)
  val memory_mask = (Mux(executing(2).size === 0.U, 1.U(4.W), Mux(executing(2).size === 1.U, 3.U(4.W), 15.U(4.W))) << memory_address(1, 0))(3, 0)
  val memory_exit = executing(2).op === STORE && memory_address === "h80000000".U && executing(2).size === 2.U
  val memory_fault = WireDefault(0.U(4.W))
  when((executing(2).size === 1.U && memory_address(0)) || (executing(2).size === 2.U && memory_address(1, 0) =/= 0.U)) {
    memory_fault := Mux(executing(2).op === LOAD, LOAD_ALIGN, STORE_ALIGN)
  }.elsewhen(memory_address >= p.ramBytes.U && !memory_exit) { memory_fault := Mux(executing(2).op === LOAD, LOAD_RANGE, STORE_RANGE) }
  val storeForwardCandidates = VecInit(stores.map(s => s.valid && s.address(31, 2) === memory_address(31, 2) && (s.mask & memory_mask).orR)).asUInt
  val chooseForward = Module(new CircularGrant(p.storeSlots))
  chooseForward.ready := storeForwardCandidates; chooseForward.head := store_head
  val forward_match = chooseForward.valid
  val forward_full = (0 until p.storeSlots).map(s => chooseForward.grant(s) && (stores(s).mask & memory_mask) === memory_mask).reduce(_ | _)
  val forwardRead = Module(new GrantRead(p.storeSlots, 36))
  forwardRead.grant := chooseForward.grant; forwardRead.words := pack(stores.map(s => Cat(s.mask, s.data)))
  val chooseStore = Module(new Select(p.storeSlots, st))
  chooseStore.ready := VecInit(stores.map(s => s.valid && s.committed && !s.issued)).asUInt
  chooseStore.owner := pack((0 until p.storeSlots).map(_.U(st.W))); chooseStore.rob_head := store_head
  val store_send_slot = chooseStore.index
  dcache.store_valid := chooseStore.valid && state =/= done && state =/= fault
  dcache.store_tag := store_send_slot; dcache.store_address := Cat(stores(store_send_slot).address(31, 2), 0.U(2.W))
  dcache.store_data := stores(store_send_slot).data; dcache.store_mask := stores(store_send_slot).mask
  dcache.result_ready := true.B
  val store_pop = store_count =/= 0.U && stores(store_head).done
  val memory_allowed = select_valid(2) && !flush_all && !younger(executing(2).rid) && !dcache.result_valid
  dcache.load_valid := memory_allowed && executing(2).op === LOAD && memory_fault === 0.U && !forward_match && load_available
  dcache.load_address := Cat(memory_address(31, 2), 0.U(2.W)); dcache.load_tag := free_load
  val load_result = extendLoad(Mux(forward_full, forwardRead.value(31, 0), dcache.load_data), memory_address(1, 0), executing(2).size, executing(2).sign_extend)
  val load_allocate = dcache.load_valid && dcache.load_ready && !dcache.load_hit
  val store_allocate = memory_allowed && executing(2).op === STORE && memory_fault === 0.U && !memory_exit && store_count < p.storeSlots.U
  val memory_complete = memory_allowed && (memory_fault =/= 0.U || memory_exit || store_allocate ||
    (executing(2).op === LOAD && (forward_full || (dcache.load_valid && dcache.load_ready && dcache.load_hit))))
  val squashed_stores = PopCount(stores.map(s => s.valid && !s.committed && (younger(s.rid) || flush_all)))
  for (w <- 0 until 3) {
    wb_valid(w) := false.B; issue_fire(w) := false.B; wb_rid(w) := executing(w).rid
    wb_value(w) := 0.U; wb_fault(w) := 0.U; wb_address(w) := 0.U
  }
  when(!flush_all) {
    when(mdu.rsp_valid) {
      wb_valid(0) := rob(mdu.rsp_tag(rw - 1, 0)).valid && !younger(mdu.rsp_tag(rw - 1, 0))
      wb_rid(0) := mdu.rsp_tag; wb_value(0) := mdu.rsp_result
    }.elsewhen(select_valid(0) && !younger(executing(0).rid)) {
      when(isMdu(executing(0).op)) { issue_fire(0) := mdu.req_ready }.otherwise {
        issue_fire(0) := true.B; wb_valid(0) := true.B
        wb_value(0) := Mux(isBranch(executing(0).op), branch_i.result, alu_result(0))
        when(isBranch(executing(0).op) && branch_i.misaligned) { wb_fault(0) := TARGET_ALIGN; wb_address(0) := branch_i.next_pc }
      }
    }
    when(select_valid(1) && !younger(executing(1).rid)) { issue_fire(1) := true.B; wb_valid(1) := true.B; wb_value(1) := alu_result(1) }
    when(dcache.result_valid) {
      val owner = loads(dcache.result_tag)
      wb_rid(2) := owner.rid
      wb_valid(2) := owner.valid && !owner.canceled && rob(owner.rid).valid && !younger(owner.rid)
      wb_value(2) := extendLoad(dcache.result_data, owner.address(1, 0), owner.size, owner.sign_extend)
      wb_fault(2) := Mux(dcache.result_error, LOAD_BUS, NONE); wb_address(2) := owner.address
    }.otherwise {
      issue_fire(2) := memory_complete || load_allocate; wb_valid(2) := memory_complete
      wb_value(2) := Mux(executing(2).op === LOAD, load_result, executing(2).b)
      wb_fault(2) := memory_fault; wb_address(2) := memory_address
    }
  }

  var blockedRetirement: Bool = false.B
  var committedStore: Bool = false.B
  val retireLanes = (0 until 2).map { lane =>
    val meta = retirement_meta(lane)
    val can = !blockedRetirement && state === run && rob_count > lane.U && meta.done && meta.fault === 0.U && !meta.exiting &&
      (if (lane == 0) true.B else !redirect || redirect_rid =/= head) && (!committedStore || !meta.store)
    val allowed = if (lane < p.commitWidth) can else false.B
    commit_valid(lane) := allowed && meta.rd =/= 0.U; commit_rd(lane) := Mux(allowed, meta.rd, 0.U)
    blockedRetirement = !allowed; committedStore = committedStore || (allowed && meta.store)
    allowed
  }
  commit_count := PopCount(retireLanes)
  var blockedDispatch: Bool = false.B
  var usedBanks: UInt = 0.U(3.W)
  var saving: Bool = false.B
  var saveLane: Bool = false.B
  for (lane <- 0 until 2) {
    val d = decoded(lane)
    val instruction = word(frontend.packet_inst, lane, 32)
    val memoryClass = InstructionClass.memory(instruction)
    val branchClass = InstructionClass.branch(instruction)
    val mduClass = InstructionClass.mdu(instruction)
    dispatch_rid(lane) := tail + lane.U(rw.W)
    val bankChoice = WireDefault(0.U(2.W))
    when(memoryClass) { bankChoice := 2.U }
      .elsewhen(branchClass || mduClass) { bankChoice := 0.U }
      .elsewhen(usedBanks(0) || !free_queue_valid(0)) { bankChoice := 1.U }
      .elsewhen(usedBanks(1) || !free_queue_valid(1)) { bankChoice := 0.U }
      .otherwise { bankChoice := (occupancy(1) < occupancy(0) || (occupancy(1) === occupancy(0) && steer)).asUInt }
    if (p.integerPorts == 1) { when(!memoryClass) { bankChoice := 0.U } }
    val hasInput = if (lane >= p.renameWidth) false.B else if (physicalAllocation.isEmpty) {
      !blockedDispatch && frontend.packet_valid(lane) && (rob_count +& lane.U) < p.robEntries.U
    } else {
      !blockedDispatch && frontend.packet_valid(lane) && (rob_count +& lane.U) < p.robEntries.U && physicalAllocation.get._2(lane)
    }
    val faulting = word(frontend.packet_fault, lane, 4) =/= 0.U || d.illegal
    val bankAvailable = !usedBanks(bankChoice) && free_queue_valid(bankChoice) && (!branchClass || (checkpoint_available && !saving))
    val prepare = hasInput && (faulting || bankAvailable)
    val prepareNormal = prepare && !faulting
    dispatch_prepare(lane) := prepare; dispatch_valid(lane) := prepare && !flush_all && !redirect
    dispatch_bank(lane) := Mux(hasInput, Mux(faulting, 3.U, Mux(bankAvailable, bankChoice, 0.U)), 0.U)
    dispatch_index(lane) := Mux(prepareNormal, free_queue(bankChoice), 0.U)
    rename_prepare(lane) := prepareNormal && d.writes_rd
    rename_valid(lane) := rename_prepare(lane) && !flush_all && !redirect
    rename_rd(lane) := Mux(rename_prepare(lane), d.rd, 0.U)
    val save = prepareNormal && branchClass
    usedBanks = usedBanks | Mux(prepareNormal, (1.U(3.W) << bankChoice)(2, 0), 0.U(3.W))
    blockedDispatch = !prepare
    saving = saving || save
    saveLane = Mux(save, (lane == 1).B, saveLane)
  }
  dispatch_count := Mux(flush_all || redirect, 0.U, PopCount(dispatch_prepare))
  save_checkpoint := saving && !flush_all && !redirect; save_after_lane := saveLane
  for (lane <- 0 until 2) {
    val payload = dispatch_payload(lane); val d = decoded(lane)
    payload := 0.U.asTypeOf(new IssueEntry(p))
    payload.valid := true.B; payload.rid := dispatch_rid(lane); payload.generation := dispatch_order(lane)(rw)
    payload.op := d.op; payload.imm := d.imm; payload.pc := word(frontend.packet_pc, lane, 32)(31, 2)
    payload.history := word(frontend.packet_history, lane, hb); payload.prediction := word(frontend.packet_prediction, lane, 32)(31, 2)
    payload.size := d.mem_size; payload.sign_extend := d.load_signed; payload.use_imm := d.use_imm; payload.checkpoint := free_checkpoint
    for (s <- 0 until 2) {
      val port = lane * 2 + s; val registerId = source_register(port); val sourceId = word(rename_maps.source_slot, port, rw)
      val pending = rename_maps.source_pending(port) && registerId =/= 0.U && (if (s == 0) d.uses_rs1 else d.uses_rs2)
      val rawReady = !pending || (source_status(port)(5, 4) === 3.U && source_status(port)(3, 0) === 0.U)
      val rawValue = Mux(pending, source_result(port), Mux(registerId === 0.U, 0.U, source_architectural(port)))
      val hits = (0 until 3).map(w => pending && wb_good(w) && wb_rid(w) === sourceId)
      val chosen = Seq(hits(0) && !(hits(1) || hits(2)), hits(1) && !hits(2), hits(2))
      val value = mask(rawValue, !hits.reduce(_ | _)) | mask(wb_value(0), chosen(0)) |
        mask(wb_value(1), chosen(1)) | mask(loadValueCopies(5), chosen(2))
      val intraBundle = (lane == 1).B && rename_prepare(0) && sourceId === dispatch_rid(0) && pending
      val ready = (rawReady || hits.reduce(_ | _)) && !intraBundle
      if (s == 0) { payload.a := value; payload.ready_a := ready; payload.source_a := sourceId }
      else { payload.b := value; payload.ready_b := ready; payload.source_b := sourceId }
    }
  }

  val faultPC = reg(32); val faultInst = reg(32); val faultIV = flag(); val faultCause = reg(4); val faultAddress = reg(32)
  val cycleCount = reg(64); val retiredCount = reg(64); val branchMissCount = reg(64)
  val retireValid = flags(4); val retireStore = flags(4)
  val retirePC = regs(4, 32); val retireInst = regs(4, 32); val retireRd = regs(4, 5); val retireValue = regs(4, 32)
  val retireAddress = regs(4, 32); val retireWdata = regs(4, 32); val retireMask = regs(4, 4)
  fault_pc := faultPC; fault_inst := faultInst; fault_inst_valid := faultIV; fault_cause := faultCause; fault_addr := faultAddress
  cycle_count := cycleCount; retired_count := retiredCount; branch_miss_count := branchMissCount
  retire_valid := retireValid.asUInt; retire_store := retireStore.asUInt
  retire_pc := pack(retirePC); retire_inst := pack(retireInst); retire_rd := pack(retireRd); retire_value := pack(retireValue)
  retire_addr := pack(retireAddress); retire_wdata := pack(retireWdata); retire_wstrb := pack(retireMask)
  when(rst) {
    state := run; head := 0.U; tail := 0.U; tail_generation := false.B; rob_count := 0.U
    store_head := 0.U; store_tail := 0.U; store_count := 0.U; steer := false.B
    faultPC := 0.U; faultInst := 0.U; faultIV := false.B; faultCause := 0.U; faultAddress := 0.U
    cycleCount := 0.U; retiredCount := 0.U; branchMissCount := 0.U
    for (l <- 0 until 4) {
      retireValid(l) := false.B; retireStore(l) := false.B; retirePC(l) := 0.U; retireInst(l) := 0.U; retireRd(l) := 0.U
      retireValue(l) := 0.U; retireAddress(l) := 0.U; retireWdata(l) := 0.U; retireMask(l) := 0.U
    }
  }.otherwise {
    for (l <- 0 until 4) { retireValid(l) := false.B; retireStore(l) := false.B }
    when(state =/= done && state =/= fault) { cycleCount := cycleCount + 1.U }
    head := head + commit_count
    when(redirect) {
      tail := redirect_rid + 1.U
      rob_count := age(redirect_rid).pad(rw + 1) + 1.U - commit_count
      tail_generation := branch_generation_q ^ redirect_rid.andR
    }.otherwise {
      tail := tail + dispatch_count; rob_count := rob_count + dispatch_count - commit_count
      tail_generation := (Cat(tail_generation, tail) + dispatch_count)(rw)
    }
    store_count := store_count + store_allocate.asUInt - store_pop.asUInt - squashed_stores
    store_head := store_head + store_pop.asUInt; store_tail := store_tail + store_allocate.asUInt - squashed_stores
    when(dispatch_count =/= 0.U) { steer := !steer }
    when(redirect) { branchMissCount := branchMissCount + 1.U }
    retiredCount := retiredCount + commit_count + exit_accept.asUInt
    for (l <- 0 until 2) {
      when(commit_count > l.U) {
        retireValid(l) := true.B; retirePC(l) := rob(commit_rid(l)).pc; retireInst(l) := rob(commit_rid(l)).inst
        retireRd(l) := retirement_meta(l).rd; retireValue(l) := Mux(retirement_meta(l).rd === 0.U, 0.U, retirement_value(l))
        retireStore(l) := retirement_meta(l).store; retireAddress(l) := rob(commit_rid(l)).address.asUInt
        retireWdata(l) := rob(commit_rid(l)).wdata.asUInt; retireMask(l) := rob(commit_rid(l)).mask
      }
    }
    when(exit_head) { state := drain }
    when(exit_accept) {
      state := done
      for (l <- 0 until 4) { retireValid(l) := (l == 0).B; retireStore(l) := (l == 0).B }
      retirePC(0) := rob(head).pc; retireInst(0) := rob(head).inst; retireRd(0) := 0.U; retireValue(0) := 0.U
      retireAddress(0) := "h80000000".U; retireWdata(0) := retirement_value(0); retireMask(0) := 15.U
    }
    when(fault_head) {
      state := fault; faultPC := rob(head).pc; faultInst := rob(head).inst; faultIV := rob(head).iv
      faultCause := retirement_meta(0).fault; faultAddress := rob(head).fault_address.asUInt
    }
    when(dcache.store_error) {
      state := fault; faultCause := STORE_BUS; faultPC := stores(dcache.store_done_tag).pc
      faultInst := stores(dcache.store_done_tag).inst; faultIV := true.B; faultAddress := stores(dcache.store_done_tag).address
    }
  }
  def writeBytes(destination: Vec[UInt], value: UInt): Unit = {
    for (byte <- 0 until 4) destination(byte) := word(value, byte, 8)
  }
  for (r <- 0 until p.robEntries) {
    val row = rob(r); val controls = recoveryCopies(r / 4)
    when(rst) { row.valid := false.B; row.done := false.B }.otherwise {
      for (l <- 0 until 2) { when(commit_count > l.U && commit_rid(l) === r.U(rw.W)) { row.valid := false.B } }
      for (w <- 0 until 3) {
        when(wb_valid(w) && wb_rid(w) === r.U(rw.W)) {
          row.done := true.B; row.fault := wb_fault(w)
          if (!p.robWriteTree) {
            writeBytes(row.fault_address, wb_address(w))
            if (prfOwner.isEmpty) writeBytes(values(r), if (w == 2) loadValueCopies(2 * r / p.robEntries) else wb_value(w))
          }
        }
      }
      when(memory_complete && executing(2).rid === r.U(rw.W) && executing(2).op === STORE) {
        if (!p.robWriteTree) { writeBytes(row.address, memory_address); writeBytes(row.wdata, memory_data) }
        row.mask := memory_mask; row.exiting := memory_exit; row.store_slot := store_tail
      }
      when(recoveryYounger(r.U(rw.W), controls) || (controls(2 * rw + 2) && r.U(rw.W) =/= controls(rw - 1, 0))) { row.valid := false.B }
      for (l <- 0 until 2) {
        when(dispatch_valid(l) && dispatch_rid(l) === r.U(rw.W)) {
          row.valid := true.B; row.done := dispatch_bank(l) === 3.U; row.exiting := false.B
          row.fault := Mux(word(frontend.packet_fault, l, 4) =/= 0.U, word(frontend.packet_fault, l, 4), Mux(decoded(l).illegal, ILLEGAL, NONE))
          if (!p.robWriteTree) {
            writeBytes(row.fault_address, word(frontend.packet_pc, l, 32)); writeBytes(row.address, 0.U(32.W)); writeBytes(row.wdata, 0.U(32.W))
          }
          row.mask := 0.U
        }
      }
    }
    if (p.robWriteTree) {
      val writeControl = VecInit((0 until 3).map(w => wb_valid(w) && wb_rid(w) === r.U(rw.W)) ++
        Seq(memory_complete && executing(2).rid === r.U(rw.W) && executing(2).op === STORE) ++
        (0 until 2).map(l => dispatch_valid(l) && dispatch_rid(l) === r.U(rw.W))).asUInt
      val byteControls = Distribution(writeControl, 4)
      for (byte <- 0 until 4) {
        val c = byteControls(byte)
        when(!rst) {
          for (w <- 0 until 3) {
            when(c(w)) {
              row.fault_address(byte) := word(wb_address(w), byte, 8)
              if (prfOwner.isEmpty) values(r)(byte) := word(if (w == 2) loadValueCopies(2 * r / p.robEntries) else wb_value(w), byte, 8)
            }
          }
          when(c(3)) { row.address(byte) := word(memory_address, byte, 8); row.wdata(byte) := word(memory_data, byte, 8) }
          for (l <- 0 until 2) {
            when(c(4 + l)) { row.fault_address(byte) := word(word(frontend.packet_pc, l, 32), byte, 8); row.address(byte) := 0.U; row.wdata(byte) := 0.U }
          }
        }
      }
    }
    when(!rst && !row.valid) {
      for (l <- 0 until 2) {
        when(dispatch_rid(l) === r.U(rw.W)) {
          row.pc := word(frontend.packet_pc, l, 32); row.inst := word(frontend.packet_inst, l, 32); row.iv := frontend.packet_inst_valid(l)
          row.rd := rename_rd(l); row.store := decoded(l).op === STORE
        }
      }
    }
  }
  prfOwner.foreach { owners =>
    for (r <- 0 until p.robEntries; lane <- 0 until 2) {
      when(!rst && dispatch_valid(lane) && dispatch_rid(lane) === r.U(rw.W)) {
        owners(r) := physicalAllocation.get._1(lane)
      }
    }
    for (physical <- 0 until p.prfEntries; w <- 0 until 3) {
      when(!rst && wb_valid(w) && owners(wb_rid(w)) === physical.U) { writeBytes(values(physical), wb_value(w)) }
    }
    withClockAndReset(clk, rst) {
      when(!rst && PopCount(rob.map(_.valid)) > p.prfEntries.U) { stop("Speculative PRF overallocated") }
      for (a <- 0 until p.robEntries; b <- a + 1 until p.robEntries) {
        when(!rst && rob(a).valid && rob(b).valid && owners(a) === owners(b)) { stop("PRF slot has two live owners") }
      }
    }
  }
  for (b <- 0 until 3; q <- 0 until p.iqEntries) {
    val row = queue(b)(q); val controls = recoveryCopies(robRecGroups + b)
    val prepareLane = (0 until 2).map(l => dispatch_prepare(l) && dispatch_bank(l) === b.U(2.W) && dispatch_index(l) === q.U(qw.W))
    val wake = wakeCopies(b * 2 + 2 * q / p.iqEntries)
    def operand(live: Bool, prepare: Bool, ready: Bool, value: UInt, source: UInt, initialReady: Bool, initialValue: UInt): Operand = {
      val m = Module(new Operand(rw)); m.live := live; m.prepare := prepare; m.old_ready := ready; m.old_value := value
      m.source := source; m.initial_ready := initialReady; m.initial_value := initialValue
      m.wb_good := wake(3 * rw + 2, 3 * rw); m.wb_slots := wake(3 * rw - 1, 0)
      m.wb_values := Cat(loadValueCopies(2 + b), wb_value(1), wb_value(0)); m
    }
    val a = operand(row.valid, prepareLane.reduce(_ | _), row.ready_a, row.a, row.source_a,
      Mux(prepareLane(1), dispatch_payload(1).ready_a, dispatch_payload(0).ready_a),
      Mux(prepareLane(1), dispatch_payload(1).a, dispatch_payload(0).a))
    val bOperand = operand(row.valid, prepareLane.reduce(_ | _), row.ready_b, row.b, row.source_b,
      Mux(prepareLane(1), dispatch_payload(1).ready_b, dispatch_payload(0).ready_b),
      Mux(prepareLane(1), dispatch_payload(1).b, dispatch_payload(0).b))
    row.ready_a := a.next_ready; row.a := a.next_value; row.ready_b := bOperand.next_ready; row.b := bOperand.next_value
    if (b == 2) {
      val liveValue = operand(true.B, false.B, row.ready_a, row.a, row.source_a, false.B, 0.U(32.W)).next_value
      val liveSum = PrefixAdder(liveValue, row.imm)._1
      val capture = Module(new PriorityMux(32, 3))
      capture.enable := VecInit(Seq(!row.valid && prepareLane(0), !row.valid && prepareLane(1), row.valid && !row.ready_a)).asUInt
      capture.old_value := prepared_address(q); capture.data := Cat(liveSum, dispatch_address(1), dispatch_address(0))
      prepared_address(q) := capture.value
    }
    when(rst) { row.valid := false.B }.otherwise {
      when((issue_fire(b) && selected(b) === q.U(qw.W)) || recoveryYounger(row.rid, controls) || controls(2 * rw + 2)) { row.valid := false.B }
      for (l <- 0 until 2) {
        when(dispatch_valid(l) && dispatch_bank(l) === b.U(2.W) && dispatch_index(l) === q.U(qw.W)) { row.valid := true.B }
      }
    }
    when(!row.valid) {
      for (l <- 0 until 2) {
        when(prepareLane(l)) {
          val d = dispatch_payload(l)
          row.rid := d.rid; row.op := d.op; row.generation := d.generation
          row.source_a := d.source_a; row.source_b := d.source_b; row.pc := d.pc; row.prediction := d.prediction
          row.history := d.history; row.checkpoint := d.checkpoint; row.size := d.size; row.sign_extend := d.sign_extend
          row.use_imm := d.use_imm; row.imm := d.imm
        }
      }
    }
  }
  for (cp <- 0 until p.checkpoints) {
    val controls = recoveryCopies.last
    when(rst) { checkpoint_valid(cp) := false.B; checkpoint_owner(cp) := 0.U }.otherwise {
      when((branch_fire && branch_checkpoint_q === cp.U(cpw.W)) || recoveryYounger(checkpoint_owner(cp), controls) || controls(2 * rw + 2)) {
        checkpoint_valid(cp) := false.B
      }
      when(save_checkpoint && free_checkpoint === cp.U(cpw.W)) {
        checkpoint_valid(cp) := true.B; checkpoint_owner(cp) := dispatch_rid(save_after_lane)
      }
    }
  }
  for (s <- 0 until p.storeSlots) {
    val row = stores(s); val controls = recoveryCopies(robRecGroups + 3 + s / 4)
    when(rst) { row.valid := false.B }.otherwise {
      when(store_pop && store_head === s.U(st.W)) { row.valid := false.B }
      when(dcache.store_valid && dcache.store_ready && store_send_slot === s.U(st.W)) { row.issued := true.B }
      when(dcache.store_done && dcache.store_done_tag === s.U(st.W)) { row.done := true.B }
      for (l <- 0 until 2) {
        when(commit_count > l.U && retirement_meta(l).store && retirement_meta(l).store_slot === s.U(st.W)) { row.committed := true.B }
      }
      when(!row.committed && (recoveryYounger(row.rid, controls) || controls(2 * rw + 2))) { row.valid := false.B }
      when(store_allocate && store_tail === s.U(st.W)) {
        row.valid := true.B; row.committed := false.B; row.issued := false.B; row.done := false.B
        row.rid := executing(2).rid; row.address := memory_address; row.data := memory_data; row.mask := memory_mask
        row.pc := rob(executing(2).rid).pc; row.inst := rob(executing(2).rid).inst
      }
    }
  }
  for (l <- 0 until p.loadSlots) {
    val row = loads(l); val controls = recoveryCopies(robRecGroups + 3 + storeRecGroups + l / 4)
    when(rst) { row.valid := false.B }.otherwise {
      when(dcache.result_valid && dcache.result_tag === l.U(lt.W)) { row.valid := false.B }
      when(recoveryYounger(row.rid, controls) || controls(2 * rw + 2)) { row.canceled := true.B }
      when(load_allocate && free_load === l.U(lt.W)) {
        row.valid := true.B; row.canceled := false.B; row.rid := executing(2).rid
        row.address := memory_address; row.size := executing(2).size; row.sign_extend := executing(2).sign_extend
      }
    }
  }
  withClockAndReset(clk, rst) {
    when(!rst) {
      assert(rob_count <= p.robEntries.U, "ROB overflow")
      assert(store_count <= p.storeSlots.U, "Store queue overflow")
      // A direct dynamic-index assert is also emitted as an unguarded SVA by
      // firtool 1.62.0. Keep this simulation check in printf/stop form so the
      // unchanged course Yosys flow sees no verification-only $check cell.
      when(dcache.result_valid && !loads(dcache.result_tag).valid) {
        stop("Unowned cache response")
      }
      when(store_allocate) { assert(!stores(store_tail).valid, "Store slot reused early") }
      for (l <- 0 until 2) { when(dispatch_valid(l)) { assert(!rob(dispatch_rid(l)).valid, "ROB slot reused early") } }
      assert(wb_good(0) === (wb_valid(0) && wb_fault(0) === 0.U && rob(wb_rid(0)).rd =/= 0.U), "Integer wakeup qualification differs")
    }
  }
}
