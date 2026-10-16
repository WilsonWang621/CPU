package tier3

import chisel3._
import chisel3.util._
import tier3.Bits._

/** Verification-only observability. The production Core is inherited intact. */
class ObservedCore(p: Config) extends Core(p) {
  override def desiredName = "observed_cpu_top"
  val observed_issue = IO(Output(UInt(3.W)))
  val observed_ooo = IO(Output(Bool()))
  observed_issue := issue_fire.asUInt
  observed_ooo := rob(1).valid && !rob(1).done && (0 until 3).map { w =>
    wb_valid(w) && wb_rid(w) >= 2.U && wb_rid(w) <= 4.U
  }.reduce(_ || _)
}

/** Run only with requirements-programs/out-of-order.data. Asserts actual
  * execution width, younger execution past an older missing load, and ordered
  * retirement. It is never used for the area/frequency submission.
  */
class ArchitectureProbe(p: Config) extends Logic {
  override def desiredName = "student_top"
  val clock = IO(Input(Clock())); val reset = inBool()
  val araddr = out(32); val arvalid = outBool(); val arready = inBool()
  val rdata = in(32); val rresp = in(2); val rvalid = inBool(); val rready = outBool()
  val awaddr = out(32); val awvalid = outBool(); val awready = inBool()
  val wdata = out(32); val wstrb = out(4); val wvalid = outBool(); val wready = inBool()
  val bresp = in(2); val bvalid = inBool(); val bready = outBool()
  val core = Module(new ObservedCore(p)); core.clk := clock; core.rst := reset
  val bridge = Module(new AxiAdapter(p.maxMemOutstanding)); bridge.clock := clock; bridge.reset := reset
  bridge.req_valid := core.mem_req_valid; bridge.req_write := core.mem_req_write
  bridge.req_addr := core.mem_req_addr; bridge.req_data := core.mem_req_wdata; bridge.req_mask := core.mem_req_wstrb
  core.mem_req_ready := bridge.req_ready; core.mem_rsp_valid := bridge.resp_valid
  core.mem_rsp_rdata := bridge.resp_data; core.mem_rsp_error := bridge.resp_error
  bridge.resp_ready := core.mem_rsp_ready || core.halted
  araddr := bridge.araddr; arvalid := bridge.arvalid; bridge.arready := arready
  bridge.rdata := rdata; bridge.rresp := rresp; bridge.rvalid := rvalid; rready := bridge.rready
  awaddr := bridge.awaddr; awvalid := bridge.awvalid; bridge.awready := awready
  wdata := bridge.wdata; wstrb := bridge.wstrb; wvalid := bridge.wvalid; bridge.wready := wready
  bridge.bresp := bresp; bridge.bvalid := bvalid; bready := bridge.bready
  withClockAndReset(clock, reset) {
    val seenOutOfOrder = RegInit(false.B)
    val maximumIssue = RegInit(0.U(2.W))
    val nextRetiredPC = RegInit(0.U(32.W))
    val fired = PopCount(core.observed_issue)
    val retired = PopCount(core.retire_valid)
    when(!reset) {
      assert(!core.faulted, "Architectural fault in OoO probe")
      assert(fired <= p.issueWidth.U, "Actual issue count exceeds configured width")
      if (p.integerPorts == 1) assert(!core.observed_issue(1), "Disabled integer port issued")
      when(fired > maximumIssue) { maximumIssue := fired }
      when(core.observed_ooo) { seenOutOfOrder := true.B }
      for (lane <- 0 until 4) {
        val offset = if (lane == 0) 0.U else PopCount(core.retire_valid(lane - 1, 0))
        when(core.retire_valid(lane)) {
          assert(word(core.retire_pc, lane, 32) === nextRetiredPC + (offset << 2), "Retirement reordered the program")
        }
      }
      nextRetiredPC := nextRetiredPC + (retired << 2)
      when(awvalid && awready && awaddr === "h80000000".U) {
        assert(seenOutOfOrder, "No younger instruction executed past the older outstanding load")
        assert(nextRetiredPC + (retired << 2) === 48.U, "Missing or extra retirement")
        assert(maximumIssue === p.issueWidth.U, "Stimulus did not exercise the configured maximum issue width")
        printf(p"Architecture probe: PASS ooo=${seenOutOfOrder} max_issue=${maximumIssue} retired_bytes=${nextRetiredPC + (retired << 2)}\n")
      }
    }
  }
}
