// Compute both cyclic-priority regions in parallel, then select one winner.
module v2_circular_grant #(
  parameter integer ENTRIES=16, INDEX_BITS=$clog2(ENTRIES)
)(
  input wire [ENTRIES-1:0] ready,
  input wire [INDEX_BITS-1:0] head,
  output wire valid,
  output logic [INDEX_BITS-1:0] index,
  output wire [ENTRIES-1:0] grant
);
  wire [ENTRIES-1:0] wrapped;
  wire any_wrapped=|wrapped;
  for(genvar q=0;q<ENTRIES;q=q+1) begin: slot
    wire highest_wrapped,highest_any;
    assign wrapped[q]=ready[q] && INDEX_BITS'(q)<head;
    if(q==ENTRIES-1) begin: last_slot
      assign highest_wrapped=wrapped[q];assign highest_any=ready[q];
    end else begin: earlier_slot
      assign highest_wrapped=wrapped[q] && !(|wrapped[ENTRIES-1:q+1]);
      assign highest_any=ready[q] && !(|ready[ENTRIES-1:q+1]);
    end
    assign grant[q]=highest_wrapped || (!any_wrapped && highest_any);
  end
  assign valid=|ready;
  always_comb begin
    index=0;
    for(integer q=0;q<ENTRIES;q=q+1)
      index=index | (INDEX_BITS'(q) & {INDEX_BITS{grant[q]}});
  end
endmodule
