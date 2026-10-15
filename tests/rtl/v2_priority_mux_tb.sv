`timescale 1ns/1ps
module priority_mux_case #(parameter WORD_BITS=32,PORTS=3)(output reg done=0);
  reg [PORTS-1:0] enable;
  reg [WORD_BITS-1:0] old_value,expected;
  reg [PORTS*WORD_BITS-1:0] data;
  wire [WORD_BITS-1:0] value;
  v2_priority_mux #(.WORD_BITS(WORD_BITS),.PORTS(PORTS)) dut(enable,old_value,data,value);
  initial begin
    for(integer n=0;n<10000;n=n+1) begin
      enable=PORTS'(n);old_value={$random,$random};
      for(integer p=0;p<PORTS;p=p+1) data[p*WORD_BITS+:WORD_BITS]={$random,$random};
      expected=old_value;
      for(integer p=0;p<PORTS;p=p+1) if(enable[p]) expected=data[p*WORD_BITS+:WORD_BITS];
      #1;
      if(value!==expected) $fatal(1,"priority mux differs width=%0d ports=%0d enable=%h",WORD_BITS,PORTS,enable);
    end
    $display("Priority mux: PASS bits=%0d ports=%0d checks=10000",WORD_BITS,PORTS);done=1;
  end
endmodule
module v2_priority_mux_tb;
 wire [3:0] done;
 priority_mux_case #(.WORD_BITS(1),.PORTS(1)) one(done[0]);
 priority_mux_case #(.WORD_BITS(17),.PORTS(2)) odd(done[1]);
 priority_mux_case #(.WORD_BITS(32),.PORTS(3)) word32(done[2]);
 priority_mux_case #(.WORD_BITS(37),.PORTS(3)) wide(done[3]);
 initial begin wait(&done);$finish;end
endmodule
