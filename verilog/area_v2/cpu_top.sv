module cpu_top #(
  parameter integer ROB_ENTRIES=32, IQ_ENTRIES=8, LOAD_SLOTS=8, STORE_SLOTS=16,
  parameter integer CHECKPOINTS=4, RENAME_WIDTH=2, COMMIT_WIDTH=2, INTEGER_PORTS=2,
  parameter integer ICACHE_BYTES=1024, DCACHE_BYTES=2048, DCACHE_LINE_BYTES=64, D_MSHRS=4,
  parameter integer FETCH_QUEUE_ENTRIES=8, BHT_ENTRIES=256, BTB_ENTRIES=32, LOCAL_HISTORY_BITS=1, HISTORY_ENTRIES=64,
  parameter integer MAX_MEM_OUTSTANDING=64, RAM_BYTES=268435456
) (
  input logic clk, rst,
  output logic mem_req_valid, mem_req_write,
  output logic [31:0] mem_req_addr, mem_req_wdata,
  output logic [3:0] mem_req_wstrb,
  input logic mem_req_ready,
  input logic mem_rsp_valid,
  input logic [31:0] mem_rsp_rdata,
  input logic mem_rsp_error,
  output logic mem_rsp_ready,
  output logic halted, faulted,
  output logic [31:0] fault_pc, fault_inst,
  output logic fault_inst_valid,
  output logic [3:0] fault_cause,
  output logic [31:0] fault_addr,
  output logic [3:0] retire_valid,
  output logic [127:0] retire_pc, retire_inst,
  output logic [19:0] retire_rd,
  output logic [127:0] retire_value,
  output logic [3:0] retire_store,
  output logic [127:0] retire_addr, retire_wdata,
  output logic [15:0] retire_wstrb,
  output logic [63:0] cycle_count, retired_count, branch_miss_count, load_replay_count,
  output logic [63:0] icache_miss_count, dcache_miss_count
);
  import cpu_pkg::*;
  localparam integer HB=LOCAL_HISTORY_BITS>0 ? LOCAL_HISTORY_BITS:1;
  localparam integer RW=$clog2(ROB_ENTRIES), QW=$clog2(IQ_ENTRIES);
  localparam integer LT=$clog2(LOAD_SLOTS), ST=$clog2(STORE_SLOTS), CPW=$clog2(CHECKPOINTS);
  typedef logic [RW-1:0] rid_t;
  typedef struct packed {
    logic valid,done,iv,store,exiting;
    logic [4:0] rd;
    logic [3:0] fault;
    logic [ST-1:0] store_slot;
    logic [3:0] mask;
    logic [31:0] pc,inst,fault_address,address,wdata;
  } rob_t;
  typedef struct packed {
    logic done,exiting,store;
    logic [3:0] fault;
    logic [4:0] rd;
    logic [ST-1:0] store_slot;
  } retire_meta_t;
  localparam integer RETIRE_META_BITS=$bits(retire_meta_t);
  retire_meta_t retirement_meta [2];
  wire [ROB_ENTRIES*RETIRE_META_BITS-1:0] retirement_words;
  logic [31:0] retirement_value [2];
  typedef struct packed {
    logic valid,ready_a,ready_b,use_imm,sign_extend,generation;
    rid_t rid,source_a,source_b;
    op_t op;
    logic [29:0] pc,prediction;
    logic [HB-1:0] history;
    logic [1:0] size;
    logic [CPW-1:0] checkpoint;
    // Keep full words aligned in the packed simulation representation too.
    logic [31:0] a,b,imm;
  } issue_t;
  localparam integer ISSUE_BITS=$bits(issue_t);
  typedef struct packed {
    logic valid,committed,issued,done;
    rid_t rid;
    logic [3:0] mask;
    logic [31:0] address,data,pc,inst;
  } store_t;
  typedef struct packed {
    logic valid,canceled,sign_extend;
    rid_t rid;
    logic [1:0] size;
    logic [31:0] address;
  } load_t;
  typedef enum logic [1:0] {RUN,DRAIN,DONE,FAULT} state_t;
  state_t state;
  rob_t rob [ROB_ENTRIES];
  logic [31:0] values [ROB_ENTRIES],architectural [32];
  wire [ROB_ENTRIES*32-1:0] result_words;
  wire [ROB_ENTRIES*6-1:0] result_status_words;
  wire [32*32-1:0] architectural_words;
  logic [31:0] source_result [4],source_architectural [4];
  logic [5:0] source_status [4];
  issue_t queue [3][IQ_ENTRIES],dispatch_payload[2];
  store_t stores [STORE_SLOTS];
  load_t loads [LOAD_SLOTS];
  rid_t head,tail;
  logic tail_generation;
  wire [RW:0] allocation_end={tail_generation,tail}+(RW+1)'(dispatch_count);
  wire [2*(RW+1)-1:0] dispatch_order;
  logic [RW:0] rob_count;
  logic [ST-1:0] store_head,store_tail;
  logic [ST:0] store_count;
  logic [CHECKPOINTS-1:0] checkpoint_valid;
  rid_t checkpoint_owner [CHECKPOINTS];
  logic [CPW-1:0] free_checkpoint;
  logic checkpoint_available;
  logic [1:0] fetch_valid,fetch_iv,pop_count;
  logic [63:0] fetch_pc,fetch_inst,fetch_prediction;
  logic [7:0] fetch_fault;
  logic [2*HB-1:0] fetch_history;
  decoded_t decoded [2];
  logic frontend_idle,stop_frontend,redirect,flush_all,exit_head,fault_head;
  logic [31:0] redirect_pc;
  rid_t redirect_rid;
  logic [CPW-1:0] redirect_checkpoint;
  logic train_valid,train_taken;
  op_t train_op;
  logic [31:0] train_pc,train_target;
  logic [1:0] client_req_valid,client_req_ready,client_req_write,client_rsp_valid,client_rsp_ready,client_rsp_error;
  logic [63:0] client_req_addr,client_req_data,client_rsp_data;
  logic [7:0] client_req_mask;
  logic bus_req_valid,bus_req_ready,bus_req_write,bus_rsp_ready,controller_idle;
  logic [31:0] bus_req_addr,bus_req_data;
  logic [3:0] bus_req_mask;
  logic cache_idle,cache_load_valid,cache_load_ready,cache_load_hit;
  logic [31:0] cache_load_address,cache_load_data;
  logic [LT-1:0] cache_load_tag,cache_result_tag;
  logic cache_result_valid,cache_result_error;
  logic [31:0] cache_result_data;
  logic cache_store_valid,cache_store_ready,cache_store_done,cache_store_error;
  logic [ST-1:0] cache_store_tag,cache_store_done_tag;
  logic [31:0] cache_store_address,cache_store_data;
  logic [3:0] cache_store_mask;
  logic [1:0] rename_valid,commit_valid;
  logic [9:0] rename_rd,commit_rd;
  logic [2*RW-1:0] rename_slot,commit_slot;
  logic [19:0] source_register;
  logic [3:0] source_pending;
  logic [4*RW-1:0] source_slot;
  logic save_checkpoint,save_after_lane;
  logic [1:0] dispatch_valid,dispatch_prepare,rename_prepare;
  logic [1:0] dispatch_bank [2];
  logic [QW-1:0] dispatch_index [2];
  rid_t dispatch_rid [2],commit_rid [2];
  logic [1:0] dispatch_count,commit_count;
  logic [2:0] used_bank;
  logic [2:0] free_queue_valid;
  logic [QW-1:0] free_queue [3],selected [3];
  logic [QW:0] occupancy [3];
  logic [2:0] select_valid,issue_fire;
  logic [2:0] selected_valid;
  logic [IQ_ENTRIES-1:0] select_ready [3];
  logic [IQ_ENTRIES*(RW+1)-1:0] select_owner [3];
  logic [STORE_SLOTS-1:0] store_forward_candidates,store_send_candidates;
  logic [STORE_SLOTS*ST-1:0] store_owners;
  issue_t executing [3];
  logic steer;
  logic load_available;
  logic [LT-1:0] free_load;
  logic [2:0] wb_valid;
  rid_t wb_rid [3];
  wire [2:0] wb_good;
  wire [3*RW-1:0] wb_slots;
  wire [95:0] wb_values;
  for(genvar w=0;w<3;w=w+1) begin: writeback_ports
    assign wb_good[w]=wb_valid[w] && wb_fault[w]==0 && rob[wb_rid[w]].rd!=0;
    assign wb_slots[w*RW+:RW]=wb_rid[w];
    assign wb_values[w*32+:32]=wb_value[w];
  end
  logic [31:0] wb_value [3],wb_address[3];
  logic [3:0] wb_fault [3];
  logic [31:0] alu_result[2],branch_value,branch_next;
  logic branch_taken,branch_bad,branch_fire,branch_capture;
  logic branch_pending,branch_bad_q,branch_taken_q;
  logic [31:0] branch_next_q,branch_pc_q;
  logic [29:0] branch_prediction_q;
  logic [HB-1:0] branch_history_q;
  rid_t branch_rid_q;
  logic branch_generation_q;
  logic [CPW-1:0] branch_checkpoint_q;
  op_t branch_op_q;
  logic [31:0] execute_pc[2],execute_b[2];
  logic mdu_valid,mdu_ready,mdu_mul_ready,mdu_div_ready,mdu_result_valid,mdu_result_ready;
  logic [31:0] mdu_result;
  logic [7:0] mdu_result_tag;
  logic [255:0] mdu_kill;
  logic memory_allowed,memory_complete,store_allocate,load_allocate;
  logic [31:0] memory_address,memory_data,load_word,load_result;
  logic [3:0] memory_mask,memory_fault;
  logic memory_exit,forward_match,forward_full;
  logic [ST-1:0] forward_slot;
  logic store_pop,store_send_valid;
  logic [ST-1:0] store_send_slot;
  logic [ST:0] squashed_stores;
  logic exit_send,exit_accept;
  function automatic rid_t age(input rid_t rid);
    return rid-head;
  endfunction
  function automatic logic younger(input rid_t rid);
    // The circular order needs only the wrap side and the raw slot order.
    // Avoid distributing head through a subtractor for every live entry.
    return redirect && ((rid<head)==(redirect_rid<head) ? rid>redirect_rid:rid<head);
  endfunction
  function automatic logic [31:0] extend_load(input logic [31:0] word_value,
      input logic [1:0] offset,size,input logic sign_extend);
    logic [31:0] shifted;
    begin
      shifted=word_value>>(8*offset);
      case(size)
        0:return {{24{sign_extend && shifted[7]}},shifted[7:0]};
        1:return {{16{sign_extend && shifted[15]}},shifted[15:0]};
        default:return shifted;
      endcase
    end
  endfunction
  assign halted=state==DONE;
  assign faulted=state==FAULT;
  assign load_replay_count=0;
  assign exit_head=state==RUN && rob_count!=0 && retirement_meta[0].done && retirement_meta[0].exiting && retirement_meta[0].fault==0;
  assign fault_head=state==RUN && rob_count!=0 && retirement_meta[0].done && retirement_meta[0].fault!=0;
  // The terminal state publishes the squash after retirement stops.
  assign flush_all=state!=RUN;
  assign stop_frontend=flush_all;
  assign exit_send=state==DRAIN && store_count==0 && cache_idle && frontend_idle && controller_idle;
  assign exit_accept=exit_send && mem_req_ready;
  assign mem_req_valid=state!=DONE && (exit_send || bus_req_valid);
  assign mem_req_write=exit_send || bus_req_write;
  assign mem_req_addr=exit_send ? 32'h80000000:bus_req_addr;
  assign mem_req_wdata=exit_send ? retirement_value[0]:bus_req_data;
  assign mem_req_wstrb=exit_send ? 4'hf:bus_req_mask;
  assign bus_req_ready=mem_req_ready && !exit_send && state!=DONE;
  assign mem_rsp_ready=bus_rsp_ready;
  for(genvar row=0;row<ROB_ENTRIES;row=row+1) begin: result_read_words
    assign retirement_words[row*RETIRE_META_BITS+:RETIRE_META_BITS]=
      {rob[row].done,rob[row].exiting,rob[row].store,rob[row].fault,rob[row].rd,rob[row].store_slot};
    assign result_words[row*32+:32]=values[row];
    assign result_status_words[row*6+:6]={rob[row].valid,rob[row].done,rob[row].fault};
  end
  for(genvar lane=0;lane<2;lane=lane+1) begin: retirement_reads
    assign commit_rid[lane]=head+rid_t'(lane);
    wire [RETIRE_META_BITS-1:0] meta_word;
    assign retirement_meta[lane]=meta_word;
    v2_retire_read #(.ENTRIES(ROB_ENTRIES),.WORD_BITS(RETIRE_META_BITS),.LANE(lane)) read_metadata (
      .clk,.rst,.advance(commit_count),.words(retirement_words),.value(meta_word));
    v2_retire_read #(.ENTRIES(ROB_ENTRIES),.LANE(lane)) read_value (
      .clk,.rst,.advance(commit_count),.words(result_words),.value(retirement_value[lane]));
  end
  for(genvar row=0;row<32;row=row+1) begin: architectural_read_words
    assign architectural_words[row*32+:32]=architectural[row];
  end
  for(genvar port_id=0;port_id<4;port_id=port_id+1) begin: operand_reads
    v2_read #(.ENTRIES(ROB_ENTRIES)) read_result (
      .index(source_slot[port_id*RW+:RW]),.words(result_words),.value(source_result[port_id]));
    v2_read #(.ENTRIES(ROB_ENTRIES),.WORD_BITS(6)) read_status (
      .index(source_slot[port_id*RW+:RW]),.words(result_status_words),.value(source_status[port_id]));
    v2_read #(.ENTRIES(32)) read_architectural (
      .index(source_register[port_id*5+:5]),.words(architectural_words),.value(source_architectural[port_id]));
  end
  v2_frontend #(.CACHE_BYTES(ICACHE_BYTES),.QUEUE_ENTRIES(FETCH_QUEUE_ENTRIES),
    .BHT_ENTRIES(BHT_ENTRIES),.BTB_ENTRIES(BTB_ENTRIES),.LOCAL_HISTORY_BITS(LOCAL_HISTORY_BITS),
    .HISTORY_ENTRIES(HISTORY_ENTRIES),.RAM_BYTES(RAM_BYTES)) frontend (
    .clk,.rst,.stop(stop_frontend),.redirect,.redirect_pc,.pop_count,
    .packet_valid(fetch_valid),.packet_pc(fetch_pc),.packet_inst(fetch_inst),.packet_prediction(fetch_prediction),
    .packet_fault(fetch_fault),.packet_inst_valid(fetch_iv),.packet_history(fetch_history),.train_history(branch_history_q),.train_valid,.train_taken,.train_op,.train_pc,.train_target,
    .mem_req_valid(client_req_valid[0]),.mem_req_ready(client_req_ready[0]),.mem_req_addr(client_req_addr[31:0]),
    .mem_rsp_valid(client_rsp_valid[0]),.mem_rsp_ready(client_rsp_ready[0]),.mem_rsp_data(client_rsp_data[31:0]),
    .mem_rsp_error(client_rsp_error[0]),.idle(frontend_idle),.miss_count(icache_miss_count));
  assign client_req_write[0]=0;assign client_req_data[31:0]=0;assign client_req_mask[3:0]=0;
  v2_dcache #(.CACHE_BYTES(DCACHE_BYTES),.LINE_BYTES(DCACHE_LINE_BYTES),.MSHRS(D_MSHRS),.LOAD_SLOTS(LOAD_SLOTS),.STORE_SLOTS(STORE_SLOTS),
    .CREDITS(MAX_MEM_OUTSTANDING),.RAM_BYTES(RAM_BYTES)) dcache (
    .clk,.rst,.load_valid(cache_load_valid),.load_address(cache_load_address),.load_tag(cache_load_tag),
    .load_ready(cache_load_ready),.load_hit(cache_load_hit),.load_data(cache_load_data),
    .result_valid(cache_result_valid),.result_ready(1'b1),.result_tag(cache_result_tag),
    .result_data(cache_result_data),.result_error(cache_result_error),
    .store_valid(cache_store_valid),.store_ready(cache_store_ready),.store_address(cache_store_address),
    .store_data(cache_store_data),.store_mask(cache_store_mask),.store_tag(cache_store_tag),
    .store_done(cache_store_done),.store_done_tag(cache_store_done_tag),.store_error(cache_store_error),
    .mem_req_valid(client_req_valid[1]),.mem_req_ready(client_req_ready[1]),.mem_req_write(client_req_write[1]),
    .mem_req_addr(client_req_addr[63:32]),.mem_req_data(client_req_data[63:32]),.mem_req_mask(client_req_mask[7:4]),
    .mem_rsp_valid(client_rsp_valid[1]),.mem_rsp_ready(client_rsp_ready[1]),.mem_rsp_data(client_rsp_data[63:32]),
    .mem_rsp_error(client_rsp_error[1]),.idle(cache_idle),.miss_count(dcache_miss_count));
  memory_controller #(.MAX_MEM_OUTSTANDING(MAX_MEM_OUTSTANDING)) memory_bus (
    .clk,.rst,.s_req_valid(client_req_valid),.s_req_ready(client_req_ready),.s_req_write(client_req_write),
    .s_req_addr(client_req_addr),.s_req_wdata(client_req_data),.s_req_wstrb(client_req_mask),
    .s_rsp_valid(client_rsp_valid),.s_rsp_ready(client_rsp_ready),.s_rsp_rdata(client_rsp_data),.s_rsp_error(client_rsp_error),
    .mem_req_valid(bus_req_valid),.mem_req_ready(bus_req_ready),.mem_req_write(bus_req_write),
    .mem_req_addr(bus_req_addr),.mem_req_wdata(bus_req_data),.mem_req_wstrb(bus_req_mask),
    .mem_rsp_valid,.mem_rsp_ready(bus_rsp_ready),.mem_rsp_rdata,.mem_rsp_error,.idle(controller_idle));
  for(genvar d=0;d<2;d=d+1) begin: decode_lanes
    decoder decoder_i(.inst(fetch_inst[d*32+:32]),.dec(decoded[d]));
    assign source_register[(d*2)*5+:5]=decoded[d].rs1;
    assign source_register[(d*2+1)*5+:5]=decoded[d].rs2;
    assign rename_slot[d*RW+:RW]=dispatch_rid[d];
    assign commit_slot[d*RW+:RW]=commit_rid[d];
    assign dispatch_order[d*(RW+1)+:(RW+1)]={tail_generation,tail}+(RW+1)'(d);
  end
  v2_rename #(.SLOT_BITS(RW),.CHECKPOINTS(CHECKPOINTS)) rename_maps (
    .clk,.rst,.dispatch_valid(rename_valid),.prepare_valid(rename_prepare),.dispatch_rd(rename_rd),.dispatch_slot(rename_slot),
    .source_register,.source_pending,.source_slot,.commit_valid,.commit_rd,.commit_slot,
    .save_valid(save_checkpoint),.save_after_lane,.save_index(free_checkpoint),
    .restore_valid(redirect),.restore_index(redirect_checkpoint));
  for(genvar p=0;p<2;p=p+1) begin: integer_units
    assign execute_pc[p]={executing[p].pc,2'b0};
    assign execute_b[p]=executing[p].use_imm ? executing[p].imm:executing[p].b;
    alu alu_i(.op(executing[p].op),.a(executing[p].a),.b(execute_b[p]),
      .pc(execute_pc[p]),.imm(executing[p].imm),.result(alu_result[p]));
  end
  branch_unit branch_i(.op(executing[0].op),.a(executing[0].a),.b(executing[0].b),
    .pc(execute_pc[0]),.imm(executing[0].imm),.result(branch_value),.next_pc(branch_next),
    .taken(branch_taken),.misaligned(branch_bad));
  muldiv mdu(.clk,.rst,.kill(flush_all),.kill_mask(mdu_kill),.req_valid(mdu_valid),.req_ready(mdu_ready),
    .mul_ready(mdu_mul_ready),.div_ready(mdu_div_ready),.req_op(executing[0].op),
    .req_a(executing[0].a),.req_b(executing[0].b),.req_tag(8'(executing[0].rid)),
    .rsp_valid(mdu_result_valid),.rsp_ready(mdu_result_ready),.rsp_result(mdu_result),.rsp_tag(mdu_result_tag));
  for(genvar bank=0;bank<3;bank=bank+1) begin: balanced_selection
    wire [IQ_ENTRIES*ISSUE_BITS-1:0] payloads;
    wire [ISSUE_BITS-1:0] selected_payload;
    for(genvar q=0;q<IQ_ENTRIES;q=q+1) begin: candidate
      assign select_ready[bank][q]=queue[bank][q].valid && (bank==2 || (queue[bank][q].ready_a && queue[bank][q].ready_b));
      assign select_owner[bank][q*(RW+1)+:(RW+1)]={queue[bank][q].generation,queue[bank][q].rid};
      assign payloads[q*ISSUE_BITS+:ISSUE_BITS]=queue[bank][q];
    end
    v2_select #(.ENTRIES(IQ_ENTRIES),.SLOT_BITS(RW+1),.EXTENDED_ORDER(1)) choose (
      .ready(select_ready[bank]),.owner(select_owner[bank]),.rob_head({(RW+1){1'b0}}),.valid(selected_valid[bank]),.index(selected[bank]));
    for(genvar first=0;first<ISSUE_BITS;first=first+32) begin: read_payload
      wire [IQ_ENTRIES*(ISSUE_BITS-first<32 ? ISSUE_BITS-first:32)-1:0] slice_words;
      for(genvar row=0;row<IQ_ENTRIES;row=row+1) begin: slice_row
        assign slice_words[row*(ISSUE_BITS-first<32 ? ISSUE_BITS-first:32)+:(ISSUE_BITS-first<32 ? ISSUE_BITS-first:32)]=
          payloads[row*ISSUE_BITS+first+:(ISSUE_BITS-first<32 ? ISSUE_BITS-first:32)];
      end
      v2_iq_read #(.ENTRIES(IQ_ENTRIES),.WORD_BITS(ISSUE_BITS-first<32 ? ISSUE_BITS-first:32)) read_slice (
        .index(selected[bank]),.words(slice_words),.value(selected_payload[first+:(ISSUE_BITS-first<32 ? ISSUE_BITS-first:32)]));
    end
    assign executing[bank]=selected_payload;
    assign select_valid[bank]=selected_valid[bank] && (bank!=2 || (executing[bank].ready_a && executing[bank].ready_b));
  end
  for(genvar s=0;s<STORE_SLOTS;s=s+1) begin: store_candidates
    assign store_owners[s*ST+:ST]=ST'(s);
    assign store_forward_candidates[s]=stores[s].valid && stores[s].address[31:2]==memory_address[31:2] &&
                                       (|(stores[s].mask & memory_mask));
    assign store_send_candidates[s]=stores[s].valid && stores[s].committed && !stores[s].issued;
  end
  v2_select #(.ENTRIES(STORE_SLOTS),.SLOT_BITS(ST),.YOUNGEST(1)) choose_forward (
    .ready(store_forward_candidates),.owner(store_owners),.rob_head(store_head),.valid(forward_match),.index(forward_slot));
  v2_select #(.ENTRIES(STORE_SLOTS),.SLOT_BITS(ST)) choose_store (
    .ready(store_send_candidates),.owner(store_owners),.rob_head(store_head),.valid(store_send_valid),.index(store_send_slot));
  always_comb begin: select_instructions
    free_queue_valid=0;
    for(integer bank=0;bank<3;bank=bank+1) begin
      free_queue[bank]=0;occupancy[bank]=0;
      for(integer q=0;q<IQ_ENTRIES;q=q+1) begin
        if(queue[bank][q].valid) begin
          occupancy[bank]=occupancy[bank]+1'b1;
        end else if(!free_queue_valid[bank]) begin free_queue_valid[bank]=1;free_queue[bank]=QW'(q);end
      end
    end
    checkpoint_available=0;free_checkpoint=0;
    for(integer c=0;c<CHECKPOINTS;c=c+1)
      if(!checkpoint_valid[c] && !checkpoint_available) begin checkpoint_available=1;free_checkpoint=CPW'(c);end
    load_available=0;free_load=0;
    for(integer l=0;l<LOAD_SLOTS;l=l+1)
      if(!loads[l].valid && !load_available) begin load_available=1;free_load=LT'(l);end
    mdu_kill='1;
    for(integer r=0;r<ROB_ENTRIES;r=r+1) mdu_kill[r]=!rob[r].valid;
  end
  // Execute branches immediately, but publish prediction recovery from a
  // register. A resolving branch cannot retire before this recovery cycle.
  assign branch_capture=select_valid[0] && is_branch(executing[0].op) &&
                        !flush_all && !mdu_result_valid && !younger(executing[0].rid);
  always_ff @(posedge clk) begin
    if(rst) branch_pending<=0;
    else branch_pending<=branch_capture;
    branch_bad_q<=branch_bad;branch_taken_q<=branch_taken;
    branch_next_q<=branch_next;branch_pc_q<=execute_pc[0];
    branch_prediction_q<=executing[0].prediction;
    branch_history_q<=executing[0].history;
    branch_rid_q<=executing[0].rid;branch_checkpoint_q<=executing[0].checkpoint;
    branch_generation_q<=executing[0].generation;
    branch_op_q<=executing[0].op;
  end
  assign branch_fire=branch_pending && !flush_all;
  assign redirect=branch_fire && !branch_bad_q && branch_next_q!={branch_prediction_q,2'b0};
  assign redirect_pc=branch_next_q;
  assign redirect_rid=branch_rid_q;
  assign redirect_checkpoint=branch_checkpoint_q;
  assign train_valid=branch_fire && !branch_bad_q;
  assign train_op=branch_op_q;
  assign train_taken=branch_taken_q;
  assign train_pc=branch_pc_q;
  assign train_target=branch_next_q;
  assign mdu_valid=select_valid[0] && is_mdu(executing[0].op) && !flush_all &&
                   !mdu_result_valid && !younger(executing[0].rid);
  assign mdu_result_ready=!flush_all;
  assign memory_address=executing[2].a+executing[2].imm;
  assign memory_data=executing[2].b<<(8*memory_address[1:0]);
  assign memory_mask=(executing[2].size==0 ? 4'b0001:executing[2].size==1 ? 4'b0011:4'b1111)<<memory_address[1:0];
  assign memory_exit=executing[2].op==OP_STORE && memory_address==32'h80000000 && executing[2].size==2;
  always_comb begin: memory_ordering
    memory_fault=0;
    if((executing[2].size==1 && memory_address[0]) || (executing[2].size==2 && memory_address[1:0]!=0))
      memory_fault=executing[2].op==OP_LOAD ? FAULT_LOAD_ALIGN:FAULT_STORE_ALIGN;
    else if(memory_address>=RAM_BYTES && !memory_exit)
      memory_fault=executing[2].op==OP_LOAD ? FAULT_LOAD_RANGE:FAULT_STORE_RANGE;
    forward_full=0;squashed_stores=0;
    for(integer s=0;s<STORE_SLOTS;s=s+1) begin
      if(stores[s].valid && !stores[s].committed && (younger(stores[s].rid) || flush_all))
        squashed_stores=squashed_stores+1'b1;
    end
    if(forward_match) forward_full=(stores[forward_slot].mask & memory_mask)==memory_mask;
  end
  assign cache_store_valid=store_send_valid && state!=DONE && state!=FAULT;
  assign cache_store_tag=store_send_slot;
  assign cache_store_address={stores[store_send_slot].address[31:2],2'b0};
  assign cache_store_data=stores[store_send_slot].data;
  assign cache_store_mask=stores[store_send_slot].mask;
  assign store_pop=store_count!=0 && stores[store_head].done;
  assign memory_allowed=select_valid[2] && !flush_all && !younger(executing[2].rid) && !cache_result_valid;
  assign cache_load_valid=memory_allowed && executing[2].op==OP_LOAD && memory_fault==0 &&
                         !forward_match && load_available;
  assign cache_load_address={memory_address[31:2],2'b0};
  assign cache_load_tag=free_load;
  assign load_word=forward_full ? stores[forward_slot].data:cache_load_data;
  assign load_result=extend_load(load_word,memory_address[1:0],executing[2].size,executing[2].sign_extend);
  assign load_allocate=cache_load_valid && cache_load_ready && !cache_load_hit;
  assign store_allocate=memory_allowed && executing[2].op==OP_STORE && memory_fault==0 && !memory_exit && int'(store_count)<STORE_SLOTS;
  assign memory_complete=memory_allowed && (memory_fault!=0 || memory_exit || store_allocate ||
                          (executing[2].op==OP_LOAD && (forward_full || (cache_load_valid && cache_load_ready && cache_load_hit))));
  always_comb begin: completion
    wb_valid=0;issue_fire=0;
    for(integer w=0;w<3;w=w+1) begin wb_rid[w]=executing[w].rid;wb_value[w]=0;wb_fault[w]=0;wb_address[w]=0;end
    if(!flush_all) begin
      if(mdu_result_valid) begin
        wb_valid[0]=rob[rid_t'(mdu_result_tag)].valid && !younger(rid_t'(mdu_result_tag));
        wb_rid[0]=rid_t'(mdu_result_tag);wb_value[0]=mdu_result;
      end else if(select_valid[0] && !younger(executing[0].rid)) begin
        if(is_mdu(executing[0].op)) issue_fire[0]=mdu_ready;
        else begin
          issue_fire[0]=1;wb_valid[0]=1;
          wb_value[0]=is_branch(executing[0].op) ? branch_value:alu_result[0];
          if(is_branch(executing[0].op) && branch_bad) begin wb_fault[0]=FAULT_TARGET_ALIGN;wb_address[0]=branch_next;end
        end
      end
      if(INTEGER_PORTS==2 && select_valid[1] && !younger(executing[1].rid)) begin
        issue_fire[1]=1;wb_valid[1]=1;wb_value[1]=alu_result[1];
      end
      if(cache_result_valid) begin
        wb_rid[2]=loads[cache_result_tag].rid;
        wb_valid[2]=loads[cache_result_tag].valid && !loads[cache_result_tag].canceled &&
                    rob[loads[cache_result_tag].rid].valid && !younger(loads[cache_result_tag].rid);
        wb_value[2]=extend_load(cache_result_data,loads[cache_result_tag].address[1:0],
          loads[cache_result_tag].size,loads[cache_result_tag].sign_extend);
        wb_fault[2]=cache_result_error ? FAULT_LOAD_BUS:FAULT_NONE;
        wb_address[2]=loads[cache_result_tag].address;
      end else begin
        issue_fire[2]=memory_complete || load_allocate;
        wb_valid[2]=memory_complete;
        wb_value[2]=executing[2].op==OP_LOAD ? load_result:executing[2].b;
        wb_fault[2]=memory_fault;wb_address[2]=memory_address;
      end
    end
  end
  always_comb begin: retirement
    logic blocked_retirement,committed_store;
    blocked_retirement=0;committed_store=0;commit_count=0;commit_valid=0;commit_rd=0;
    for(integer lane=0;lane<2;lane=lane+1) begin
      if(lane<COMMIT_WIDTH && !blocked_retirement && state==RUN && int'(rob_count)>lane &&
         retirement_meta[lane].done && retirement_meta[lane].fault==0 && !retirement_meta[lane].exiting &&
         // The head is oldest. Its successor crosses the recovery boundary
         // only when the resolving branch is itself at the head.
         (lane==0 || !redirect || redirect_rid!=head) &&
         (!committed_store || !retirement_meta[lane].store)) begin
        commit_count=commit_count+1'b1;
        commit_valid[lane]=retirement_meta[lane].rd!=0;
        commit_rd[lane*5+:5]=retirement_meta[lane].rd;
        if(retirement_meta[lane].store) committed_store=1;
      end else blocked_retirement=1;
    end
  end
  always_comb begin: dispatch_control
    logic blocked_dispatch;
    integer bank_choice;
    // Work out the dispatch prefix without recovery gating. Only valid bits
    // publish it; free destination rows can prepare their payload in parallel.
    blocked_dispatch=0;
    dispatch_prepare=0;dispatch_valid=0;dispatch_count=0;rename_prepare=0;rename_valid=0;rename_rd=0;used_bank=0;
    save_checkpoint=0;save_after_lane=0;
    for(integer lane=0;lane<2;lane=lane+1) begin
      dispatch_rid[lane]=tail+rid_t'(lane);dispatch_bank[lane]=0;dispatch_index[lane]=0;bank_choice=0;
      if(lane<RENAME_WIDTH && !blocked_dispatch && fetch_valid[lane] && int'(rob_count)+lane<ROB_ENTRIES) begin
        if(decoded[lane].op==OP_LOAD || decoded[lane].op==OP_STORE) bank_choice=2;
        else if(is_branch(decoded[lane].op) || is_mdu(decoded[lane].op) || INTEGER_PORTS==1) bank_choice=0;
        else if(used_bank[0] || !free_queue_valid[0]) bank_choice=1;
        else if(used_bank[1] || !free_queue_valid[1]) bank_choice=0;
        else bank_choice=(occupancy[1]<occupancy[0] || (occupancy[1]==occupancy[0] && steer)) ? 1:0;
        if(fetch_fault[lane*4+:4]!=0 || decoded[lane].illegal) begin
          dispatch_prepare[lane]=1;dispatch_count=dispatch_count+1'b1;
          dispatch_bank[lane]=3;
        end else if(!used_bank[bank_choice] && free_queue_valid[bank_choice] &&
                    (!is_branch(decoded[lane].op) || (checkpoint_available && !save_checkpoint))) begin
          dispatch_prepare[lane]=1;dispatch_count=dispatch_count+1'b1;
          dispatch_bank[lane]=2'(bank_choice);dispatch_index[lane]=free_queue[bank_choice];used_bank[bank_choice]=1;
          rename_prepare[lane]=decoded[lane].writes_rd;rename_rd[lane*5+:5]=decoded[lane].writes_rd ? decoded[lane].rd:5'd0;
          if(is_branch(decoded[lane].op)) begin save_checkpoint=1;save_after_lane=1'(lane);end
        end else blocked_dispatch=1;
      end else blocked_dispatch=1;
    end
    dispatch_valid=dispatch_prepare & {2{!flush_all && !redirect}};
    rename_valid=rename_prepare & {2{!flush_all && !redirect}};
    if(flush_all || redirect) begin dispatch_count=0;save_checkpoint=0;end
    pop_count=dispatch_count;
  end
  always_comb begin: capture_sources
    rid_t source_id;
    logic [4:0] register_id;
    logic pending,ready_value;
    logic [31:0] source_value;
    source_id=0;register_id=0;pending=0;ready_value=0;source_value=0;
    for(integer lane=0;lane<2;lane=lane+1) begin
      dispatch_payload[lane]='0;dispatch_payload[lane].valid=1;dispatch_payload[lane].rid=dispatch_rid[lane];
      dispatch_payload[lane].generation=dispatch_order[lane*(RW+1)+RW];
      dispatch_payload[lane].op=decoded[lane].op;dispatch_payload[lane].imm=decoded[lane].imm;
      dispatch_payload[lane].pc=fetch_pc[lane*32+2+:30];
      dispatch_payload[lane].history=fetch_history[lane*HB+:HB];
      dispatch_payload[lane].prediction=fetch_prediction[lane*32+2+:30];
      dispatch_payload[lane].size=decoded[lane].mem_size;dispatch_payload[lane].sign_extend=decoded[lane].load_signed;
      dispatch_payload[lane].use_imm=decoded[lane].use_imm;dispatch_payload[lane].checkpoint=free_checkpoint;
      for(integer source_number=0;source_number<2;source_number=source_number+1) begin
        register_id=source_register[(lane*2+source_number)*5+:5];
        source_id=source_slot[(lane*2+source_number)*RW+:RW];
        pending=source_pending[lane*2+source_number] && register_id!=0 &&
                (source_number==0 ? decoded[lane].uses_rs1:decoded[lane].uses_rs2);
        ready_value=!pending || (source_status[lane*2+source_number][5:4]==2'b11 &&
                                source_status[lane*2+source_number][3:0]==0);
        source_value=pending ? source_result[lane*2+source_number]:
                     (register_id==0 ? 32'd0:source_architectural[lane*2+source_number]);
        for(integer w=0;w<3;w=w+1)
          if(pending && wb_valid[w] && wb_rid[w]==source_id && wb_fault[w]==0) begin ready_value=1;source_value=wb_value[w];end
        // A fresh intra-bundle writer has no value even if its old physical
        // row still contains a completed result from an earlier wrap.
        if(lane==1 && rename_prepare[0] && source_id==dispatch_rid[0] && pending) ready_value=0;
        if(source_number==0) begin
          dispatch_payload[lane].a=source_value;dispatch_payload[lane].ready_a=ready_value;
          dispatch_payload[lane].source_a=source_id;
        end else begin
          dispatch_payload[lane].b=source_value;dispatch_payload[lane].ready_b=ready_value;
          dispatch_payload[lane].source_b=source_id;
        end
      end
    end
  end
  always_ff @(posedge clk) begin: control_state
    if(rst) begin
      state<=RUN;head<=0;tail<=0;tail_generation<=0;rob_count<=0;store_head<=0;store_tail<=0;store_count<=0;steer<=0;
      fault_pc<=0;fault_inst<=0;fault_inst_valid<=0;fault_cause<=0;fault_addr<=0;
      cycle_count<=0;retired_count<=0;branch_miss_count<=0;
      retire_valid<=0;retire_pc<=0;retire_inst<=0;retire_rd<=0;retire_value<=0;
      retire_store<=0;retire_addr<=0;retire_wdata<=0;retire_wstrb<=0;
    end else begin
      retire_valid<=0;retire_store<=0;
      if(state!=DONE && state!=FAULT) cycle_count<=cycle_count+1;
      head<=head+rid_t'(commit_count);
      if(redirect) begin tail<=redirect_rid+1'b1;rob_count<=(RW+1)'(age(redirect_rid))+1-(RW+1)'(commit_count);end
      else begin tail<=tail+rid_t'(dispatch_count);rob_count<=rob_count+(RW+1)'(dispatch_count)-(RW+1)'(commit_count);end
      if(redirect) tail_generation<=branch_generation_q ^ (&redirect_rid);
      else tail_generation<=allocation_end[RW];
      store_count<=store_count+(ST+1)'(store_allocate)-(ST+1)'(store_pop)-squashed_stores;
      store_head<=store_head+ST'(store_pop);store_tail<=store_tail+ST'(store_allocate)-ST'(squashed_stores);
      if(dispatch_count!=0) steer<=!steer;
      if(redirect) branch_miss_count<=branch_miss_count+1;
      retired_count<=retired_count+64'(commit_count)+64'(exit_accept);
      for(integer lane=0;lane<2;lane=lane+1)
        if(int'(commit_count)>lane) begin
          retire_valid[lane]<=1;retire_pc[lane*32+:32]<=rob[commit_rid[lane]].pc;
          retire_inst[lane*32+:32]<=rob[commit_rid[lane]].inst;retire_rd[lane*5+:5]<=retirement_meta[lane].rd;
          retire_value[lane*32+:32]<=retirement_meta[lane].rd==0 ? 32'd0:retirement_value[lane];
          retire_store[lane]<=retirement_meta[lane].store;
          retire_addr[lane*32+:32]<=rob[commit_rid[lane]].address;
          retire_wdata[lane*32+:32]<=rob[commit_rid[lane]].wdata;
          retire_wstrb[lane*4+:4]<=rob[commit_rid[lane]].mask;
        end
      if(exit_head) state<=DRAIN;
      if(exit_accept) begin
        state<=DONE;retire_valid<=1;retire_store<=1;retire_pc[31:0]<=rob[head].pc;retire_inst[31:0]<=rob[head].inst;
        retire_rd[4:0]<=0;retire_value[31:0]<=0;retire_addr[31:0]<=32'h80000000;
        retire_wdata[31:0]<=retirement_value[0];retire_wstrb[3:0]<=15;
      end
      if(fault_head) begin
        state<=FAULT;fault_pc<=rob[head].pc;fault_inst<=rob[head].inst;fault_inst_valid<=rob[head].iv;
        fault_cause<=retirement_meta[0].fault;fault_addr<=rob[head].fault_address;
      end
      if(cache_store_error) begin
        state<=FAULT;fault_cause<=FAULT_STORE_BUS;fault_pc<=stores[cache_store_done_tag].pc;
        fault_inst<=stores[cache_store_done_tag].inst;fault_inst_valid<=1;fault_addr<=stores[cache_store_done_tag].address;
      end
    end
  end
  for(genvar r=0;r<ROB_ENTRIES;r=r+1) begin: rob_rows
    always_ff @(posedge clk) begin
      if(rst) begin rob[r].valid<=0;rob[r].done<=0;end
      else begin
        for(integer lane=0;lane<2;lane=lane+1)
          if(int'(commit_count)>lane && commit_rid[lane]==rid_t'(r)) rob[r].valid<=0;
        for(integer w=0;w<3;w=w+1)
          if(wb_valid[w] && wb_rid[w]==rid_t'(r)) begin
            rob[r].done<=1;rob[r].fault<=wb_fault[w];rob[r].fault_address<=wb_address[w];values[r]<=wb_value[w];
          end
        if(memory_complete && executing[2].rid==rid_t'(r) && executing[2].op==OP_STORE) begin
          rob[r].address<=memory_address;rob[r].wdata<=memory_data;rob[r].mask<=memory_mask;
          rob[r].exiting<=memory_exit;rob[r].store_slot<=store_tail;
        end
        if(younger(rid_t'(r)) || (flush_all && rid_t'(r)!=head)) rob[r].valid<=0;
        for(integer lane=0;lane<2;lane=lane+1)
          if(dispatch_valid[lane] && dispatch_rid[lane]==rid_t'(r)) begin
            rob[r].valid<=1;rob[r].done<=dispatch_bank[lane]==3;rob[r].exiting<=0;
            rob[r].fault<=fetch_fault[lane*4+:4]!=0 ? fetch_fault[lane*4+:4]:decoded[lane].illegal ? FAULT_ILLEGAL:FAULT_NONE;
            rob[r].fault_address<=fetch_pc[lane*32+:32];rob[r].address<=0;rob[r].wdata<=0;rob[r].mask<=0;
          end
      end
    end
    // A live (including retiring) ROB row is never prepared. The allocator
    // excludes same-edge reuse, so these writes also supply an accepted lane.
    always_ff @(posedge clk) begin
      if(!rst && !rob[r].valid)
        for(integer lane=0;lane<2;lane=lane+1)
          if(dispatch_rid[lane]==rid_t'(r)) begin
            rob[r].pc<=fetch_pc[lane*32+:32];rob[r].inst<=fetch_inst[lane*32+:32];rob[r].iv<=fetch_iv[lane];
            rob[r].rd<=rename_rd[lane*5+:5];rob[r].store<=decoded[lane].op==OP_STORE;
          end
    end
  end
  for(genvar r=0;r<32;r=r+1) begin: architectural_registers
    wire [31:0] register_value;
    assign architectural[r]=register_value;
    v2_arch_word #(.REGISTER(r)) word_register (
      .clk,.rst,.commit_valid,.commit_rd,
      .commit_values({retirement_value[1],retirement_value[0]}),.value(register_value));
  end
  for(genvar bank=0;bank<3;bank=bank+1) begin: issue_banks
    for(genvar q=0;q<IQ_ENTRIES;q=q+1) begin: rows
      wire [1:0] prepare_lane;
      wire next_ready_a,next_ready_b;
      wire [31:0] next_value_a,next_value_b;
      for(genvar lane=0;lane<2;lane=lane+1) begin: preparation
        assign prepare_lane[lane]=dispatch_prepare[lane] && dispatch_bank[lane]==2'(bank) && dispatch_index[lane]==QW'(q);
      end
      v2_operand #(.SLOT_BITS(RW)) operand_a (
        .live(queue[bank][q].valid),.prepare(|prepare_lane),
        .old_ready(queue[bank][q].ready_a),.old_value(queue[bank][q].a),.source(queue[bank][q].source_a),
        .initial_ready(prepare_lane[1] ? dispatch_payload[1].ready_a:dispatch_payload[0].ready_a),
        .initial_value(prepare_lane[1] ? dispatch_payload[1].a:dispatch_payload[0].a),
        .wb_good,.wb_slots,.wb_values,.next_ready(next_ready_a),.next_value(next_value_a));
      v2_operand #(.SLOT_BITS(RW)) operand_b (
        .live(queue[bank][q].valid),.prepare(|prepare_lane),
        .old_ready(queue[bank][q].ready_b),.old_value(queue[bank][q].b),.source(queue[bank][q].source_b),
        .initial_ready(prepare_lane[1] ? dispatch_payload[1].ready_b:dispatch_payload[0].ready_b),
        .initial_value(prepare_lane[1] ? dispatch_payload[1].b:dispatch_payload[0].b),
        .wb_good,.wb_slots,.wb_values,.next_ready(next_ready_b),.next_value(next_value_b));
      always_ff @(posedge clk) begin
        queue[bank][q].ready_a<=next_ready_a;queue[bank][q].a<=next_value_a;
        queue[bank][q].ready_b<=next_ready_b;queue[bank][q].b<=next_value_b;
      end
      always_ff @(posedge clk) begin
        if(rst) queue[bank][q].valid<=0;
        else begin
          if((issue_fire[bank] && selected[bank]==QW'(q)) || younger(queue[bank][q].rid) || flush_all) queue[bank][q].valid<=0;
          for(integer lane=0;lane<2;lane=lane+1)
            if(dispatch_valid[lane] && dispatch_bank[lane]==2'(bank) && dispatch_index[lane]==QW'(q))
              queue[bank][q].valid<=1;
        end
      end
      always_ff @(posedge clk) begin
        // Free rows may retain arbitrary speculative data. Preparation cannot
        // overwrite a live row, and each bank accepts at most one lane.
        if(!queue[bank][q].valid) begin
          for(integer lane=0;lane<2;lane=lane+1)
            if(dispatch_prepare[lane] && dispatch_bank[lane]==2'(bank) && dispatch_index[lane]==QW'(q)) begin
              queue[bank][q].rid<=dispatch_payload[lane].rid;queue[bank][q].op<=dispatch_payload[lane].op;
              queue[bank][q].generation<=dispatch_payload[lane].generation;
              queue[bank][q].source_a<=dispatch_payload[lane].source_a;queue[bank][q].source_b<=dispatch_payload[lane].source_b;
              queue[bank][q].pc<=dispatch_payload[lane].pc;queue[bank][q].prediction<=dispatch_payload[lane].prediction;
              queue[bank][q].history<=dispatch_payload[lane].history;queue[bank][q].checkpoint<=dispatch_payload[lane].checkpoint;
              queue[bank][q].size<=dispatch_payload[lane].size;queue[bank][q].sign_extend<=dispatch_payload[lane].sign_extend;
              queue[bank][q].use_imm<=dispatch_payload[lane].use_imm;
              queue[bank][q].imm<=dispatch_payload[lane].imm;
            end
        end
      end
    end
  end
  for(genvar cp=0;cp<CHECKPOINTS;cp=cp+1) begin: checkpoint_rows
    always_ff @(posedge clk) begin
      if(rst) begin checkpoint_valid[cp]<=0;checkpoint_owner[cp]<=0;end
      else begin
        if((branch_fire && branch_checkpoint_q==CPW'(cp)) || younger(checkpoint_owner[cp]) || flush_all)
          checkpoint_valid[cp]<=0;
        if(save_checkpoint && free_checkpoint==CPW'(cp)) begin
          checkpoint_valid[cp]<=1;checkpoint_owner[cp]<=dispatch_rid[save_after_lane];
        end
      end
    end
  end
  for(genvar s=0;s<STORE_SLOTS;s=s+1) begin: store_rows
    always_ff @(posedge clk) begin
      if(rst) stores[s].valid<=0;
      else begin
        if(store_pop && store_head==ST'(s)) stores[s].valid<=0;
        if(cache_store_valid && cache_store_ready && store_send_slot==ST'(s)) stores[s].issued<=1;
        if(cache_store_done && cache_store_done_tag==ST'(s)) stores[s].done<=1;
        for(integer lane=0;lane<2;lane=lane+1)
          if(int'(commit_count)>lane && retirement_meta[lane].store && retirement_meta[lane].store_slot==ST'(s)) stores[s].committed<=1;
        if(!stores[s].committed && (younger(stores[s].rid) || flush_all)) stores[s].valid<=0;
        if(store_allocate && store_tail==ST'(s)) begin
          stores[s].valid<=1;stores[s].committed<=0;stores[s].issued<=0;stores[s].done<=0;
          stores[s].rid<=executing[2].rid;stores[s].address<=memory_address;stores[s].data<=memory_data;stores[s].mask<=memory_mask;
          stores[s].pc<=rob[executing[2].rid].pc;stores[s].inst<=rob[executing[2].rid].inst;
        end
      end
    end
  end
  for(genvar l=0;l<LOAD_SLOTS;l=l+1) begin: load_rows
    always_ff @(posedge clk) begin
      if(rst) loads[l].valid<=0;
      else begin
        if(cache_result_valid && cache_result_tag==LT'(l)) loads[l].valid<=0;
        if(younger(loads[l].rid) || flush_all) loads[l].canceled<=1;
        if(load_allocate && free_load==LT'(l)) begin
          loads[l].valid<=1;loads[l].canceled<=0;loads[l].rid<=executing[2].rid;
          loads[l].address<=memory_address;loads[l].size<=executing[2].size;loads[l].sign_extend<=executing[2].sign_extend;
        end
      end
    end
  end
`ifndef SYNTHESIS
`ifdef V2_VERIFY
  longint unsigned coverage_redirect,coverage_dual_commit,coverage_load_cancel,coverage_canceled_response;
  longint unsigned coverage_canceled_error,coverage_live_tag_reuse,coverage_forward,coverage_partial_wait,coverage_multi_load;
  longint unsigned coverage_mdu_cancel,coverage_victim_store_collision;
  logic [ROB_ENTRIES-1:0] monitored_mdu;
  always_ff @(posedge clk) begin: verify_state
    integer live_count,active_loads;
    rid_t expected_tag;
    logic expected_pending;
    if(rst) begin
      coverage_redirect<=0;coverage_dual_commit<=0;coverage_load_cancel<=0;coverage_canceled_response<=0;
      coverage_canceled_error<=0;coverage_live_tag_reuse<=0;coverage_forward<=0;coverage_partial_wait<=0;
      coverage_multi_load<=0;coverage_mdu_cancel<=0;coverage_victim_store_collision<=0;monitored_mdu<=0;
    end else begin
      live_count=0;active_loads=0;expected_tag=0;expected_pending=0;
      if(redirect) coverage_redirect<=coverage_redirect+1;
      if(commit_count==2) coverage_dual_commit<=coverage_dual_commit+1;
      if(memory_complete && executing[2].op==OP_LOAD && forward_full) coverage_forward<=coverage_forward+1;
      if(memory_allowed && executing[2].op==OP_LOAD && forward_match && !forward_full) coverage_partial_wait<=coverage_partial_wait+1;
      if(dcache.allocate && dcache.store_tag_hit && dcache.selected_line==dcache.store_line && cache_store_valid)
        coverage_victim_store_collision<=coverage_victim_store_collision+1;
      for(integer l=0;l<LOAD_SLOTS;l=l+1) begin
        if(loads[l].valid) active_loads=active_loads+1;
        if(loads[l].valid && !loads[l].canceled && younger(loads[l].rid)) coverage_load_cancel<=coverage_load_cancel+1;
        for(integer d=0;d<2;d=d+1)
          if(dispatch_valid[d] && loads[l].valid && loads[l].canceled && loads[l].rid==dispatch_rid[d])
            coverage_live_tag_reuse<=coverage_live_tag_reuse+1;
      end
      if(active_loads>1) coverage_multi_load<=coverage_multi_load+1;
      if(cache_result_valid && loads[cache_result_tag].canceled) begin
        coverage_canceled_response<=coverage_canceled_response+1;
        if(cache_result_error) coverage_canceled_error<=coverage_canceled_error+1;
      end
      for(integer r=0;r<ROB_ENTRIES;r=r+1) begin
        if(rob[r].valid) live_count=live_count+1;
        if(monitored_mdu[r] && (younger(rid_t'(r)) || flush_all)) begin
          coverage_mdu_cancel<=coverage_mdu_cancel+1;monitored_mdu[r]<=0;
        end
        if(mdu_result_valid && mdu_result_ready && rid_t'(mdu_result_tag)==rid_t'(r)) monitored_mdu[r]<=0;
        if(mdu_valid && mdu_ready && executing[0].rid==rid_t'(r)) monitored_mdu[r]<=1;
      end
      if(state==RUN) begin
        assert(live_count==int'(rob_count)) else $fatal(1,"ROB live/count mismatch");
        for(integer a=1;a<32;a=a+1) begin
          expected_pending=0;expected_tag=0;
          for(integer r=0;r<ROB_ENTRIES;r=r+1)
            if(rob[r].valid && rob[r].rd==5'(a) && (!expected_pending || age(rid_t'(r))>age(expected_tag))) begin
              expected_pending=1;expected_tag=rid_t'(r);
            end
          assert(rename_maps.pending_q[a]==expected_pending) else $fatal(1,"RAT presence mismatch x%0d",a);
          if(expected_pending) assert(rename_maps.tag_q[a]==expected_tag) else $fatal(1,"RAT youngest-writer mismatch x%0d",a);
        end
      end
      for(integer a=0;a<3;a=a+1)
        for(integer b=a+1;b<3;b=b+1)
          assert(!(wb_valid[a] && wb_valid[b] && wb_rid[a]==wb_rid[b])) else $fatal(1,"duplicate result owner");
    end
  end
  final $display("V2_COVERAGE redirects=%0d dual_commit=%0d load_cancel=%0d canceled_response=%0d canceled_error=%0d live_tag_reuse=%0d forward=%0d partial_wait=%0d multi_load=%0d mdu_cancel=%0d victim_store_collision=%0d",
    coverage_redirect,coverage_dual_commit,coverage_load_cancel,coverage_canceled_response,coverage_canceled_error,
    coverage_live_tag_reuse,coverage_forward,coverage_partial_wait,coverage_multi_load,coverage_mdu_cancel,coverage_victim_store_collision);
`endif
  always_ff @(posedge clk) if(!rst) begin
    assert(int'(rob_count)<=ROB_ENTRIES) else $fatal(1,"ROB overflow");
    assert(int'(store_count)<=STORE_SLOTS) else $fatal(1,"store queue overflow");
    if(cache_result_valid) assert(loads[cache_result_tag].valid) else $fatal(1,"unowned cache response");
    if(store_allocate) assert(!stores[store_tail].valid) else $fatal(1,"store slot reused early");
    for(integer d=0;d<2;d=d+1)
      if(dispatch_valid[d]) assert(!rob[dispatch_rid[d]].valid) else $fatal(1,"ROB reused early");
  end
`endif
  initial begin
    if(ROB_ENTRIES<8 || ROB_ENTRIES>128 || (ROB_ENTRIES&(ROB_ENTRIES-1))!=0 ||
       IQ_ENTRIES<2 || (IQ_ENTRIES&(IQ_ENTRIES-1))!=0 || CHECKPOINTS<2 ||
       (CHECKPOINTS&(CHECKPOINTS-1))!=0 || RENAME_WIDTH<1 || RENAME_WIDTH>2 ||
       COMMIT_WIDTH<1 || COMMIT_WIDTH>2 || INTEGER_PORTS<1 || INTEGER_PORTS>2 ||
       LOAD_SLOTS<2 || (LOAD_SLOTS&(LOAD_SLOTS-1))!=0 || STORE_SLOTS<2 ||
       (STORE_SLOTS&(STORE_SLOTS-1))!=0 || RAM_BYTES<4096 || (RAM_BYTES&(RAM_BYTES-1))!=0)
      $fatal(1,"invalid Area-v2 dimensions");
  end
endmodule
