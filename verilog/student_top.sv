// ParaRisc RV32IM: two-wide out-of-order issue, ordered retirement, SRAM caches.
module student_top #(
  parameter integer ROB_BITS = 4,
  parameter integer IC_INDEX_BITS = 8,
  parameter integer DC_INDEX_BITS = 9,
  parameter integer DC_LINE_BITS = 6
) (
  input wire clock, reset,
  output wire [31:0] araddr,
  output wire arvalid,
  input wire arready,
  input wire [31:0] rdata,
  input wire [1:0] rresp,
  input wire rvalid,
  output wire rready,
  output wire [31:0] awaddr,
  output wire awvalid,
  input wire awready,
  output wire [31:0] wdata,
  output wire [3:0] wstrb,
  output wire wvalid,
  input wire wready,
  input wire [1:0] bresp,
  input wire bvalid,
  output wire bready
);
  wire f_valid, f_ready, f_two, redirect;
  wire [31:0] f_pc, f_i0, f_i1, f_p0, f_p1, redirect_pc;
  wire frontend_redirect;
  wire [31:0] frontend_redirect_pc;
  wire train_valid, train_taken, train_cond, train_ind;
  wire [31:0] train_pc, train_target;
  wire ic_req, ic_ready, ic_resp, ic_resp_ready;
  wire [31:0] ic_addr;
  wire [255:0] ic_line;
  wire load_req, load_ready, load_resp, load_resp_ready;
  wire [31:0] load_addr, load_data;
  wire [4:0] load_word;
  wire st_valid, st_ready;
  wire [31:0] st_addr, st_data;
  wire [3:0] st_mask;
  wire bus_fault;
  pararisc_frontend frontend (
    .clock(clock), .reset(reset), .redirect(frontend_redirect), .redirect_pc(frontend_redirect_pc),
    .valid(f_valid), .ready(f_ready), .pc0(f_pc), .insn0(f_i0), .insn1(f_i1), .pred0(f_p0), .pred1(f_p1), .two(f_two),
    .train_valid(train_valid), .train_pc(train_pc), .train_target(train_target), .train_taken(train_taken),
    .train_conditional(train_cond), .train_indirect(train_ind), .cache_valid(ic_req), .cache_ready(ic_ready),
    .cache_addr(ic_addr), .cache_resp_valid(ic_resp), .cache_resp_ready(ic_resp_ready), .cache_line(ic_line)
  );
  pararisc_backend #(.ROB_BITS(ROB_BITS)) backend (
    .clock(clock), .reset(reset), .bus_fault(bus_fault),
    .fetch_valid(f_valid), .fetch_ready(f_ready), .fetch_two(f_two), .fetch_pc(f_pc),
    .fetch_i0(f_i0), .fetch_i1(f_i1), .fetch_pred0(f_p0), .fetch_pred1(f_p1),
    .redirect(redirect), .redirect_pc(redirect_pc), .frontend_redirect(frontend_redirect),
    .frontend_redirect_pc(frontend_redirect_pc), .train_valid(train_valid), .train_pc(train_pc),
    .train_target(train_target), .train_taken(train_taken), .train_conditional(train_cond), .train_indirect(train_ind),
    .store_valid(st_valid), .store_ready(st_ready), .store_addr(st_addr), .store_data(st_data), .store_mask(st_mask),
    .load_valid(load_req), .load_ready(load_ready), .load_addr(load_addr), .load_word(load_word), .load_resp_valid(load_resp),
    .load_resp_ready(load_resp_ready), .load_resp_data(load_data)
  );

  reg [31:0] sq_addr [0:15], sq_data [0:15];
  reg [3:0] sq_mask [0:15];
  reg [3:0] sq_head, sq_tail;
  reg [4:0] sq_count;
  wire push = st_valid && st_ready;
  wire dc_ready;
  wire pop = sq_count != 0 && dc_ready;
  assign st_ready = sq_count < 16;
  assign load_ready = sq_count == 0 && !push && dc_ready;
  wire dc_req = sq_count != 0 || (load_req && !push);
  wire [31:0] dc_addr = sq_count != 0 ? sq_addr[sq_head] : load_addr;
  wire [32*(1<<(DC_LINE_BITS-2))-1:0] dc_line;
  always @(posedge clock) begin
    if (reset) begin sq_head <= 0; sq_tail <= 0; sq_count <= 0; end
    else begin
      if (push) begin
        sq_addr[sq_tail] <= st_addr; sq_data[sq_tail] <= st_data; sq_mask[sq_tail] <= st_mask;
        sq_tail <= sq_tail + 1;
      end
      if (pop) sq_head <= sq_head + 1;
      case ({push,pop})
        2'b10: sq_count <= sq_count+1;
        2'b01: sq_count <= sq_count-1;
        default: begin end
      endcase
    end
  end
  wire i_miss, d_miss, i_miss_ready, d_miss_ready, i_refill, d_refill;
  wire [31:0] i_miss_addr, d_miss_addr, refill_data;
  wire [4:0] refill_beat;
  wire bus_store_valid, bus_store_ready;
  wire [31:0] bus_store_addr, bus_store_data;
  wire [3:0] bus_store_mask;
  pararisc_cache #(.INDEX_BITS(IC_INDEX_BITS), .READ_ONLY(1)) icache (
    .clock(clock), .reset(reset), .req_valid(ic_req), .req_ready(ic_ready), .req_addr(ic_addr),
    .req_data(32'b0), .req_mask(4'b0), .req_write(1'b0), .req_invalidate(1'b0), .resp_valid(ic_resp), .resp_ready(ic_resp_ready), .resp_line(ic_line),
    .miss_req(i_miss), .miss_addr(i_miss_addr), .miss_ready(i_miss_ready), .refill_valid(i_refill),
    .refill_beat(refill_beat[2:0]), .refill_data(refill_data), .store_valid(), .store_addr(), .store_data(), .store_mask(), .store_ready(1'b1)
  );
  wire l1_req, l1_ready, l1_invalidate, l1_resp, l1_resp_ready;
  wire [31:0] l1_addr;
  wire update_valid, update_ready, memory_ready;
  wire [31:0] update_addr, update_data;
  wire [3:0] update_mask;
  reg [31:0] updates_addr [0:15], updates_data [0:15];
  reg [3:0] updates_mask [0:15];
  reg [3:0] updates_head, updates_tail;
  reg [4:0] updates_count;
  wire update_push=update_valid && update_ready;
  wire update_pop=updates_count!=0 && memory_ready;
  assign update_ready=updates_count<16;
  assign l1_ready=updates_count==0 && !update_push && memory_ready;
  always @(posedge clock) begin
    if (reset) begin updates_head<=0; updates_tail<=0; updates_count<=0; end
    else begin
      if (update_push) begin
        updates_addr[updates_tail]<=update_addr; updates_data[updates_tail]<=update_data;
        updates_mask[updates_tail]<=update_mask; updates_tail<=updates_tail+1;
      end
      if (update_pop) updates_head<=updates_head+1;
      case ({update_push,update_pop})
        2'b10: updates_count<=updates_count+1;
        2'b01: updates_count<=updates_count-1;
        default: begin end
      endcase
    end
  end
  pararisc_l0 #(.LINE_BITS(DC_LINE_BITS)) data_buffer (
    .clock(clock), .reset(reset), .req_valid(dc_req), .req_ready(dc_ready), .req_addr(dc_addr),
    .req_data(sq_data[sq_head]), .req_mask(sq_mask[sq_head]), .req_write(sq_count != 0),
    .resp_valid(load_resp), .resp_ready(load_resp_ready), .resp_data(load_data),
    .cache_req(l1_req), .cache_ready(l1_ready), .cache_addr(l1_addr), .cache_invalidate(l1_invalidate),
    .cache_resp_valid(l1_resp), .cache_resp_ready(l1_resp_ready), .cache_line(dc_line),
    .store_valid(update_valid), .store_addr(update_addr), .store_data(update_data),
    .store_mask(update_mask), .store_ready(update_ready)
  );
  pararisc_cache #(.INDEX_BITS(DC_INDEX_BITS), .LINE_BITS(DC_LINE_BITS)) dcache (
    .clock(clock), .reset(reset), .req_valid(updates_count!=0 || (l1_req && !update_push)),
    .req_ready(memory_ready), .req_addr(updates_count!=0 ? updates_addr[updates_head] : l1_addr),
    .req_data(updates_data[updates_head]), .req_mask(updates_mask[updates_head]), .req_write(updates_count!=0), .req_invalidate(1'b0),
    .resp_valid(l1_resp), .resp_ready(l1_resp_ready), .resp_line(dc_line),
    .miss_req(d_miss), .miss_addr(d_miss_addr), .miss_ready(d_miss_ready), .refill_valid(d_refill),
    .refill_beat(refill_beat[DC_LINE_BITS-3:0]), .refill_data(refill_data),
    .store_valid(bus_store_valid), .store_addr(bus_store_addr), .store_data(bus_store_data),
    .store_mask(bus_store_mask), .store_ready(bus_store_ready)
  );
  pararisc_bus #(.DC_LINE_BITS(DC_LINE_BITS)) bus (
    .clock(clock), .reset(reset), .i_req(i_miss), .d_req(d_miss), .i_addr(i_miss_addr), .d_addr(d_miss_addr),
    .i_ready(i_miss_ready), .d_ready(d_miss_ready), .i_valid(i_refill), .d_valid(d_refill), .beat(refill_beat), .refill_data(refill_data),
    .store_valid(bus_store_valid), .store_ready(bus_store_ready), .store_addr(bus_store_addr), .store_data(bus_store_data), .store_mask(bus_store_mask),
    .fault(bus_fault), .araddr(araddr), .arvalid(arvalid), .arready(arready), .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready),
    .awaddr(awaddr), .awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb), .wvalid(wvalid), .wready(wready),
    .bresp(bresp), .bvalid(bvalid), .bready(bready)
  );
