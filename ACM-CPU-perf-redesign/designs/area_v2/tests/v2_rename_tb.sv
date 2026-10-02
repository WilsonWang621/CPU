module v2_rename_tb;
  logic clk=0,rst=1;
  logic [1:0] dispatch_valid,commit_valid;
  logic [9:0] dispatch_rd,dispatch_slot,commit_rd,commit_slot;
  logic [19:0] source_register,source_slot;
  logic [3:0] source_pending;
  logic save_valid,save_after_lane,restore_valid;
  logic [1:0] save_index,restore_index;
  v2_rename dut(.*);
  logic [5:0] reference_map [32],snapshots [4][32],work_map [32],saved [32];
  logic [5:0] expected_sources [4];
  integer r,cp,c,iteration;
  logic [4:0] regno;
  task automatic tick;
    #1;clk=1;#1;clk=0;
  endtask
  task automatic step;
    for (integer a=0;a<32;a=a+1) begin
      work_map[a]=reference_map[a];saved[a]=0;
    end
    for (integer d=0;d<2;d=d+1) begin
      for (integer b=0;b<2;b=b+1)
        expected_sources[2*d+b]=work_map[source_register[(2*d+b)*5+:5]];
      if (dispatch_valid[d] && dispatch_rd[d*5+:5]!=0)
        work_map[dispatch_rd[d*5+:5]]={1'b1,dispatch_slot[d*5+:5]};
      if (save_after_lane==1'(d))
        for (integer a=0;a<32;a=a+1) saved[a]=work_map[a];
    end
    #1;
    for (integer p=0;p<4;p=p+1) begin
      assert (source_pending[p]==expected_sources[p][5]) else $fatal(1,"source pending p=%0d iteration=%0d",p,iteration);
      if (source_pending[p])
        assert (source_slot[p*5+:5]==expected_sources[p][4:0]) else $fatal(1,"source tag p=%0d iteration=%0d",p,iteration);
    end
    if (restore_valid)
      for (integer a=0;a<32;a=a+1) work_map[a]=snapshots[restore_index][a];
    for (integer p=0;p<2;p=p+1)
      if (commit_valid[p] && commit_rd[p*5+:5]!=0) begin
        if (work_map[commit_rd[p*5+:5]][4:0]==commit_slot[p*5+:5]) work_map[commit_rd[p*5+:5]][5]=0;
        if (saved[commit_rd[p*5+:5]][4:0]==commit_slot[p*5+:5]) saved[commit_rd[p*5+:5]][5]=0;
        for (integer k=0;k<4;k=k+1)
          if (snapshots[k][commit_rd[p*5+:5]][4:0]==commit_slot[p*5+:5]) snapshots[k][commit_rd[p*5+:5]][5]=0;
      end
    if (save_valid && !restore_valid)
      for (integer a=0;a<32;a=a+1) snapshots[save_index][a]=saved[a];
    for (integer a=0;a<32;a=a+1) reference_map[a]=work_map[a];
    tick();
  endtask
  initial begin
    dispatch_valid=0;commit_valid=0;dispatch_rd=0;dispatch_slot=0;
    commit_rd=0;commit_slot=0;source_register=0;
    save_valid=0;restore_valid=0;save_after_lane=0;save_index=0;restore_index=0;
    for (r=0;r<32;r=r+1) reference_map[r]=0;
    for (cp=0;cp<4;cp=cp+1) for(r=0;r<32;r=r+1) snapshots[cp][r]=0;
    tick();rst=0;
    // Snapshot after lane 0 excludes lane 1's younger overwrite; lane 1
    // reads lane 0. Then the older producer commits and its slot is reused.
    dispatch_valid=3;dispatch_rd={5'd1,5'd1};dispatch_slot={5'd8,5'd7};
    source_register={5'd1,5'd1,5'd0,5'd0};save_valid=1;step();
    dispatch_valid=0;save_valid=0;commit_valid=1;commit_rd=1;commit_slot=7;step();
    commit_valid=0;dispatch_valid=1;dispatch_rd=1;dispatch_slot=7;step();
    dispatch_valid=0;restore_valid=1;step();restore_valid=0;step();
    assert (!source_pending[2]) else $fatal(1,"restore revived committed slot");
    // Random overlapping writes, retirement, checkpoint capture and restore.
    for (iteration=0;iteration<5000;iteration=iteration+1) begin
      dispatch_valid=2'($urandom);dispatch_rd=10'($urandom);dispatch_slot=10'($urandom);
      if (dispatch_slot[4:0]==dispatch_slot[9:5]) dispatch_valid[1]=0;
      source_register=20'($urandom);
      commit_valid=2'($urandom);commit_rd=10'($urandom);
      for (c=0;c<2;c=c+1) begin
        regno=commit_rd[c*5+:5];
        commit_slot[c*5+:5]=reference_map[regno][4:0];
        if (commit_slot[c*5+:5]==dispatch_slot[4:0] || commit_slot[c*5+:5]==dispatch_slot[9:5]) commit_valid[c]=0;
      end
      restore_valid=($urandom_range(0,9)==0);restore_index=2'($urandom);
      if (restore_valid) dispatch_valid=0;
      save_valid=($urandom_range(0,2)==0);save_index=2'($urandom);save_after_lane=1'($urandom);
      step();
    end
    $display("PASS rename: directed stale-slot restore and 5000 random cycles");
    $finish;
  end
endmodule
