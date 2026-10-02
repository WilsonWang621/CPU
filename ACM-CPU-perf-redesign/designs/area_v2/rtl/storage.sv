// Area-v2 structural prototypes. These are synthesizable building blocks,
// not a CPU and not a replacement for end-to-end area/timing measurement.
// Every storage bit and every specified port remains observable at the ports.
module v2_array #(
  parameter integer WIDTH=32, DEPTH=256, READ_PORTS=1, WRITE_PORTS=1,
  parameter integer ADDR_BITS=$clog2(DEPTH), MASK_BITS=4
)(
  input logic clk,
  input logic [READ_PORTS*ADDR_BITS-1:0] read_address,
  output logic [READ_PORTS*WIDTH-1:0] read_data,
  input logic [WRITE_PORTS-1:0] write_valid,
  input logic [WRITE_PORTS*ADDR_BITS-1:0] write_address,
  input logic [WRITE_PORTS*WIDTH-1:0] write_data,
  input logic [WRITE_PORTS*MASK_BITS-1:0] write_mask
);
  (* ram_style="registers" *) logic [WIDTH-1:0] words [DEPTH];
  for (genvar p=0;p<READ_PORTS;p=p+1) begin: reads
    assign read_data[p*WIDTH+:WIDTH]=words[read_address[p*ADDR_BITS+:ADDR_BITS]];
  end
  // A single physical write port is arbitrated BEFORE this array. No reset
  // of the data bits; tags/valid state determines architectural visibility.
  always_ff @(posedge clk) begin
    for (integer p=0;p<WRITE_PORTS;p=p+1)
      for (integer b=0;b<MASK_BITS;b=b+1)
        if (write_valid[p] && write_mask[p*MASK_BITS+b])
          words[write_address[p*ADDR_BITS+:ADDR_BITS]][b*(WIDTH/MASK_BITS)+:(WIDTH/MASK_BITS)]
            <=write_data[p*WIDTH+b*(WIDTH/MASK_BITS)+:(WIDTH/MASK_BITS)];
  end
endmodule

// Source values are captured at dispatch and by three result buses. Wakeup
// compares a 5-bit ROB slot, not a large PRF index plus a generation number.
// A slot cannot be recycled while a canceled external result still owns it;
// an independent transaction table performs that lifetime tracking.
module v2_operands #(
  parameter integer ENTRIES=24, ISSUE_PORTS=3, RESULT_PORTS=3,
  parameter integer SLOT_BITS=5, INDEX_BITS=$clog2(ENTRIES)
)(
  input logic clk,rst,
  input logic [ENTRIES-1:0] clear,
  input logic [1:0] dispatch_valid,
  input logic [2*INDEX_BITS-1:0] dispatch_index,
  input logic [2*SLOT_BITS-1:0] dispatch_owner,
  input logic [3:0] dispatch_ready,
  input logic [4*SLOT_BITS-1:0] dispatch_tag,
  input logic [127:0] dispatch_value,
  input logic [RESULT_PORTS-1:0] result_valid,
  input logic [RESULT_PORTS*SLOT_BITS-1:0] result_tag,
  input logic [RESULT_PORTS*32-1:0] result_value,
  input logic [ISSUE_PORTS*INDEX_BITS-1:0] issue_index,
  output logic [ISSUE_PORTS*64-1:0] issue_value,
  output logic [ENTRIES-1:0] ready,
  output logic [ENTRIES*SLOT_BITS-1:0] owner
);
  logic [ENTRIES-1:0] live;
  logic [1:0] available [ENTRIES];
  logic [SLOT_BITS-1:0] tags [ENTRIES][2];
  logic [31:0] values [ENTRIES][2];
  logic [SLOT_BITS-1:0] owners [ENTRIES];
  for (genvar e=0;e<ENTRIES;e=e+1) begin: row
    assign ready[e]=live[e] && (&available[e]);
    assign owner[e*SLOT_BITS+:SLOT_BITS]=owners[e];
    always_ff @(posedge clk) begin
      if (rst) begin
        live[e]<=0;
        available[e]<=0;
      end else begin
        if (clear[e]) live[e]<=0;
        for (integer s=0;s<2;s=s+1)
          for (integer r=0;r<RESULT_PORTS;r=r+1)
            if (live[e] && !available[e][s] && result_valid[r] &&
                tags[e][s]==result_tag[r*SLOT_BITS+:SLOT_BITS]) begin
              available[e][s]<=1;
              values[e][s]<=result_value[r*32+:32];
            end
        for (integer d=0;d<2;d=d+1)
          if (dispatch_valid[d] && dispatch_index[d*INDEX_BITS+:INDEX_BITS]==INDEX_BITS'(e)) begin
            live[e]<=1;
            owners[e]<=dispatch_owner[d*SLOT_BITS+:SLOT_BITS];
            for (integer s=0;s<2;s=s+1) begin
              available[e][s]<=dispatch_ready[d*2+s];
              tags[e][s]<=dispatch_tag[(d*2+s)*SLOT_BITS+:SLOT_BITS];
              values[e][s]<=dispatch_value[(d*2+s)*32+:32];
            end
          end
      end
    end
  end
  for (genvar p=0;p<ISSUE_PORTS;p=p+1) begin: reads
    assign issue_value[p*64+:32]=values[issue_index[p*INDEX_BITS+:INDEX_BITS]][0];
    assign issue_value[p*64+32+:32]=values[issue_index[p*INDEX_BITS+:INDEX_BITS]][1];
  end
endmodule

// Single winner per fixed functional port. The operand queues are partitioned
// 8 + 8 integer entries and 8 FIFO memory entries; never sort the same ready
// vector repeatedly to manufacture a generic four-wide issue fabric.
