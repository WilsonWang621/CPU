module v2_select #(
  parameter integer ENTRIES=8, SLOT_BITS=5, INDEX_BITS=$clog2(ENTRIES), YOUNGEST=0
)(
  input logic [ENTRIES-1:0] ready,
  input logic [ENTRIES*SLOT_BITS-1:0] owner,
  input logic [SLOT_BITS-1:0] rob_head,
  output logic valid,
  output logic [INDEX_BITS-1:0] index
);
  localparam integer LEAVES=2**$clog2(ENTRIES);
  // Give every level its own scalar wires. Older Verilator versions treat a
  // shared unpacked array as one dependency and misidentify a tree as a loop.
  for (genvar n=1;n<2*LEAVES;n=n+1) begin: node
    wire [SLOT_BITS-1:0] position;
    wire wrapped;
    wire [INDEX_BITS-1:0] selected;
    wire winner;
    if(n>=LEAVES) begin: leaf
      if(n-LEAVES<ENTRIES) begin: used
        assign position=owner[(n-LEAVES)*SLOT_BITS+:SLOT_BITS];
        assign wrapped=position<rob_head;
        assign winner=ready[n-LEAVES];
      end else begin: padding
        assign position=0;assign wrapped=0;assign winner=0;
      end
      assign selected=INDEX_BITS'(n-LEAVES);
    end else begin: branch
      wire same_side=node[2*n].wrapped==node[2*n+1].wrapped;
      wire left_first=YOUNGEST!=0 ?
        (same_side ? node[2*n].position>=node[2*n+1].position:node[2*n].wrapped):
        (same_side ? node[2*n].position<=node[2*n+1].position:!node[2*n].wrapped);
      wire left_wins=node[2*n].winner && (!node[2*n+1].winner || left_first);
      assign winner=node[2*n].winner || node[2*n+1].winner;
      assign selected=left_wins ? node[2*n].selected:node[2*n+1].selected;
      assign position=left_wins ? node[2*n].position:node[2*n+1].position;
      assign wrapped=left_wins ? node[2*n].wrapped:node[2*n+1].wrapped;
    end
  end
  assign valid=node[1].winner;
  assign index=node[1].selected;
endmodule
