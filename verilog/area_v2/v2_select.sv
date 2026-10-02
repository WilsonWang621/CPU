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
    wire [SLOT_BITS-1:0] age;
    wire [INDEX_BITS-1:0] selected;
    wire winner;
    if(n>=LEAVES) begin: leaf
      if(n-LEAVES<ENTRIES) begin: used
        assign age=owner[(n-LEAVES)*SLOT_BITS+:SLOT_BITS]-rob_head;
        assign winner=ready[n-LEAVES];
      end else begin: padding
        assign age=0;assign winner=0;
      end
      assign selected=INDEX_BITS'(n-LEAVES);
    end else begin: branch
      wire left_wins=node[2*n].winner && (!node[2*n+1].winner ||
        (YOUNGEST!=0 ? node[2*n].age>=node[2*n+1].age:node[2*n].age<=node[2*n+1].age));
      assign winner=node[2*n].winner || node[2*n+1].winner;
      assign selected=left_wins ? node[2*n].selected:node[2*n+1].selected;
      assign age=left_wins ? node[2*n].age:node[2*n+1].age;
    end
  end
  assign valid=node[1].winner;
  assign index=node[1].selected;
endmodule
