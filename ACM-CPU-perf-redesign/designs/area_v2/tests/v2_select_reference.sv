// Frozen pre-portability-rewrite graph for combinational equivalence.
module v2_select_reference #(
  parameter integer ENTRIES=8, SLOT_BITS=5, INDEX_BITS=$clog2(ENTRIES), YOUNGEST=0
)(
  input logic [ENTRIES-1:0] ready,
  input logic [ENTRIES*SLOT_BITS-1:0] owner,
  input logic [SLOT_BITS-1:0] rob_head,
  output logic valid,
  output logic [INDEX_BITS-1:0] index
);
  localparam integer LEAVES=2**$clog2(ENTRIES);
  logic [SLOT_BITS-1:0] ages [2*LEAVES];
  logic [INDEX_BITS-1:0] indices [2*LEAVES];
  logic winners [2*LEAVES];
  for (genvar e=0;e<LEAVES;e=e+1) begin: leaves
    if (e<ENTRIES) begin: used
      assign ages[LEAVES+e]=owner[e*SLOT_BITS+:SLOT_BITS]-rob_head;
      assign winners[LEAVES+e]=ready[e];
    end else begin: padding
      assign ages[LEAVES+e]='0;
      assign winners[LEAVES+e]=0;
    end
    assign indices[LEAVES+e]=INDEX_BITS'(e);
  end
  for (genvar n=1;n<LEAVES;n=n+1) begin: tree
    wire left_wins=winners[2*n] && (!winners[2*n+1] ||
      (YOUNGEST!=0 ? ages[2*n]>=ages[2*n+1]:ages[2*n]<=ages[2*n+1]));
    assign winners[n]=winners[2*n] || winners[2*n+1];
    assign indices[n]=left_wins ? indices[2*n]:indices[2*n+1];
    assign ages[n]=left_wins ? ages[2*n]:ages[2*n+1];
  end
  assign valid=winners[1];
  assign index=indices[1];
endmodule
