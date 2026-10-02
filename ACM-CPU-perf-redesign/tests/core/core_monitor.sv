// Simulation-only coverage and checkpoint assertions; no production RTL hooks.
module core_monitor #(
  parameter integer PW=7, ROB_ENTRIES=64
)(
  input logic clk,rst,
  input logic [2:0] rename_count,
  input logic [3:0] rename_writes,retire_valid,
  input logic [19:0] rename_rd,
  input logic redirect,replay,
  input logic [32*PW-1:0] checkpoint,
  input logic [PW-1:0] rat [32],
  input logic [ROB_ENTRIES-1:0] pending_mdu,
  input logic [255:0] kill_mask
);
  integer renames,waws,redirects,replays,canceled_mdu,commits,rename_four,commit_four,older_redirects;
  logic expected_restore;
  logic [32*PW-1:0] expected_map;
  logic group_waw,redirect_over_resolved_branch;
  always_comb begin
    group_waw=0;
    redirect_over_resolved_branch=0;
    for(integer later=1;later<4;later=later+1)
      for(integer earlier=0;earlier<later;earlier=earlier+1)
        if(later<int'(rename_count) && rename_writes[earlier] && rename_writes[later] &&
           rename_rd[earlier*5+:5]==rename_rd[later*5+:5]) group_waw=1;
    for(integer slot=0;slot<ROB_ENTRIES;slot=slot+1)
      if(redirect && !replay && core.rob_q[slot].valid && core.rob_q[slot].branch_resolved &&
         (slot+ROB_ENTRIES-int'(core.head_q))%ROB_ENTRIES >
         (int'(core.recovery_rid)+ROB_ENTRIES-int'(core.head_q))%ROB_ENTRIES)
        redirect_over_resolved_branch=1;
  end
  always_ff @(posedge clk) begin
    if(rst) begin
      renames<=0;waws<=0;redirects<=0;replays<=0;canceled_mdu<=0;commits<=0;
      rename_four<=0;commit_four<=0;expected_restore<=0;expected_map<=0;older_redirects<=0;
    end else begin
      if(expected_restore) for(integer k=0;k<32;k=k+1)
        assert(rat[k]==expected_map[k*PW+:PW]) else $fatal(1,"RAT checkpoint restore mismatch x%0d",k);
      expected_restore<=redirect;
      if(redirect) begin
        expected_map<=checkpoint;redirects<=redirects+1;
        if(replay) replays<=replays+1;
      end
      if(rename_count>=2) renames<=renames+1;
      if(redirect_over_resolved_branch) older_redirects<=older_redirects+1;
      if(rename_count==4) rename_four<=rename_four+1;
      if(group_waw) waws<=waws+1;
      if(|(pending_mdu & kill_mask[ROB_ENTRIES-1:0])) canceled_mdu<=canceled_mdu+1;
      if(retire_valid[1]) commits<=commits+1;
      if(retire_valid==4'b1111) commit_four<=commit_four+1;
    end
  end
  final $display("CORE_COVERAGE rename=%0d waw=%0d checkpoint=%0d replay=%0d mdu_cancel=%0d commit=%0d rename4=%0d commit4=%0d older_redirect=%0d",
                 renames,waws,redirects,replays,canceled_mdu,commits,rename_four,commit_four,older_redirects);
endmodule

bind core core_monitor #(.PW(PW),.ROB_ENTRIES(ROB_ENTRIES)) monitor (
  .clk,.rst,.rename_count(fetch_pop),.retire_valid,
  .rename_writes({decoded[3].writes_rd,decoded[2].writes_rd,decoded[1].writes_rd,decoded[0].writes_rd}),
  .rename_rd({decoded[3].rd,decoded[2].rd,decoded[1].rd,decoded[0].rd}),
  .redirect,.replay,.checkpoint(map_q[recovery_rid]),.rat(rat_q),
  .pending_mdu(mdu_pending_q),.kill_mask(mdu_kill_mask)
);
