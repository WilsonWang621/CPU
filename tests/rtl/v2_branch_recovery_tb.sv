`timescale 1ns/1ps
// Recovery may trail execution by one edge. Younger branches and stores must
// be canceled even when the resolving branch retires in the recovery cycle.
module v2_branch_recovery_tb #(parameter integer CONTROL_TREE=0, REGISTER_REDIRECT=0, ROB_WRITE_TREE=0, COMMIT_TREE=0);
  reg clk=0,rst=1;
  always #5 clk=~clk;
  wire request_valid,request_write;
  cpu_top #(.ROB_ENTRIES(8),.IQ_ENTRIES(2),.LOAD_SLOTS(2),.STORE_SLOTS(4),
    .CHECKPOINTS(2),.ICACHE_BYTES(128),.DCACHE_BYTES(256),.D_MSHRS(2),
    .FETCH_QUEUE_ENTRIES(2),.BHT_ENTRIES(8),.BTB_ENTRIES(2),.HISTORY_ENTRIES(2),
    .MAX_MEM_OUTSTANDING(4),.RAM_BYTES(4096),.CONTROL_TREE(CONTROL_TREE),
    .REGISTER_REDIRECT(REGISTER_REDIRECT),.ROB_WRITE_TREE(ROB_WRITE_TREE),.COMMIT_TREE(COMMIT_TREE)) dut (
    .clk(clk),.rst(rst),.mem_req_valid(request_valid),.mem_req_write(request_write),
    .mem_req_ready(1'b0),.mem_rsp_valid(1'b0),.mem_rsp_rdata(32'b0),.mem_rsp_error(1'b0));
  task check_recovery(input integer branch_slot, input bit correct_prediction,
                      input integer older_count);
    integer store_slot,young_slot,oldest,r;
    begin
      @(negedge clk);rst=1;
      repeat(3) @(negedge clk);
      rst=0;
      store_slot=(branch_slot+1)%8;young_slot=(branch_slot+2)%8;
      oldest=(branch_slot+8-older_count)%8;
      dut.retirement_reads[0].read_metadata.selected=8'b1<<oldest;
      dut.retirement_reads[0].read_value.selected=8'b1<<oldest;
      dut.retirement_reads[1].read_metadata.selected=8'b1<<((oldest+1)%8);
      dut.retirement_reads[1].read_value.selected=8'b1<<((oldest+1)%8);
      dut.head=oldest;dut.tail=(branch_slot+3)%8;dut.rob_count=3+older_count;
      for(r=0;r<older_count;r=r+1) begin
        dut.rob[(oldest+r)%8]=0;
        dut.rob[(oldest+r)%8][dut.ROB_T_VALID_LSB]=1;
        dut.rob[(oldest+r)%8][dut.ROB_T_DONE_LSB]=1;
      end
      dut.rob[branch_slot]=0;dut.rob[store_slot]=0;dut.rob[young_slot]=0;
      dut.rob[branch_slot][dut.ROB_T_VALID_LSB]=1;
      dut.rob[store_slot][dut.ROB_T_VALID_LSB]=1;
      dut.rob[store_slot][dut.ROB_T_STORE_LSB]=1;
      dut.rob[young_slot][dut.ROB_T_VALID_LSB]=1;
      dut.checkpoint_valid=1;dut.checkpoint_owner[0]=branch_slot;
      dut.queue[0]=0;dut.queue[1]=0;dut.queue[4]=0;
      dut.queue[0][dut.ISSUE_T_VALID_LSB]=1;
      dut.queue[0][dut.ISSUE_T_READY_A_LSB]=1;
      dut.queue[0][dut.ISSUE_T_READY_B_LSB]=1;
      dut.queue[0][dut.ISSUE_T_RID_LSB+:3]=branch_slot;
      dut.queue[0][dut.ISSUE_T_OP_LSB+:6]=dut.OP_BEQ;
      dut.queue[0][dut.ISSUE_T_PC_LSB+:30]=1;
      dut.queue[0][dut.ISSUE_T_IMM_LSB+:32]=16;
      dut.queue[0][dut.ISSUE_T_PREDICTION_LSB+:30]=correct_prediction ? 5:2;
      dut.queue[0][dut.ISSUE_T_HISTORY_LSB]=1;
      dut.queue[1][dut.ISSUE_T_VALID_LSB]=1;
      dut.queue[1][dut.ISSUE_T_READY_A_LSB]=1;
      dut.queue[1][dut.ISSUE_T_READY_B_LSB]=1;
      dut.queue[1][dut.ISSUE_T_RID_LSB+:3]=young_slot;
      dut.queue[1][dut.ISSUE_T_GENERATION_LSB]=young_slot<branch_slot;
      dut.queue[1][dut.ISSUE_T_OP_LSB+:6]=dut.OP_BEQ;
      dut.queue[1][dut.ISSUE_T_PC_LSB+:30]=3;
      dut.queue[1][dut.ISSUE_T_IMM_LSB+:32]=16;
      // The next selected branch has different predictor history.
      dut.queue[1][dut.ISSUE_T_HISTORY_LSB]=0;
      dut.queue[4][dut.ISSUE_T_VALID_LSB]=1;
      dut.queue[4][dut.ISSUE_T_READY_A_LSB]=1;
      dut.queue[4][dut.ISSUE_T_READY_B_LSB]=1;
      dut.queue[4][dut.ISSUE_T_RID_LSB+:3]=store_slot;
      dut.queue[4][dut.ISSUE_T_GENERATION_LSB]=store_slot<branch_slot;
      dut.queue[4][dut.ISSUE_T_OP_LSB+:6]=dut.OP_STORE;
      dut.balanced_selection[2].prepared_selection.grant_valid=1;
      dut.balanced_selection[2].prepared_selection.grant_index=0;
      dut.queue[4][dut.ISSUE_T_A_LSB+:32]=32'h100;
`ifdef V2_PREPARED_ADDRESS_TEST
      dut.prepared_address[0]=32'h100;
