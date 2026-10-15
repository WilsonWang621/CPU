module v2_parallel_select #(
  parameter integer ENTRIES=4, SLOT_BITS=6, INDEX_BITS=$clog2(ENTRIES)
)(
  input wire [ENTRIES-1:0] ready,
  input wire [ENTRIES*SLOT_BITS-1:0] owner,
  input wire [SLOT_BITS-1:0] rob_head,
  output wire valid,
  output logic [INDEX_BITS-1:0] index,
  output wire [ENTRIES-1:0] grant
);
  for(genvar row=0;row<ENTRIES;row=row+1) begin: candidate
    wire [ENTRIES-1:0] blocked;
    for(genvar other=0;other<ENTRIES;other=other+1) begin: comparison
      wire first;
      if(row<other) begin: ordered_pair
        v2_order_compare #(.BITS(SLOT_BITS)) compare (
          .a(owner[row*SLOT_BITS+:SLOT_BITS]),.b(owner[other*SLOT_BITS+:SLOT_BITS]),.first(first));
      end else if(row>other) begin: inverse_pair
        assign first=!candidate[other].comparison[row].first;
      end else begin: same_row
        assign first=1;
      end
      assign blocked[other]=ready[other] && !first;
    end
    assign grant[row]=ready[row] && !(|blocked);
  end
  assign valid=|ready;
  always_comb begin
    index=0;
    for(integer row=0;row<ENTRIES;row=row+1)
      index=index | (INDEX_BITS'(row) & {INDEX_BITS{grant[row]}});
  end
endmodule
