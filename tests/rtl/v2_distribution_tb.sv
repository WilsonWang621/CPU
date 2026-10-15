`timescale 1ns/1ps
module v2_distribution_case #(parameter WIDTH=1, LEAVES=1)(output reg done);
  reg [WIDTH-1:0] value;
  wire [WIDTH*LEAVES-1:0] copies;
  v2_distribution #(.WIDTH(WIDTH),.LEAVES(LEAVES)) dut (
    .data_in(value),.data_out(copies));
  integer iteration,leaf;
  initial begin
    done=0;
    for(iteration=0;iteration<300;iteration=iteration+1) begin
      if(iteration==0) value=0;
      else if(iteration==1) value=~0;
      else value={$random,$random};
      #1;
      for(leaf=0;leaf<LEAVES;leaf=leaf+1)
        if(copies[leaf*WIDTH+:WIDTH]!==value)
          $fatal(1,"distribution mismatch width=%0d leaves=%0d leaf=%0d",WIDTH,LEAVES,leaf);
    end
    done=1;
  end
endmodule

module v2_distribution_tb;
  wire [5:0] done;
  v2_distribution_case #(.WIDTH(1),.LEAVES(1)) a(done[0]);
  v2_distribution_case #(.WIDTH(1),.LEAVES(2)) b(done[1]);
  v2_distribution_case #(.WIDTH(7),.LEAVES(3)) c(done[2]);
  v2_distribution_case #(.WIDTH(11),.LEAVES(8)) d(done[3]);
  v2_distribution_case #(.WIDTH(35),.LEAVES(9)) e(done[4]);
  v2_distribution_case #(.WIDTH(64),.LEAVES(32)) f(done[5]);
  initial begin
    wait(&done);
    $display("distribution: all 6 configurations passed");
    $finish;
  end
endmodule
