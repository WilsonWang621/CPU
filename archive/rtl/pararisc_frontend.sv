// Four recently fetched lines decouple SRAM lookup from two-wide instruction supply.
module pararisc_frontend (
  input wire clock, reset, redirect,
  input wire [31:0] redirect_pc,
  output wire valid,
  input wire ready,
  output wire [31:0] pc0, insn0, insn1, pred0, pred1,
  output wire two,
  input wire train_valid,
  input wire [31:0] train_pc, train_target,
  input wire train_taken, train_conditional, train_indirect,
  output wire cache_valid,
  input wire cache_ready,
  output wire [31:0] cache_addr,
  input wire cache_resp_valid,
  output wire cache_resp_ready,
  input wire [255:0] cache_line
);
  reg [31:0] pc;
  reg [255:0] lines [0:3];
  reg [26:0] bases [0:3];
  reg [3:0] line_valid;
  reg [1:0] replace_way;
  reg pending;
  reg [31:0] pending_addr;
  reg [1:0] counters [0:127];
  reg [31:0] indirect_target [0:15];
  reg [25:0] indirect_tag [0:15];
  reg [15:0] indirect_valid;
  reg hit;
  reg [31:0] selected0, selected1;
  reg packet_valid, packet_two;
  reg [31:0] packet_pc, packet_i0, packet_i1, packet_p0, packet_p1;
  for (genvar p=0; p<128; p=p+1) begin : predictor_counter
    always @(posedge clock) begin
      if (reset) counters[p] <= 2'b01;
      else if (train_valid && train_conditional && train_pc[8:2] == 7'(p)) begin
        if (train_taken && counters[p] != 3) counters[p] <= counters[p] + 1;
        if (!train_taken && counters[p] != 0) counters[p] <= counters[p] - 1;
      end
    end
  end
  always @* begin
    hit = 0; selected0 = 0; selected1 = 0;
    for (integer j=0; j<4; j=j+1) begin
      if (line_valid[j] && bases[j] == pc[31:5]) hit = 1;
      for (integer w=0; w<8; w=w+1) begin
        selected0 = selected0 | (lines[j][w*32 +: 32] &
          {32{line_valid[j] && bases[j] == pc[31:5] && pc[4:2] == 3'(w)}});
        selected1 = selected1 | (lines[j][w*32 +: 32] &
          {32{line_valid[j] && bases[j] == pc[31:5] && second_word == 3'(w)}});
      end
    end
  end
  assign pc0 = packet_pc;
  assign insn0 = packet_i0;
  wire [2:0] second_word = pc[4:2] + 1;
  assign insn1 = packet_i1;
  function automatic [31:0] prediction(input [31:0] insn, here, input direction, indirect_hit, input [31:0] indirect);
    reg [31:0] offset;
    begin
      offset = insn[6:0] == 7'h6f ?
        {{11{insn[31]}},insn[31],insn[19:12],insn[20],insn[30:21],1'b0} :
        {{19{insn[31]}},insn[31],insn[7],insn[30:25],insn[11:8],1'b0};
      if (insn[6:0] == 7'h6f || (insn[6:0] == 7'h63 && direction)) prediction = here + offset;
      else if (insn[6:0] == 7'h67 && indirect_hit) prediction = indirect;
      else prediction = here + 4;
    end
  endfunction
  wire [31:0] second_pc = pc + 4;
  wire [31:0] predicted0 = prediction(selected0, pc, counters[pc[8:2]][1],
    indirect_valid[pc[5:2]] && indirect_tag[pc[5:2]] == pc[31:6], indirect_target[pc[5:2]]);
  wire [31:0] predicted1 = prediction(selected1, second_pc, counters[second_pc[8:2]][1],
    indirect_valid[second_pc[5:2]] && indirect_tag[second_pc[5:2]] == second_pc[31:6], indirect_target[second_pc[5:2]]);
  wire selected_two = pc[4:2] != 7 && predicted0 == second_pc;
  assign two = packet_two;
  assign pred0 = packet_p0;
  assign pred1 = packet_p1;
  assign valid = packet_valid && !redirect;
  assign cache_valid = !hit && !pending && !redirect;
  assign cache_addr = pc;
  assign cache_resp_ready = 1;
  always @(posedge clock) begin
    if (reset) begin
      pc <= 0; line_valid <= 0; replace_way <= 0; pending <= 0; pending_addr <= 0;
      packet_valid <= 0; packet_two <= 0;
      indirect_valid <= 0;
    end else begin
      if (ready) packet_valid <= 0;
      if (hit && (!packet_valid || ready)) begin
        packet_valid <= 1; packet_pc <= pc; packet_i0 <= selected0; packet_i1 <= selected1;
        packet_p0 <= predicted0; packet_p1 <= predicted1; packet_two <= selected_two;
        pc <= selected_two ? predicted1 : predicted0;
      end
      if (redirect) begin pc <= redirect_pc; packet_valid <= 0; end
      if (cache_valid && cache_ready) begin pending <= 1; pending_addr <= pc; end
      if (cache_resp_valid) begin
        pending <= 0; lines[replace_way] <= cache_line;
        bases[replace_way] <= pending_addr[31:5]; line_valid[replace_way] <= 1;
        replace_way <= replace_way + 1;
      end
      if (train_valid && train_indirect) begin
        indirect_valid[train_pc[5:2]] <= 1; indirect_tag[train_pc[5:2]] <= train_pc[31:6];
        indirect_target[train_pc[5:2]] <= train_target;
      end
    end
  end
endmodule
