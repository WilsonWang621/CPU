// Bound each wakeup decoder and feedback mux to one operand word.
(* keep_hierarchy=1 *)
module v2_operand #(parameter integer SLOT_BITS=5)(
  input wire live,prepare,old_ready,initial_ready,
  input wire [SLOT_BITS-1:0] source,
  input wire [31:0] old_value,initial_value,
  input wire [2:0] wb_good,
  input wire [3*SLOT_BITS-1:0] wb_slots,
  input wire [95:0] wb_values,
  output logic next_ready,
  output logic [31:0] next_value
);
  always_comb begin
    next_ready=old_ready;next_value=old_value;
    if(live) begin
      for(integer w=0;w<3;w=w+1)
        if(!old_ready && wb_good[w] && source==wb_slots[w*SLOT_BITS+:SLOT_BITS]) begin
          next_ready=1;next_value=wb_values[w*32+:32];
        end
    end else if(prepare) begin
      next_ready=initial_ready;next_value=initial_value;
    end
  end
endmodule
