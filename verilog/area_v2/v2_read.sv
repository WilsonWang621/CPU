// Decode the address once per entry, then combine words with a balanced tree.
// A binary mux otherwise makes each address bit drive every payload bit.
module v2_read #(
  parameter integer ENTRIES=8, WORD_BITS=32, INDEX_BITS=$clog2(ENTRIES), INDEX_GROUP=0
)(
  input logic [INDEX_BITS-1:0] index,
  input logic [ENTRIES*WORD_BITS-1:0] words,
  output logic [WORD_BITS-1:0] value
);
  localparam integer LEAVES=2**$clog2(ENTRIES);
  localparam integer GROUP_SIZE=INDEX_GROUP>0 ? INDEX_GROUP:ENTRIES;
  localparam integer INDEX_COPIES=(ENTRIES+GROUP_SIZE-1)/GROUP_SIZE;
  wire [INDEX_BITS*INDEX_COPIES-1:0] local_indices;
  v2_distribution #(.WIDTH(INDEX_BITS),.LEAVES(INDEX_COPIES)) index_tree (
    .data_in(index),.data_out(local_indices));
  for(genvar n=1;n<2*LEAVES;n=n+1) begin: node
    wire [WORD_BITS-1:0] word_value;
    if(n>=LEAVES) begin: leaf
      if(n-LEAVES<ENTRIES) begin: used
        wire selected=local_indices[((n-LEAVES)/GROUP_SIZE)*INDEX_BITS+:INDEX_BITS]==INDEX_BITS'(n-LEAVES);
        v2_read_mask #(.WORD_BITS(WORD_BITS)) mask_word (
          .selected(selected),.word(words[(n-LEAVES)*WORD_BITS+:WORD_BITS]),.value(word_value));
      end else begin: padding
        assign word_value=0;
      end
    end else begin: branch
      assign word_value=node[2*n].word_value | node[2*n+1].word_value;
    end
  end
  assign value=node[1].word_value;
endmodule

// Keep the per-word mask separate so the default ABC pass cannot turn the
// decoded read back into a bit-level mux with a shared high-fanout selector.
(* keep_hierarchy=1 *)
module v2_read_mask #(parameter integer WORD_BITS=32)(
  input wire selected,
  input wire [WORD_BITS-1:0] word,
  output wire [WORD_BITS-1:0] value
);
  assign value=word & {WORD_BITS{selected}};
endmodule