`endif
      dut.queue[4][dut.ISSUE_T_B_LSB+:32]=32'hdeadbeef;
      dut.queue[4][dut.ISSUE_T_SIZE_LSB+:2]=2;
      #1;
      if(!dut.branch_capture || dut.redirect || !dut.store_allocate || dut.commit_count!=older_count)
        $fatal(1,"recovery fixture did not execute branch/store before retirement");
      @(posedge clk);#1;
      if(!dut.branch_fire || dut.redirect==correct_prediction || dut.redirect_rid!=branch_slot ||
         dut.redirect_pc!=20 || !dut.train_valid || dut.train_pc!=4 || !dut.train_taken ||
         dut.frontend.train_history!=1)
        $fatal(1,"registered recovery or predictor metadata incorrect");
      if(!dut.checkpoint_valid[0]) $fatal(1,"checkpoint freed before recovery");
      if(dut.head!=branch_slot) $fatal(1,"older retirement did not advance head to branch");
      if(correct_prediction) begin
        if(!dut.branch_capture || !dut.wb_valid[0]) $fatal(1,"correct prediction blocked next branch");
      end else begin
        if(dut.branch_capture || dut.wb_valid[0] || dut.wb_valid[2] || dut.mdu_valid || dut.commit_count!=1 ||
           dut.cache_store_valid || !dut.stores[0][dut.STORE_T_VALID_LSB])
          $fatal(1,"younger work published during recovery");
        @(posedge clk);#1;
        if(dut.branch_pending || dut.redirect || dut.rob_count!=0 || dut.store_count!=0 ||
           dut.stores[0][dut.STORE_T_VALID_LSB] || dut.rob[store_slot][dut.ROB_T_VALID_LSB] ||
           dut.rob[young_slot][dut.ROB_T_VALID_LSB] || dut.queue[1][dut.ISSUE_T_VALID_LSB])
          $fatal(1,"younger state survived recovery or generated a stale redirect");
      end
    end
  endtask
  initial begin
    force dut.fetch_valid=0;
    check_recovery(0,0,0);
    check_recovery(7,0,0);
    check_recovery(7,1,0);
    check_recovery(0,0,2);
    check_recovery(7,0,1);
    check_recovery(7,1,2);
    $display("Branch recovery: PASS wrap, 0/1/2 older commits, younger branch/store cancellation and prediction history");
    $finish;
  end
endmodule
