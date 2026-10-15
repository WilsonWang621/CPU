// Keep each physical tag comparison separate from the set selection logic.
(* keep_hierarchy=1 *)
module v2_cache_tag_match #(
  parameter integer TAG_BITS=18, WORDS=16, WORD_BITS=$clog2(WORDS)
)(
  input wire selected,valid,
  input wire [TAG_BITS-1:0] tag,request_tag,
  input wire [WORDS-1:0] word_valid,
  input wire [WORD_BITS-1:0] word_index,
  output wire match_bits,hit
);
  assign match_bits=selected && valid && tag==request_tag;
  assign hit=match_bits && word_valid[word_index];
endmodule
