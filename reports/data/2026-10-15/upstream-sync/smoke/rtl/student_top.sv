module student_top(input clock, reset, input [7:0] a, b, input enable, output reg [7:0] y);
reg [7:0] source;
always @(posedge clock) begin
  if(reset) begin source<=0; y<=0; end
  else begin source<=a+b; if(enable) y<=source^b; end
end
endmodule
