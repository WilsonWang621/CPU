// Keep bank-local decoding separate from the final bank selection. A late
// address bit then drives local decoder inputs instead of all cache words.
(* keep_hierarchy=1 *)
module v2_cache_read #(
  parameter integer ENTRIES=64,WORD_BITS=32,INDEX_BITS=$clog2(ENTRIES)
)(
  input wire [INDEX_BITS-1:0] index,
  input wire [ENTRIES*WORD_BITS-1:0] words,
  output wire [WORD_BITS-1:0] value
);
  v2_read #(.ENTRIES(ENTRIES),.WORD_BITS(WORD_BITS),.INDEX_BITS(INDEX_BITS)) read_word (
    .index(index),.words(words),.value(value));
endmodule
