// Parallel set/tag lookup with bounded address loads. Way zero wins ties.
(* keep_hierarchy=1 *)
module v2_cache_lookup #(
  parameter integer SETS=16, TAG_BITS=18, WORDS=16,
  SET_BITS=$clog2(SETS), WORD_BITS=$clog2(WORDS)
)(
  input wire [TAG_BITS+SET_BITS+WORD_BITS-1:0] address,
  input wire [2*SETS*TAG_BITS-1:0] tags,
  input wire [2*SETS-1:0] valid,
  input wire [2*SETS*WORDS-1:0] word_valid,
  output wire [1:0] match_bits,
  output wire hit
);
  localparam integer ADDRESS_BITS=TAG_BITS+SET_BITS+WORD_BITS;
  localparam integer GROUPS=(2*SETS+3)/4;
  wire [ADDRESS_BITS*GROUPS-1:0] addresses;
  wire [2*SETS-1:0] line_matches,line_hits;
  wire [1:0] way_hits;
  v2_distribution #(.WIDTH(ADDRESS_BITS),.LEAVES(GROUPS)) distribute_address (
    .data_in(address),.data_out(addresses));
  for(genvar line=0;line<2*SETS;line=line+1) begin: comparison
    wire [ADDRESS_BITS-1:0] local_address=addresses[(line/4)*ADDRESS_BITS+:ADDRESS_BITS];
    v2_cache_tag_match #(.TAG_BITS(TAG_BITS),.WORDS(WORDS)) compare (
      .selected(local_address[WORD_BITS+:SET_BITS]==SET_BITS'(line/2)),.valid(valid[line]),
      .tag(tags[line*TAG_BITS+:TAG_BITS]),.request_tag(local_address[WORD_BITS+SET_BITS+:TAG_BITS]),
      .word_valid(word_valid[line*WORDS+:WORDS]),.word_index(local_address[0+:WORD_BITS]),
      .match_bits(line_matches[line]),.hit(line_hits[line]));
  end
  for(genvar way=0;way<2;way=way+1) begin: reduction
    wire [SETS-1:0] set_matches,set_hits;
    for(genvar set_id=0;set_id<SETS;set_id=set_id+1) begin: set_result
      assign set_matches[set_id]=line_matches[set_id*2+way];
      assign set_hits[set_id]=line_hits[set_id*2+way];
    end
    assign match_bits[way]=|set_matches;
    assign way_hits[way]=|set_hits;
  end
  assign hit=match_bits[0] ? way_hits[0]:way_hits[1];
endmodule
