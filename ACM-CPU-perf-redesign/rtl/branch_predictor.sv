// Four consecutive lookups fold speculative history and RAS effects in order.
// Snapshots describe predictor state BEFORE each instruction, including the
// control instruction that ends a predicted packet.
module branch_predictor #(
  parameter integer BHT_ENTRIES=2048, BTB_ENTRIES=256, RAS_DEPTH=16,
  parameter integer PREDICTOR_MODE=2, HISTORY_BITS=8,
  parameter bit ENABLE=1
)(
  input logic clk, rst, advance,
  input logic [31:0] query_pc,
  input logic [2:0] query_count,
  output logic [31:0] predicted_pc [4],
  output logic [3:0] predicted_taken,
  output logic [3:0] bimodal_taken,gshare_taken,
  output logic [15:0] history [4],
  output logic [511:0] ras_snapshot [4],
  output logic [4:0] ras_count [4],
  output logic [2:0] predicted_count,
  output logic [31:0] next_pc,
  input logic redirect_valid,
  input logic [31:0] redirect_branch_pc, redirect_inst,
  input logic [15:0] redirect_history,
  input logic [511:0] redirect_ras_snapshot,
  input logic [4:0] redirect_ras_count,
  input logic redirect_taken,
  input logic [3:0] train_valid,
  input logic [127:0] train_pc, train_inst, train_next_pc,
  input logic [3:0] train_taken,
  input logic [3:0] train_bimodal_taken,train_gshare_taken,
  input logic [63:0] train_history
);
  localparam integer BH=(BHT_ENTRIES>1 ? $clog2(BHT_ENTRIES):1);
  localparam integer BT=(BTB_ENTRIES>1 ? $clog2(BTB_ENTRIES):1);
  localparam integer TAG_BITS=(32-BT-2>0 ? 32-BT-2:1);
  localparam logic [15:0] HISTORY_MASK=16'hffff >> (16-HISTORY_BITS);
  localparam logic [511:0] RAS_MASK={512{1'b1}} >> (512-32*RAS_DEPTH);
  (* ram_style="block" *) logic [1:0] bht [BHT_ENTRIES];
  (* ram_style="block" *) logic [1:0] bimodal [BHT_ENTRIES];
  (* ram_style="block" *) logic [1:0] chooser [BHT_ENTRIES];
  logic [BTB_ENTRIES-1:0] valid;
  logic [BHT_ENTRIES-1:0] initialized_history,initialized_pc;
  typedef struct packed {
    logic conditional,pop_ras,push_ras;
    logic [11:0] return_imm;
  } target_meta_t;
  (* ram_style="block" *) logic [TAG_BITS-1:0] tags [BTB_ENTRIES];
  (* ram_style="block" *) logic [31:0] targets [BTB_ENTRIES];
  (* ram_style="block" *) target_meta_t target_meta [BTB_ENTRIES];
  target_meta_t lookup_meta;
  logic [15:0] history_q, history_next;
  logic [511:0] ras_q, ras_next;
  logic [4:0] ras_count_q, ras_count_next;
  logic [BH-1:0] train_index [4];
  logic [BH-1:0] train_pc_index [4];
  logic [1:0] train_counter [4];
  logic [1:0] train_bimodal_counter [4],train_chooser_counter [4];
  logic [3:0] train_conditional;
  logic [3:0] train_control;
  logic [31:0] train_target [4];
  target_meta_t train_meta [4];
  logic [15:0] walk_history;
  logic [511:0] walk_ras;
  logic [4:0] walk_count;
  logic walking, hit, direction, conditional, pop_hint, push_hint;
  logic [31:0] lane_pc,target;
  logic [BH-1:0] history_index,pc_index;
  logic [BT-1:0] target_index;
  logic [516:0] ras_update, redirect_ras_update;

  function automatic logic is_link(input logic [4:0] reg_number);
    return reg_number==5'd1 || reg_number==5'd5;
  endfunction
  function automatic logic is_control(input logic [31:0] inst);
    return inst[6:0]==7'h63 || inst[6:0]==7'h6f || inst[6:0]==7'h67;
  endfunction
  function automatic logic ras_push(input logic [31:0] inst);
    return is_link(inst[11:7]) && (inst[6:0]==7'h6f || inst[6:0]==7'h67);
  endfunction
  function automatic logic ras_pop(input logic [31:0] inst);
    return inst[6:0]==7'h67 && is_link(inst[19:15]) &&
           (!is_link(inst[11:7]) || inst[11:7]!=inst[19:15]);
  endfunction
  function automatic logic [31:0] branch_offset(input logic [31:0] inst);
    return {{19{inst[31]}},inst[31],inst[7],inst[30:25],inst[11:8],1'b0};
  endfunction
  function automatic logic [31:0] jump_offset(input logic [31:0] inst);
    return {{11{inst[31]}},inst[31],inst[19:12],inst[20],inst[30:21],1'b0};
  endfunction
  function automatic logic [BH-1:0] gshare(input logic [31:0] pc,
                                            input logic [15:0] past);
    return pc[BH+1:2] ^ BH'(past & HISTORY_MASK);
  endfunction
  function automatic logic [1:0] saturate(input logic [1:0] counter,
                                          input logic taken);
    if(taken) return counter==2'b11 ? counter : counter+2'd1;
    return counter==2'b00 ? counter : counter-2'd1;
  endfunction
  // Stack element zero is the newest return address. Overflow drops the oldest
  // entry; coroutine pop+push replaces the top while preserving stack depth.
  function automatic logic [516:0] update_ras(input logic [511:0] stack,
    input logic [4:0] count,input logic [31:0] pc,input logic pop,input logic push);
    logic [511:0] value;
    logic [4:0] depth;
    begin
      value=stack;depth=count;
      if(RAS_DEPTH>0) begin
        if(pop && depth!=0) begin value=value>>32;depth=depth-5'd1;end
        if(push) begin
          value={value[479:0],pc+32'd4};
          if(int'(depth)<RAS_DEPTH) depth=depth+5'd1;
        end
        for(integer k=RAS_DEPTH;k<16;k=k+1) value[k*32+:32]=32'b0;
      end else begin value=0;depth=0;end
      return {depth,value};
    end
  endfunction

  always_comb begin
    walk_history=history_q;walk_ras=ras_q;walk_count=ras_count_q;
    walking=1;hit=0;direction=0;conditional=0;pop_hint=0;push_hint=0;
    lane_pc=query_pc;lookup_meta='0;target=0;history_index=0;pc_index=0;target_index=0;ras_update=0;
    predicted_count=query_count;
    next_pc=query_pc+32'(query_count)*32'd4;
    predicted_taken=0;bimodal_taken=0;gshare_taken=0;
    for(integer lane=0;lane<4;lane=lane+1) begin
      lane_pc=query_pc+32'(lane)*32'd4;
      predicted_pc[lane]=lane_pc+32'd4;
      history[lane]=walk_history;ras_snapshot[lane]=walk_ras;ras_count[lane]=walk_count;
      if(lane<int'(query_count) && walking) begin
        target_index=lane_pc[BT+1:2];history_index=gshare(lane_pc,walk_history);pc_index=lane_pc[BH+1:2];
        // Preserve the direction votes at fetch, even if the target misses.
        // Retirement must not reconstruct these from subsequently updated tables.
        bimodal_taken[lane]=initialized_pc[pc_index] && bimodal[pc_index][1];
        gshare_taken[lane]=initialized_history[history_index] && bht[history_index][1];
        // The index supplies the omitted middle PC bits. Word alignment must
        // still be checked explicitly when the two low tag bits are omitted.
        hit=ENABLE && valid[target_index] && lane_pc[1:0]==2'b00 &&
            tags[target_index]==TAG_BITS'(lane_pc>>(BT+2));
        lookup_meta=target_meta[target_index];conditional=lookup_meta.conditional;
        case(PREDICTOR_MODE)
          0: direction=bimodal_taken[lane];
          1: direction=gshare_taken[lane];
          default: direction=(initialized_pc[pc_index] && chooser[pc_index][1]) ? gshare_taken[lane]:bimodal_taken[lane];
        endcase
        direction=hit && (!conditional || direction);
        target=targets[target_index];
        pop_hint=lookup_meta.pop_ras;push_hint=lookup_meta.push_ras;
        if(hit && pop_hint && walk_count!=0 && RAS_DEPTH>0)
          target=(walk_ras[31:0]+{{20{lookup_meta.return_imm[11]}},lookup_meta.return_imm}) & 32'hfffffffe;
        if(hit && conditional) walk_history={walk_history[14:0],direction};
        if(direction) begin
          predicted_taken[lane]=1;predicted_pc[lane]=target;
          predicted_count=3'(lane+1);next_pc=target;walking=0;
          if(pop_hint || push_hint) begin
            ras_update=update_ras(walk_ras,walk_count,lane_pc,pop_hint,push_hint);
            walk_ras=ras_update[511:0];walk_count=ras_update[516:512];
          end
        end
      end
    end
  end

  always_comb begin
    history_next=walk_history;ras_next=walk_ras;ras_count_next=walk_count;
    redirect_ras_update=update_ras(redirect_ras_snapshot,redirect_ras_count,
                                   redirect_branch_pc,ras_pop(redirect_inst),ras_push(redirect_inst));
    if(redirect_valid) begin
      history_next=redirect_history;
      if(redirect_inst[6:0]==7'h63) history_next={redirect_history[14:0],redirect_taken};
      ras_next=redirect_ras_update[511:0];ras_count_next=redirect_ras_update[516:512];
    end
  end

  // Fold all three tables in retirement order, including aliases between lanes.
  // The chooser uses the recorded fetch-time votes, not the current counters.
  always_comb begin
    train_conditional=0;train_control=0;
    for(integer lane=0;lane<4;lane=lane+1) begin
      train_index[lane]=gshare(train_pc[lane*32+:32],train_history[lane*16+:16]);
      train_pc_index[lane]=train_pc[lane*32+2+:BH];
      train_conditional[lane]=train_valid[lane] && train_inst[lane*32+:7]==7'h63;
      train_control[lane]=train_valid[lane] && is_control(train_inst[lane*32+:32]);
      train_meta[lane].conditional=train_inst[lane*32+:7]==7'h63;
      train_meta[lane].pop_ras=ras_pop(train_inst[lane*32+:32]);
      train_meta[lane].push_ras=ras_push(train_inst[lane*32+:32]);
      train_meta[lane].return_imm=train_inst[lane*32+20+:12];
      case(train_inst[lane*32+:7])
        7'h63: train_target[lane]=train_pc[lane*32+:32]+branch_offset(train_inst[lane*32+:32]);
        7'h6f: train_target[lane]=train_pc[lane*32+:32]+jump_offset(train_inst[lane*32+:32]);
        default: train_target[lane]=train_next_pc[lane*32+:32];
      endcase
      train_counter[lane]=initialized_history[train_index[lane]] ? bht[train_index[lane]]:2'b01;
      train_bimodal_counter[lane]=initialized_pc[train_pc_index[lane]] ? bimodal[train_pc_index[lane]]:2'b01;
      train_chooser_counter[lane]=initialized_pc[train_pc_index[lane]] ? chooser[train_pc_index[lane]]:2'b00;
      for(integer older=0;older<lane;older=older+1) begin
        if(train_conditional[older] && train_index[older]==train_index[lane])
          train_counter[lane]=train_counter[older];
        if(train_conditional[older] && train_pc_index[older]==train_pc_index[lane]) begin
          train_bimodal_counter[lane]=train_bimodal_counter[older];
          train_chooser_counter[lane]=train_chooser_counter[older];
        end
      end
      if(train_conditional[lane]) begin
        train_counter[lane]=saturate(train_counter[lane],train_taken[lane]);
        train_bimodal_counter[lane]=saturate(train_bimodal_counter[lane],train_taken[lane]);
        if(train_bimodal_taken[lane]!=train_gshare_taken[lane])
          train_chooser_counter[lane]=saturate(train_chooser_counter[lane],
                                             train_gshare_taken[lane]==train_taken[lane]);
      end
    end
  end

  always_ff @(posedge clk) begin
    if(rst) begin
      history_q<=0;ras_q<=0;ras_count_q<=0;
    end else begin
      if(redirect_valid || advance) begin
        history_q<=history_next;ras_q<=ras_next & RAS_MASK;ras_count_q<=ras_count_next;
      end
    end
  end
  // Folded values preserve retirement order; later aliased lanes win.
  always_ff @(posedge clk) begin
    if(rst) begin
      initialized_history<='0;initialized_pc<='0;
    end else begin
      for(integer lane=0;lane<4;lane=lane+1) if(train_conditional[lane]) begin
        initialized_history[train_index[lane]]<=1'b1;initialized_pc[train_pc_index[lane]]<=1'b1;
        bht[train_index[lane]]<=train_counter[lane];
        bimodal[train_pc_index[lane]]<=train_bimodal_counter[lane];
        chooser[train_pc_index[lane]]<=train_chooser_counter[lane];
      end
    end
  end
  always_ff @(posedge clk) begin
    if(rst) valid<='0;
    else for(integer lane=0;lane<4;lane=lane+1) if(train_control[lane]) begin
      valid[train_pc[lane*32+2+:BT]]<=train_pc[lane*32+:2]==2'b00;
      tags[train_pc[lane*32+2+:BT]]<=TAG_BITS'(train_pc[lane*32+:32]>>(BT+2));
      target_meta[train_pc[lane*32+2+:BT]]<=train_meta[lane];
      targets[train_pc[lane*32+2+:BT]]<=train_target[lane];
    end
  end
  initial begin
    if(BHT_ENTRIES<2 || (BHT_ENTRIES & (BHT_ENTRIES-1))!=0 || BHT_ENTRIES>65536 ||
      BTB_ENTRIES<2 || (BTB_ENTRIES & (BTB_ENTRIES-1))!=0)
      $fatal(1,"Invalid branch predictor table capacities");
    if(RAS_DEPTH<0 || RAS_DEPTH>16) $fatal(1,"RAS_DEPTH must fit the 16-entry snapshot");
    if(PREDICTOR_MODE<0 || PREDICTOR_MODE>2 || HISTORY_BITS<1 || HISTORY_BITS>16)
      $fatal(1,"Predictor mode must be 0/1/2 and history length 1..16");
  end
endmodule
