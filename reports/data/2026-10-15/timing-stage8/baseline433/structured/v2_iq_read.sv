// Limit each selected-entry decoder to one word of a wide issue payload.
(* keep_hierarchy=1 *)
module v2_iq_read #(
  parameter integer ENTRIES=8, WORD_BITS=32, INDEX_BITS=$clog2(ENTRIES)
)(
  input wire [INDEX_BITS-1:0] index,
  input wire [ENTRIES*WORD_BITS-1:0] words,
  output wire [WORD_BITS-1:0] value
);
  v2_read #(.ENTRIES(ENTRIES),.WORD_BITS(WORD_BITS),.INDEX_BITS(INDEX_BITS)) read_word (
    .index(index),.words(words),.value(value));
endmodule
