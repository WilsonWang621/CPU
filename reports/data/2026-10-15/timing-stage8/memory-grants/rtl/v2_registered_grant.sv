// Independent local one-hot copies at the existing memory-selection edge.
(* keep_hierarchy=1 *)
module v2_registered_grant #(parameter integer ENTRIES=4, INDEX_BITS=$clog2(ENTRIES))(
  input wire clk,rst,valid,
  input wire [INDEX_BITS-1:0] index,
  output logic [ENTRIES-1:0] grant
);
  for(genvar q=0;q<ENTRIES;q=q+1) begin: row
    always_ff @(posedge clk)
      if(rst) grant[q]<=0;
      else grant[q]<=valid && index==INDEX_BITS'(q);
  end
endmodule
