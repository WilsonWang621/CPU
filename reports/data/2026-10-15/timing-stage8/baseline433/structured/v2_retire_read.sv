// A rotating one-hot head mirror removes binary head decoding from the
// retirement read. Separate instances bound each mirror's payload fanout.
(* keep_hierarchy=1 *)
module v2_retire_read #(
  parameter integer ENTRIES=32, WORD_BITS=32, LANE=0, CONTROL_TREE=0
)(
  input wire clk,rst,
  input wire [1:0] advance,
  input wire [ENTRIES*WORD_BITS-1:0] words,
  output wire [WORD_BITS-1:0] value
);
  logic [ENTRIES-1:0] selected;
  generate if(CONTROL_TREE) begin: distributed_advance
    wire [2*((ENTRIES+7)/8)-1:0] advances;
    v2_distribution #(.WIDTH(2),.LEAVES((ENTRIES+7)/8)) tree (
      .data_in(advance),.data_out(advances));
    for(genvar row=0;row<ENTRIES;row=row+1) begin: head_bit
      always_ff @(posedge clk) begin
        if(rst) selected[row]<=(row==LANE);
        else case(advances[(row/8)*2+:2])
          1:selected[row]<=selected[(row+ENTRIES-1)%ENTRIES];
          2:selected[row]<=selected[(row+ENTRIES-2)%ENTRIES];
          default:;
        endcase
      end
    end
  end else begin: direct_advance
  always_ff @(posedge clk) begin
    if(rst) selected<= {{(ENTRIES-1){1'b0}},1'b1} << LANE;
    else case(advance)
      1:selected<={selected[ENTRIES-2:0],selected[ENTRIES-1]};
      2:selected<={selected[ENTRIES-3:0],selected[ENTRIES-1:ENTRIES-2]};
      default:;
    endcase
  end
  end endgenerate
  for(genvar n=1;n<2*ENTRIES;n=n+1) begin: node
    wire [WORD_BITS-1:0] word_value;
    if(n>=ENTRIES) begin: leaf
      v2_read_mask #(.WORD_BITS(WORD_BITS)) mask_word (
        .selected(selected[n-ENTRIES]),.word(words[(n-ENTRIES)*WORD_BITS+:WORD_BITS]),.value(word_value));
    end else begin: branch
      assign word_value=node[2*n].word_value | node[2*n+1].word_value;
    end
  end
  assign value=node[1].word_value;
endmodule
