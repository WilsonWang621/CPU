`timescale 1ns/1ps
// Exercise retirement indices using externally chosen legal advance widths.
module v2_retire_index_case #(parameter integer ENTRIES=32)(output reg done=0);
  reg clk=0,rst=1;
  reg [1:0] advance=0;
  always #5 clk=~clk;
  cpu_top #(.ROB_ENTRIES(ENTRIES),.IQ_ENTRIES(2),.LOAD_SLOTS(2),.STORE_SLOTS(4),
    .CHECKPOINTS(2),.ICACHE_BYTES(128),.DCACHE_BYTES(256),.D_MSHRS(2),
    .FETCH_QUEUE_ENTRIES(2),.BHT_ENTRIES(8),.BTB_ENTRIES(2),.HISTORY_ENTRIES(2),
    .MAX_MEM_OUTSTANDING(4),.RAM_BYTES(4096)) dut (
    .clk(clk),.rst(rst),.mem_req_ready(1'b0),.mem_rsp_valid(1'b0),
    .mem_rsp_rdata(32'b0),.mem_rsp_error(1'b0));
  integer seed=32'h3980141+ENTRIES,step,expected=0,wraps=0,resets=0,dual=0;
  initial begin
    force dut.fetch_valid=0;
    force dut.commit_count=advance;
    repeat(2) @(negedge clk);
    for(step=0;step<5000;step=step+1) begin
      @(negedge clk);
      advance=($random(seed)&32'h7fffffff)%3;
      rst=step%97==0;
      if(rst) begin expected=0;resets=resets+1;end
      else begin
        if(expected+advance>=ENTRIES) wraps=wraps+1;
        expected=(expected+advance)%ENTRIES;
        if(advance==2) dual=dual+1;
      end
      @(posedge clk);#1;
      if(dut.head!==expected || dut.commit_rid[0]!==expected || dut.commit_rid[1]!==((expected+1)%ENTRIES))
        $fatal(1,"retirement index mismatch entries=%0d step=%0d head=%d second=%d expected=%d",
          ENTRIES,step,dut.head,dut.commit_rid[1],expected);
    end
    if(wraps<20 || resets<50 || dual<1000) $fatal(1,"insufficient retirement index coverage");
    $display("Retirement indices: PASS entries=%0d checks=%0d wraps=%0d resets=%0d dual=%0d",
      ENTRIES,step,wraps,resets,dual);
    done=1;
  end
endmodule

module v2_retire_index_tb;
  wire [2:0] done;
  v2_retire_index_case #(.ENTRIES(8)) small_case(done[0]);
  v2_retire_index_case #(.ENTRIES(32)) default_case(done[1]);
  v2_retire_index_case #(.ENTRIES(64)) large_case(done[2]);
  initial begin wait(&done);$finish;end
endmodule
