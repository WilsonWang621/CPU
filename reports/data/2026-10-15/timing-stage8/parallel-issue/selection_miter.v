module selection_miter(input [5:0] base,input [19:0] offsets,input [3:0] ready,output bad);
  wire [23:0] owner;
  for(genvar q=0;q<4;q=q+1) begin: positions
    assign owner[q*6+:6]=base+{1'b0,offsets[q*5+:5]};
  end
  wire old_valid,new_valid;
  wire [1:0] old_index,new_index;
  wire [3:0] grant;
  v2_select #(.ENTRIES(4),.SLOT_BITS(6),.EXTENDED_ORDER(1)) old_selection (
    .ready(ready),.owner(owner),.rob_head(6'b0),.valid(old_valid),.index(old_index));
  v2_parallel_select #(.ENTRIES(4),.SLOT_BITS(6)) new_selection (
    .ready(ready),.owner(owner),.rob_head(6'b0),.valid(new_valid),.index(new_index),.grant(grant));
  assign bad=(old_valid!=new_valid) || (new_valid && old_index!=new_index) ||
    (grant!=(new_valid ? (4'b1<<new_index):4'b0));
endmodule