`ifndef SYNTHESIS
  reg [63:0] stat_cycles, stat_retired, stat_dual, stat_branch, stat_redirect;
  reg [63:0] stat_load, stat_store, stat_i_miss, stat_d_miss, stat_full, stat_load_busy;
  always @(posedge clock) begin
    if (reset) begin
      stat_cycles <= 0; stat_retired <= 0; stat_dual <= 0; stat_branch <= 0; stat_redirect <= 0;
      stat_load <= 0; stat_store <= 0; stat_i_miss <= 0; stat_d_miss <= 0; stat_full <= 0; stat_load_busy <= 0;
    end else begin
      stat_cycles <= stat_cycles+1;
      stat_retired <= stat_retired+64'(backend.retire0)+64'(backend.retire1);
      if (backend.retire1) stat_dual <= stat_dual+1;
      if (train_valid) stat_branch <= stat_branch+1;
      if (redirect) stat_redirect <= stat_redirect+1;
      if (load_req && load_ready) stat_load <= stat_load+1;
      if (push) stat_store <= stat_store+1;
      if (i_miss && i_miss_ready) stat_i_miss <= stat_i_miss+1;
      if (d_miss && d_miss_ready) stat_d_miss <= stat_d_miss+1;
      if (f_valid && !f_ready) stat_full <= stat_full+1;
      if (backend.ld_active) stat_load_busy <= stat_load_busy+1;
    end
  end
  final $fdisplay(32'h80000002,
    "PARARISC cycles=%0d retired=%0d dual=%0d branches=%0d redirects=%0d loads=%0d stores=%0d imiss=%0d dmiss=%0d dispatch_stall=%0d load_busy=%0d",
    stat_cycles,stat_retired,stat_dual,stat_branch,stat_redirect,stat_load,stat_store,stat_i_miss,stat_d_miss,stat_full,stat_load_busy);
`endif
endmodule
