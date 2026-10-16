module student_top(
input wire clock,
input wire reset,
input wire arready,
input wire [31:0] rdata,
input wire [1:0] rresp,
input wire rvalid,
input wire awready,
input wire wready,
input wire [1:0] bresp,
input wire bvalid,
output wire [31:0] araddr,
output wire arvalid,
output wire rready,
output wire [31:0] awaddr,
output wire awvalid,
output wire [31:0] wdata,
output wire [3:0] wstrb,
output wire wvalid,
output wire bready);
wire [31:0] ref_araddr;
wire ref_arvalid;
wire ref_rready;
wire [31:0] ref_awaddr;
wire ref_awvalid;
wire [31:0] ref_wdata;
wire [3:0] ref_wstrb;
wire ref_wvalid;
wire ref_bready;
chisel_student_top native(.clock(clock),.reset(reset),.arready(arready),.rdata(rdata),.rresp(rresp),.rvalid(rvalid),.awready(awready),.wready(wready),.bresp(bresp),.bvalid(bvalid),.araddr(araddr),.arvalid(arvalid),.rready(rready),.awaddr(awaddr),.awvalid(awvalid),.wdata(wdata),.wstrb(wstrb),.wvalid(wvalid),.bready(bready));
ref_student_top reference(.clock(clock),.reset(reset),.arready(arready),.rdata(rdata),.rresp(rresp),.rvalid(rvalid),.awready(awready),.wready(wready),.bresp(bresp),.bvalid(bvalid),.araddr(ref_araddr),.arvalid(ref_arvalid),.rready(ref_rready),.awaddr(ref_awaddr),.awvalid(ref_awvalid),.wdata(ref_wdata),.wstrb(ref_wstrb),.wvalid(ref_wvalid),.bready(ref_bready));
always @(posedge clock) if (!reset) begin
  if (arvalid !== ref_arvalid) $fatal(1,"Chisel/Verilog cycle mismatch: arvalid");
  if (awvalid !== ref_awvalid) $fatal(1,"Chisel/Verilog cycle mismatch: awvalid");
  if (wvalid !== ref_wvalid) $fatal(1,"Chisel/Verilog cycle mismatch: wvalid");
  if (rready !== ref_rready) $fatal(1,"Chisel/Verilog cycle mismatch: rready");
  if (bready !== ref_bready) $fatal(1,"Chisel/Verilog cycle mismatch: bready");
  if (arvalid && araddr !== ref_araddr) $fatal(1,"Chisel/Verilog payload mismatch: araddr");
  if (awvalid && awaddr !== ref_awaddr) $fatal(1,"Chisel/Verilog payload mismatch: awaddr");
  if (wvalid && wdata !== ref_wdata) $fatal(1,"Chisel/Verilog payload mismatch: wdata");
  if (wvalid && wstrb !== ref_wstrb) $fatal(1,"Chisel/Verilog payload mismatch: wstrb");
end
endmodule
