// ParaRisc: Area-v2 queues/checkpoints and an ordered AXI4-Lite adapter.
module student_top #(
  parameter integer ROB_BITS=5, IQ_ENTRIES=4, LOAD_SLOTS=8, STORE_SLOTS=16,
  parameter integer CHECKPOINTS=3, ISSUE_WIDTH=2, COMMIT_WIDTH=2,
  parameter integer IC_INDEX_BITS=5, DC_INDEX_BITS=4, DC_LINE_BITS=6
) (
  input wire clock, reset,
  output wire [31:0] araddr,
  output wire arvalid,
  input wire arready,
  input wire [31:0] rdata,
  input wire [1:0] rresp,
  input wire rvalid,
  output wire rready,
  output wire [31:0] awaddr,
  output wire awvalid,
  input wire awready,
  output wire [31:0] wdata,
  output wire [3:0] wstrb,
  output wire wvalid,
  input wire wready,
  input wire [1:0] bresp,
  input wire bvalid,
  output wire bready
);
  wire request_valid,request_write,request_ready,response_valid,response_ready,response_error;
  wire [31:0] request_addr,request_data,response_data;
  wire [3:0] request_mask;
  wire halted,faulted,core_response_ready;
  // The core finishes when its exit request is accepted; AXI finishes at B.
  assign response_ready = core_response_ready || halted;
  wire [31:0] fault_pc,fault_inst,fault_addr;
  wire [3:0] fault_cause;
  cpu_top #(.ROB_ENTRIES(1<<ROB_BITS),.IQ_ENTRIES(IQ_ENTRIES),.LOAD_SLOTS(LOAD_SLOTS),
    .STORE_SLOTS(STORE_SLOTS),.CHECKPOINTS(CHECKPOINTS),.INTEGER_PORTS(ISSUE_WIDTH),.COMMIT_WIDTH(COMMIT_WIDTH),
    .ICACHE_BYTES(32*(1<<IC_INDEX_BITS)),.DCACHE_BYTES(2*(1<<DC_LINE_BITS)*(1<<DC_INDEX_BITS)),
    .DCACHE_LINE_BYTES(1<<DC_LINE_BITS),.MAX_MEM_OUTSTANDING(16),.RAM_BYTES(268435456)) core (
    .clk(clock),.rst(reset),.mem_req_valid(request_valid),.mem_req_write(request_write),
    .mem_req_addr(request_addr),.mem_req_wdata(request_data),.mem_req_wstrb(request_mask),.mem_req_ready(request_ready),
    .mem_rsp_valid(response_valid),.mem_rsp_ready(core_response_ready),.mem_rsp_rdata(response_data),.mem_rsp_error(response_error),
    .halted(halted),.faulted(faulted),.fault_pc(fault_pc),.fault_inst(fault_inst),.fault_addr(fault_addr),.fault_cause(fault_cause),
    .fault_inst_valid(),.retire_valid(),.retire_pc(),.retire_inst(),.retire_rd(),.retire_value(),.retire_store(),
    .retire_addr(),.retire_wdata(),.retire_wstrb(),.cycle_count(),.retired_count(),.branch_miss_count(),
    .load_replay_count(),.icache_miss_count(),.dcache_miss_count()
  );
  pararisc_axi_adapter bridge (
    .clock(clock),.reset(reset),.req_valid(request_valid),.req_write(request_write),
    .req_addr(request_addr),.req_data(request_data),.req_mask(request_mask),.req_ready(request_ready),
    .resp_valid(response_valid),.resp_ready(response_ready),.resp_data(response_data),.resp_error(response_error),
    .araddr(araddr),.arvalid(arvalid),.arready(arready),.rdata(rdata),.rresp(rresp),.rvalid(rvalid),.rready(rready),
    .awaddr(awaddr),.awvalid(awvalid),.awready(awready),.wdata(wdata),.wstrb(wstrb),.wvalid(wvalid),.wready(wready),
    .bresp(bresp),.bvalid(bvalid),.bready(bready)
  );
`ifndef SYNTHESIS
  always @(posedge clock) if(!reset && faulted)
    $fatal(1,"ParaRisc fault cause=%0d pc=%08x inst=%08x addr=%08x",fault_cause,fault_pc,fault_inst,fault_addr);
`endif
endmodule
