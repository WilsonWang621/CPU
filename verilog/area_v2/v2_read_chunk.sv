// Small, wide queues can afford a separate decode for each 32-bit chunk.
// The selector then drives a few dozen decoders instead of a full payload.
(* keep_hierarchy=1 *)
module v2_read_chunk #(
  parameter integer WORD_BITS=32, INDEX_BITS=3, ROW=0
)(
  input wire [INDEX_BITS-1:0] index,
  input wire [WORD_BITS-1:0] word,
  output wire [WORD_BITS-1:0] value
);
  assign value=word & {WORD_BITS{index==INDEX_BITS'(ROW)}};
endmodule

