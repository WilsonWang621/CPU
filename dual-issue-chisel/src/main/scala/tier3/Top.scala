package tier3

import chisel3._

class StudentTop(p: Config = Config()) extends Logic {
  override def desiredName = "student_top"
  val clock = IO(Input(Clock())); val reset = inBool()
  val araddr = out(32); val arvalid = outBool(); val arready = inBool()
  val rdata = in(32); val rresp = in(2); val rvalid = inBool(); val rready = outBool()
  val awaddr = out(32); val awvalid = outBool(); val awready = inBool()
  val wdata = out(32); val wstrb = out(4); val wvalid = outBool(); val wready = inBool()
  val bresp = in(2); val bvalid = inBool(); val bready = outBool()
  val core = Module(new Core(p)); core.clk := clock; core.rst := reset
  val bridge = Module(new AxiAdapter); bridge.clock := clock; bridge.reset := reset
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
    when(!reset) { assert(!core.faulted, "ParaRisc architectural fault") }
  }
}
