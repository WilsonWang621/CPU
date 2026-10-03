`timescale 1ns/1ps
module v2_address_add_tb;
  reg [31:0] a,b;
  wire [31:0] value;
  integer checks=0;
  v2_address_add dut(.a,.b,.value);
  task automatic check(input [31:0] left,right);
    begin
      a=left;b=right;#1;
      if(value!==32'(left+right)) $fatal(1,"address add %h + %h = %h",left,right,value);
      checks=checks+1;
    end
  endtask
  initial begin
    for(integer bits=0;bits<32;bits=bits+1) begin
      check((32'b1<<bits)-1,1);
      check(32'hffffffff,32'b1<<bits);
      check(32'b1<<bits,~(32'b1<<bits));
    end
    check(32'hffffffff,1);check(32'h80000000,32'h80000000);
    repeat(100000) check($urandom,$urandom);
    $display("Address addition: PASS %0d checks",checks);$finish;
  end
endmodule
