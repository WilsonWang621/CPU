`timescale 1ns/1ps
// The terminal transition may accept a younger speculative store. It must
// never publish that store, and the next edge must keep older committed work.
module v2_terminal_squash_tb;
  reg clk=0,rst=1;
  always #5 clk=~clk;
  wire request_valid,request_write;
  cpu_top #(.ROB_ENTRIES(8),.IQ_ENTRIES(2),.LOAD_SLOTS(2),.STORE_SLOTS(4),
    .CHECKPOINTS(2),.ICACHE_BYTES(128),.DCACHE_BYTES(256),.D_MSHRS(2),
    .FETCH_QUEUE_ENTRIES(2),.BHT_ENTRIES(8),.BTB_ENTRIES(2),.HISTORY_ENTRIES(2),
    .MAX_MEM_OUTSTANDING(4),.RAM_BYTES(4096)) dut (
    .clk(clk),.rst(rst),.mem_req_valid(request_valid),.mem_req_write(request_write),
    .mem_req_ready(1'b0),.mem_rsp_valid(1'b0),.mem_rsp_rdata(32'b0),.mem_rsp_error(1'b0));
  task check_terminal(input bit fault_case);
    begin
      @(negedge clk);rst=1;
      repeat(3) @(negedge clk);
      rst=0;
      dut.head=0;dut.tail=2;dut.rob_count=2;
      dut.rob[0]=0;dut.rob[1]=0;
      dut.rob[0][dut.ROB_T_VALID_LSB]=1;
      dut.rob[0][dut.ROB_T_DONE_LSB]=1;
      dut.rob[0][dut.ROB_T_EXITING_LSB]=!fault_case;
      dut.rob[0][dut.ROB_T_FAULT_LSB+:4]=fault_case ? 4'd1:4'd0;
      dut.rob[1][dut.ROB_T_VALID_LSB]=1;
      dut.rob[1][dut.ROB_T_DONE_LSB]=1;
      // Older, already issued store stays owned until its response arrives.
      dut.stores[0]=0;dut.stores[1]=0;
      dut.stores[0][dut.STORE_T_VALID_LSB]=1;
      dut.stores[0][dut.STORE_T_COMMITTED_LSB]=1;
      dut.stores[0][dut.STORE_T_ISSUED_LSB]=1;
      dut.store_count=1;dut.store_head=0;dut.store_tail=1;
      dut.queue[4]=0;
      dut.queue[4][dut.ISSUE_T_VALID_LSB]=1;
      dut.queue[4][dut.ISSUE_T_READY_A_LSB]=1;
      dut.queue[4][dut.ISSUE_T_READY_B_LSB]=1;
      dut.queue[4][dut.ISSUE_T_RID_LSB+:3]=1;
      dut.queue[4][dut.ISSUE_T_OP_LSB+:6]=dut.OP_STORE;
      dut.balanced_selection[2].prepared_selection.grant_valid=1;
      dut.balanced_selection[2].prepared_selection.grant_index=0;
`ifdef V2_REGISTERED_MEMORY_GRANTS_TEST
      // Publish the same injected row in every registered local grant copy.
      dut.balanced_selection[2].unused_direct_grant.payload_copy[0].local_grant.grant=1;
      dut.balanced_selection[2].unused_direct_grant.payload_copy[1].local_grant.grant=1;
      dut.balanced_selection[2].unused_direct_grant.payload_copy[2].local_grant.grant=1;
      dut.balanced_selection[2].unused_direct_grant.payload_copy[3].local_grant.grant=1;
      dut.balanced_selection[2].unused_direct_grant.payload_copy[4].local_grant.grant=1;
      dut.balanced_selection[2].unused_direct_grant.payload_copy[5].local_grant.grant=1;
      dut.balanced_selection[2].unused_direct_grant.address_copy.grant=1;
`endif
      dut.queue[4][dut.ISSUE_T_A_LSB+:32]=32'h100;
`ifdef V2_PREPARED_ADDRESS_TEST
      dut.prepared_address[0]=32'h100;
`endif
      dut.queue[4][dut.ISSUE_T_B_LSB+:32]=32'hdeadbeef;
      dut.queue[4][dut.ISSUE_T_SIZE_LSB+:2]=2;
      #1;
      if(dut.commit_count!=0 || !dut.store_allocate) $fatal(1,"terminal fixture did not block retirement and allow speculation");
      @(posedge clk);#1;
      if(dut.state!=(fault_case ? dut.FAULT:dut.DRAIN)) $fatal(1,"terminal state not entered");
      if(!dut.stores[1][dut.STORE_T_VALID_LSB] || dut.stores[1][dut.STORE_T_COMMITTED_LSB]) $fatal(1,"younger store ownership incorrect");
      if(dut.cache_store_valid || (request_valid && request_write)) $fatal(1,"younger store published at terminal transition");
      @(posedge clk);#1;
      if(dut.stores[1][dut.STORE_T_VALID_LSB] || dut.rob[1][dut.ROB_T_VALID_LSB] || dut.queue[4][dut.ISSUE_T_VALID_LSB]) $fatal(1,"younger state survived terminal squash");
      if(!dut.stores[0][dut.STORE_T_VALID_LSB] || !dut.stores[0][dut.STORE_T_COMMITTED_LSB] || dut.store_count!=1) $fatal(1,"older committed store lost");
    end
  endtask
  // Run permission must follow every terminal state transition, including
  // an asynchronous store response error rather than a fault at ROB head.
  always @(negedge clk)
    if(!rst && dut.flush_all!==(dut.state!=dut.RUN))
      $fatal(1,"terminal permission disagrees with CPU state");
  task check_store_error;
    begin
      @(negedge clk);rst=1;
      repeat(3) @(negedge clk);
      rst=0;
      dut.stores[0]=0;
      dut.stores[0][dut.STORE_T_VALID_LSB]=1;
      dut.stores[0][dut.STORE_T_COMMITTED_LSB]=1;
      force dut.cache_store_done_tag=0;
      force dut.cache_store_error=1;
      @(posedge clk);#1;
      if(dut.state!=dut.FAULT || !dut.flush_all || dut.commit_count!=0 || dut.memory_allowed)
        $fatal(1,"store response error did not stop execution");
      release dut.cache_store_error;
      release dut.cache_store_done_tag;
      repeat(3) @(negedge clk);
      if(!dut.flush_all) $fatal(1,"terminal permission did not remain stopped");
      rst=1;
      @(posedge clk);#1;
      if(dut.state!=dut.RUN || dut.flush_all) $fatal(1,"reset did not restore run permission");
    end
  endtask
  initial begin
    force dut.fetch_valid=0;
    check_terminal(0);
    check_terminal(1);
    check_store_error();
    $display("Terminal squash: PASS exit/head fault/store response error, committed store ownership and reset");
    $finish;
  end
endmodule
