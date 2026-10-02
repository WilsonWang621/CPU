`timescale 1ns/1ps
module increment_case #(parameter integer BITS=30)(output reg done=0);
  reg [BITS-1:0] value=0;
  wire [BITS-1:0] result;
  reg [BITS-1:0] expected;
  integer seed=BITS*32'h542810,checks=0,r;
  v2_increment #(.BITS(BITS)) dut(.value(value),.result(result));
  task check;
    begin
      expected=value+1'b1;#1;
      if(result!==expected) $fatal(1,"increment bits=%0d input=%h got=%h expected=%h",BITS,value,result,expected);
      checks=checks+1;
    end
  endtask
  initial begin
    value=0;check();value='1;check();
    for(r=0;r<BITS;r=r+1) begin
      value=('1 >> (BITS-r-1));check();
      value=~value;check();
    end
    repeat(20000) begin value=$random(seed);check();end
    $display("Increment: PASS bits=%0d checks=%0d",BITS,checks);
    done=1;
  end
endmodule
module v2_increment_tb;
  wire [3:0] done;
  increment_case #(.BITS(8)) a(done[0]);
  increment_case #(.BITS(29)) b(done[1]);
  increment_case #(.BITS(30)) c(done[2]);
  increment_case #(.BITS(32)) d(done[3]);
  initial begin wait(&done);$finish;end
endmodule
