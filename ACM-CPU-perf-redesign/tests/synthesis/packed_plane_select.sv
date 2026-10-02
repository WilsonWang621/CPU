// A nested packed part-select must not lower to a full-plane barrel shifter.
module packed_plane_select #(parameter SETS=32, WAYS=4, WORDS=8)(
 input logic [SETS*WAYS*WORDS*4-1:0] plane,
 input logic [$clog2(SETS)-1:0] s,
 input logic [$clog2(WAYS)-1:0] w,
 input logic [31:0] word_index,
 output logic [3:0] nibble);
 logic [SETS-1:0][WAYS-1:0][WORDS*4-1:0] value;
 assign value=plane;
 assign nibble=value[s][w][word_index*4+:4];
endmodule

module narrow_row_select #(parameter SETS=32, WAYS=4, WORDS=8)(
 input logic [SETS*WAYS*WORDS*4-1:0] plane,
 input logic [$clog2(SETS)-1:0] s,
 input logic [$clog2(WAYS)-1:0] w,
 input logic [31:0] word_index,
 output logic [3:0] nibble);
 logic [WORDS*4-1:0] rows [SETS*WAYS];
 logic [WORDS*4-1:0] selected_row;
 for(genvar k=0;k<SETS*WAYS;k=k+1) assign rows[k]=plane[k*WORDS*4+:WORDS*4];
 assign selected_row=rows[int'(s)*WAYS+int'(w)];
 assign nibble=selected_row[word_index*4+:4];
endmodule

module plane_select_miter #(parameter SETS=32, WAYS=4, WORDS=8)(
 input logic [SETS*WAYS*WORDS*4-1:0] plane,
 input logic [$clog2(SETS)-1:0] s,
 input logic [$clog2(WAYS)-1:0] w,
 input logic [31:0] word_index,
 output logic ok);
 logic [3:0] packed_result, narrow_result;
 packed_plane_select #(.SETS(SETS),.WAYS(WAYS),.WORDS(WORDS)) a(plane,s,w,word_index,packed_result);
 narrow_row_select #(.SETS(SETS),.WAYS(WAYS),.WORDS(WORDS)) b(plane,s,w,word_index,narrow_result);
 // Real cache word indices are within their line. Do not assert equivalence
 // for out-of-range Verilog part-selects, whose value is unspecified.
 assign ok=word_index>=WORDS || packed_result==narrow_result;
endmodule
