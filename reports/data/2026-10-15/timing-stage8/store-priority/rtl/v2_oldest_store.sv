// Select the first ready physical slot at or after head, wrapping if needed.
module v2_oldest_store #(
  parameter integer ENTRIES=16, INDEX_BITS=$clog2(ENTRIES)
)(
  input wire [ENTRIES-1:0] ready,
  input wire [INDEX_BITS-1:0] head,
  output wire valid,
  output logic [INDEX_BITS-1:0] index,
  output wire [ENTRIES-1:0] grant
);
  wire [ENTRIES-1:0] current_region;
  wire any_current=|current_region;
  for(genvar q=0;q<ENTRIES;q=q+1) begin: slot
    wire first_current,first_any;
    assign current_region[q]=ready[q] && INDEX_BITS'(q)>=head;
    if(q==0) begin: first_slot
      assign first_current=current_region[q];assign first_any=ready[q];
    end else begin: later_slot
      assign first_current=current_region[q] && !(|current_region[q-1:0]);
      assign first_any=ready[q] && !(|ready[q-1:0]);
    end
    assign grant[q]=first_current || (!any_current && first_any);
  end
  assign valid=|ready;
  always_comb begin
    index=0;
    for(integer q=0;q<ENTRIES;q=q+1)
      index=index | (INDEX_BITS'(q) & {INDEX_BITS{grant[q]}});
  end
endmodule
