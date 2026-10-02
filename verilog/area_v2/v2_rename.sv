// ROB-tag rename state with four branch-only snapshots. Committing a producer
// clears its tag from every snapshot before the ROB slot can be reused. Thus
// restore never revives a stale mapping to a younger owner of the same slot.
module v2_rename #(
  parameter integer SLOT_BITS=5, CHECKPOINTS=4,
  parameter integer CHECKPOINT_BITS=$clog2(CHECKPOINTS)
)(
  input logic clk,rst,
  input logic [1:0] dispatch_valid,
  input logic [1:0] prepare_valid,
  input logic [9:0] dispatch_rd,
  input logic [2*SLOT_BITS-1:0] dispatch_slot,
  input logic [19:0] source_register,
  output logic [3:0] source_pending,
  output logic [4*SLOT_BITS-1:0] source_slot,
  input logic [1:0] commit_valid,
  input logic [9:0] commit_rd,
  input logic [2*SLOT_BITS-1:0] commit_slot,
  input logic save_valid, save_after_lane,
  input logic [CHECKPOINT_BITS-1:0] save_index,
  input logic restore_valid,
  input logic [CHECKPOINT_BITS-1:0] restore_index
);
  logic [31:0] pending_q,pending_next,save_pending;
  logic [SLOT_BITS-1:0] tag_q [32],tag_next [32],save_tag [32];
  logic [31:0] checkpoint_pending [CHECKPOINTS];
  logic [SLOT_BITS-1:0] checkpoint_tag [CHECKPOINTS][32];

  always_comb begin
    pending_next=pending_q;
    for (integer r=0;r<32;r=r+1) tag_next[r]=tag_q[r];
    save_pending='0;
    for (integer r=0;r<32;r=r+1) save_tag[r]='0;
    // Source lookup sees the still-live retiring producer's ROB result.
    // Lane 1 observes lane 0's destination without an extra clock boundary.
    for (integer lane=0;lane<2;lane=lane+1) begin
      if (dispatch_valid[lane] && dispatch_rd[lane*5+:5]!=0) begin
        pending_next[dispatch_rd[lane*5+:5]]=1;
        tag_next[dispatch_rd[lane*5+:5]]=dispatch_slot[lane*SLOT_BITS+:SLOT_BITS];
      end
      if (save_after_lane==1'(lane)) begin
        save_pending=pending_next;
        for (integer r=0;r<32;r=r+1) save_tag[r]=tag_next[r];
      end
    end
    if (restore_valid) begin
      pending_next=checkpoint_pending[restore_index];
      for (integer r=0;r<32;r=r+1) tag_next[r]=checkpoint_tag[restore_index][r];
    end
    // A legal allocator never assigns a committing slot to a new writer on
    // the same edge. This one-cycle exclusion also simplifies external tags.
    for (integer r=1;r<32;r=r+1)
      for (integer c=0;c<2;c=c+1)
        if (commit_valid[c] && commit_rd[c*5+:5]==5'(r)) begin
          if (tag_next[r]==commit_slot[c*SLOT_BITS+:SLOT_BITS]) pending_next[r]=0;
          if (save_tag[r]==commit_slot[c*SLOT_BITS+:SLOT_BITS]) save_pending[r]=0;
        end
    pending_next[0]=0;save_pending[0]=0;
  end

  // Lookup and intra-bundle forwarding use the prepared prefix. Recovery
  // only gates publication and the actual RAT update, not these wide paths.
  for(genvar port_id=0;port_id<4;port_id=port_id+1) begin: lookup
    wire [4:0] register_id=source_register[port_id*5+:5];
    wire bypass=port_id>=2 && prepare_valid[0] && dispatch_rd[4:0]!=0 &&
                dispatch_rd[4:0]==register_id;
    wire [32*(SLOT_BITS+1)-1:0] mappings;
    wire [SLOT_BITS:0] mapping;
    for(genvar r=0;r<32;r=r+1) begin: row
      assign mappings[r*(SLOT_BITS+1)+:SLOT_BITS+1]={pending_q[r],tag_q[r]};
    end
    v2_read #(.ENTRIES(32),.WORD_BITS(SLOT_BITS+1)) read_mapping (
      .index(register_id),.words(mappings),.value(mapping));
    assign source_pending[port_id]=bypass || mapping[SLOT_BITS];
    assign source_slot[port_id*SLOT_BITS+:SLOT_BITS]=bypass ? dispatch_slot[0+:SLOT_BITS]:mapping[SLOT_BITS-1:0];
  end

  always_ff @(posedge clk) begin
    if (rst) pending_q<=0;
    else pending_q<=pending_next;
    for (integer r=0;r<32;r=r+1) tag_q[r]<=tag_next[r];
  end
  for (genvar cp=0;cp<CHECKPOINTS;cp=cp+1) begin: snapshot
    for (genvar r=0;r<32;r=r+1) begin: regmap
      always_ff @(posedge clk) begin
        if (rst) checkpoint_pending[cp][r]<=0;
        else begin
          for (integer c=0;c<2;c=c+1)
            if (commit_valid[c] && commit_rd[c*5+:5]==5'(r) &&
                checkpoint_tag[cp][r]==commit_slot[c*SLOT_BITS+:SLOT_BITS])
              checkpoint_pending[cp][r]<=0;
          if (save_valid && save_index==CHECKPOINT_BITS'(cp) && !restore_valid) begin
            checkpoint_pending[cp][r]<=save_pending[r];
            checkpoint_tag[cp][r]<=save_tag[r];
          end
        end
      end
    end
  end
endmodule
