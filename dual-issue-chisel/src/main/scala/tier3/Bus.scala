package tier3

import chisel3._
import chisel3.util._
import tier3.Bits._

class MemoryController(maxOutstanding: Int = 16) extends ClockedLogic {
  override def desiredName = "memory_controller"
  require(maxOutstanding >= 1)
  val pw = log2Ceil(maxOutstanding) max 1; val cw = log2Ceil(maxOutstanding + 1)
  val s_req_valid = in(2); val s_req_ready = out(2); val s_req_write = in(2)
  val s_req_addr = in(64); val s_req_wdata = in(64); val s_req_wstrb = in(8)
  val s_rsp_valid = out(2); val s_rsp_ready = in(2); val s_rsp_rdata = out(64); val s_rsp_error = out(2)
  val mem_req_valid = outBool(); val mem_req_ready = inBool(); val mem_req_write = outBool()
  val mem_req_addr = out(32); val mem_req_wdata = out(32); val mem_req_wstrb = out(4)
  val mem_rsp_valid = inBool(); val mem_rsp_ready = outBool(); val mem_rsp_rdata = in(32); val mem_rsp_error = inBool()
  val idle = outBool()
  val owners = flags(maxOutstanding); val head = reg(pw); val tail = reg(pw); val count = reg(cw)
  val request_valid = flag(); val request_owner = flag(); val next_owner = flag()
  val write = flag(); val address = reg(32); val data = reg(32); val strb = reg(4)
  val responseEnable = !rst && count =/= 0.U
  val responseOwner = owners(head)
  s_rsp_valid := VecInit((0 until 2).map(i => responseEnable && responseOwner === (i == 1).B && mem_rsp_valid)).asUInt
  s_rsp_rdata := pack((0 until 2).map(i => mask(mem_rsp_rdata, responseEnable && responseOwner === (i == 1).B)))
  s_rsp_error := VecInit((0 until 2).map(i => responseEnable && responseOwner === (i == 1).B && mem_rsp_error)).asUInt
  mem_rsp_ready := responseEnable && s_rsp_ready(responseOwner)
  val responseFire = mem_rsp_valid && mem_rsp_ready
  val space = count < maxOutstanding.U || responseFire
  mem_req_valid := !rst && request_valid && space
  mem_req_write := write; mem_req_addr := address; mem_req_wdata := data; mem_req_wstrb := strb
  val requestFire = mem_req_valid && mem_req_ready
  val selected = Mux(s_req_valid(next_owner), next_owner, !next_owner)
  val ready = !rst && (!request_valid || requestFire) && s_req_valid(selected)
  s_req_ready := VecInit((0 until 2).map(i => ready && selected === (i == 1).B)).asUInt
  val inputFire = s_req_valid(selected) && s_req_ready(selected)
  idle := count === 0.U && !request_valid && !s_req_valid.orR
  when(rst) {
    head := 0.U; tail := 0.U; count := 0.U
    request_valid := false.B; request_owner := false.B; next_owner := false.B
    write := false.B; address := 0.U; data := 0.U; strb := 0.U
    for (i <- 0 until maxOutstanding) owners(i) := false.B
  }.otherwise {
    when(requestFire =/= responseFire) { count := Mux(requestFire, count + 1.U, count - 1.U) }
    when(requestFire) {
      owners(tail) := request_owner
      tail := Mux(tail === (maxOutstanding - 1).U, 0.U, tail + 1.U)
      request_valid := false.B
    }
    when(responseFire) { head := Mux(head === (maxOutstanding - 1).U, 0.U, head + 1.U) }
    when(inputFire) {
      request_valid := true.B; request_owner := selected; next_owner := !selected
      write := s_req_write(selected)
      address := Mux(selected, s_req_addr(63, 32), s_req_addr(31, 0))
      data := Mux(selected, s_req_wdata(63, 32), s_req_wdata(31, 0))
      strb := Mux(selected, s_req_wstrb(7, 4), s_req_wstrb(3, 0))
    }
  }
}

class AxiAdapter(depth: Int = 16) extends Logic {
  override def desiredName = "pararisc_axi_adapter"
  require(depth >= 2 && isPow2(depth))
  val clock = IO(Input(Clock())); val reset = inBool()
  val req_valid = inBool(); val req_write = inBool(); val req_addr = in(32); val req_data = in(32); val req_mask = in(4)
  val req_ready = outBool(); val resp_valid = outBool(); val resp_data = out(32); val resp_error = outBool(); val resp_ready = inBool()
  val araddr = out(32); val arvalid = outBool(); val arready = inBool()
  val rdata = in(32); val rresp = in(2); val rvalid = inBool(); val rready = outBool()
  val awaddr = out(32); val awvalid = outBool(); val awready = inBool()
  val wdata = out(32); val wstrb = out(4); val wvalid = outBool(); val wready = inBool()
  val bresp = in(2); val bvalid = inBool(); val bready = outBool()
  private def reg(w: Int) = withClock(clock) { Reg(UInt(w.W)) }
  private def flag() = withClock(clock) { Reg(Bool()) }
  val pending = flag(); val writing = flag(); val aw_sent = flag(); val w_sent = flag()
  val address = reg(32); val data = reg(32); val mask = reg(4)
  val directions = withClock(clock) { Reg(Vec(depth, Bool())) }
  val head = reg(log2Ceil(depth)); val tail = reg(log2Ceil(depth)); val count = reg(log2Ceil(depth) + 1)
  araddr := address; arvalid := pending && !writing && !reset
  awaddr := address; awvalid := pending && writing && !aw_sent && !reset
  wdata := data; wstrb := mask; wvalid := pending && writing && !w_sent && !reset
  val launched = pending && Mux(writing, (aw_sent || awready) && (w_sent || wready), arready)
  req_ready := !reset && count < depth.U && (!pending || launched)
  val push = req_valid && req_ready
  val responseWrite = directions(head)
  resp_valid := !reset && count =/= 0.U && Mux(responseWrite, bvalid, rvalid)
  resp_data := Mux(responseWrite, 0.U, rdata); resp_error := Mux(responseWrite, bresp.orR, rresp.orR)
  rready := !reset && count =/= 0.U && !responseWrite && resp_ready
  bready := !reset && count =/= 0.U && responseWrite && resp_ready
  val pop = resp_valid && resp_ready
  when(reset) {
    pending := false.B; writing := false.B; aw_sent := false.B; w_sent := false.B
    address := 0.U; data := 0.U; mask := 0.U; head := 0.U; tail := 0.U; count := 0.U
    for (i <- 0 until depth) directions(i) := false.B
  }.otherwise {
    when(push =/= pop) { count := Mux(push, count + 1.U, count - 1.U) }
    when(pop) { head := head + 1.U }
    when(pending) {
      when(awvalid && awready) { aw_sent := true.B }
      when(wvalid && wready) { w_sent := true.B }
      when(launched) { pending := false.B; aw_sent := false.B; w_sent := false.B }
    }
    when(push) {
      directions(tail) := req_write; tail := tail + 1.U
      pending := true.B; writing := req_write; address := Cat(req_addr(31, 2), 0.U(2.W)); data := req_data; mask := req_mask
      aw_sent := false.B; w_sent := false.B
    }
  }
}
