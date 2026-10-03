// At most one instruction enters each bank per cycle. Record its age when
// it enters, so issue selection need not carry tags through a comparator tree.
module v2_issue_order #(
  parameter integer ENTRIES=8, INDEX_BITS=$clog2(ENTRIES)
)(
  input logic clk,rst,
  input logic [ENTRIES-1:0] allocate,ready,
  output logic [ENTRIES-1:0] grant,
  output logic valid,
  output logic [INDEX_BITS-1:0] index
);
  for(genvar q=0;q<ENTRIES;q=q+1) begin: row
    wire [ENTRIES-1:0] older;
    for(genvar r=0;r<ENTRIES;r=r+1) begin: column
      if(q==r) begin: self_entry
        assign older[r]=0;
      end else begin: other_entry
        logic precedes;
        always_ff @(posedge clk) begin
          if(rst) precedes<=0;
          else if(allocate[q]) precedes<=1;
          else if(allocate[r]) precedes<=0;
        end
        assign older[r]=precedes;
      end
    end
    assign grant[q]=ready[q] && !(|(ready & older));
  end
  always_comb begin
    valid=|grant;index=0;
    for(integer q=0;q<ENTRIES;q=q+1)
      index=index | ({INDEX_BITS{grant[q]}} & INDEX_BITS'(q));
  end
endmodule

