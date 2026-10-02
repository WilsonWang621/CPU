// Decode the address once per entry, then combine words with a balanced tree.
// A binary mux otherwise makes each address bit drive every payload bit.
module v2_read #(
  parameter integer ENTRIES=8, WORD_BITS=32, INDEX_BITS=$clog2(ENTRIES)
)(
  input logic [INDEX_BITS-1:0] index,
  input logic [ENTRIES*WORD_BITS-1:0] words,
  output logic [WORD_BITS-1:0] value
);
  localparam integer LEAVES=2**$clog2(ENTRIES);
  for(genvar n=1;n<2*LEAVES;n=n+1) begin: node
    wire [WORD_BITS-1:0] word_value;
    if(n>=LEAVES) begin: leaf
      if(n-LEAVES<ENTRIES) begin: used
        wire selected=index==INDEX_BITS'(n-LEAVES);
        assign word_value=words[(n-LEAVES)*WORD_BITS+:WORD_BITS] & {WORD_BITS{selected}};
      end else begin: padding
        assign word_value=0;
      end
    end else begin: branch
      assign word_value=node[2*n].word_value | node[2*n+1].word_value;
    end
  end
  assign value=node[1].word_value;
endmodule
