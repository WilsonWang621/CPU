// One AXI read owner, eight ordered words per refill; independent posted writes.
module pararisc_bus #(parameter integer DC_LINE_BITS = 6) (
  input wire clock, reset,
  input wire i_req, d_req,
  input wire [31:0] i_addr, d_addr,
  output wire i_ready, d_ready,
  output wire i_valid, d_valid,
  output wire [4:0] beat,
  output wire [31:0] refill_data,
  input wire store_valid,
  input wire [31:0] store_addr, store_data,
  input wire [3:0] store_mask,
  output wire store_ready,
  output reg fault,
  output wire [31:0] araddr, awaddr, wdata,
  output wire [3:0] wstrb,
  output wire arvalid, rready, awvalid, wvalid, bready,
  input wire arready, rvalid, awready, wready, bvalid,
  input wire [31:0] rdata,
  input wire [1:0] rresp, bresp
);
  reg active, owner;
  reg [31:0] base;
  reg [5:0] sent, received;
  wire [5:0] words = owner ? 6'(1 << (DC_LINE_BITS-2)) : 6'd8;
  reg [31:0] wq_addr [0:15], wq_data [0:15];
  reg [3:0] wq_mask [0:15];
  reg [3:0] head, tail;
  reg [4:0] count, outstanding;
  reg sent_aw, sent_w;
  wire push = store_valid && store_ready;
  wire pop = count != 0 && (sent_aw || (awvalid && awready)) && (sent_w || (wvalid && wready));
  wire ack = bvalid && bready;
  // A refill observes all earlier stores, even when AW and W have different backpressure.
  wire read_free = !active && count == 0 && outstanding == 0 && !push && !fault;
  assign d_ready = read_free;
  assign i_ready = read_free && !d_req;
  assign araddr = base + {24'b0, sent, 2'b0};
  assign arvalid = active && sent < words && !fault;
  assign rready = active && received < words;
  assign i_valid = active && !owner && rvalid && rready && rresp == 0;
  assign d_valid = active && owner && rvalid && rready && rresp == 0;
  assign beat = received[4:0];
  assign refill_data = rdata;
  assign store_ready = count < 16 && !fault;
  assign awaddr = wq_addr[head];
  assign wdata = wq_data[head];
  assign wstrb = wq_mask[head];
  assign awvalid = count != 0 && !sent_aw && outstanding < 16;
  assign wvalid = count != 0 && !sent_w && outstanding < 16;
  assign bready = outstanding != 0;
  always @(posedge clock) begin
    if (reset) begin
      active <= 0; owner <= 0; base <= 0; sent <= 0; received <= 0;
      head <= 0; tail <= 0; count <= 0; outstanding <= 0;
      sent_aw <= 0; sent_w <= 0; fault <= 0;
    end else begin
      if (read_free && (d_req || i_req)) begin
        active <= 1; owner <= d_req;
        base <= d_req ? d_addr & (32'hffff_ffff << DC_LINE_BITS) : i_addr & 32'hffff_ffe0;
        sent <= 0; received <= 0;
      end
      if (arvalid && arready) sent <= sent + 1;
      if (rvalid && rready) begin
        received <= received + 1;
        if (received == words-1) active <= 0;
        if (rresp != 0) fault <= 1;
      end
      if (push) begin
        wq_addr[tail] <= store_addr; wq_data[tail] <= store_data; wq_mask[tail] <= store_mask;
        tail <= tail + 1;
      end
      if (awvalid && awready) sent_aw <= 1;
      if (wvalid && wready) sent_w <= 1;
      if (pop) begin head <= head + 1; sent_aw <= 0; sent_w <= 0; end
      case ({push, pop})
        2'b10: count <= count + 1;
        2'b01: count <= count - 1;
        default: begin end
      endcase
      case ({pop, ack})
        2'b10: outstanding <= outstanding + 1;
        2'b01: outstanding <= outstanding - 1;
        default: begin end
      endcase
      if (ack && bresp != 0) fault <= 1;
    end
  end
endmodule
