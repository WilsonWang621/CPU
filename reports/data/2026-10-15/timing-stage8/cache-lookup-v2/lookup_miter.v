module lookup_miter(
  input [25:0] address,input [575:0] tags,input [31:0] valid,input [511:0] word_valid,output bad
);
  wire [3:0] set_index=address[7:4];
  wire [3:0] word_index=address[3:0];
  wire [17:0] requested_tag=address[25:8];
  wire [1:0] old_match,new_match;
  wire old_hit,new_hit;
  for(genvar way=0;way<2;way=way+1) begin: original
    assign old_match[way]=valid[set_index*2+way] &&
      tags[(set_index*2+way)*18+:18]==requested_tag;
  end
  wire [4:0] physical_line={set_index,!old_match[0]};
  assign old_hit=(|old_match) && word_valid[physical_line*16+word_index];
  v2_cache_lookup #(.SETS(16),.TAG_BITS(18),.WORDS(16)) replacement (
    .address(address),.tags(tags),.valid(valid),.word_valid(word_valid),.match_bits(new_match),.hit(new_hit));
  assign bad=(old_match!=new_match) || (old_hit!=new_hit);
endmodule
