// Translate ordered memory requests into independent AXI4-Lite channels.
// R and B may return in either order; the direction FIFO restores core order.
module pararisc_axi_adapter #(parameter integer DEPTH=16, PTR_BITS=$clog2(DEPTH)) (
  input wire clock, reset,
  input wire req_valid, req_write,
  input wire [31:0] req_addr, req_data,
  input wire [3:0] req_mask,
  output wire req_ready,
  output wire resp_valid,
  output wire [31:0] resp_data,
  output wire resp_error,
  input wire resp_ready,
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
  reg pending, writing, aw_sent, w_sent;
  reg [31:0] address, data;
  reg [3:0] mask;
  reg [DEPTH-1:0] directions;
  reg [PTR_BITS-1:0] head, tail;
  reg [PTR_BITS:0] count;
  assign araddr=address;
  assign arvalid=pending && !writing && !reset;
  assign awaddr=address;
  assign awvalid=pending && writing && !aw_sent && !reset;
  assign wdata=data;
  assign wstrb=mask;
  assign wvalid=pending && writing && !w_sent && !reset;
  wire launched=pending && (writing ?
    ((aw_sent || awready) && (w_sent || wready)) : arready);
  assign req_ready=!reset && count<DEPTH && (!pending || launched);
  wire push=req_valid && req_ready;
  wire response_write=directions[head];
  assign resp_valid=!reset && count!=0 && (response_write ? bvalid:rvalid);
  assign resp_data=response_write ? 32'b0:rdata;
  assign resp_error=response_write ? |bresp:|rresp;
  assign rready=!reset && count!=0 && !response_write && resp_ready;
  assign bready=!reset && count!=0 && response_write && resp_ready;
  wire pop=resp_valid && resp_ready;
  always @(posedge clock) begin
    if(reset) begin
      pending<=0; writing<=0; aw_sent<=0; w_sent<=0;
      address<=0; data<=0; mask<=0;
      head<=0; tail<=0; count<=0; directions<=0;
    end else begin
      case({push,pop})
        2'b10: count<=count+1'b1;
        2'b01: count<=count-1'b1;
        default: begin end
      endcase
      if(pop) head<=head+1'b1;
      if(pending) begin
        if(awvalid && awready) aw_sent<=1;
        if(wvalid && wready) w_sent<=1;
        if(launched) begin pending<=0; aw_sent<=0; w_sent<=0; end
      end
      if(push) begin
        directions[tail]<=req_write; tail<=tail+1'b1;
        pending<=1; writing<=req_write; address<={req_addr[31:2],2'b0}; data<=req_data; mask<=req_mask;
        aw_sent<=0; w_sent<=0;
      end
    end
  end
endmodule
