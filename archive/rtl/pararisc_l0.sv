// Four-line fully associative buffer. Hits accept one CPU word per cycle.
// Ordered background updates keep SRAM coherent; misses wait for those updates.
module pararisc_l0 #(parameter integer LINE_BITS=6) (
  input wire clock, reset,
  input wire req_valid,
  output wire req_ready,
  input wire [31:0] req_addr, req_data,
  input wire [3:0] req_mask,
  input wire req_write,
  output wire resp_valid,
  input wire resp_ready,
  output wire [31:0] resp_data,
  output wire cache_req,
  input wire cache_ready,
  output wire [31:0] cache_addr,
  output wire cache_invalidate,
  input wire cache_resp_valid,
  output wire cache_resp_ready,
  input wire [32*(1<<(LINE_BITS-2))-1:0] cache_line,
  output wire store_valid,
  input wire store_ready,
  output wire [31:0] store_addr, store_data,
  output wire [3:0] store_mask
);
  localparam integer WORDS=1<<(LINE_BITS-2);
  localparam [2:0] IDLE=0, INV_REQ=1, INV_WAIT=2, READ_REQ=3, READ_WAIT=4;
  reg [2:0] state;
  reg [31:LINE_BITS] tags [0:3];
  reg [31:0] words [0:4*WORDS-1];
  reg [WORDS-1:0] word_valid [0:3];
  reg [3:0] live, dirty;
  reg [1:0] replacement, target_way;
  reg [31:0] pending_addr, victim_addr;
  reg load_pending;
  reg tag_hit, word_hit;
  reg [1:0] selected;
  reg [31:0] selected_data;
  wire [LINE_BITS-3:0] word_index=req_addr[LINE_BITS-1:2];
  always @* begin
    tag_hit=0; word_hit=0; selected=replacement; selected_data=0;
    for (integer j=0;j<4;j=j+1) begin
      if (live[j] && tags[j]==req_addr[31:LINE_BITS]) begin
        tag_hit=1; selected=2'(j); word_hit=word_valid[j][word_index];
      end
      for (integer w=0;w<WORDS;w=w+1)
        selected_data=selected_data | (words[j*WORDS+w] &
          {32{live[j] && tags[j]==req_addr[31:LINE_BITS] && word_index==(LINE_BITS-2)'(w)}});
    end
  end
  assign req_ready=state==IDLE && (req_write ? store_ready : (!word_hit || resp_ready));
  wire accept=req_valid && req_ready;
  assign resp_valid=(state==IDLE && req_valid && !req_write && word_hit) ||
    (state==READ_WAIT && cache_resp_valid);
  assign resp_data=state==READ_WAIT ? cache_line[pending_addr[LINE_BITS-1:2]*32 +:32] : selected_data;
  assign cache_req=state==INV_REQ || state==READ_REQ;
  assign cache_invalidate=state==INV_REQ;
  assign cache_addr=state==INV_REQ ? victim_addr : pending_addr;
  assign cache_resp_ready=state==INV_WAIT || (state==READ_WAIT && resp_ready);
  assign store_valid=state==IDLE && req_valid && req_write;
  assign store_addr={req_addr[31:2],2'b0};
  assign store_data=req_data;
  assign store_mask=req_mask;
  wire fill=state==READ_WAIT && cache_resp_valid && resp_ready;
  wire do_store=accept && req_write;
  for (genvar j=0;j<4;j=j+1) begin: way
    for (genvar w=0;w<WORDS;w=w+1) begin: word_bank
      always @(posedge clock) begin
        if (fill && target_way==2'(j)) words[j*WORDS+w]<=cache_line[w*32+:32];
        else if (do_store && selected==2'(j) && word_index==(LINE_BITS-2)'(w)) begin
          for (integer b=0;b<4;b=b+1)
            if (req_mask[b]) words[j*WORDS+w][b*8+:8]<=req_data[b*8+:8];
        end
      end
    end
  end
  always @(posedge clock) begin
    if (reset) begin
      state<=IDLE; live<=0; dirty<=0; replacement<=0; target_way<=0;
      pending_addr<=0; victim_addr<=0; load_pending<=0;
      for (integer j=0;j<4;j=j+1) word_valid[j]<=0;
    end else begin
      if (accept) begin
        if (req_write) begin
          if (!tag_hit) begin
            live[selected]<=1; tags[selected]<=req_addr[31:LINE_BITS];
            word_valid[selected]<=req_mask==4'hf ? WORDS'(1)<<word_index : {WORDS{1'b0}};
            replacement<=replacement+1;
          end else if (req_mask==4'hf) word_valid[selected][word_index]<=1;
          dirty[selected]<=1;
        end else if (!word_hit) begin
          pending_addr<=req_addr; target_way<=selected; load_pending<=1;
          state<=READ_REQ;
          if (!tag_hit) replacement<=replacement+1;
        end
      end
      if (state==INV_REQ && cache_ready) state<=INV_WAIT;
      if (state==INV_WAIT && cache_resp_valid) state<=load_pending ? READ_REQ : IDLE;
      if (state==READ_REQ && cache_ready) state<=READ_WAIT;
      if (fill) begin
        tags[target_way]<=pending_addr[31:LINE_BITS]; live[target_way]<=1; dirty[target_way]<=0;
        word_valid[target_way]<={WORDS{1'b1}}; state<=IDLE;
      end
    end
  end
endmodule
