`timescale 1ns/1ps
module v2_issue_order_tb;
  reg clk=0,rst=1;
  reg [7:0] allocate=0,ready=0,live=0;
  wire [7:0] grant;
  wire valid;
  wire [2:0] index;
  integer age[8];
  integer serial=0,chosen,best,allocations=0,checks=0;
  reg [7:0] expected;
  v2_issue_order dut(.clk,.rst,.allocate,.ready,.grant,.valid,.index);
  always #5 clk=~clk;
  initial begin
    for(integer q=0;q<8;q=q+1) age[q]=0;
    repeat(2) @(negedge clk);
    for(integer step=0;step<20000;step=step+1) begin
      rst=step%251==0;
      allocate=0;
      if(rst) live=0;
      else begin
        // Removal models issue or recovery. Reuse a physical row with an
        // unbounded software timestamp, independent of the RTL age matrix.
        for(integer q=0;q<8;q=q+1)
          if($urandom_range(0,7)==0) live[q]=0;
        chosen=$urandom_range(0,7);
        if(!live[chosen] && $urandom_range(0,3)!=0) begin
          live[chosen]=1;allocate[chosen]=1;
          serial=serial+1;age[chosen]=serial;allocations=allocations+1;
        end
      end
      @(posedge clk);#1;
      for(integer trial=0;trial<8;trial=trial+1) begin
        ready=live & $urandom;
        #1;best=-1;expected=0;
        for(integer q=0;q<8;q=q+1)
          if(ready[q] && (best<0 || age[q]<age[best])) best=q;
        if(best>=0) expected[best]=1;
        if(grant!==expected || valid!==(best>=0) || (best>=0 && index!==3'(best)))
          $fatal(1,"age selection step=%0d ready=%h got=%h expected=%h",step,ready,grant,expected);
        checks=checks+1;
      end
      @(negedge clk);
    end
    if(allocations<1000) $fatal(1,"insufficient reuse coverage");
    $display("Issue age selection: PASS %0d checks, %0d allocations",checks,allocations);
    $finish;
  end
endmodule
