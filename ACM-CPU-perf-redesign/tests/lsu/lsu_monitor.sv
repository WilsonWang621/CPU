// Simulation-only observer bound into the actual multi-entry LSU. Hierarchical
// reads preserve implementation signals without adding production debug ports.
module lsu_monitor #(
  parameter integer ROB_BITS=6,PHYS_BITS=7,ROB_ENTRIES=64,LQ_ENTRIES=32,IQ_ENTRIES=32,PHYS_REGS=128
)(input logic clk,rst);
  logic [LQ_ENTRIES-1:0] cancel_response,cancel_error,cancel_preaccept;
  logic [LQ_ENTRIES-1:0] partial_forward,new_cancel,unknown_bypass,shadow_forward,shadow_avoided;
  logic [IQ_ENTRIES-1:0] wait_release_event,wait_reuse_event,wait_tracked,wait_released,wait_reuse_seen;
  logic [ROB_BITS-1:0] waited_rid [IQ_ENTRIES],waiting_load_rid [IQ_ENTRIES];
  logic [15:0] waited_generation [IQ_ENTRIES],waiting_load_generation [IQ_ENTRIES];
  logic [LQ_ENTRIES-1:0] physical_reallocated,rob_reallocated;
  logic [LQ_ENTRIES-1:0] previous_valid,freed,seen_physical,seen_rob;
  logic [15:0] previous_generation [LQ_ENTRIES],tracked_generation [LQ_ENTRIES];
  logic [ROB_BITS-1:0] previous_rid [LQ_ENTRIES],tracked_rid [LQ_ENTRIES];
  logic [PHYS_BITS-1:0] tracked_pdst [LQ_ENTRIES];
  logic older_redirect,redirect_with_load;
  integer canceled_responses,canceled_errors,canceled_preaccept,partial_forwarded;
  integer physical_reuse,rob_reuse,nested_recovery,nested_recovery_with_load;
  integer canceled_redirects,pending_cancellations,speculative_bypasses,replays;
  integer shadow_forwarded,shadow_replay_avoided,deferred_wait_release,wait_owner_reuse;

  function automatic integer age(input integer rid);
    integer value;
    begin value=rid-int'(core.head_q);return value<0 ? value+ROB_ENTRIES:value;end
  endfunction

  always_comb begin
    integer index;
    logic [3:0] overlap;
    logic covered;
    index=0;overlap=0;covered=0;
    shadow_forward=0;shadow_avoided=0;wait_release_event=0;wait_reuse_event=0;
    cancel_response=0;cancel_error=0;cancel_preaccept=0;partial_forward=0;
    new_cancel=0;unknown_bypass=0;physical_reallocated=0;rob_reallocated=0;
    older_redirect=0;redirect_with_load=0;
    if(core.redirect && !core.replay) begin
      for(integer r=0;r<ROB_ENTRIES;r=r+1)
        if(core.rob_q[r].valid && core.rob_q[r].branch_resolved &&
           cpu_pkg::is_branch(core.rob_q[r].dec.op) && age(r)>int'(core.recovery_age))
          older_redirect=1;
    end
    for(integer k=0;k<LQ_ENTRIES;k=k+1) begin
      if(core.lq_q[k].valid) begin
        if(!core.lq_q[k].issued && core.execute_lq[k].issued) begin
          partial_forward[k]=(core.execute_lq[k].forward_mask & core.execute_lq[k].mask)!=0 &&
            (core.execute_lq[k].forward_mask & core.execute_lq[k].mask)!=core.execute_lq[k].mask;
          for(integer r=0;r<ROB_ENTRIES;r=r+1)
            if(core.rob_q[r].valid && core.rob_q[r].dec.op==cpu_pkg::OP_STORE &&
               !core.rob_q[r].addr_ready && age(r)<age(int'(core.lq_q[k].rid))) unknown_bypass[k]=1;
          for(integer r=0;r<ROB_ENTRIES;r=r+1) begin
            if(core.execute_rob[r].valid && core.execute_rob[r].dec.op==cpu_pkg::OP_STORE &&
               core.execute_rob[r].addr_ready && !core.execute_rob[r].data_ready &&
               age(r)<age(int'(core.lq_q[k].rid)) &&
               core.execute_rob[r].addr[31:2]==core.execute_lq[k].addr[31:2]) begin
              overlap=core.execute_rob[r].wstrb & core.execute_lq[k].mask;
              covered=overlap!=0;
              for(integer byte_lane=0;byte_lane<4;byte_lane=byte_lane+1)
                if(overlap[byte_lane] && (!core.execute_lq[k].forward_from_rob[byte_lane] ||
                   age(int'(core.execute_lq[k].forward_owner[byte_lane*ROB_BITS+:ROB_BITS]))<=age(r) ||
                   age(int'(core.execute_lq[k].forward_owner[byte_lane*ROB_BITS+:ROB_BITS]))>=age(int'(core.lq_q[k].rid)))) covered=0;
              if(covered) shadow_forward[k]=1;
            end
          end
        end
        new_cancel[k]=!core.lq_q[k].canceled && core.lq_d[k].canceled &&
          core.lq_q[k].queued && !core.lq_q[k].returned;
        cancel_preaccept[k]=new_cancel[k] && core.skid_q.valid && !core.skid_q.write &&
          int'(core.skid_q.tag)==k && !core.d_req_ready;
        if(core.redirect && core.lq_q[k].queued && !core.lq_q[k].returned &&
           age(int'(core.lq_q[k].rid))>=int'(core.recovery_age)+int'(core.recovery_keep)) redirect_with_load=1;
        if(core.d_rsp_valid && !core.d_rsp_tag[7] && int'(core.d_rsp_tag[6:0])==k &&
           (core.lq_q[k].canceled || core.lq_d[k].canceled)) begin
          cancel_response[k]=1;cancel_error[k]=core.d_rsp_error;
        end
        if(core.lq_q[k].canceled) begin
          physical_reallocated[k]=freed[k] && !core.free_q[tracked_pdst[k]] && !seen_physical[k];
          rob_reallocated[k]=core.rob_q[tracked_rid[k]].valid &&
            core.rob_q[tracked_rid[k]].generation!=tracked_generation[k] && !seen_rob[k];
        end
      end
    end
    for(integer lane=0;lane<4;lane=lane+1) begin
      index=int'(core.ex_q[lane].rid);
      if(core.ex_q[lane].valid && core.ex_q[lane].op==cpu_pkg::OP_STORE &&
         core.rob_q[index].valid && core.rob_q[index].generation==core.ex_q[lane].generation &&
         !core.rob_q[index].addr_ready && core.execute_rob[index].addr_ready &&
         core.execute_rob[index].fault==0 && !core.redirect) begin
        for(integer k=0;k<LQ_ENTRIES;k=k+1) begin
          if(core.lq_q[k].valid && core.lq_q[k].issued && !core.lq_q[k].canceled &&
             age(int'(core.lq_q[k].rid))>age(index) &&
             core.lq_q[k].addr[31:2]==core.execute_rob[index].addr[31:2]) begin
            overlap=core.lq_q[k].mask & core.execute_rob[index].wstrb;
            covered=overlap!=0;
            for(integer byte_lane=0;byte_lane<4;byte_lane=byte_lane+1)
              if(overlap[byte_lane] && (!core.lq_q[k].forward_from_rob[byte_lane] ||
                 age(int'(core.lq_q[k].forward_owner[byte_lane*ROB_BITS+:ROB_BITS]))<=age(index) ||
                 age(int'(core.lq_q[k].forward_owner[byte_lane*ROB_BITS+:ROB_BITS]))>=age(int'(core.lq_q[k].rid)))) covered=0;
            if(covered) shadow_avoided[k]=1;
          end
        end
      end
    end
    for(integer k=0;k<IQ_ENTRIES;k=k+1) begin
      wait_release_event[k]=core.iq_q[k].valid && core.iq_q[k].wait_store &&
        core.iq_d[k].valid && !core.iq_d[k].wait_store && !core.iq_d[k].address_sent &&
        core.iq_d[k].rid==core.iq_q[k].rid && core.iq_d[k].generation==core.iq_q[k].generation;
      wait_reuse_event[k]=wait_tracked[k] && wait_released[k] && !wait_reuse_seen[k] &&
        core.iq_q[k].valid && core.iq_q[k].rid==waiting_load_rid[k] &&
        core.iq_q[k].generation==waiting_load_generation[k] &&
        core.rob_q[waited_rid[k]].valid && core.rob_q[waited_rid[k]].generation!=waited_generation[k];
    end
  end

  always_ff @(posedge clk) begin
    if(rst) begin
      canceled_responses<=0;canceled_errors<=0;canceled_preaccept<=0;partial_forwarded<=0;
      physical_reuse<=0;rob_reuse<=0;nested_recovery<=0;nested_recovery_with_load<=0;
      canceled_redirects<=0;pending_cancellations<=0;speculative_bypasses<=0;replays<=0;
      previous_valid<=0;freed<=0;seen_physical<=0;seen_rob<=0;
      shadow_forwarded<=0;shadow_replay_avoided<=0;deferred_wait_release<=0;wait_owner_reuse<=0;
      wait_tracked<=0;wait_released<=0;wait_reuse_seen<=0;
      for(integer k=0;k<IQ_ENTRIES;k=k+1) begin
        waited_rid[k]<=0;waiting_load_rid[k]<=0;waited_generation[k]<=0;waiting_load_generation[k]<=0;
      end
      for(integer k=0;k<LQ_ENTRIES;k=k+1) begin
        previous_generation[k]<=0;tracked_generation[k]<=0;previous_rid[k]<=0;
        tracked_rid[k]<=0;tracked_pdst[k]<=0;
      end
    end else begin
      canceled_responses<=canceled_responses+$countones(cancel_response);
      canceled_errors<=canceled_errors+$countones(cancel_error);
      canceled_preaccept<=canceled_preaccept+$countones(cancel_preaccept);
      partial_forwarded<=partial_forwarded+$countones(partial_forward);
      physical_reuse<=physical_reuse+$countones(physical_reallocated);
      rob_reuse<=rob_reuse+$countones(rob_reallocated);
      nested_recovery<=nested_recovery+int'(older_redirect);
      nested_recovery_with_load<=nested_recovery_with_load+int'(older_redirect && redirect_with_load);
      canceled_redirects<=canceled_redirects+int'(redirect_with_load);
      pending_cancellations<=pending_cancellations+$countones(new_cancel);
      speculative_bypasses<=speculative_bypasses+$countones(unknown_bypass);
      replays<=replays+int'(core.redirect && core.replay);
      shadow_forwarded<=shadow_forwarded+$countones(shadow_forward);
      shadow_replay_avoided<=shadow_replay_avoided+$countones(shadow_avoided);
      deferred_wait_release<=deferred_wait_release+$countones(wait_release_event);
      wait_owner_reuse<=wait_owner_reuse+$countones(wait_reuse_event);
      for(integer k=0;k<IQ_ENTRIES;k=k+1) begin
        if(!core.iq_q[k].valid || core.iq_q[k].rid!=waiting_load_rid[k] ||
           core.iq_q[k].generation!=waiting_load_generation[k]) wait_tracked[k]<=0;
        if(core.iq_q[k].valid && core.iq_q[k].wait_store && (!wait_tracked[k] ||
           core.iq_q[k].rid!=waiting_load_rid[k] || core.iq_q[k].generation!=waiting_load_generation[k] ||
           core.iq_q[k].wait_rid!=waited_rid[k])) begin
          wait_tracked[k]<=1;wait_released[k]<=0;wait_reuse_seen[k]<=0;
          waiting_load_rid[k]<=core.iq_q[k].rid;waiting_load_generation[k]<=core.iq_q[k].generation;
          waited_rid[k]<=core.iq_q[k].wait_rid;waited_generation[k]<=core.rob_q[core.iq_q[k].wait_rid].generation;
        end
        if(wait_release_event[k]) wait_released[k]<=1;
        if(wait_reuse_event[k]) wait_reuse_seen[k]<=1;
      end
      for(integer k=0;k<LQ_ENTRIES;k=k+1) begin
        previous_valid[k]<=core.lq_q[k].valid;
        previous_generation[k]<=core.lq_q[k].generation;previous_rid[k]<=core.lq_q[k].rid;
        if(core.lq_q[k].valid && (!previous_valid[k] ||
           previous_generation[k]!=core.lq_q[k].generation || previous_rid[k]!=core.lq_q[k].rid)) begin
          tracked_rid[k]<=core.lq_q[k].rid;tracked_generation[k]<=core.lq_q[k].generation;
          tracked_pdst[k]<=core.rob_q[core.lq_q[k].rid].pdst;
          freed[k]<=0;seen_physical[k]<=0;seen_rob[k]<=0;
        end else if(core.lq_q[k].valid && core.lq_q[k].canceled) begin
          if(core.free_q[tracked_pdst[k]]) freed[k]<=1;
          if(physical_reallocated[k]) seen_physical[k]<=1;
          if(rob_reallocated[k]) seen_rob[k]<=1;
        end
      end
    end
  end
  final $display("LSU_COVERAGE canceled_responses=%0d canceled_errors=%0d canceled_preaccept=%0d partial_forwarded=%0d physical_reuse=%0d rob_reuse=%0d nested_recovery=%0d nested_recovery_with_load=%0d redirects_with_load=%0d pending_cancellations=%0d speculative_bypasses=%0d replays=%0d shadow_forwarded=%0d shadow_replay_avoided=%0d deferred_wait_release=%0d wait_owner_reuse=%0d",
    canceled_responses,canceled_errors,canceled_preaccept,partial_forwarded,physical_reuse,rob_reuse,
    nested_recovery,nested_recovery_with_load,canceled_redirects,pending_cancellations,speculative_bypasses,replays,
    shadow_forwarded,shadow_replay_avoided,deferred_wait_release,wait_owner_reuse);
endmodule
bind core lsu_monitor #(.ROB_BITS(RW),.PHYS_BITS(PW),.ROB_ENTRIES(ROB_ENTRIES),
  .LQ_ENTRIES(LQ_ENTRIES),.IQ_ENTRIES(IQ_ENTRIES),.PHYS_REGS(PHYS_REGS)) lsu_observer (.clk,.rst);
