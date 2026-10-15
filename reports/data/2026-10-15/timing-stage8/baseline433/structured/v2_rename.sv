// ROB-tag rename state with four branch-only snapshots. Committing a producer
// clears its tag from every snapshot before the ROB slot can be reused. Thus
// restore never revives a stale mapping to a younger owner of the same slot.
module v2_rename #(
  parameter integer SLOT_BITS=5, CHECKPOINTS=4,
  parameter integer CHECKPOINT_BITS=$clog2(CHECKPOINTS), COMMIT_TREE=0
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
  localparam integer COMMIT_BITS=12+2*SLOT_BITS;
  localparam integer COMMIT_GROUPS=4*(CHECKPOINTS+1);
  wire [COMMIT_BITS*COMMIT_GROUPS-1:0] commit_controls;
  generate if(COMMIT_TREE) begin: distributed_commit
    v2_distribution #(.WIDTH(COMMIT_BITS),.LEAVES(COMMIT_GROUPS)) tree (
      .data_in({commit_valid,commit_rd,commit_slot}),.data_out(commit_controls));
  end else begin: direct_commit
    assign commit_controls={COMMIT_GROUPS{{commit_valid,commit_rd,commit_slot}}};
  end endgenerate

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
        if (commit_controls[(r/8)*COMMIT_BITS+2*SLOT_BITS+10+c] &&
            commit_controls[(r/8)*COMMIT_BITS+2*SLOT_BITS+c*5+:5]==5'(r)) begin
          if (tag_next[r]==commit_controls[(r/8)*COMMIT_BITS+c*SLOT_BITS+:SLOT_BITS]) pending_next[r]=0;
          if (save_tag[r]==commit_controls[(r/8)*COMMIT_BITS+c*SLOT_BITS+:SLOT_BITS]) save_pending[r]=0;
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
    wire save_pulse=save_valid && save_index==CHECKPOINT_BITS'(cp) && !restore_valid;
    wire [31:0] save_enables;
    if(COMMIT_TREE) begin: distributed_save
      v2_distribution #(.WIDTH(1),.LEAVES(32)) tree (
        .data_in(save_pulse),.data_out(save_enables));
    end else begin: direct_save
      assign save_enables={32{save_pulse}};
    end
    for (genvar r=0;r<32;r=r+1) begin: regmap
      wire [COMMIT_BITS-1:0] local_commit=commit_controls[((cp+1)*4+r/8)*COMMIT_BITS+:COMMIT_BITS];
      always_ff @(posedge clk) begin
        if (rst) checkpoint_pending[cp][r]<=0;
        else begin
          for (integer c=0;c<2;c=c+1)
            if (local_commit[2*SLOT_BITS+10+c] && local_commit[2*SLOT_BITS+c*5+:5]==5'(r) &&
                checkpoint_tag[cp][r]==local_commit[c*SLOT_BITS+:SLOT_BITS])
              checkpoint_pending[cp][r]<=0;
          if (save_enables[r]) begin
            checkpoint_pending[cp][r]<=save_pending[r];
            checkpoint_tag[cp][r]<=save_tag[r];
          end
        end
      end
    end
  end
endmodule
