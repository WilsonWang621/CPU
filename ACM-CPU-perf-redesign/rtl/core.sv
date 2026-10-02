// Four-lane out-of-order core. Execution results bypass into selection;
// surviving ROB writers restore rename state in one edge. Memory ordering is
// speculative, with byte forwarding and oldest-conflicting-load replay.
module core #(
  parameter integer FETCH_WIDTH=4, RENAME_WIDTH=4, ISSUE_WIDTH=4, WB_WIDTH=4,
  COMMIT_WIDTH=4, PHYS_REGS=128, ROB_ENTRIES=64, IQ_ENTRIES=32,
  LQ_ENTRIES=32, SQ_ENTRIES=32, CSB_ENTRIES=32, FETCH_QUEUE_ENTRIES=32,
  ICACHE_BYTES=4096, ICACHE_WAYS=2, DCACHE_BYTES=16384, DCACHE_WAYS=4,
  LINE_BYTES=32, I_MSHRS=4, D_MSHRS=8, BHT_ENTRIES=2048, BTB_ENTRIES=256,
  RAS_DEPTH=16, RAM_BYTES=262144, FETCH_REQUESTS=16, MAX_MEM_OUTSTANDING=64,
  PREDICTOR_MODE=2, HISTORY_BITS=8,
  parameter bit PREDICTOR=1
)(
  input logic clk,rst,
  output logic i_req_valid, input logic i_req_ready,
  output logic [31:0] i_req_addr, output logic [2:0] i_req_count,
  output logic [7:0] i_req_tag,
  input logic i_rsp_valid, output logic i_rsp_ready,
  input logic [127:0] i_rsp_data, input logic [7:0] i_rsp_tag, input logic i_rsp_error,
  input logic [3:0] i_rsp_error_mask,
  output logic d_req_valid, input logic d_req_ready, output logic d_req_write,
  output logic [31:0] d_req_addr,d_req_wdata,
  output logic [3:0] d_req_wstrb, output logic [7:0] d_req_tag,
  input logic d_rsp_valid, output logic d_rsp_ready,
  input logic [127:0] d_rsp_data, input logic [7:0] d_rsp_tag, input logic d_rsp_error,
  output logic exit_pending, output logic [31:0] exit_value,
  output logic stores_empty,frontend_idle,
  input logic exit_accept,system_error,
  output logic halted,faulted,
  output logic [31:0] fault_pc,fault_inst,fault_addr,
  output logic fault_inst_valid, output logic [3:0] fault_cause,
  output logic [3:0] retire_valid,retire_store,
  output logic [127:0] retire_pc,retire_inst,retire_value,retire_addr,retire_wdata,
  output logic [19:0] retire_rd, output logic [15:0] retire_wstrb,
  output logic [63:0] cycle_count,retired_count,branch_miss_count,load_replay_count
);
  import cpu_pkg::*;
  localparam logic [511:0] RAS_MASK={512{1'b1}} >> (512-32*RAS_DEPTH);
  localparam integer PW=$clog2(PHYS_REGS), RW=$clog2(ROB_ENTRIES);
  localparam integer LW=(LQ_ENTRIES>1 ? $clog2(LQ_ENTRIES):1);
  localparam integer CSW=(CSB_ENTRIES>1 ? $clog2(CSB_ENTRIES):1);
  // Preserve an unused count value so the bound assertion also catches underflow.
  localparam integer SQW=$clog2(SQ_ENTRIES+2);
  localparam integer CANDIDATES=4+LQ_ENTRIES+1;
  typedef logic [PW-1:0] preg_t;
  typedef logic [RW-1:0] rid_t;
  typedef enum logic [1:0] {RUN,EXITING,DONE,FAULT} state_t;
  typedef struct packed {
    logic valid,completed,branch_resolved,addr_ready,data_ready;
    logic [15:0] generation;
    logic [31:0] pc,inst,predicted_pc;
    logic inst_valid,bimodal_taken,gshare_taken;
    logic [15:0] history;
    decoded_t dec;
    preg_t pdst,old_pdst,src1,src2;
    logic [LW-1:0] lqid;
    logic [31:0] value,next_pc,addr,wdata,fault_addr;
    logic [3:0] wstrb,fault;
    logic taken;
  } rob_t;
  typedef struct packed {
    logic valid,address_sent,wait_store;
    rid_t rid,wait_rid;
    logic [15:0] generation;
    preg_t src1,src2;
  } iq_t;
  typedef struct packed {
    logic valid,data_ready;
    rid_t rid;
    logic [15:0] generation;
    op_t op;
    logic [31:0] a,b,pc,imm;
  } execute_t;
  typedef struct packed {
    logic valid,issued,queued,canceled,value_ready,returned;
    rid_t rid;
    logic [15:0] generation;
    logic [31:0] addr,forward_data,value,fault_addr;
    logic [3:0] forward_mask,mask,fault,forward_from_rob;
    logic [4*RW-1:0] forward_owner;
    logic [1:0] size;
    logic sign_extend;
  } load_t;
  typedef struct packed {
    logic valid,issued,completed;
    logic [31:0] addr,wdata,pc,inst;
    logic [3:0] wstrb;
  } store_t;
  typedef struct packed {
    logic valid,write;
    logic [31:0] addr,wdata;
    logic [3:0] wstrb;
    logic [7:0] tag;
  } request_t;
  typedef struct packed {
    logic valid;
    rid_t rid;
    logic [15:0] generation;
    logic [31:0] value,fault_addr;
    logic [3:0] fault;
  } result_t;

  rob_t rob_q [ROB_ENTRIES],rob_d [ROB_ENTRIES];
  iq_t iq_q [IQ_ENTRIES],iq_d [IQ_ENTRIES];
  execute_t ex_q [4],ex_d [4];
  load_t lq_q [LQ_ENTRIES],lq_d [LQ_ENTRIES];
  store_t csb_q [CSB_ENTRIES],csb_d [CSB_ENTRIES];
  preg_t rat_q [32],rat_d [32],rrat_q [32],rrat_d [32];
  logic [31:0] prf_q [PHYS_REGS],prf_d [PHYS_REGS];
  logic [PHYS_REGS-1:0] free_q,free_d,ready_q,ready_d;
`ifndef SYNTHESIS
  // Independent rename-time reference retained only in simulation.
  logic [32*PW-1:0] map_q [ROB_ENTRIES],map_d [ROB_ENTRIES];
`endif
  preg_t recovery_map [32];
  logic [ROB_ENTRIES-1:0] recovery_survivor;
  logic [511:0] ras_q [ROB_ENTRIES],ras_d [ROB_ENTRIES];
  logic [4:0] ras_count_q [ROB_ENTRIES],ras_count_d [ROB_ENTRIES];
  logic [3:0] checkpoint_valid,rename_valid;
  rid_t checkpoint_rid [4],rename_rid [4];
`ifndef SYNTHESIS
  logic [32*PW-1:0] checkpoint_data [4];
`endif
  logic [511:0] checkpoint_ras [4];
  logic [4:0] checkpoint_ras_count [4];
  rob_t rename_result [4];
  // Keep control forwarding narrow. Bulk queue payloads have bounded event
  // ports, applied independently at each physical row after the control path.
  localparam integer IQW=(IQ_ENTRIES>1 ? $clog2(IQ_ENTRIES):1);
  typedef struct packed {
    logic valid,address_sent,wait_store;
    rid_t wait_rid;
  } iq_control_t;
  typedef struct packed {
    logic valid,queued,canceled,value_ready,returned;
  } load_control_t;
  typedef struct packed { logic valid,issued; } store_control_t;
  iq_control_t iq_work [IQ_ENTRIES];
  load_control_t load_work [LQ_ENTRIES];
  store_control_t store_work [CSB_ENTRIES];
  logic [3:0] iq_allocate,load_allocate,store_allocate;
  logic [IQW-1:0] iq_allocate_slot [4];
  logic [LW-1:0] load_allocate_slot [4];
  logic [CSW-1:0] store_allocate_slot [4];
  iq_t iq_allocate_data [4];
  load_t load_allocate_data [4];
  store_t store_allocate_data [4];
  logic [ROB_ENTRIES-1:0] retire_live;
  logic [ROB_ENTRIES-1:0] mdu_pending_q,mdu_pending_d;
  state_t state_q,state_d;
  rid_t head_q,head_d,tail_q,tail_d;
  logic [RW:0] count_q,count_d;
  logic [SQW-1:0] sq_count_q,sq_count_d;
  logic [CSW-1:0] csb_head_q,csb_head_d,csb_tail_q,csb_tail_d;
  logic [CSW:0] csb_count_q,csb_count_d;
  logic [ROB_ENTRIES-1:0] rob_valid;
  logic [15:0] rob_generation [ROB_ENTRIES];
  logic [RW:0] rob_age [ROB_ENTRIES];
  logic [CSW:0] csb_age [CSB_ENTRIES];
  request_t skid_q,skid_d,request;
  logic last_store_q,last_store_d;
  logic [31:0] exit_value_q,exit_value_d;
  logic [31:0] fault_pc_d,fault_inst_d,fault_addr_d;
  logic fault_inst_valid_d;
  logic [3:0] fault_cause_d;
  logic [63:0] retired_count_d,branch_miss_count_d,load_replay_count_d;
  logic [3:0] retire_valid_d,retire_store_d;
  logic [127:0] retire_pc_d,retire_inst_d,retire_value_d,retire_addr_d,retire_wdata_d;
  logic [19:0] retire_rd_d;
  logic [15:0] retire_wstrb_d;

  fetch_t fetch_packet [4];
  decoded_t decoded [4];
  logic [3:0] fetch_valid,train_valid,train_taken,train_bimodal_taken,train_gshare_taken;
  logic [2:0] fetch_pop;
  logic redirect,redirect_taken,replay;
  rid_t recovery_rid;
  logic [RW:0] recovery_age;
  logic recovery_keep;
  logic [31:0] redirect_pc,redirect_branch_pc,redirect_inst;
  logic [15:0] redirect_history;
  logic [511:0] redirect_ras_snapshot;
  logic [4:0] redirect_ras_count;
  logic [127:0] train_pc,train_inst,train_next_pc;
  logic [63:0] train_history;
  logic [31:0] alu_result [4],branch_result [4],branch_next [4];
  logic branch_taken [4],branch_misaligned [4];
  logic mdu_req_valid,mdu_req_ready,mdu_rsp_valid,mdu_rsp_ready,mul_ready,div_ready;
  logic [31:0] mdu_result,mdu_a,mdu_b;
  logic [7:0] mdu_req_tag,mdu_rsp_tag;
  logic [255:0] mdu_kill_mask;
  op_t mdu_op;
  result_t candidate [CANDIDATES];
  rob_t execute_rob [ROB_ENTRIES],writeback_rob [ROB_ENTRIES];
  logic [3:0] branch_update,store_update,no_result_complete;
  logic [31:0] execute_address [4],execute_store_data [4];
  logic [3:0] execute_store_mask [4],execute_store_fault [4];
  load_t execute_lq [LQ_ENTRIES];
  store_t execute_csb [CSB_ENTRIES];
  logic [3:0] execute_fault [ROB_ENTRIES];
  logic [31:0] execute_fault_addr [ROB_ENTRIES];
  logic execute_load_issued [LQ_ENTRIES];
  logic execute_store_completed [CSB_ENTRIES];
  execute_t execute_ex [4];
  logic [ROB_ENTRIES-1:0] load_retry;
  rid_t load_wait_store [ROB_ENTRIES];
  logic execute_error;
  logic [31:0] execute_error_pc,execute_error_inst,execute_error_addr;
  logic [CANDIDATES-1:0] wb_accept;
  result_t wb_result [4];
  integer wb_source [4];
  logic [3:0] wb_valid;
  integer request_load,request_store,mdu_lane;

  // Select the observed field, never a whole queue record, at dynamic ports.
  for(genvar row=0;row<ROB_ENTRIES;row=row+1) begin: execution_read_columns
    assign execute_fault[row]=execute_rob[row].fault;
    assign execute_fault_addr[row]=execute_rob[row].fault_addr;
  end
  for(genvar row=0;row<LQ_ENTRIES;row=row+1) begin: load_issue_column
    // next_state changes validity/ownership, but never issued before IQ cleanup.
    assign execute_load_issued[row]=execute_lq[row].issued;
  end
  for(genvar row=0;row<CSB_ENTRIES;row=row+1) begin: store_completion_column
    // Prefix removal changes valid/head/count; allocation follows all removals.
    assign execute_store_completed[row]=execute_csb[row].completed;
  end


  // Narrow wire columns; physical ROB state remains unchanged.
  logic rob_col_addr_ready [ROB_ENTRIES];
  logic rob_col_bimodal_taken [ROB_ENTRIES];
  logic rob_col_branch_resolved [ROB_ENTRIES];
  logic [31:0] rob_col_dec_imm [ROB_ENTRIES];
  logic [1:0] rob_col_dec_mem_size [ROB_ENTRIES];
  op_t rob_col_dec_op [ROB_ENTRIES];
  logic [4:0] rob_col_dec_rd [ROB_ENTRIES];
  logic rob_col_dec_use_imm [ROB_ENTRIES];
  logic rob_col_dec_writes_rd [ROB_ENTRIES];
  logic [3:0] rob_col_fault [ROB_ENTRIES];
  logic [15:0] rob_col_generation [ROB_ENTRIES];
  logic rob_col_gshare_taken [ROB_ENTRIES];
  logic [15:0] rob_col_history [ROB_ENTRIES];
  logic [31:0] rob_col_inst [ROB_ENTRIES];
  logic rob_col_inst_valid [ROB_ENTRIES];
  logic [LW-1:0] rob_col_lqid [ROB_ENTRIES];
  preg_t rob_col_old_pdst [ROB_ENTRIES];
  logic [31:0] rob_col_pc [ROB_ENTRIES];
  preg_t rob_col_pdst [ROB_ENTRIES];
  logic [31:0] rob_col_predicted_pc [ROB_ENTRIES];
  logic rob_col_valid [ROB_ENTRIES];
  for(genvar row=0;row<ROB_ENTRIES;row=row+1) begin:narrow_rob_read_columns
    assign rob_col_addr_ready[row]=rob_q[row].addr_ready;
    assign rob_col_bimodal_taken[row]=rob_q[row].bimodal_taken;
    assign rob_col_branch_resolved[row]=rob_q[row].branch_resolved;
    assign rob_col_dec_imm[row]=rob_q[row].dec.imm;
    assign rob_col_dec_mem_size[row]=rob_q[row].dec.mem_size;
    assign rob_col_dec_op[row]=rob_q[row].dec.op;
    assign rob_col_dec_rd[row]=rob_q[row].dec.rd;
    assign rob_col_dec_use_imm[row]=rob_q[row].dec.use_imm;
    assign rob_col_dec_writes_rd[row]=rob_q[row].dec.writes_rd;
    assign rob_col_fault[row]=rob_q[row].fault;
    assign rob_col_generation[row]=rob_q[row].generation;
    assign rob_col_gshare_taken[row]=rob_q[row].gshare_taken;
    assign rob_col_history[row]=rob_q[row].history;
    assign rob_col_inst[row]=rob_q[row].inst;
    assign rob_col_inst_valid[row]=rob_q[row].inst_valid;
    assign rob_col_lqid[row]=rob_q[row].lqid;
    assign rob_col_old_pdst[row]=rob_q[row].old_pdst;
    assign rob_col_pc[row]=rob_q[row].pc;
    assign rob_col_pdst[row]=rob_q[row].pdst;
    assign rob_col_predicted_pc[row]=rob_q[row].predicted_pc;
    assign rob_col_valid[row]=rob_q[row].valid;
  end


  // Narrow wire columns; physical ROB state remains unchanged.
  logic [31:0] retire_col_addr [ROB_ENTRIES];
  logic retire_col_addr_ready [ROB_ENTRIES];
  logic retire_col_completed [ROB_ENTRIES];
  logic retire_col_data_ready [ROB_ENTRIES];
  logic [3:0] retire_col_fault [ROB_ENTRIES];
  logic [31:0] retire_col_fault_addr [ROB_ENTRIES];
  logic [31:0] retire_col_next_pc [ROB_ENTRIES];
  logic retire_col_taken [ROB_ENTRIES];
  logic [31:0] retire_col_value [ROB_ENTRIES];
  logic [31:0] retire_col_wdata [ROB_ENTRIES];
  logic [3:0] retire_col_wstrb [ROB_ENTRIES];
  for(genvar row=0;row<ROB_ENTRIES;row=row+1) begin:narrow_retire_read_columns
    assign retire_col_addr[row]=writeback_rob[row].addr;
    assign retire_col_addr_ready[row]=writeback_rob[row].addr_ready;
    assign retire_col_completed[row]=writeback_rob[row].completed;
    assign retire_col_data_ready[row]=writeback_rob[row].data_ready;
    assign retire_col_fault[row]=writeback_rob[row].fault;
    assign retire_col_fault_addr[row]=writeback_rob[row].fault_addr;
    assign retire_col_next_pc[row]=writeback_rob[row].next_pc;
    assign retire_col_taken[row]=writeback_rob[row].taken;
    assign retire_col_value[row]=writeback_rob[row].value;
    assign retire_col_wdata[row]=writeback_rob[row].wdata;
    assign retire_col_wstrb[row]=writeback_rob[row].wstrb;
  end

  // Circular ages are bounded by the queue capacity. Keep a signed extra bit
  // for the subtraction, including supported non-power-of-two capacities.
  function automatic logic [RW:0] distance(input rid_t r,input rid_t h);
    logic signed [RW+1:0] delta;
    begin
      if((ROB_ENTRIES & (ROB_ENTRIES-1))==0) return {1'b0,rid_t'(r-h)};
      delta=$signed({2'b00,r})-$signed({2'b00,h});
      if(delta[RW+1]) delta=delta+(RW+2)'(ROB_ENTRIES);
      return (RW+1)'(delta);
    end
  endfunction
  function automatic logic live(input rid_t r,input logic [15:0] gen);
    return rob_valid[r] && rob_generation[r]==gen;
  endfunction
  function automatic logic killed(input rid_t r,input rid_t head,
      input logic recovering,input logic [RW:0] cutoff);
    return recovering && distance(r,head)>=cutoff;
  endfunction
  for(genvar row=0;row<ROB_ENTRIES;row=row+1) begin: rob_read_columns
    assign rob_valid[row]=rob_col_valid[row];
    assign rob_generation[row]=rob_col_generation[row];
    assign rob_age[row]=distance(rid_t'(row),head_q);
  end
  for(genvar row=0;row<CSB_ENTRIES;row=row+1) begin: csb_ages
    assign csb_age[row]=(CSW+1)'(row)>= {1'b0,csb_head_q} ?
      (CSW+1)'(row)-{1'b0,csb_head_q} :
      (CSW+1)'(row+CSB_ENTRIES)-{1'b0,csb_head_q};
  end
  function automatic logic [3:0] byte_mask(input logic [1:0] size,input logic [1:0] offset);
    return (size==0 ? 4'b0001 : size==1 ? 4'b0011:4'b1111) << offset;
  endfunction
  function automatic logic [31:0] extend_load(input logic [31:0] value,
      input logic [1:0] offset,input logic [1:0] size,input logic signed_load);
    logic [31:0] shifted;
    begin
      shifted=value>>(8*offset);
      case(size)
        0:return signed_load ? {{24{shifted[7]}},shifted[7:0]}:{24'b0,shifted[7:0]};
        1:return signed_load ? {{16{shifted[15]}},shifted[15:0]}:{16'b0,shifted[15:0]};
        default:return shifted;
      endcase
    end
  endfunction
  function automatic logic [3:0] check_address(input logic [31:0] addr,
      input logic [1:0] size,input logic is_store);
    begin
      if((size==1 && addr[0]) || (size==2 && addr[1:0]!=0))
        return is_store ? FAULT_STORE_ALIGN:FAULT_LOAD_ALIGN;
      if(addr>RAM_BYTES-(1<<size) && !(is_store && addr==32'h80000000 && size==2))
        return is_store ? FAULT_STORE_RANGE:FAULT_LOAD_RANGE;
      return FAULT_NONE;
    end
  endfunction


  // Balanced stable argmin: equal ages retain the earlier scan position.
  // Validity includes the original strict sentinel bound. No clock is added.
`define CPU_OLDEST_FUNCTION(NAME, N, LIMIT) \
  function automatic integer NAME(input logic [(N)-1:0] valid, \
      input logic [(N)*(RW+1)-1:0] ages); \
    localparam integer LEAVES=1<<$clog2(N), INDEX_BITS=((N)>1 ? $clog2(N):1); \
    logic [2*LEAVES-1:1] tree_valid; \
    logic [RW:0] tree_age [2*LEAVES-1:1]; \
    logic [INDEX_BITS-1:0] tree_index [2*LEAVES-1:1]; \
    logic left_wins; \
    begin \
      NAME=-1;left_wins=0; \
      if(|valid) begin \
        for(integer n=0;n<LEAVES;n=n+1) begin \
          tree_valid[LEAVES+n]=0;tree_age[LEAVES+n]=0;tree_index[LEAVES+n]=0; \
          if(n<(N)) begin \
            tree_valid[LEAVES+n]=valid[n] && ages[n*(RW+1)+:RW+1]<(RW+1)'(LIMIT); \
            tree_age[LEAVES+n]=ages[n*(RW+1)+:RW+1]; \
            tree_index[LEAVES+n]=INDEX_BITS'(n); \
          end \
        end \
        for(integer n=LEAVES-1;n>0;n=n-1) begin \
          left_wins=tree_valid[2*n] && (!tree_valid[2*n+1] || tree_age[2*n]<=tree_age[2*n+1]); \
          tree_valid[n]=tree_valid[2*n] || tree_valid[2*n+1]; \
          tree_age[n]=left_wins ? tree_age[2*n]:tree_age[2*n+1]; \
          tree_index[n]=left_wins ? tree_index[2*n]:tree_index[2*n+1]; \
        end \
        if(tree_valid[1]) NAME=int'(tree_index[1]); \
      end \
    end \
  endfunction
  localparam integer RECOVERY_CANDIDATES=4+4*LQ_ENTRIES;
  `CPU_OLDEST_FUNCTION(oldest_recovery,RECOVERY_CANDIDATES,ROB_ENTRIES)
`undef CPU_OLDEST_FUNCTION

  // Compare each pair once. Rank all ready entries in parallel with balanced
  // population counts, so selecting four winners does not cascade four argmins.
`define CPU_ORDER_FUNCTION(NAME, N) \
  function automatic logic [(N)*(N)-1:0] NAME(input logic [(N)*(RW+1)-1:0] ages); \
    logic earlier; \
    begin \
      NAME='0;earlier=0; \
      for(integer a=0;a<(N);a=a+1) begin \
        for(integer b=a+1;b<(N);b=b+1) begin \
          earlier=ages[a*(RW+1)+:RW+1]<=ages[b*(RW+1)+:RW+1]; \
          NAME[b*(N)+a]=earlier;NAME[a*(N)+b]=!earlier; \
        end \
      end \
    end \
  endfunction
`define CPU_RANK_FUNCTION(NAME, N) \
  function automatic logic [(N)*$clog2((N)+1)-1:0] NAME( \
      input logic [(N)-1:0] valid,input logic [(N)*(N)-1:0] older); \
    localparam integer LEAVES=1<<$clog2(N), CW=$clog2((N)+1); \
    logic [CW-1:0] count_tree [2*LEAVES-1:1]; \
    begin \
      NAME='0; \
      if(|valid) begin \
        for(integer row=0;row<(N);row=row+1) begin \
          for(integer n=0;n<LEAVES;n=n+1) begin \
            count_tree[LEAVES+n]=0; \
            if(n<(N)) count_tree[LEAVES+n]=CW'(valid[n] && older[row*(N)+n]); \
          end \
          for(integer n=LEAVES-1;n>0;n=n-1) \
            count_tree[n]=count_tree[2*n]+count_tree[2*n+1]; \
          NAME[row*CW+:CW]=count_tree[1]; \
        end \
      end \
    end \
  endfunction
  localparam integer WBRW=$clog2(CANDIDATES+1), IQRW=$clog2(IQ_ENTRIES+1);
  `CPU_ORDER_FUNCTION(writeback_order,CANDIDATES)
  `CPU_ORDER_FUNCTION(issue_order,IQ_ENTRIES)
  `CPU_RANK_FUNCTION(writeback_rank,CANDIDATES)
  `CPU_RANK_FUNCTION(issue_rank,IQ_ENTRIES)
`undef CPU_ORDER_FUNCTION
`undef CPU_RANK_FUNCTION


  // Balanced lowest-physical-index selection. Padded leaves are unavailable;
  // an empty mask returns the original signed -1 sentinel.
`define CPU_LOWEST_FUNCTION(NAME, N) \
  function automatic integer NAME(input logic [(N)-1:0] available); \
    localparam integer LEAVES=1<<$clog2(N), IW=((N)>1 ? $clog2(N):1); \
    logic [2*LEAVES-1:1] tree_valid; \
    logic [IW-1:0] tree_index [2*LEAVES-1:1]; \
    begin \
      NAME=-1; \
      for(integer n=0;n<LEAVES;n=n+1) begin \
        tree_valid[LEAVES+n]=0;tree_index[LEAVES+n]=0; \
        if(n<(N)) begin \
          tree_valid[LEAVES+n]=available[n];tree_index[LEAVES+n]=IW'(n); \
        end \
      end \
      for(integer n=LEAVES-1;n>0;n=n-1) begin \
        tree_valid[n]=tree_valid[2*n] || tree_valid[2*n+1]; \
        tree_index[n]=tree_valid[2*n] ? tree_index[2*n]:tree_index[2*n+1]; \
      end \
      if(tree_valid[1]) NAME=int'(tree_index[1]); \
    end \
  endfunction
  `CPU_LOWEST_FUNCTION(lowest_iq_slot,IQ_ENTRIES)
  `CPU_LOWEST_FUNCTION(lowest_physical_register,PHYS_REGS)
  `CPU_LOWEST_FUNCTION(lowest_load_slot,LQ_ENTRIES)
`undef CPU_LOWEST_FUNCTION

  frontend #(.FETCH_WIDTH(FETCH_WIDTH),.FETCH_QUEUE_ENTRIES(FETCH_QUEUE_ENTRIES),
    .RAM_BYTES(RAM_BYTES),.BHT_ENTRIES(BHT_ENTRIES),.BTB_ENTRIES(BTB_ENTRIES),
    .RAS_DEPTH(RAS_DEPTH),.PREDICTOR(PREDICTOR),.LINE_BYTES(LINE_BYTES),
    .FETCH_REQUESTS(FETCH_REQUESTS),.PREDICTOR_MODE(PREDICTOR_MODE),.HISTORY_BITS(HISTORY_BITS)) front(
    .clk,.rst,.stop(state_q!=RUN),.redirect_valid(redirect),.redirect_pc,
    .redirect_branch_pc,.redirect_inst,.redirect_history,.redirect_ras_snapshot,
    .redirect_ras_count,.redirect_taken,.out_valid(fetch_valid),.out_packet(fetch_packet),
    .pop_count(fetch_pop),.train_valid,.train_pc,.train_inst,.train_next_pc,.train_taken,.train_history,
    .train_bimodal_taken,.train_gshare_taken,
    .req_valid(i_req_valid),.req_ready(i_req_ready),.req_addr(i_req_addr),
    .req_count(i_req_count),.req_tag(i_req_tag),.rsp_valid(i_rsp_valid),
    .rsp_ready(i_rsp_ready),.rsp_data(i_rsp_data),.rsp_tag(i_rsp_tag),
    .rsp_error(i_rsp_error),.rsp_error_mask(i_rsp_error_mask),.idle(frontend_idle));
  for(genvar g=0;g<4;g=g+1) begin: execute_units
    decoder decode(.inst(fetch_packet[g].inst),.dec(decoded[g]));
    alu integer_alu(.op(ex_q[g].op),.a(ex_q[g].a),.b(ex_q[g].b),
      .pc(ex_q[g].pc),.imm(ex_q[g].imm),.result(alu_result[g]));
    branch_unit branch(.op(ex_q[g].op),.a(ex_q[g].a),.b(ex_q[g].b),
      .pc(ex_q[g].pc),.imm(ex_q[g].imm),.result(branch_result[g]),
      .next_pc(branch_next[g]),.taken(branch_taken[g]),.misaligned(branch_misaligned[g]));
  end
  muldiv mdu(.clk,.rst,.kill(state_q!=RUN),.kill_mask(mdu_kill_mask),
    .req_valid(mdu_req_valid),.req_ready(mdu_req_ready),.mul_ready,.div_ready,
    .req_op(mdu_op),.req_a(mdu_a),.req_b(mdu_b),.req_tag(mdu_req_tag),
    .rsp_valid(mdu_rsp_valid),.rsp_ready(mdu_rsp_ready),.rsp_result(mdu_result),.rsp_tag(mdu_rsp_tag));

  assign halted=state_q==DONE;
  assign faulted=state_q==FAULT;
  assign exit_pending=state_q==EXITING || state_q==DONE;
  assign exit_value=exit_value_q;
  assign stores_empty=csb_count_q==0 && !skid_q.valid;
  assign d_rsp_ready=1;
  assign d_req_valid=request.valid;
  assign d_req_write=request.write;
  assign d_req_addr=request.addr;
  assign d_req_wdata=request.wdata;
  assign d_req_wstrb=request.wstrb;
  assign d_req_tag=request.tag;

  always_comb begin : recovery_selection
    integer index,best;
    logic [31:0] address;
    logic [3:0] mask,unshadowed;
    logic [RECOVERY_CANDIDATES-1:0] eligible;
    logic [RECOVERY_CANDIDATES*(RW+1)-1:0] ages;
    rid_t identities [RECOVERY_CANDIDATES];
    index=0;best=-1;address=0;mask=0;unshadowed=0;eligible=0;ages=0;
    for(integer k=0;k<RECOVERY_CANDIDATES;k=k+1) identities[k]=0;
    redirect=0;replay=0;recovery_rid=0;recovery_age=(RW+1)'(ROB_ENTRIES);recovery_keep=1;
    redirect_pc=0;redirect_taken=0;redirect_branch_pc=0;redirect_inst=0;
    redirect_history=0;redirect_ras_snapshot=0;redirect_ras_count=0;mdu_kill_mask=0;
    for(integer lane=0;lane<4;lane=lane+1) begin
      index=int'(ex_q[lane].rid);
      identities[lane]=ex_q[lane].rid;
      ages[lane*(RW+1)+:RW+1]=distance(ex_q[lane].rid,head_q);
      eligible[lane]=state_q==RUN && ex_q[lane].valid && live(ex_q[lane].rid,ex_q[lane].generation) &&
        is_branch(ex_q[lane].op) && !rob_col_branch_resolved[index] && !branch_misaligned[lane] &&
        branch_next[lane]!=rob_col_predicted_pc[index];
    end
    for(integer lane=0;lane<4;lane=lane+1) begin
      index=int'(ex_q[lane].rid);address=ex_q[lane].a+ex_q[lane].imm;
      mask=byte_mask(rob_col_dec_mem_size[index],address[1:0]);
      for(integer k=0;k<LQ_ENTRIES;k=k+1) begin
        identities[4+lane*LQ_ENTRIES+k]=lq_q[k].rid;
        ages[(4+lane*LQ_ENTRIES+k)*(RW+1)+:RW+1]=distance(lq_q[k].rid,head_q);
      end
      if(state_q==RUN && ex_q[lane].valid && ex_q[lane].op==OP_STORE &&
         live(ex_q[lane].rid,ex_q[lane].generation) && !rob_col_addr_ready[index] &&
         check_address(address,rob_col_dec_mem_size[index],1'b1)==0) begin
        for(integer k=0;k<LQ_ENTRIES;k=k+1) begin
          unshadowed=lq_q[k].mask & mask;
          for(integer b=0;b<4;b=b+1)
            if(lq_q[k].forward_from_rob[b] &&
               distance(lq_q[k].forward_owner[b*RW+:RW],head_q)>distance(ex_q[lane].rid,head_q) &&
               distance(lq_q[k].forward_owner[b*RW+:RW],head_q)<distance(lq_q[k].rid,head_q)) unshadowed[b]=0;
          eligible[4+lane*LQ_ENTRIES+k]=lq_q[k].valid && lq_q[k].issued && !lq_q[k].canceled &&
            live(lq_q[k].rid,lq_q[k].generation) && distance(lq_q[k].rid,head_q)>distance(ex_q[lane].rid,head_q) &&
            lq_q[k].addr[31:2]==address[31:2] && unshadowed!=0;
        end
      end
    end
    best=oldest_recovery(eligible,ages);
    if(best>=0) begin
      redirect=1;recovery_rid=identities[best];recovery_age=ages[best*(RW+1)+:RW+1];
      replay=best>=4;recovery_keep=best<4;
      if(best<4) begin redirect_pc=branch_next[best];redirect_taken=branch_taken[best];end
      redirect_branch_pc=rob_col_pc[recovery_rid];redirect_inst=replay ? 32'b0:rob_col_inst[recovery_rid];
      if(replay) redirect_pc=redirect_branch_pc;
      redirect_history=rob_col_history[recovery_rid];
      redirect_ras_snapshot=ras_q[recovery_rid];redirect_ras_count=ras_count_q[recovery_rid];
      for(integer k=0;k<ROB_ENTRIES;k=k+1)
        if(rob_col_valid[k] && rob_age[k]>=recovery_age+(RW+1)'(recovery_keep)) mdu_kill_mask[k]=1;
    end
  end

  // Execution event payloads are computed once per port, then each physical
  // ROB entry decodes the destination. Loads keep their address in the LQ.
  always_comb begin: execution_events
    branch_update=0;store_update=0;no_result_complete=0;
    for(integer lane=0;lane<4;lane=lane+1) begin
      execute_address[lane]=ex_q[lane].a+ex_q[lane].imm;
      execute_store_data[lane]=ex_q[lane].b<<(8*execute_address[lane][1:0]);
      execute_store_mask[lane]=byte_mask(rob_col_dec_mem_size[ex_q[lane].rid],execute_address[lane][1:0]);
      execute_store_fault[lane]=check_address(execute_address[lane],rob_col_dec_mem_size[ex_q[lane].rid],1'b1);
      if(state_q==RUN && ex_q[lane].valid && live(ex_q[lane].rid,ex_q[lane].generation)) begin
        branch_update[lane]=is_branch(ex_q[lane].op) && !rob_col_branch_resolved[ex_q[lane].rid];
        store_update[lane]=ex_q[lane].op==OP_STORE;
        no_result_complete[lane]=(is_alu(ex_q[lane].op) || is_branch(ex_q[lane].op)) &&
          !killed(ex_q[lane].rid,head_q,redirect,recovery_age+(RW+1)'(recovery_keep)) && !rob_col_dec_writes_rd[ex_q[lane].rid];
      end
    end
  end
  for(genvar row=0;row<ROB_ENTRIES;row=row+1) begin: execution_state
    always_comb begin
      execute_rob[row]=rob_q[row];
      for(integer lane=0;lane<4;lane=lane+1) begin
        if(branch_update[lane] && ex_q[lane].rid==rid_t'(row)) begin
          execute_rob[row].branch_resolved=1;execute_rob[row].next_pc=branch_next[lane];
          execute_rob[row].taken=branch_taken[lane];
          execute_rob[row].fault=branch_misaligned[lane] ? FAULT_TARGET_ALIGN:FAULT_NONE;
          execute_rob[row].fault_addr=branch_next[lane];
        end
      end
      for(integer lane=0;lane<4;lane=lane+1) begin
        if(store_update[lane] && ex_q[lane].rid==rid_t'(row)) begin
          execute_rob[row].addr=execute_address[lane];execute_rob[row].addr_ready=1;
          execute_rob[row].wstrb=execute_store_mask[lane];execute_rob[row].fault=execute_store_fault[lane];
          execute_rob[row].fault_addr=execute_address[lane];
          if(ex_q[lane].data_ready || execute_store_fault[lane]!=0) begin
            execute_rob[row].wdata=execute_store_data[lane];
            execute_rob[row].data_ready=1;execute_rob[row].completed=1;
          end
        end
      end
      for(integer lane=0;lane<4;lane=lane+1)
        if(no_result_complete[lane] && ex_q[lane].rid==rid_t'(row)) execute_rob[row].completed=1;
    end
    always_comb begin
      writeback_rob[row]=execute_rob[row];
      for(integer lane=0;lane<WB_WIDTH;lane=lane+1) begin
        if(wb_valid[lane] && wb_result[lane].rid==rid_t'(row)) begin
          writeback_rob[row].completed=1;writeback_rob[row].value=wb_result[lane].value;
          writeback_rob[row].fault=wb_result[lane].fault;writeback_rob[row].fault_addr=wb_result[lane].fault_addr;
        end
      end
    end
  end

  // State arrays use decoded constant-entry writes: a dynamic field assignment
  // can lower to a read/modify/write mux spanning the entire packed array.
  // Execution depends only on registered operands and returned cache data.
  // It does not depend on issue readiness or request acceptance.
  always_comb begin : execution_completion
    integer index,slot,lqid;
    logic [31:0] address,forward_data,merged,load_value;
    logic [3:0] mask,forward_mask,mem_fault,blocked_mask,forward_from_rob;
    logic [4*RW-1:0] blocked_owner,forward_owner;
    logic [CSW:0] csb_byte_age [4];
    logic [RW:0] rob_byte_age [4];
    logic [3:0] csb_byte_found,rob_byte_found;
    logic store_blocked;
    index=0;slot=0;lqid=0;address=0;forward_data=0;merged=0;load_value=0;
    mask=0;forward_mask=0;mem_fault=0;store_blocked=0;blocked_mask=0;
    blocked_owner=0;forward_owner=0;forward_from_rob=0;
    csb_byte_found=0;rob_byte_found=0;
    for(integer b=0;b<4;b=b+1) begin csb_byte_age[b]=0;rob_byte_age[b]=0;end
    for(integer k=0;k<ROB_ENTRIES;k=k+1) load_wait_store[k]=0;
    for(integer k=0;k<LQ_ENTRIES;k=k+1) execute_lq[k]=lq_q[k];
    for(integer k=0;k<CSB_ENTRIES;k=k+1) execute_csb[k]=csb_q[k];
    for(integer k=0;k<4;k=k+1) execute_ex[k]=ex_q[k];
    for(integer k=0;k<CANDIDATES;k=k+1) candidate[k]='0;
    load_retry=0;execute_error=0;execute_error_pc=0;execute_error_inst=0;execute_error_addr=0;
    // Cache responses have private storage, so a blocked PRF never blocks memory.
    if(d_rsp_valid) begin
      slot=int'(d_rsp_tag[6:0]);
      if(d_rsp_tag[7] && slot<CSB_ENTRIES && csb_q[slot].valid && csb_q[slot].issued) begin
        for(integer row=0;row<CSB_ENTRIES;row=row+1)
          if(row==slot) execute_csb[row].completed=1;
        if(d_rsp_error && state_q!=FAULT && state_q!=DONE) begin
          execute_error=1;execute_error_pc=csb_q[slot].pc;
          execute_error_inst=csb_q[slot].inst;execute_error_addr=csb_q[slot].addr;
        end
      end else if(!d_rsp_tag[7] && slot<LQ_ENTRIES && lq_q[slot].valid && lq_q[slot].queued) begin
        merged=d_rsp_data[31:0];
        for(integer b=0;b<4;b=b+1) if(lq_q[slot].forward_mask[b])
          merged[b*8+:8]=lq_q[slot].forward_data[b*8+:8];
        load_value=extend_load(merged,lq_q[slot].addr[1:0],lq_q[slot].size,lq_q[slot].sign_extend);
        for(integer row=0;row<LQ_ENTRIES;row=row+1) if(row==slot) begin
          execute_lq[row].returned=1;
          if(lq_q[slot].canceled || !live(lq_q[slot].rid,lq_q[slot].generation)) execute_lq[row].valid=0;
          else begin
            execute_lq[row].value=load_value;
            execute_lq[row].fault=d_rsp_error ? FAULT_LOAD_BUS:FAULT_NONE;
            execute_lq[row].fault_addr=lq_q[slot].addr;execute_lq[row].value_ready=1;
          end
        end
      end
    end
    for(integer lane=0;lane<4;lane=lane+1)
      if(store_update[lane]) execute_ex[lane].valid=0;

    // AGU + forwarding; independent Loads occupy independent LQ/cache tags.
    for(integer lane=0;lane<4;lane=lane+1) begin
      index=int'(ex_q[lane].rid);
      if(state_q==RUN && ex_q[lane].valid && ex_q[lane].op==OP_LOAD &&
         live(ex_q[lane].rid,ex_q[lane].generation) && !killed(ex_q[lane].rid,head_q,redirect,recovery_age+(RW+1)'(recovery_keep))) begin
        lqid=int'(rob_col_lqid[index]);address=ex_q[lane].a+ex_q[lane].imm;
        mask=byte_mask(rob_col_dec_mem_size[index],address[1:0]);
        mem_fault=check_address(address,rob_col_dec_mem_size[index],1'b0);
        forward_mask=0;forward_data=0;store_blocked=0;blocked_mask=0;
        blocked_owner=0;forward_owner=0;forward_from_rob=0;
        csb_byte_found=0;rob_byte_found=0;
        for(integer b=0;b<4;b=b+1) begin csb_byte_age[b]=0;rob_byte_age[b]=0;end
        // Each physical entry is read directly. Rotating an array index inside
        // a full scan would build N independent N:1 record multiplexers.
        // Compare ages instead, selecting the newest producer per byte.
        for(integer n=0;n<CSB_ENTRIES;n=n+1) begin
          if(csb_q[n].valid && csb_q[n].addr[31:2]==address[31:2]) begin
            for(integer b=0;b<4;b=b+1) if(csb_q[n].wstrb[b] &&
                (!csb_byte_found[b] || csb_age[n]>csb_byte_age[b])) begin
              csb_byte_found[b]=1;csb_byte_age[b]=csb_age[n];
              forward_mask[b]=1;forward_data[b*8+:8]=csb_q[n].wdata[b*8+:8];
            end
          end
        end
        for(integer n=0;n<ROB_ENTRIES;n=n+1) begin
          if(rob_age[n]<distance(ex_q[lane].rid,head_q) && execute_rob[n].valid && execute_rob[n].dec.op==OP_STORE &&
             execute_rob[n].addr_ready && execute_rob[n].fault==0 && execute_rob[n].addr[31:2]==address[31:2]) begin
            for(integer b=0;b<4;b=b+1) if(execute_rob[n].wstrb[b] &&
                (!rob_byte_found[b] || rob_age[n]>rob_byte_age[b])) begin
              rob_byte_found[b]=1;rob_byte_age[b]=rob_age[n];
              blocked_mask[b]=!execute_rob[n].data_ready;
              blocked_owner[b*RW+:RW]=rid_t'(n);
              if(execute_rob[n].data_ready) begin
                forward_mask[b]=1;forward_data[b*8+:8]=execute_rob[n].wdata[b*8+:8];
                forward_from_rob[b]=1;forward_owner[b*RW+:RW]=rid_t'(n);
              end
            end
          end
        end
        store_blocked=(blocked_mask & mask)!=0;
        if(!store_blocked || mem_fault!=0) begin
          load_value=extend_load(forward_data,address[1:0],lq_q[lqid].size,lq_q[lqid].sign_extend);
          for(integer row=0;row<LQ_ENTRIES;row=row+1) if(row==lqid) begin
            execute_lq[row].issued=1;execute_lq[row].addr=address;execute_lq[row].mask=mask;
            execute_lq[row].forward_mask=forward_mask;execute_lq[row].forward_data=forward_data;
            execute_lq[row].forward_from_rob=forward_from_rob;execute_lq[row].forward_owner=forward_owner;
            if(mem_fault!=0 || (forward_mask & mask)==mask) begin
              execute_lq[row].value=load_value;
              execute_lq[row].value_ready=1;execute_lq[row].returned=1;
              execute_lq[row].fault=mem_fault;execute_lq[row].fault_addr=address;
            end
          end
          execute_ex[lane].valid=0;
        end else begin
          // Requeue a known alias waiting for Store data; do not occupy an AGU.
          load_retry[ex_q[lane].rid]=1;
          for(integer b=0;b<4;b=b+1) if(blocked_mask[b] && mask[b])
            for(integer row=0;row<ROB_ENTRIES;row=row+1) if(rid_t'(row)==ex_q[lane].rid)
              load_wait_store[row]=blocked_owner[b*RW+:RW];
          execute_ex[lane].valid=0;
        end
      end
    end

    // Gather completed register results; no-result instructions complete without
    // consuming a physical register write port. Unselected execute slots hold.
    for(integer lane=0;lane<4;lane=lane+1) begin
      index=int'(ex_q[lane].rid);
      if(state_q==RUN && ex_q[lane].valid && live(ex_q[lane].rid,ex_q[lane].generation) &&
         (is_alu(ex_q[lane].op) || is_branch(ex_q[lane].op)) && !killed(ex_q[lane].rid,head_q,redirect,recovery_age+(RW+1)'(recovery_keep))) begin
        candidate[lane].valid=1;candidate[lane].rid=ex_q[lane].rid;candidate[lane].generation=ex_q[lane].generation;
        candidate[lane].value=is_branch(ex_q[lane].op) ? ex_q[lane].pc+32'd4:alu_result[lane];
        if(is_branch(ex_q[lane].op)) begin
          candidate[lane].fault=execute_fault[index];candidate[lane].fault_addr=execute_fault_addr[index];
        end
        if(!rob_col_dec_writes_rd[index]) begin
          candidate[lane].valid=0;execute_ex[lane].valid=0;
        end
      end
    end
    for(integer k=0;k<LQ_ENTRIES;k=k+1) begin
      if(state_q==RUN && execute_lq[k].valid && execute_lq[k].value_ready && !execute_lq[k].canceled &&
         live(execute_lq[k].rid,execute_lq[k].generation) && !killed(execute_lq[k].rid,head_q,redirect,recovery_age+(RW+1)'(recovery_keep))) begin
        candidate[k+4].valid=1;candidate[k+4].rid=execute_lq[k].rid;candidate[k+4].generation=execute_lq[k].generation;
        candidate[k+4].value=execute_lq[k].value;candidate[k+4].fault=execute_lq[k].fault;candidate[k+4].fault_addr=execute_lq[k].fault_addr;
      end
    end
    if(mdu_rsp_valid && int'(mdu_rsp_tag)<ROB_ENTRIES) begin
      index=int'(mdu_rsp_tag);
      if(state_q==RUN && mdu_pending_q[index] && rob_col_valid[index] && !killed(rid_t'(index),head_q,redirect,recovery_age+(RW+1)'(recovery_keep))) begin
        candidate[CANDIDATES-1].valid=1;candidate[CANDIDATES-1].rid=rid_t'(index);
        candidate[CANDIDATES-1].generation=rob_col_generation[index];candidate[CANDIDATES-1].value=mdu_result;
      end
    end
  end

  always_comb begin : writeback_arbitration
    logic [CANDIDATES-1:0] eligible;
    logic [CANDIDATES*(RW+1)-1:0] ages;
    logic [CANDIDATES*WBRW-1:0] ranks;
    logic take;
    wb_accept=0;wb_valid=0;eligible=0;ages=0;ranks=0;take=0;
    for(integer k=0;k<CANDIDATES;k=k+1) begin
      ages[k*(RW+1)+:RW+1]=distance(candidate[k].rid,head_q);
      eligible[k]=candidate[k].valid && ages[k*(RW+1)+:RW+1]<(RW+1)'(ROB_ENTRIES+1);
    end
    ranks=writeback_rank(eligible,writeback_order(ages));
    for(integer lane=0;lane<4;lane=lane+1) begin wb_result[lane]='0;wb_source[lane]=0;end
    for(integer lane=0;lane<WB_WIDTH;lane=lane+1) begin
      for(integer k=0;k<CANDIDATES;k=k+1) begin
        take=eligible[k] && ranks[k*WBRW+:WBRW]==WBRW'(lane) && !execute_error;
        wb_accept[k]=wb_accept[k] || take;wb_valid[lane]=wb_valid[lane] || take;
        wb_source[lane]=wb_source[lane] | (k & {32{take}});
        wb_result[lane]=wb_result[lane] | (candidate[k] & {$bits(result_t){take}});
      end
    end
    mdu_rsp_ready=wb_accept[CANDIDATES-1] ||
      (mdu_rsp_valid && (int'(mdu_rsp_tag)>=ROB_ENTRIES ||
       !mdu_pending_q[rid_t'(mdu_rsp_tag)] || !rob_col_valid[rid_t'(mdu_rsp_tag)] ||
       killed(rid_t'(mdu_rsp_tag),head_q,redirect,recovery_age+(RW+1)'(recovery_keep)) || state_q!=RUN));
  end

  always_comb begin : mdu_request_mux
    mdu_req_valid=0;mdu_a=0;mdu_b=0;mdu_op=OP_MUL;mdu_req_tag=0;mdu_lane=-1;
    for(integer lane=0;lane<4;lane=lane+1) begin
      if(ex_q[lane].valid && live(ex_q[lane].rid,ex_q[lane].generation) &&
         is_mdu(ex_q[lane].op) && state_q==RUN && !killed(ex_q[lane].rid,head_q,redirect,recovery_age+(RW+1)'(recovery_keep)) && !mdu_req_valid) begin
        mdu_req_valid=1;mdu_a=ex_q[lane].a;mdu_b=ex_q[lane].b;mdu_op=ex_q[lane].op;
        mdu_req_tag=8'(ex_q[lane].rid);mdu_lane=lane;
      end
    end
  end

  always_comb begin : cache_request_mux
    logic [RW:0] best_age,age;
    logic [CSW:0] store_age;
    request='0;request_load=-1;request_store=-1;best_age=(RW+1)'(ROB_ENTRIES+1);age=0;store_age=(CSW+1)'(CSB_ENTRIES);
    for(integer k=0;k<LQ_ENTRIES;k=k+1) begin
      age=distance(execute_lq[k].rid,head_q);
      if(execute_lq[k].valid && execute_lq[k].issued && !execute_lq[k].queued &&
         !execute_lq[k].returned && !execute_lq[k].canceled && !killed(execute_lq[k].rid,head_q,redirect,recovery_age+(RW+1)'(recovery_keep)) && age<best_age) begin
        request_load=k;best_age=age;
      end
    end
    for(integer n=0;n<CSB_ENTRIES;n=n+1) begin
      if(csb_age[n]<csb_count_q && csb_q[n].valid && !csb_q[n].issued && csb_age[n]<store_age) begin
        request_store=n;store_age=csb_age[n];
      end
    end
    if(skid_q.valid) request=skid_q;
    else if(state_q==RUN || state_q==EXITING) begin
      if(request_store>=0 && (request_load<0 || state_q==EXITING || int'(csb_count_q)>=CSB_ENTRIES-4 || !last_store_q)) begin
        request.valid=1;request.write=1;request.addr={csb_q[request_store].addr[31:2],2'b00};
        request.wdata=csb_q[request_store].wdata;request.wstrb=csb_q[request_store].wstrb;
        request.tag=8'h80 | 8'(request_store);
      end else if(request_load>=0 && state_q==RUN) begin
        request.valid=1;request.addr={execute_lq[request_load].addr[31:2],2'b00};request.tag=8'(request_load);
      end
    end
  end

  // Reconstruct each architectural mapping from committed state and all
  // surviving speculative writers. The two fixed-index segments are in ROB
  // age order even when the live window wraps; the last writer wins.
  for(genvar row=0;row<ROB_ENTRIES;row=row+1) begin: recovery_writers
    assign recovery_survivor[row]=rob_col_valid[row] && rob_col_dec_writes_rd[row] &&
      rob_age[row]<recovery_age+(RW+1)'(recovery_keep);
  end
  for(genvar arch=0;arch<32;arch=arch+1) begin: reconstruct_rat
    if(arch==0) begin: zero_register
      assign recovery_map[arch]='0;
    end else begin: nonzero_register
      always_comb begin
        recovery_map[arch]=rrat_q[arch];
        if(redirect) begin
          for(integer row=0;row<ROB_ENTRIES;row=row+1)
            if(rid_t'(row)>=head_q && recovery_survivor[row] && rob_col_dec_rd[row]==5'(arch))
              recovery_map[arch]=rob_col_pdst[row];
          for(integer row=0;row<ROB_ENTRIES;row=row+1)
            if(rid_t'(row)<head_q && recovery_survivor[row] && rob_col_dec_rd[row]==5'(arch))
              recovery_map[arch]=rob_col_pdst[row];
        end
      end
    end
  end

  always_comb begin : next_state
    integer index,slot,best,iqslot,pdst,lqid,commit_index,mdu_issued,train_lane;
    logic [2:0] issue_port_rank;
    logic [IQ_ENTRIES-1:0] issue_eligible,issue_memory,issue_mdu,issue_filtered;
    logic [IQ_ENTRIES*IQ_ENTRIES-1:0] issue_older;
    logic [IQ_ENTRIES*IQRW-1:0] issue_mem_rank,issue_final_rank;
    logic [IQ_ENTRIES*(RW+1)-1:0] issue_ages;
    logic [IQ_ENTRIES-1:0] rename_iq_free;
    logic [PHYS_REGS-1:0] rename_prf_free;
    logic [LQ_ENTRIES-1:0] rename_lq_free;
    logic prefix,resources,src1_ready,src2_ready,trigger_exit,div_accepted;
    rob_t renamed;
    iq_t renamed_iq;
    preg_t wb_pdst;
    op_t iq_op [IQ_ENTRIES];
    logic [IQ_ENTRIES-1:0] iq_live,iq_address_ready,iq_wait_ready;
    load_t renamed_load;
    store_t committed_store;
`ifndef SYNTHESIS
    logic [32*PW-1:0] checkpoint_map;
`endif
    renamed='0;renamed_iq='0;renamed_load='0;committed_store='0;wb_pdst=0;
`ifndef SYNTHESIS
    checkpoint_map=0;
`endif
    iq_live=0;iq_address_ready=0;iq_wait_ready=0;
    for(integer k=0;k<IQ_ENTRIES;k=k+1) iq_op[k]=OP_ADD;
    checkpoint_valid=0;rename_valid=0;
    iq_allocate=0;load_allocate=0;store_allocate=0;
    for(integer lane=0;lane<4;lane=lane+1) begin
      iq_allocate_slot[lane]=0;load_allocate_slot[lane]=0;store_allocate_slot[lane]=0;
      iq_allocate_data[lane]='0;load_allocate_data[lane]='0;store_allocate_data[lane]='0;
    end
    for(integer lane=0;lane<4;lane=lane+1) begin
      checkpoint_rid[lane]=0;checkpoint_ras[lane]=0;
`ifndef SYNTHESIS
      checkpoint_data[lane]=0;
`endif
      checkpoint_ras_count[lane]=0;rename_rid[lane]=0;rename_result[lane]='0;
    end
    for(integer k=0;k<ROB_ENTRIES;k=k+1) retire_live[k]=writeback_rob[k].valid;
    for(integer k=0;k<IQ_ENTRIES;k=k+1) begin
      iq_work[k].valid=iq_q[k].valid;
      iq_work[k].address_sent=iq_q[k].address_sent;
      iq_work[k].wait_store=iq_q[k].wait_store;
      iq_work[k].wait_rid=iq_q[k].wait_rid;
      if(load_retry[iq_q[k].rid]) begin
        iq_work[k].address_sent=0;iq_work[k].wait_store=1;iq_work[k].wait_rid=load_wait_store[iq_q[k].rid];
      end
    end
    for(integer k=0;k<LQ_ENTRIES;k=k+1) begin
      load_work[k].valid=execute_lq[k].valid;
      load_work[k].queued=execute_lq[k].queued;
      load_work[k].canceled=execute_lq[k].canceled;
      load_work[k].value_ready=execute_lq[k].value_ready;
      load_work[k].returned=execute_lq[k].returned;
    end
    for(integer k=0;k<CSB_ENTRIES;k=k+1) begin
      store_work[k].valid=execute_csb[k].valid;
      store_work[k].issued=execute_csb[k].issued;
    end
    for(integer k=0;k<4;k=k+1) ex_d[k]=execute_ex[k];
    for(integer k=0;k<32;k=k+1) begin rat_d[k]=rat_q[k];rrat_d[k]=rrat_q[k];end
    for(integer k=0;k<PHYS_REGS;k=k+1) prf_d[k]=prf_q[k];
    free_d=free_q;ready_d=ready_q;state_d=state_q;head_d=head_q;tail_d=tail_q;count_d=count_q;
    sq_count_d=sq_count_q;csb_head_d=csb_head_q;csb_tail_d=csb_tail_q;csb_count_d=csb_count_q;
    skid_d=skid_q;last_store_d=last_store_q;mdu_pending_d=mdu_pending_q;
    exit_value_d=exit_value_q;
    fault_pc_d=fault_pc;fault_inst_d=fault_inst;fault_addr_d=fault_addr;
    fault_inst_valid_d=fault_inst_valid;fault_cause_d=fault_cause;
    retired_count_d=retired_count;branch_miss_count_d=branch_miss_count;load_replay_count_d=load_replay_count;
    retire_valid_d=0;retire_store_d=0;retire_pc_d=0;retire_inst_d=0;retire_value_d=0;
    retire_addr_d=0;retire_wdata_d=0;retire_rd_d=0;retire_wstrb_d=0;
    fetch_pop=0;train_valid=0;train_taken=0;train_pc=0;train_inst=0;train_next_pc=0;train_history=0;
    train_bimodal_taken=0;train_gshare_taken=0;
    index=0;slot=0;best=-1;issue_eligible=0;issue_ages=0;iqslot=0;pdst=0;lqid=0;commit_index=0;
    mdu_issued=0;train_lane=0;issue_port_rank=0;
    issue_memory=0;issue_mdu=0;issue_filtered=0;issue_older=0;issue_mem_rank=0;issue_final_rank=0;
    prefix=0;resources=0;src1_ready=0;src2_ready=0;trigger_exit=0;div_accepted=0;
    rename_iq_free=0;rename_prf_free=0;rename_lq_free=0;

    if(execute_error) begin
      state_d=FAULT;fault_cause_d=FAULT_STORE_BUS;fault_pc_d=execute_error_pc;
      fault_inst_d=execute_error_inst;fault_inst_valid_d=1;fault_addr_d=execute_error_addr;
    end
    for(integer n=0;n<4;n=n+1) begin
      if(csb_count_d>0 && execute_store_completed[csb_head_d]) begin
        for(integer row=0;row<CSB_ENTRIES;row=row+1)
          if(CSW'(row)==csb_head_d) store_work[row].valid=0;
        csb_head_d=CSW'((int'(csb_head_d)+1)%CSB_ENTRIES);csb_count_d=csb_count_d-1;
      end
    end
    if(request.valid) begin
      if(!skid_q.valid) begin
        if(request.write) begin
          for(integer row=0;row<CSB_ENTRIES;row=row+1)
            if(row==request_store) store_work[row].issued=1;
          last_store_d=1;
        end else begin
          for(integer row=0;row<LQ_ENTRIES;row=row+1)
            if(row==request_load) load_work[row].queued=1;
          last_store_d=0;
        end
      end
      if(d_req_ready) skid_d.valid=0;else skid_d=request;
    end
    if(mdu_req_valid && mdu_req_ready) begin
      ex_d[mdu_lane].valid=0;mdu_pending_d[rid_t'(mdu_req_tag)]=1;
      if(mdu_op>=OP_DIV) div_accepted=1;
    end
    // Exactly WB_WIDTH physical register and completion write ports.
    for(integer lane=0;lane<WB_WIDTH;lane=lane+1) if(wb_valid[lane]) begin
      index=int'(wb_result[lane].rid);wb_pdst=rob_col_pdst[index];
      if(rob_col_dec_writes_rd[index] && wb_result[lane].fault==0) begin
        ready_d[wb_pdst]=1;
        for(integer row=1;row<PHYS_REGS;row=row+1)
          if(preg_t'(row)==wb_pdst) prf_d[row]=wb_result[lane].value;
      end
      if(wb_source[lane]<4) ex_d[wb_source[lane]].valid=0;
      else if(wb_source[lane]<CANDIDATES-1) begin
        for(integer row=0;row<LQ_ENTRIES;row=row+1)
          if(row==wb_source[lane]-4) load_work[row].value_ready=0;
      end
      else mdu_pending_d[index]=0;
    end
    if(redirect) begin
      if(replay) load_replay_count_d=load_replay_count+64'd1;
      else branch_miss_count_d=branch_miss_count+64'd1;
    end

    // Atomic rename recovery. Irrevocable cache reads keep only their
    // canceled waiter, never the reclaimed ROB/physical-register association.
    if(redirect && state_q==RUN) begin
      for(integer k=0;k<32;k=k+1) rat_d[k]=recovery_map[k];
      for(integer k=0;k<ROB_ENTRIES;k=k+1) if(rob_col_valid[k] && killed(rid_t'(k),head_q,redirect,recovery_age+(RW+1)'(recovery_keep))) begin
        retire_live[k]=0;mdu_pending_d[k]=0;
        if(rob_col_dec_writes_rd[k]) begin free_d[rob_col_pdst[k]]=1;ready_d[rob_col_pdst[k]]=0;end
        if(rob_col_dec_op[k]==OP_STORE && rob_col_inst_valid[k] && rob_col_fault[k]!=FAULT_ILLEGAL)
          sq_count_d=sq_count_d-1;
      end
      for(integer k=0;k<IQ_ENTRIES;k=k+1) if(iq_work[k].valid && killed(iq_q[k].rid,head_q,redirect,recovery_age+(RW+1)'(recovery_keep))) iq_work[k].valid=0;
      for(integer k=0;k<4;k=k+1) if(ex_d[k].valid && killed(ex_d[k].rid,head_q,redirect,recovery_age+(RW+1)'(recovery_keep))) ex_d[k].valid=0;
      for(integer k=0;k<LQ_ENTRIES;k=k+1) if(load_work[k].valid && killed(execute_lq[k].rid,head_q,redirect,recovery_age+(RW+1)'(recovery_keep))) begin
        load_work[k].canceled=1;load_work[k].value_ready=0;
        if(!load_work[k].queued || load_work[k].returned) load_work[k].valid=0;
      end
      count_d=(RW+1)'(recovery_age+(RW+1)'(recovery_keep));
      tail_d=rid_t'((int'(recovery_rid)+int'(recovery_keep))%ROB_ENTRIES);
    end

    // Retire a prefix; multiple control transfers train without serialization.
    prefix=1;train_lane=0;
    for(integer lane=0;lane<COMMIT_WIDTH;lane=lane+1) begin
      commit_index=int'(head_d);
      if(state_q==RUN && state_d==RUN && !redirect && prefix && count_d>0 &&
         rob_col_valid[commit_index] && retire_col_completed[commit_index]) begin
        if(retire_col_fault[commit_index]!=0) begin
          state_d=FAULT;fault_pc_d=rob_col_pc[commit_index];fault_inst_d=rob_col_inst[commit_index];
          fault_inst_valid_d=rob_col_inst_valid[commit_index];fault_cause_d=retire_col_fault[commit_index];
          fault_addr_d=retire_col_fault_addr[commit_index];prefix=0;
        end else if(rob_col_dec_op[commit_index]==OP_STORE && retire_col_addr[commit_index]==32'h80000000) begin
          trigger_exit=1;state_d=EXITING;exit_value_d=retire_col_wdata[commit_index];prefix=0;
        end else if(rob_col_dec_op[commit_index]==OP_STORE && int'(csb_count_d)>=CSB_ENTRIES) prefix=0;
        else begin
          retire_valid_d[lane]=1;retire_pc_d[lane*32+:32]=rob_col_pc[commit_index];
          retire_inst_d[lane*32+:32]=rob_col_inst[commit_index];
          retire_rd_d[lane*5+:5]=rob_col_dec_writes_rd[commit_index] ? rob_col_dec_rd[commit_index]:5'd0;
          retire_value_d[lane*32+:32]=retire_col_value[commit_index];
          if(rob_col_dec_writes_rd[commit_index]) begin
            rrat_d[rob_col_dec_rd[commit_index]]=rob_col_pdst[commit_index];free_d[rob_col_old_pdst[commit_index]]=1;
          end
          if(is_branch(rob_col_dec_op[commit_index])) begin
            train_valid[train_lane]=1;train_pc[train_lane*32+:32]=rob_col_pc[commit_index];
            train_inst[train_lane*32+:32]=rob_col_inst[commit_index];
            train_next_pc[train_lane*32+:32]=retire_col_next_pc[commit_index];
            train_taken[train_lane]=retire_col_taken[commit_index];train_history[train_lane*16+:16]=rob_col_history[commit_index];
            train_bimodal_taken[train_lane]=rob_col_bimodal_taken[commit_index];
            train_gshare_taken[train_lane]=rob_col_gshare_taken[commit_index];
            train_lane=train_lane+1;
          end
          if(rob_col_dec_op[commit_index]==OP_LOAD)
            for(integer row=0;row<LQ_ENTRIES;row=row+1)
              if(LW'(row)==rob_col_lqid[commit_index]) load_work[row].valid=0;
          if(rob_col_dec_op[commit_index]==OP_STORE) begin
            sq_count_d=sq_count_d-1;committed_store='0;committed_store.valid=1;
            committed_store.addr=retire_col_addr[commit_index];committed_store.wdata=retire_col_wdata[commit_index];
            committed_store.wstrb=retire_col_wstrb[commit_index];
            committed_store.pc=rob_col_pc[commit_index];committed_store.inst=rob_col_inst[commit_index];
            store_allocate[lane]=1;store_allocate_slot[lane]=csb_tail_d;
            store_allocate_data[lane]=committed_store;
            for(integer row=0;row<CSB_ENTRIES;row=row+1)
              if(CSW'(row)==csb_tail_d) begin
                store_work[row].valid=1;store_work[row].issued=0;
              end
            csb_tail_d=CSW'((int'(csb_tail_d)+1)%CSB_ENTRIES);csb_count_d=csb_count_d+1;
            retire_store_d[lane]=1;retire_addr_d[lane*32+:32]=retire_col_addr[commit_index];
            retire_wdata_d[lane*32+:32]=retire_col_wdata[commit_index];retire_wstrb_d[lane*4+:4]=retire_col_wstrb[commit_index];
          end
          for(integer row=0;row<ROB_ENTRIES;row=row+1)
            if(row==commit_index) retire_live[row]=0;
          head_d=rid_t'((commit_index+1)%ROB_ENTRIES);count_d=count_d-1'b1;
          retired_count_d=retired_count_d+64'd1;
        end
      end else prefix=0;
    end

    // Delete IQ entries whose memory operation finished, retaining Store entries
    // after early address-only execution and Load entries until AGU acceptance.
    for(integer k=0;k<IQ_ENTRIES;k=k+1) begin
      index=int'(iq_q[k].rid);
      iq_op[k]=rob_col_dec_op[index];
      iq_live[k]=retire_live[index] && live(iq_q[k].rid,iq_q[k].generation);
      iq_address_ready[k]=retire_col_addr_ready[index];
      iq_wait_ready[k]=retire_col_data_ready[iq_work[k].wait_rid] || !retire_live[iq_work[k].wait_rid];
      if(iq_work[k].wait_store && iq_wait_ready[k]) iq_work[k].wait_store=0;
      if(iq_work[k].valid && (!retire_live[index] || retire_col_completed[index])) iq_work[k].valid=0;
      if(iq_work[k].valid && rob_col_dec_op[index]==OP_LOAD && execute_load_issued[rob_col_lqid[index]]) iq_work[k].valid=0;
    end

    mdu_issued=0;
    for(integer lane=0;lane<4;lane=lane+1) begin
      if(ex_d[lane].valid && is_mdu(ex_d[lane].op)) mdu_issued=1;
    end
    // Class limits are independent of lane assignment. Only the oldest two
    // ready memory operations and oldest ready MDU can enter the global top K.
    // Then assign those winners to free execution lanes in increasing order.
    for(integer k=0;k<IQ_ENTRIES;k=k+1) begin
      issue_ages[k*(RW+1)+:RW+1]=distance(iq_q[k].rid,head_q);
      resources=0;src1_ready=0;src2_ready=0;
      if(iq_q[k].valid && iq_work[k].valid && iq_live[k]) begin
        src1_ready=ready_d[iq_q[k].src1];src2_ready=ready_d[iq_q[k].src2];
        resources=src1_ready && src2_ready;
        if(iq_op[k]==OP_STORE)
          resources=src1_ready && ((!iq_work[k].address_sent) || (iq_address_ready[k] && src2_ready));
        if(iq_op[k]==OP_LOAD) begin
          resources=resources && !iq_work[k].address_sent;
          if(iq_work[k].wait_store) resources=resources && iq_wait_ready[k];
        end
        if(is_mdu(iq_op[k])) begin
          resources=resources && mdu_issued==0;
          if(iq_op[k]>=OP_DIV) resources=resources && div_ready && !div_accepted;
          else resources=resources && mul_ready;
        end
        issue_eligible[k]=resources && issue_ages[k*(RW+1)+:RW+1]<(RW+1)'(ROB_ENTRIES+1);
      end
      issue_memory[k]=issue_eligible[k] && (iq_op[k]==OP_STORE || iq_op[k]==OP_LOAD);
      issue_mdu[k]=issue_eligible[k] && is_mdu(iq_op[k]);
    end
    issue_older=issue_order(issue_ages);
    issue_mem_rank=issue_rank(issue_memory,issue_older);
    for(integer k=0;k<IQ_ENTRIES;k=k+1)
      issue_filtered[k]=issue_eligible[k] &&
        (!issue_memory[k] || !(|(issue_mem_rank[k*IQRW+:IQRW] >> 1))) &&
        (!issue_mdu[k] || !(|(issue_mdu & issue_older[k*IQ_ENTRIES+:IQ_ENTRIES])));
    issue_final_rank=issue_rank(issue_filtered,issue_older);
    issue_port_rank=0;
    for(integer lane=0;lane<ISSUE_WIDTH;lane=lane+1) begin
      best=-1;
      if(state_q==RUN && state_d==RUN && !redirect && !ex_d[lane].valid) begin
        // Ranks are unique. Encode each lane's one-hot winner by masked OR.
        index=0;resources=0;
        for(integer k=0;k<IQ_ENTRIES;k=k+1)
          if(issue_filtered[k] && int'(issue_final_rank[k*IQRW+:IQRW])==int'(issue_port_rank)) begin
            index=index | k;resources=1;
          end
        if(resources) best=index;
        issue_port_rank=issue_port_rank+3'd1;
        if(best>=0) begin
          index=int'(iq_q[best].rid);ex_d[lane]='0;ex_d[lane].valid=1;ex_d[lane].rid=iq_q[best].rid;
          ex_d[lane].generation=iq_q[best].generation;ex_d[lane].op=rob_col_dec_op[index];
          ex_d[lane].pc=rob_col_pc[index];ex_d[lane].imm=rob_col_dec_imm[index];
          ex_d[lane].a=prf_d[iq_q[best].src1];ex_d[lane].b=prf_d[iq_q[best].src2];
          ex_d[lane].data_ready=ready_d[iq_q[best].src2];
          if(rob_col_dec_use_imm[index] && is_alu(ex_d[lane].op)) ex_d[lane].b=rob_col_dec_imm[index];
          if(ex_d[lane].op==OP_STORE || ex_d[lane].op==OP_LOAD) begin
            for(integer row=0;row<IQ_ENTRIES;row=row+1) if(row==best) begin
              iq_work[row].address_sent=1;iq_work[row].wait_store=0;
              if(ex_d[lane].op==OP_STORE && ex_d[lane].data_ready) iq_work[row].valid=0;
            end
          end else for(integer row=0;row<IQ_ENTRIES;row=row+1)
            if(row==best) iq_work[row].valid=0;
        end
      end
    end

    // Rename in program order, using this cycle's committed frees and checkpoint
    // destinations atomically. Newly dispatched IQ entries issue next cycle.
    prefix=1;
    for(integer lane=0;lane<RENAME_WIDTH;lane=lane+1) begin
      if(state_q==RUN && state_d==RUN && !redirect && prefix && fetch_valid[lane] && int'(count_d)<ROB_ENTRIES) begin
        // Read the current work masks again for each rename lane, after any
        // earlier-lane allocation and this cycle's commit/issue/recovery frees.
        for(integer k=0;k<IQ_ENTRIES;k=k+1) rename_iq_free[k]=!iq_work[k].valid;
        for(integer k=0;k<LQ_ENTRIES;k=k+1) rename_lq_free[k]=!load_work[k].valid;
        rename_prf_free=free_d;rename_prf_free[0]=0;
        iqslot=lowest_iq_slot(rename_iq_free);
        pdst=lowest_physical_register(rename_prf_free);
        lqid=lowest_load_slot(rename_lq_free);
        resources=1;
        if(fetch_packet[lane].fault==0 && !decoded[lane].illegal) begin
          resources=iqslot>=0;
          if(decoded[lane].writes_rd) resources=resources && pdst>=0;
          if(decoded[lane].op==OP_LOAD) resources=resources && lqid>=0;
          if(decoded[lane].op==OP_STORE) resources=resources && int'(sq_count_d)<SQ_ENTRIES;
        end
        if(resources) begin
          index=int'(tail_d);renamed='0;renamed.valid=1;
          renamed.generation=rob_col_generation[index]+16'd1;
          renamed.pc=fetch_packet[lane].pc;renamed.inst=fetch_packet[lane].inst;
          renamed.predicted_pc=fetch_packet[lane].predicted_pc;renamed.inst_valid=fetch_packet[lane].inst_valid;
          renamed.history=fetch_packet[lane].history;renamed.dec=decoded[lane];
          renamed.bimodal_taken=fetch_packet[lane].bimodal_taken;
          renamed.gshare_taken=fetch_packet[lane].gshare_taken;
          renamed.fault=fetch_packet[lane].fault;renamed.fault_addr=fetch_packet[lane].fault_addr;
          if(fetch_packet[lane].fault!=0 || decoded[lane].illegal) begin
            renamed.completed=1;renamed.dec.writes_rd=0;
            if(fetch_packet[lane].fault==0) begin renamed.fault=FAULT_ILLEGAL;renamed.fault_addr=fetch_packet[lane].pc;end
          end else begin
            renamed_iq='0;renamed_iq.valid=1;renamed_iq.rid=rid_t'(index);renamed_iq.generation=renamed.generation;
            renamed_iq.src1=decoded[lane].uses_rs1 ? rat_d[decoded[lane].rs1]:preg_t'(0);
            renamed_iq.src2=decoded[lane].uses_rs2 ? rat_d[decoded[lane].rs2]:preg_t'(0);
            renamed.src1=renamed_iq.src1;renamed.src2=renamed_iq.src2;
            iq_allocate[lane]=1;iq_allocate_slot[lane]=IQW'(iqslot);
            iq_allocate_data[lane]=renamed_iq;
            for(integer row=0;row<IQ_ENTRIES;row=row+1)
              if(row==iqslot) begin
                iq_work[row]='0;iq_work[row].valid=1;
              end
            if(decoded[lane].op==OP_LOAD) begin
`ifndef SYNTHESIS
              for(integer k=0;k<32;k=k+1) checkpoint_map[k*PW+:PW]=rat_d[k];
              checkpoint_data[lane]=checkpoint_map;
`endif
              renamed_load='0;renamed_load.valid=1;renamed_load.rid=rid_t'(index);renamed_load.generation=renamed.generation;
              renamed_load.size=decoded[lane].mem_size;renamed_load.sign_extend=decoded[lane].load_signed;
              renamed.lqid=LW'(lqid);
              load_allocate[lane]=1;load_allocate_slot[lane]=LW'(lqid);
              load_allocate_data[lane]=renamed_load;
              for(integer row=0;row<LQ_ENTRIES;row=row+1)
                if(row==lqid) begin
                  load_work[row]='0;load_work[row].valid=1;
                end
            end
            if(decoded[lane].writes_rd) begin
              renamed.pdst=preg_t'(pdst);renamed.old_pdst=rat_d[decoded[lane].rd];
              rat_d[decoded[lane].rd]=preg_t'(pdst);free_d[pdst]=0;ready_d[pdst]=0;
            end
`ifndef SYNTHESIS
            if(is_branch(decoded[lane].op)) begin
              for(integer k=0;k<32;k=k+1) checkpoint_map[k*PW+:PW]=rat_d[k];
              checkpoint_data[lane]=checkpoint_map;
            end
`endif
            if(is_branch(decoded[lane].op) || decoded[lane].op==OP_LOAD) begin
              checkpoint_valid[lane]=1;checkpoint_rid[lane]=rid_t'(index);
              checkpoint_ras[lane]=fetch_packet[lane].ras_snapshot;
              checkpoint_ras_count[lane]=fetch_packet[lane].ras_count;
            end
            if(decoded[lane].op==OP_STORE) sq_count_d=sq_count_d+1;
          end
          rename_valid[lane]=1;rename_rid[lane]=rid_t'(index);rename_result[lane]=renamed;
          tail_d=rid_t'((index+1)%ROB_ENTRIES);count_d=count_d+1'b1;fetch_pop=fetch_pop+3'd1;
        end else prefix=0;
      end else prefix=0;
    end

    if(trigger_exit || state_d==FAULT) begin
      for(integer k=0;k<IQ_ENTRIES;k=k+1) iq_work[k].valid=0;
      for(integer k=0;k<4;k=k+1) ex_d[k].valid=0;
      mdu_pending_d=0;
      for(integer k=0;k<LQ_ENTRIES;k=k+1) if(load_work[k].valid) begin
        load_work[k].canceled=1;load_work[k].value_ready=0;
        if(!load_work[k].queued || load_work[k].returned) load_work[k].valid=0;
      end
      if(trigger_exit) begin
        for(integer k=0;k<ROB_ENTRIES;k=k+1) if(k!=int'(head_d)) retire_live[k]=0;
        for(integer k=0;k<32;k=k+1) rat_d[k]=rrat_d[k];
        free_d='1;for(integer k=0;k<32;k=k+1) free_d[rrat_d[k]]=0;
        count_d=1;tail_d=rid_t'((int'(head_d)+1)%ROB_ENTRIES);sq_count_d=1;
      end
    end

    if(system_error && state_q!=DONE && state_q!=FAULT && state_d!=FAULT) begin
      state_d=FAULT;fault_cause_d=FAULT_STORE_BUS;fault_pc_d=rob_col_pc[head_q];
      fault_inst_d=rob_col_inst[head_q];fault_inst_valid_d=rob_col_inst_valid[head_q];fault_addr_d=0;
    end
    if(state_q==EXITING && exit_accept && !system_error) begin
      state_d=DONE;retire_valid_d=4'b0001;retire_store_d=4'b0001;
      retire_pc_d[31:0]=rob_col_pc[head_q];retire_inst_d[31:0]=rob_col_inst[head_q];
      retire_addr_d[31:0]=32'h80000000;retire_wdata_d[31:0]=exit_value_q;retire_wstrb_d[3:0]=4'hf;
      retired_count_d=retired_count+64'd1;
      for(integer row=0;row<ROB_ENTRIES;row=row+1)
        if(rid_t'(row)==head_q) retire_live[row]=0;
      count_d=0;sq_count_d=0;
    end
    free_d[0]=0;ready_d[0]=1;prf_d[0]=0;rat_d[0]=0;rrat_d[0]=0;
  end

  for(genvar row=0;row<IQ_ENTRIES;row=row+1) begin: queue_iq_state
    always_comb begin
      iq_d[row]=iq_q[row];
      for(integer lane=0;lane<RENAME_WIDTH;lane=lane+1)
        if(iq_allocate[lane] && iq_allocate_slot[lane]==IQW'(row))
          iq_d[row]=iq_allocate_data[lane];
      iq_d[row].valid=iq_work[row].valid;
      iq_d[row].address_sent=iq_work[row].address_sent;
      iq_d[row].wait_store=iq_work[row].wait_store;
      iq_d[row].wait_rid=iq_work[row].wait_rid;
    end
  end
  for(genvar row=0;row<LQ_ENTRIES;row=row+1) begin: queue_load_state
    always_comb begin
      lq_d[row]=execute_lq[row];
      for(integer lane=0;lane<RENAME_WIDTH;lane=lane+1)
        if(load_allocate[lane] && load_allocate_slot[lane]==LW'(row))
          lq_d[row]=load_allocate_data[lane];
      lq_d[row].valid=load_work[row].valid;
      lq_d[row].queued=load_work[row].queued;
      lq_d[row].canceled=load_work[row].canceled;
      lq_d[row].value_ready=load_work[row].value_ready;
      lq_d[row].returned=load_work[row].returned;
    end
  end
  for(genvar row=0;row<CSB_ENTRIES;row=row+1) begin: queue_store_state
    always_comb begin
      csb_d[row]=execute_csb[row];
      for(integer lane=0;lane<COMMIT_WIDTH;lane=lane+1)
        if(store_allocate[lane] && store_allocate_slot[lane]==CSW'(row))
          csb_d[row]=store_allocate_data[lane];
      csb_d[row].valid=store_work[row].valid;
      csb_d[row].issued=store_work[row].issued;
    end
  end

  // Dispatch produces four bounded event ports. Each entry decodes its own
  // enable, so branch/rename control never multiplexes a whole checkpoint bank.
  for(genvar row=0;row<ROB_ENTRIES;row=row+1) begin: dispatch_state
    always_comb begin
      rob_d[row]=writeback_rob[row];rob_d[row].valid=retire_live[row];
`ifndef SYNTHESIS
      map_d[row]=map_q[row];
`endif
      ras_d[row]=ras_q[row];ras_count_d[row]=ras_count_q[row];
      for(integer lane=0;lane<RENAME_WIDTH;lane=lane+1) begin
        if(rename_valid[lane] && rename_rid[lane]==rid_t'(row)) rob_d[row]=rename_result[lane];
        if(checkpoint_valid[lane] && checkpoint_rid[lane]==rid_t'(row)) begin
`ifndef SYNTHESIS
          map_d[row]=checkpoint_data[lane];
`endif
          ras_d[row]=checkpoint_ras[lane];
          ras_count_d[row]=checkpoint_ras_count[lane];
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if(rst) begin
      state_q<=RUN;head_q<=0;tail_q<=0;count_q<=0;sq_count_q<=0;
      csb_head_q<=0;csb_tail_q<=0;csb_count_q<=0;skid_q<='0;last_store_q<=0;mdu_pending_q<=0;exit_value_q<=0;
      fault_pc<=0;fault_inst<=0;fault_addr<=0;fault_inst_valid<=0;fault_cause<=0;
      cycle_count<=0;retired_count<=0;branch_miss_count<=0;load_replay_count<=0;
      retire_valid<=0;retire_store<=0;retire_pc<=0;retire_inst<=0;retire_value<=0;retire_addr<=0;
      retire_wdata<=0;retire_rd<=0;retire_wstrb<=0;
      for(integer k=0;k<ROB_ENTRIES;k=k+1) begin
        rob_q[k]<='0;ras_q[k]<=0;ras_count_q[k]<=0;
`ifndef SYNTHESIS
        map_q[k]<=0;
`endif
      end
      for(integer k=0;k<IQ_ENTRIES;k=k+1) iq_q[k]<='0;
      for(integer k=0;k<LQ_ENTRIES;k=k+1) lq_q[k]<='0;
      for(integer k=0;k<CSB_ENTRIES;k=k+1) csb_q[k]<='0;
      for(integer k=0;k<4;k=k+1) ex_q[k]<='0;
      for(integer k=0;k<32;k=k+1) begin rat_q[k]<=preg_t'(k);rrat_q[k]<=preg_t'(k);end
      for(integer k=0;k<PHYS_REGS;k=k+1) begin prf_q[k]<=0;ready_q[k]<=(k<32);free_q[k]<=(k>=32);end
    end else begin
      state_q<=state_d;head_q<=head_d;tail_q<=tail_d;count_q<=count_d;sq_count_q<=sq_count_d;
      csb_head_q<=csb_head_d;csb_tail_q<=csb_tail_d;csb_count_q<=csb_count_d;skid_q<=skid_d;
      last_store_q<=last_store_d;mdu_pending_q<=mdu_pending_d;exit_value_q<=exit_value_d;
      fault_pc<=fault_pc_d;fault_inst<=fault_inst_d;fault_addr<=fault_addr_d;
      fault_inst_valid<=fault_inst_valid_d;fault_cause<=fault_cause_d;
      if(state_q!=DONE && state_q!=FAULT) cycle_count<=cycle_count+64'd1;
      retired_count<=retired_count_d;branch_miss_count<=branch_miss_count_d;load_replay_count<=load_replay_count_d;
      retire_valid<=retire_valid_d;retire_store<=retire_store_d;retire_pc<=retire_pc_d;retire_inst<=retire_inst_d;
      retire_value<=retire_value_d;retire_addr<=retire_addr_d;retire_wdata<=retire_wdata_d;retire_rd<=retire_rd_d;retire_wstrb<=retire_wstrb_d;
      for(integer k=0;k<ROB_ENTRIES;k=k+1) begin
        rob_q[k]<=rob_d[k];ras_q[k]<=ras_d[k] & RAS_MASK;ras_count_q[k]<=ras_count_d[k];
`ifndef SYNTHESIS
        map_q[k]<=map_d[k];
`endif
      end
      for(integer k=0;k<IQ_ENTRIES;k=k+1) iq_q[k]<=iq_d[k];
      for(integer k=0;k<LQ_ENTRIES;k=k+1) lq_q[k]<=lq_d[k];
      for(integer k=0;k<CSB_ENTRIES;k=k+1) csb_q[k]<=csb_d[k];
      for(integer k=0;k<4;k=k+1) ex_q[k]<=ex_d[k];
      for(integer k=0;k<32;k=k+1) begin rat_q[k]<=rat_d[k];rrat_q[k]<=rrat_d[k];end
      for(integer k=0;k<PHYS_REGS;k=k+1) prf_q[k]<=prf_d[k];
      free_q<=free_d;ready_q<=ready_d;
    end
  end
  initial begin
    if((FETCH_WIDTH!=1 && FETCH_WIDTH!=2 && FETCH_WIDTH!=4) ||
       (RENAME_WIDTH!=1 && RENAME_WIDTH!=2 && RENAME_WIDTH!=4) ||
       (ISSUE_WIDTH!=1 && ISSUE_WIDTH!=2 && ISSUE_WIDTH!=4) ||
       (WB_WIDTH!=1 && WB_WIDTH!=2 && WB_WIDTH!=4) ||
       (COMMIT_WIDTH!=1 && COMMIT_WIDTH!=2 && COMMIT_WIDTH!=4)) $fatal(1,"Widths must be 1,2,4");
    if(PHYS_REGS<32+RENAME_WIDTH || ROB_ENTRIES<4 || ROB_ENTRIES>128 || IQ_ENTRIES<1 ||
       LQ_ENTRIES<1 || LQ_ENTRIES>128 || SQ_ENTRIES<1 || CSB_ENTRIES<4 || CSB_ENTRIES>128)
      $fatal(1,"Invalid core capacities");
  end
`ifndef SYNTHESIS
  always_ff @(posedge clk) if(!rst) begin
    if(redirect && state_q==RUN) for(integer k=0;k<32;k=k+1)
      assert(recovery_map[k]==map_q[recovery_rid][k*PW+:PW])
        else $fatal(1,"Reconstructed RAT differs from rename-time checkpoint x%0d",k);
    assert(int'(count_q)<=ROB_ENTRIES) else $fatal(1,"ROB count overflow");
    assert(int'(sq_count_q)<=SQ_ENTRIES) else $fatal(1,"SQ count");
    assert(int'(csb_count_q)<=CSB_ENTRIES) else $fatal(1,"CSB count");
    assert(prf_q[0]==0 && ready_q[0] && !free_q[0]) else $fatal(1,"x0");
    for(integer k=0;k<32;k=k+1) begin
      assert(!free_q[rrat_q[k]]) else $fatal(1,"Committed mapping free");
      if(state_q==RUN) assert(!free_q[rat_q[k]]) else $fatal(1,"Speculative mapping free");
    end
    for(integer k=0;k<LQ_ENTRIES;k=k+1)
      if(lq_q[k].valid && !lq_q[k].canceled) assert(live(lq_q[k].rid,lq_q[k].generation)) else $fatal(1,"LQ identity");
  end
`endif
endmodule
