// One predecoded grant copy drives each payload word.
(* keep_hierarchy=1 *)
module v2_grant_read #(parameter integer ENTRIES=4, WORD_BITS=32)(
  input wire [ENTRIES-1:0] grant,
  input wire [ENTRIES*WORD_BITS-1:0] words,
  output wire [WORD_BITS-1:0] value
);
  localparam integer LEAVES=2**$clog2(ENTRIES);
  for(genvar n=1;n<2*LEAVES;n=n+1) begin: node
    wire [WORD_BITS-1:0] word_value;
    if(n>=LEAVES) begin: leaf
      if(n-LEAVES<ENTRIES) begin: used
        v2_read_mask #(.WORD_BITS(WORD_BITS)) mask_word (
          .selected(grant[n-LEAVES]),.word(words[(n-LEAVES)*WORD_BITS+:WORD_BITS]),.value(word_value));
      end else begin: padding
        assign word_value=0;
      end
    end else begin: branch
      assign word_value=node[2*n].word_value | node[2*n+1].word_value;
    end
  end
  assign value=node[1].word_value;
endmodule
