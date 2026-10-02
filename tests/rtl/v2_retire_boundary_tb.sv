`timescale 1ns/1ps
// Exhaust every head/recovery slot pair, including wrap. The oracle uses
// integer distance in the circular ROB, independently of the RTL comparator.
module v2_retire_boundary_tb;
  reg clk=0,rst=1;
  integer h,b,r,expected,checks=0;
  cpu_top #(.ROB_ENTRIES(8),.IQ_ENTRIES(2),.LOAD_SLOTS(2),.STORE_SLOTS(4),
    .CHECKPOINTS(2),.ICACHE_BYTES(128),.DCACHE_BYTES(256),.D_MSHRS(2),
    .FETCH_QUEUE_ENTRIES(2),.BHT_ENTRIES(8),.BTB_ENTRIES(2),.HISTORY_ENTRIES(2),
    .MAX_MEM_OUTSTANDING(4),.RAM_BYTES(4096)) dut (
    .clk(clk),.rst(rst),.mem_req_ready(1'b0),.mem_rsp_valid(1'b0),
    .mem_rsp_rdata(32'b0),.mem_rsp_error(1'b0));
  task pulse;
    begin #1;clk=1;#1;clk=0;#1;end
  endtask
  initial begin
    force dut.fetch_valid=0;
    for(h=0;h<8;h=h+1) begin
      rst=1;pulse();rst=0;
      dut.rob_count=8;
      // Advance through real edges so any mirrored retirement selectors
      // remain aligned with head; never overwrite head in the fixture.
      force dut.commit_count=2'd1;
      repeat(h) pulse();
      release dut.commit_count;
      if(dut.head!=h) $fatal(1,"head did not advance to fixture slot %0d",h);
      for(r=0;r<8;r=r+1) begin
        dut.rob[r]=0;dut.values[r]=0;
        dut.rob[r][dut.ROB_T_VALID_LSB]=1;
        dut.rob[r][dut.ROB_T_DONE_LSB]=1;
      end
      dut.rob_count=2;
      dut.branch_pending=1;dut.branch_bad_q=0;
      dut.branch_next_q=4;dut.branch_prediction_q=0;
      for(b=0;b<8;b=b+1) begin
        dut.branch_rid_q=b;#1;
        expected=((b+8-h)%8)==0 ? 1:2;
        if(dut.redirect!==1'b1 || dut.commit_count!==expected)
          $fatal(1,"retirement boundary head=%0d branch=%0d count=%0d expected=%0d",
            h,b,dut.commit_count,expected);
        checks=checks+1;
      end
    end
    $display("Retirement recovery boundary: PASS %0d slot pairs",checks);
    $finish;
  end
endmodule
