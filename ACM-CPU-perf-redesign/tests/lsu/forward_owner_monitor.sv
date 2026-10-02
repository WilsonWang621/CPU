module forward_owner_monitor #(parameter integer ROB_ENTRIES=32,RW=5,LQ_ENTRIES=16)(input logic clk,rst);
  function automatic integer age(input integer rid);
    integer delta;
    begin delta=rid-int'(core.head_q);return delta<0 ? delta+ROB_ENTRIES:delta;end
  endfunction
  always @(posedge clk) if(!rst) begin
    for(integer k=0;k<LQ_ENTRIES;k=k+1) begin
      if(core.lq_q[k].valid && !core.lq_q[k].issued && core.execute_lq[k].issued && core.execute_lq[k].forward_from_rob!=0)
        $display("OWNER_FORWARD cycle=%0d head=%0d load=%0d load_pc=%08x mask=%x owner0=%0d owner_pc=%08x owner_valid=%0d",core.cycle_count,core.head_q,core.lq_q[k].rid,core.rob_q[core.lq_q[k].rid].pc,core.execute_lq[k].forward_from_rob,core.execute_lq[k].forward_owner[0+:RW],core.rob_q[core.execute_lq[k].forward_owner[0+:RW]].pc,core.rob_q[core.execute_lq[k].forward_owner[0+:RW]].valid);
    end
    for(integer lane=0;lane<4;lane=lane+1) begin
      if(core.ex_q[lane].valid && core.ex_q[lane].op==cpu_pkg::OP_STORE &&
         core.rob_q[core.ex_q[lane].rid].valid && core.rob_q[core.ex_q[lane].rid].generation==core.ex_q[lane].generation &&
         !core.rob_q[core.ex_q[lane].rid].addr_ready) begin
        for(integer k=0;k<LQ_ENTRIES;k=k+1) begin
          if(core.lq_q[k].valid && core.lq_q[k].issued && !core.lq_q[k].canceled &&
             age(int'(core.lq_q[k].rid))>age(int'(core.ex_q[lane].rid)) &&
             core.lq_q[k].addr==(core.ex_q[lane].a+core.ex_q[lane].imm) && core.lq_q[k].forward_from_rob!=0)
            $display("OWNER_CONFLICT cycle=%0d head=%0d store=%0d store_pc=%08x store_age=%0d load=%0d load_pc=%08x load_age=%0d owner0=%0d owner_age=%0d owner_valid=%0d owner_pc=%08x replay=%0d",core.cycle_count,core.head_q,core.ex_q[lane].rid,core.rob_q[core.ex_q[lane].rid].pc,age(int'(core.ex_q[lane].rid)),core.lq_q[k].rid,core.rob_q[core.lq_q[k].rid].pc,age(int'(core.lq_q[k].rid)),core.lq_q[k].forward_owner[0+:RW],age(int'(core.lq_q[k].forward_owner[0+:RW])),core.rob_q[core.lq_q[k].forward_owner[0+:RW]].valid,core.rob_q[core.lq_q[k].forward_owner[0+:RW]].pc,core.replay);
        end
      end
    end
  end
endmodule
bind core forward_owner_monitor #(.ROB_ENTRIES(ROB_ENTRIES),.RW(RW),.LQ_ENTRIES(LQ_ENTRIES)) owner_monitor(.clk(clk),.rst(rst));
