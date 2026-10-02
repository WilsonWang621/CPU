// Unified external port and precise exit sequencing around the speculative core.
module cpu_top #(
  parameter integer FETCH_WIDTH=4, RENAME_WIDTH=4, ISSUE_WIDTH=4, WB_WIDTH=4,
  parameter integer COMMIT_WIDTH=4, PHYS_REGS=128, ROB_ENTRIES=64, IQ_ENTRIES=32,
  parameter integer LQ_ENTRIES=32, SQ_ENTRIES=32, CSB_ENTRIES=32,
  parameter integer FETCH_QUEUE_ENTRIES=32, ICACHE_BYTES=4096, ICACHE_WAYS=2,
  parameter integer DCACHE_BYTES=16384, DCACHE_WAYS=4, LINE_BYTES=32,
  parameter integer I_MSHRS=4, D_MSHRS=8, BHT_ENTRIES=2048, BTB_ENTRIES=256,
  parameter integer RAS_DEPTH=16, RAM_BYTES=262144,
  parameter integer FETCH_REQUESTS=16, MAX_MEM_OUTSTANDING=64,
  parameter integer PREDICTOR_MODE=2, HISTORY_BITS=8,
  parameter bit PREDICTOR=1
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
  logic i_req_valid, i_req_ready, i_rsp_valid, i_rsp_ready, i_rsp_error;
  logic [31:0] i_req_addr;
  logic [127:0] i_rsp_data;
  logic [2:0] i_req_count;
  logic [7:0] i_req_tag, i_rsp_tag;
  logic [3:0] i_rsp_error_mask;
  logic d_req_valid, d_req_ready, d_req_write, d_rsp_valid, d_rsp_ready, d_rsp_error;
  logic [31:0] d_req_addr, d_req_wdata;
  logic [3:0] d_req_wstrb;
  logic [7:0] d_req_tag, d_rsp_tag;
  logic [127:0] d_rsp_data;
  logic i_idle, d_idle, controller_idle, frontend_idle;
  logic d_flush_valid, d_flush_done, d_flush_error;
  logic [1:0] s_req_valid, s_req_ready, s_req_write, s_rsp_valid, s_rsp_ready, s_rsp_error;
  logic [63:0] s_req_addr, s_req_wdata, s_rsp_rdata;
  logic [7:0] s_req_wstrb;
  logic bus_req_valid, bus_req_ready, bus_req_write, bus_rsp_valid, bus_rsp_ready;
  logic [31:0] bus_req_addr, bus_req_wdata;
  logic [3:0] bus_req_wstrb;
  logic exit_pending, exit_accept, stores_empty, system_error;
  logic [31:0] exit_value, exit_value_q;
  logic error_q, quiescent;
  typedef enum logic [3:0] {
    X_RUN, X_DRAIN, X_QUIESCE, X_FLUSH, X_WAIT_WRITES, X_SEND_EXIT, X_DONE, X_ERROR
  } exit_state_t;
  exit_state_t exit_state;

  initial begin
    if (BHT_ENTRIES < 2 || (BHT_ENTRIES & (BHT_ENTRIES-1)) != 0 ||
        BTB_ENTRIES < 2 || (BTB_ENTRIES & (BTB_ENTRIES-1)) != 0)
      $fatal(1, "BHT and BTB entries must be powers of two and at least two");
    if (RAS_DEPTH < 0) $fatal(1, "RAS_DEPTH must be nonnegative");
    if (RAM_BYTES < LINE_BYTES || RAM_BYTES % LINE_BYTES != 0)
      $fatal(1, "RAM_BYTES must be positive and contain complete cache lines");
    if (MAX_MEM_OUTSTANDING<1) $fatal(1, "At least one memory credit is required");
  end

  core #(
    .FETCH_WIDTH(FETCH_WIDTH), .RENAME_WIDTH(RENAME_WIDTH), .ISSUE_WIDTH(ISSUE_WIDTH),
    .WB_WIDTH(WB_WIDTH), .COMMIT_WIDTH(COMMIT_WIDTH), .PHYS_REGS(PHYS_REGS),
    .ROB_ENTRIES(ROB_ENTRIES), .IQ_ENTRIES(IQ_ENTRIES), .LQ_ENTRIES(LQ_ENTRIES),
    .SQ_ENTRIES(SQ_ENTRIES), .CSB_ENTRIES(CSB_ENTRIES),
    .FETCH_QUEUE_ENTRIES(FETCH_QUEUE_ENTRIES), .ICACHE_BYTES(ICACHE_BYTES),
    .ICACHE_WAYS(ICACHE_WAYS), .DCACHE_BYTES(DCACHE_BYTES), .DCACHE_WAYS(DCACHE_WAYS),
    .LINE_BYTES(LINE_BYTES), .I_MSHRS(I_MSHRS), .D_MSHRS(D_MSHRS),
    .BHT_ENTRIES(BHT_ENTRIES), .BTB_ENTRIES(BTB_ENTRIES), .RAS_DEPTH(RAS_DEPTH),
    .RAM_BYTES(RAM_BYTES), .PREDICTOR(PREDICTOR),
    .FETCH_REQUESTS(FETCH_REQUESTS), .MAX_MEM_OUTSTANDING(MAX_MEM_OUTSTANDING),
    .PREDICTOR_MODE(PREDICTOR_MODE), .HISTORY_BITS(HISTORY_BITS)
  ) core_i (
    .clk, .rst,
    .i_req_valid, .i_req_ready, .i_req_addr, .i_req_count, .i_req_tag,
    .i_rsp_valid, .i_rsp_ready, .i_rsp_data, .i_rsp_tag, .i_rsp_error, .i_rsp_error_mask,
    .d_req_valid, .d_req_ready, .d_req_write, .d_req_addr, .d_req_wdata, .d_req_wstrb,
    .d_req_tag, .d_rsp_valid, .d_rsp_ready, .d_rsp_data, .d_rsp_tag, .d_rsp_error,
    .exit_pending, .exit_value, .stores_empty, .frontend_idle, .exit_accept, .system_error,
    .halted, .faulted, .fault_pc, .fault_inst, .fault_inst_valid, .fault_cause, .fault_addr,
    .retire_valid, .retire_pc, .retire_inst, .retire_rd, .retire_value,
    .retire_store, .retire_addr, .retire_wdata, .retire_wstrb,
    .cycle_count, .retired_count, .branch_miss_count, .load_replay_count
  );

  cache #(.CACHE_BYTES(ICACHE_BYTES), .WAYS(ICACHE_WAYS), .LINE_BYTES(LINE_BYTES),
          .READ_ONLY(1), .MSHRS(I_MSHRS), .WAITERS(FETCH_REQUESTS), .TAG_BITS(8),
          .MAX_MEM_OUTSTANDING(MAX_MEM_OUTSTANDING)) icache (
    .clk, .rst,
    .cpu_req_valid(i_req_valid), .cpu_req_ready(i_req_ready), .cpu_req_write(1'b0),
    .cpu_req_addr(i_req_addr), .cpu_req_count(i_req_count), .cpu_req_wdata(32'b0),
    .cpu_req_wstrb(4'b0), .cpu_req_tag(i_req_tag),
    .cpu_rsp_valid(i_rsp_valid), .cpu_rsp_ready(i_rsp_ready), .cpu_rsp_data(i_rsp_data),
    .cpu_rsp_tag(i_rsp_tag), .cpu_rsp_error(i_rsp_error), .cpu_rsp_error_mask(i_rsp_error_mask),
    .flush_valid(1'b0), .flush_done(), .flush_error(), .idle(i_idle), .miss_count(icache_miss_count),
    .mem_req_valid(s_req_valid[0]), .mem_req_ready(s_req_ready[0]),
    .mem_req_write(s_req_write[0]), .mem_req_addr(s_req_addr[31:0]),
    .mem_req_wdata(s_req_wdata[31:0]), .mem_req_wstrb(s_req_wstrb[3:0]),
    .mem_rsp_valid(s_rsp_valid[0]), .mem_rsp_ready(s_rsp_ready[0]),
    .mem_rsp_rdata(s_rsp_rdata[31:0]), .mem_rsp_error(s_rsp_error[0])
  );
  cache #(.CACHE_BYTES(DCACHE_BYTES), .WAYS(DCACHE_WAYS), .LINE_BYTES(LINE_BYTES),
          .READ_ONLY(0), .MSHRS(D_MSHRS), .TAG_BITS(8), .MAX_MEM_OUTSTANDING(MAX_MEM_OUTSTANDING),
          .MAX_CPU_WORDS(1)) dcache (
    .clk, .rst,
    .cpu_req_valid(d_req_valid), .cpu_req_ready(d_req_ready), .cpu_req_write(d_req_write),
    .cpu_req_addr(d_req_addr), .cpu_req_count(3'd1), .cpu_req_wdata(d_req_wdata), .cpu_req_wstrb(d_req_wstrb),
    .cpu_req_tag(d_req_tag), .cpu_rsp_valid(d_rsp_valid), .cpu_rsp_ready(d_rsp_ready),
    .cpu_rsp_data(d_rsp_data), .cpu_rsp_tag(d_rsp_tag), .cpu_rsp_error(d_rsp_error), .cpu_rsp_error_mask(),
    .flush_valid(d_flush_valid), .flush_done(d_flush_done), .flush_error(d_flush_error),
    .idle(d_idle), .miss_count(dcache_miss_count),
    .mem_req_valid(s_req_valid[1]), .mem_req_ready(s_req_ready[1]),
    .mem_req_write(s_req_write[1]), .mem_req_addr(s_req_addr[63:32]),
    .mem_req_wdata(s_req_wdata[63:32]), .mem_req_wstrb(s_req_wstrb[7:4]),
    .mem_rsp_valid(s_rsp_valid[1]), .mem_rsp_ready(s_rsp_ready[1]),
    .mem_rsp_rdata(s_rsp_rdata[63:32]), .mem_rsp_error(s_rsp_error[1])
  );

  memory_controller #(.MAX_MEM_OUTSTANDING(MAX_MEM_OUTSTANDING)) memory_i (
    .clk, .rst, .s_req_valid, .s_req_ready, .s_req_write, .s_req_addr, .s_req_wdata,
    .s_req_wstrb, .s_rsp_valid, .s_rsp_ready, .s_rsp_rdata, .s_rsp_error,
    .mem_req_valid(bus_req_valid), .mem_req_ready(bus_req_ready),
    .mem_req_write(bus_req_write), .mem_req_addr(bus_req_addr),
    .mem_req_wdata(bus_req_wdata), .mem_req_wstrb(bus_req_wstrb),
    .mem_rsp_valid(bus_rsp_valid), .mem_rsp_ready(bus_rsp_ready),
    .mem_rsp_rdata, .mem_rsp_error, .idle(controller_idle)
  );

  assign quiescent = i_idle && d_idle && controller_idle && frontend_idle &&
                     stores_empty && !i_req_valid && !d_req_valid;
  assign d_flush_valid = exit_state == X_FLUSH;
  assign system_error = error_q || d_flush_error;
  assign exit_accept = exit_state == X_SEND_EXIT && mem_req_valid && mem_req_ready;

  // The bus switches owners only after all cache requests and responses drain.
  // During SEND_EXIT the payload is latched and valid is never withdrawn.
  always_comb begin
    mem_req_valid = bus_req_valid;
    mem_req_write = bus_req_write;
    mem_req_addr = bus_req_addr;
    mem_req_wdata = bus_req_wdata;
    mem_req_wstrb = bus_req_wstrb;
    mem_rsp_ready = bus_rsp_ready;
    bus_req_ready = mem_req_ready;
    bus_rsp_valid = mem_rsp_valid;
    if (exit_state == X_SEND_EXIT || exit_state == X_DONE) begin
      mem_req_valid = !rst && exit_state == X_SEND_EXIT;
      mem_req_write = 1'b1;
      mem_req_addr = 32'h80000000;
      mem_req_wdata = exit_value_q;
      mem_req_wstrb = 4'b1111;
      mem_rsp_ready = !rst;
      bus_req_ready = 1'b0;
      bus_rsp_valid = 1'b0;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      exit_state <= X_RUN;
      exit_value_q <= 32'b0;
      error_q <= 1'b0;
    end else begin
      if (d_flush_error) error_q <= 1'b1;
      if (system_error && exit_state != X_SEND_EXIT && exit_state != X_DONE) begin
        exit_state <= X_ERROR;
      end else begin
        case (exit_state)
          X_RUN: if (exit_pending) begin
            exit_value_q <= exit_value;
            exit_state <= X_DRAIN;
          end
          X_DRAIN: if (stores_empty) exit_state <= X_QUIESCE;
          X_QUIESCE: if (quiescent) exit_state <= X_FLUSH;
          X_FLUSH: if (d_flush_done) exit_state <= X_WAIT_WRITES;
          X_WAIT_WRITES: if (quiescent) exit_state <= X_SEND_EXIT;
          X_SEND_EXIT: if (exit_accept) exit_state <= X_DONE;
          X_DONE, X_ERROR: ;
          default: exit_state <= X_ERROR;
        endcase
      end
    end
  end
endmodule
