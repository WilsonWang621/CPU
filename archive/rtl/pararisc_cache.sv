// Blocking 32-byte direct-mapped cache, using only synchronous 1RW SRAMs.
// Valid bits are 64-bit SRAM rows: reset clears one row/cycle, not thousands of flops.
module pararisc_cache #(
  parameter integer INDEX_BITS = 10,
  parameter integer LINE_BITS = 5,
  parameter integer READ_ONLY = 0
) (
  input wire clock, reset,
  input wire req_valid,
  output wire req_ready,
  input wire [31:0] req_addr, req_data,
  input wire [3:0] req_mask,
  input wire req_write,
  input wire req_invalidate,
  output wire resp_valid,
  input wire resp_ready,
  output wire [32*(1<<(LINE_BITS-2))-1:0] resp_line,
  output wire miss_req,
  output wire [31:0] miss_addr,
  input wire miss_ready, refill_valid,
  input wire [LINE_BITS-3:0] refill_beat,
  input wire [31:0] refill_data,
  output wire store_valid,
  output wire [31:0] store_addr, store_data,
  output wire [3:0] store_mask,
  input wire store_ready
);
  localparam integer LINES = 1 << INDEX_BITS;
  localparam integer WORDS = 1 << (LINE_BITS-2);
  localparam integer TAG_BITS = 32 - LINE_BITS - INDEX_BITS;
  localparam integer VALID_BITS = INDEX_BITS - 6;
  localparam integer VALID_ROWS = 1 << VALID_BITS;
  localparam [3:0] INIT=0, IDLE=1, LOOKUP=2, MISS=3, FILL=4, REPLAY=5, RESPONSE=6, STORE=7;
  reg [3:0] state;
  reg [VALID_BITS-1:0] init_row;
  reg [31:0] addr, data;
  reg [3:0] mask;
  reg writing, invalidating, saved_hit, saved_tag_hit;
  reg [WORDS-1:0] saved_word_valid;
  reg [63:0] saved_valid;
  wire [INDEX_BITS-1:0] index = addr[INDEX_BITS+LINE_BITS-1:LINE_BITS];
  wire [INDEX_BITS-1:0] req_index = req_addr[INDEX_BITS+LINE_BITS-1:LINE_BITS];
  wire [TAG_BITS+WORDS-1:0] tag_q;
  wire [32*WORDS-1:0] data_q;
  wire [63:0] valid_q;
  wire tag_hit = valid_q[index[5:0]] && tag_q[TAG_BITS+WORDS-1:WORDS] == addr[31:INDEX_BITS+LINE_BITS];
  wire hit = tag_hit && tag_q[addr[LINE_BITS-1:2]];
  wire accept = req_valid && req_ready;
  assign resp_valid = state == LOOKUP && (invalidating || (!writing && hit));
  assign resp_line = data_q;
  assign req_ready = state == IDLE || (resp_valid && resp_ready && !invalidating);
  assign miss_req = state == MISS;
  assign miss_addr = addr;
  assign store_valid = READ_ONLY == 0 && (state == LOOKUP || state == STORE) && writing;
  assign store_addr = {addr[31:2], 2'b0};
  assign store_data = data;
  assign store_mask = mask;
  wire store_fire = store_valid && store_ready;
  wire store_allocate = store_fire && mask == 4'hf;
  wire data_write = refill_valid || store_allocate || (store_fire && (state == LOOKUP ? hit : saved_hit));
  wire [INDEX_BITS-1:0] ram_addr = accept ? req_index : index;
  wire ram_read = accept || state == REPLAY || (resp_valid && !resp_ready && !invalidating);
  wire [31:0] byte_mask = {{8{mask[3]}}, {8{mask[2]}}, {8{mask[1]}}, {8{mask[0]}}};
  // Store hit merges against the registered line read; SRAM writes whole words.
  reg [31:0] saved_word;
  wire [31:0] old_word = state == LOOKUP ? data_q[addr[LINE_BITS-1:2]*32 +: 32] : saved_word;
  wire [31:0] merged = (old_word & ~byte_mask) | (data & byte_mask);
  wire [31:0] write_word = refill_valid ? refill_data : merged;
  wire [WORDS-1:0] write_mask = WORDS'(1) << (refill_valid ? refill_beat : addr[LINE_BITS-1:2]);
  sram_fakeram #(.DEPTH(LINES), .WIDTH(32*WORDS), .WRITE_GRANULARITY(32)) data_ram (
    .clk(clock), .en(ram_read || data_write), .we(data_write), .wmask(write_mask),
    .addr(ram_addr), .wdata({WORDS{write_word}}), .rdata(data_q)
  );
  wire fill_last = refill_valid && refill_beat == (LINE_BITS-2)'(WORDS-1);
  wire previous_tag_hit = state == LOOKUP ? tag_hit : saved_tag_hit;
  wire [WORDS-1:0] previous_valid = state == LOOKUP ? tag_q[WORDS-1:0] : saved_word_valid;
  wire [WORDS-1:0] new_word_valid = fill_last ? {WORDS{1'b1}} :
    ((previous_tag_hit ? previous_valid : {WORDS{1'b0}}) | (WORDS'(1) << addr[LINE_BITS-1:2]));
  sram_fakeram #(.DEPTH(LINES), .WIDTH(TAG_BITS+WORDS)) tag_ram (
    .clk(clock), .en(ram_read || fill_last || store_allocate), .we(fill_last || store_allocate), .wmask(1'b1),
    .addr(ram_addr), .wdata({addr[31:INDEX_BITS+LINE_BITS],new_word_valid}), .rdata(tag_q)
  );
  wire [VALID_BITS-1:0] valid_addr = state == INIT ? init_row : ram_addr[INDEX_BITS-1:6];
  wire [63:0] previous_valid_row = state == LOOKUP ? valid_q : saved_valid;
  wire invalidate_fire = state == LOOKUP && invalidating && resp_ready;
  wire [63:0] valid_wdata = state == INIT ? 0 :
    (invalidating ? previous_valid_row & ~(64'b1 << index[5:0]) : previous_valid_row | (64'b1 << index[5:0]));
  sram_fakeram #(.DEPTH(VALID_ROWS), .WIDTH(64)) valid_ram (
    .clk(clock), .en(state == INIT || ram_read || fill_last || store_allocate || invalidate_fire),
    .we(state == INIT || fill_last || store_allocate || invalidate_fire), .wmask(1'b1), .addr(valid_addr),
    .wdata(valid_wdata), .rdata(valid_q)
  );
  always @(posedge clock) begin
    if (reset) begin
      state <= INIT; init_row <= 0; addr <= 0; data <= 0; mask <= 0;
      writing <= 0; invalidating <= 0; saved_hit <= 0; saved_tag_hit <= 0; saved_word_valid <= 0; saved_valid <= 0; saved_word <= 0;
    end else begin
      case (state)
        INIT: if (init_row == VALID_ROWS-1) state <= IDLE; else init_row <= init_row + 1;
        LOOKUP: begin
          saved_valid <= valid_q;
          if (invalidating) begin
            if (resp_ready) state <= IDLE;
          end else if (writing) begin
            saved_hit <= hit; saved_tag_hit <= tag_hit; saved_word_valid <= tag_q[WORDS-1:0]; saved_word <= old_word;
            state <= store_ready ? IDLE : STORE;
          end else if (hit) begin
            if (resp_ready) state <= IDLE;
          end else begin saved_valid <= valid_q; state <= MISS; end
        end
        STORE: if (store_ready) state <= IDLE;
        MISS: if (miss_ready) state <= FILL;
        FILL: if (fill_last) state <= REPLAY;
        REPLAY: state <= LOOKUP;
        RESPONSE: if (resp_ready) state <= IDLE;
        default: begin end
      endcase
      if (accept) begin
        addr <= req_addr; data <= req_data; mask <= req_mask;
        writing <= req_write && READ_ONLY == 0; invalidating <= req_invalidate; state <= LOOKUP;
      end
    end
  end
endmodule
