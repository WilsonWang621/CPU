module v2_commit_slot_monitor #(parameter integer SLOT_BITS=5,CHECKPOINTS=4)(
 input wire clk,rst,
 input wire [2*SLOT_BITS-1:0] expected,active,
 input wire [CHECKPOINTS*2*SLOT_BITS-1:0] copies
);
 integer checks=0;
 always @(posedge clk) if(!rst) begin
   assert(active==expected) else $fatal(1,"active RAT retirement indices disagree");
   for(integer cp=0;cp<CHECKPOINTS;cp=cp+1)
     assert(copies[cp*2*SLOT_BITS+:2*SLOT_BITS]==expected) else $fatal(1,"checkpoint retirement indices disagree");
   checks=checks+1;
 end
 final $fdisplay(32'h80000002,"Commit slot copies: PASS checks=%0d",checks);
endmodule
bind v2_rename v2_commit_slot_monitor #(.SLOT_BITS(SLOT_BITS),.CHECKPOINTS(CHECKPOINTS)) commit_slot_monitor (
 .clk(clk),.rst(rst),.expected(commit_slot),.active(local_commit_slot),.copies(local_checkpoint_slots)
);
