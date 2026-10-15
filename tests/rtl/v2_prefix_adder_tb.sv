`timescale 1ns/1ps
module prefix_adder_case #(parameter WIDTH=32)(output reg done=0);
  reg [WIDTH-1:0] a,b;
  reg carry_in;
  wire [WIDTH-1:0] sum;
  wire carry_out;
  reg [WIDTH:0] expected;
  v2_prefix_adder #(.WIDTH(WIDTH)) dut(a,b,carry_in,sum,carry_out);
  initial begin
    for(integer step=0;step<5000;step=step+1) begin
      case(step%8)
        0:begin a=~0;b=0;end
        1:begin a=~0;b=~0;end
        2:begin a=1;b=~0;end
        default:begin a={$random,$random};b={$random,$random};end
      endcase
      carry_in=step%2;
      expected={1'b0,a}+{1'b0,b}+carry_in;
      #1;
      if({carry_out,sum}!==expected) $fatal(1,"prefix add mismatch width=%0d step=%0d",WIDTH,step);
    end
    $display("Prefix add: PASS width=%0d checks=5000",WIDTH);done=1;
  end
endmodule
module v2_prefix_adder_tb;
  wire [4:0] done;
  prefix_adder_case #(.WIDTH(1)) a(done[0]);
  prefix_adder_case #(.WIDTH(8)) b(done[1]);
  prefix_adder_case #(.WIDTH(16)) c(done[2]);
  prefix_adder_case #(.WIDTH(32)) d(done[3]);
  prefix_adder_case #(.WIDTH(33)) e(done[4]);
  initial begin wait(&done);$finish;end
endmodule
