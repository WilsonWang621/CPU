// Parallel, mutually exclusive operand source selection.
(* keep_hierarchy=1 *)
module v2_operand #(parameter integer SLOT_BITS=5)(
  input wire live,prepare,old_ready,initial_ready,
  input wire [SLOT_BITS-1:0] source,
  input wire [31:0] old_value,initial_value,
  input wire [2:0] wb_good,
  input wire [3*SLOT_BITS-1:0] wb_slots,
  input wire [95:0] wb_values,
  output wire next_ready,
  output wire [31:0] next_value
);
  wire [2:0] hit,chosen;
  for(genvar w=0;w<3;w=w+1) begin: matching
    assign hit[w]=live && !old_ready && wb_good[w] && source==wb_slots[w*SLOT_BITS+:SLOT_BITS];
  end
  assign chosen[2]=hit[2];
  assign chosen[1]=hit[1] && !hit[2];
  assign chosen[0]=hit[0] && !(hit[1] || hit[2]);
  wire initializing=!live && prepare;
  wire holding=!(initializing || |chosen);
  assign next_ready=live ? (old_ready || |hit):(prepare ? initial_ready:old_ready);
  assign next_value=(old_value & {32{holding}}) | (initial_value & {32{initializing}}) |
                    (wb_values[31:0] & {32{chosen[0]}}) |
                    (wb_values[63:32] & {32{chosen[1]}}) |
                    (wb_values[95:64] & {32{chosen[2]}});
endmodule
