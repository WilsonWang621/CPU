// Physical store slots are ordered around head; choose the youngest match.
module v2_circular_priority #(
  parameter integer ENTRIES=16, INDEX_BITS=$clog2(ENTRIES)
)(
  input wire [ENTRIES-1:0] ready,
  input wire [INDEX_BITS-1:0] head,
  output wire valid,
  output logic [INDEX_BITS-1:0] index
);
  wire [ENTRIES-1:0] wrapped,active,winning;
  for(genvar q=0;q<ENTRIES;q=q+1) begin: slot
    assign wrapped[q]=ready[q] && INDEX_BITS'(q)<head;
    if(q==ENTRIES-1) begin: last_slot
      assign winning[q]=active[q];
    end else begin: earlier_slot
      assign winning[q]=active[q] && !(|active[ENTRIES-1:q+1]);
    end
  end
  assign valid=|ready;
  assign active=(|wrapped) ? wrapped:ready;
  always_comb begin
    index=0;
    for(integer q=0;q<ENTRIES;q=q+1)
      index=index | (INDEX_BITS'(q) & {INDEX_BITS{winning[q]}});
  end
endmodule
