`timescale 1ns/1ps
module v2_rename_prepare_tb;
  reg clk=0;
  always #5 clk=~clk;
  reg rst=1;
  reg [1:0] dispatch_valid=0,prepare_valid=0,commit_valid=0;
  reg [9:0] dispatch_rd=0,dispatch_slot=0,commit_rd=0,commit_slot=0;
  reg [19:0] source_register=0;
  wire [3:0] source_pending;
  wire [19:0] source_slot;
  reg save_valid=0,save_prepare=0,save_after_lane=0,restore_valid=0;
  reg [1:0] save_index=0,restore_index=0;
  v2_rename dut(.clk(clk),.rst(rst),.dispatch_valid(dispatch_valid),.prepare_valid(prepare_valid),
    .dispatch_rd(dispatch_rd),.dispatch_slot(dispatch_slot),.source_register(source_register),
    .source_pending(source_pending),.source_slot(source_slot),.commit_valid(commit_valid),
    .commit_rd(commit_rd),.commit_slot(commit_slot),.save_valid(save_valid),
    .save_after_lane(save_after_lane),.save_index(save_index),.restore_valid(restore_valid),.restore_index(restore_index));

  // Architectural mapping model: apply the accepted prefix in order, take a
  // branch image, restore when requested, then remove retiring producers.
  reg pending[0:31],saved_pending[0:31],cp_pending[0:3][0:31];
  integer tag[0:31],saved_tag[0:31],cp_tag[0:3][0:31];
  reg [3:0] live=0;
  integer seed=32'h31ce247,step,r,c,l,p,reg_id,slot,free_cp,restore_cp;
  integer restores=0,abandoned=0,bypasses=0,saves=0,retire_matches=0;
  reg publishing,expected_pending;
  integer expected_tag;
  function integer random_range(input integer limit);
    random_range=($random(seed)&32'h7fffffff)%limit;
  endfunction
  initial begin
    for(r=0;r<32;r=r+1) begin
      pending[r]=0;tag[r]=0;
      for(c=0;c<4;c=c+1) begin cp_pending[c][r]=0;cp_tag[c][r]=0;end
    end
    @(posedge clk);#1;
    for(step=0;step<5000;step=step+1) begin
      @(negedge clk);
      rst=step%211==0;
      if(rst) live=0;
      // A later accepted branch may reuse a released checkpoint's dead image.
      if(random_range(5)==0) live[random_range(4)]=0;
      free_cp=-1;restore_cp=-1;
      for(c=0;c<4;c=c+1) begin
        if(!live[c]) free_cp=c;
        else restore_cp=c;
      end
      prepare_valid=random_range(3)==0 ? 0:random_range(2)==0 ? 1:3;
      dispatch_rd={5'(random_range(32)),5'(random_range(32))};
      dispatch_slot={5'(random_range(32)),5'(random_range(32))};
      // Exercise intra-bundle RAW and WAW dependencies deliberately.
      if(random_range(2)==0) dispatch_rd[9:5]=dispatch_rd[4:0];
      for(p=0;p<4;p=p+1) source_register[p*5+:5]=5'(random_range(32));
      if(random_range(2)==0) source_register[14:10]=dispatch_rd[4:0];
      restore_valid=!rst && restore_cp>=0 && random_range(4)==0;
      restore_index=restore_cp<0 ? 0:2'(restore_cp);
      publishing=!rst && !restore_valid && random_range(3)!=0;
      dispatch_valid=publishing ? prepare_valid:0;
      save_prepare=!rst && free_cp>=0 && prepare_valid!=0 && random_range(2)==0;
      save_valid=save_prepare && publishing;
      save_index=free_cp<0 ? 0:2'(free_cp);
      save_after_lane=prepare_valid[1] && random_range(2)==0;
      commit_valid=rst ? 0:2'(random_range(4));
      for(l=0;l<2;l=l+1) begin
        reg_id=random_range(31)+1;
        commit_rd[l*5+:5]=5'(reg_id);
        commit_slot[l*5+:5]=random_range(2)==0 ? 5'(tag[reg_id]):5'(random_range(32));
        for(p=0;p<2;p=p+1)
          if(dispatch_valid[p] && commit_slot[l*5+:5]==dispatch_slot[p*5+:5]) commit_valid[l]=0;
      end
      #1;
      for(p=0;p<4;p=p+1) begin
        reg_id=source_register[p*5+:5];
        expected_pending=pending[reg_id];expected_tag=tag[reg_id];
        if(p>=2 && prepare_valid[0] && dispatch_rd[4:0]!=0 && dispatch_rd[4:0]==reg_id) begin
          expected_pending=1;expected_tag=dispatch_slot[4:0];bypasses=bypasses+1;
        end
        if(source_pending[p]!==expected_pending ||
           (expected_pending && source_slot[p*5+:5]!==5'(expected_tag)))
          $fatal(1,"lookup mismatch step=%0d port=%0d",step,p);
      end
      @(posedge clk);#1;
      if(rst) begin
        for(r=0;r<32;r=r+1) begin
          pending[r]=0;
          for(c=0;c<4;c=c+1) cp_pending[c][r]=0;
        end
      end else begin
        for(l=0;l<2;l=l+1) begin
          reg_id=dispatch_rd[l*5+:5];
          if(dispatch_valid[l] && reg_id!=0) begin pending[reg_id]=1;tag[reg_id]=dispatch_slot[l*5+:5];end
          if(save_after_lane==1'(l))
            for(r=0;r<32;r=r+1) begin saved_pending[r]=pending[r];saved_tag[r]=tag[r];end
        end
        if(restore_valid) begin
          restores=restores+1;
          for(r=0;r<32;r=r+1) begin pending[r]=cp_pending[restore_index][r];tag[r]=cp_tag[restore_index][r];end
        end
        for(l=0;l<2;l=l+1) if(commit_valid[l] && commit_rd[l*5+:5]!=0) begin
          reg_id=commit_rd[l*5+:5];slot=commit_slot[l*5+:5];
          if(tag[reg_id]==slot) begin pending[reg_id]=0;retire_matches=retire_matches+1;end
          if(saved_tag[reg_id]==slot) saved_pending[reg_id]=0;
          for(c=0;c<4;c=c+1) if(cp_tag[c][reg_id]==slot) cp_pending[c][reg_id]=0;
        end
        pending[0]=0;saved_pending[0]=0;
        if(save_valid) begin
          live[save_index]=1;saves=saves+1;
          for(r=0;r<32;r=r+1) begin cp_pending[save_index][r]=saved_pending[r];cp_tag[save_index][r]=saved_tag[r];end
        end
        if(save_prepare && !save_valid) abandoned=abandoned+1;
      end
      for(r=0;r<32;r=r+1) begin
        if(dut.pending_q[r]!==pending[r] || (pending[r] && dut.tag_q[r]!==5'(tag[r])))
          $fatal(1,"published mapping mismatch step=%0d register=%0d",step,r);
        for(c=0;c<4;c=c+1) if(live[c]) begin
          if(dut.checkpoint_pending[c][r]!==cp_pending[c][r] ||
             (cp_pending[c][r] && dut.checkpoint_tag[c*32+r]!==5'(cp_tag[c][r])))
            $fatal(1,"snapshot mismatch step=%0d checkpoint=%0d register=%0d pending=%b/%b tag=%0d/%0d prep=%b accept=%b rd=%h slots=%h after=%b save=%b restore=%b",
              step,c,r,dut.checkpoint_pending[c][r],cp_pending[c][r],dut.checkpoint_tag[c*32+r],cp_tag[c][r],
              prepare_valid,dispatch_valid,dispatch_rd,dispatch_slot,save_after_lane,save_valid,restore_valid);
        end
      end
    end
    if(restores<100 || abandoned<100 || bypasses<100 || saves<100 || retire_matches<100)
      $fatal(1,"insufficient recovery/preparation coverage");
    $display("Rename preparation: PASS 5000 cycles; restores=%0d abandoned=%0d bypasses=%0d saves=%0d retire_matches=%0d",
      restores,abandoned,bypasses,saves,retire_matches);
    $finish;
  end
endmodule
