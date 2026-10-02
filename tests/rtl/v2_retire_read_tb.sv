`timescale 1ns/1ps
module retire_read_case #(parameter ENTRIES=32, BITS=32)(output reg done=0);
  reg clk=0,rst=1;
  reg [1:0] advance=0;
  reg [ENTRIES*BITS-1:0] words=0;
  wire [BITS-1:0] lane0,lane1;
  integer head=0,wraps=0,dual=0;
  always #5 clk=~clk;
  v2_retire_read #(.ENTRIES(ENTRIES),.WORD_BITS(BITS),.LANE(0)) a (.clk(clk),.rst(rst),.advance(advance),.words(words),.value(lane0));
  v2_retire_read #(.ENTRIES(ENTRIES),.WORD_BITS(BITS),.LANE(1)) b (.clk(clk),.rst(rst),.advance(advance),.words(words),.value(lane1));
  initial begin
    for(integer cycle=0;cycle<20000;cycle=cycle+1) begin
      @(negedge clk);
      rst=cycle%127==0;
      advance=$urandom_range(0,2);
      for(integer row=0;row<ENTRIES;row=row+1) words[row*BITS+:BITS]=$urandom;
      @(posedge clk);#1;
      if(rst) head=0;
      else begin
        if(head+advance>=ENTRIES) wraps=wraps+1;
        if(advance==2) dual=dual+1;
        head=(head+advance)%ENTRIES;
      end
      if(lane0!==words[head*BITS+:BITS] || lane1!==words[((head+1)%ENTRIES)*BITS+:BITS]) $fatal(1,"retirement head read mismatch entries=%0d cycle=%0d",ENTRIES,cycle);
    end
    $display("Retirement read: PASS entries=%0d bits=%0d cycles=20000 wraps=%0d dual=%0d",ENTRIES,BITS,wraps,dual);
    done=1;
  end
endmodule
module v2_retire_read_tb;
  wire a,b,c;
  retire_read_case #(.ENTRIES(8),.BITS(16)) x(a);
  retire_read_case #(.ENTRIES(32),.BITS(32)) y(b);
  retire_read_case #(.ENTRIES(64),.BITS(20)) z(c);
  initial begin wait(a && b && c);$finish;end
endmodule
