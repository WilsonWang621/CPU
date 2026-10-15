// Two-way, write-through / no-write-allocate, critical-word-first cache.
// One data read port, one byte-masked write port, independent miss ownership.
module v2_dcache #(
  parameter integer CACHE_BYTES=2048, LINE_BYTES=64, MSHRS=4, LOAD_SLOTS=8, STORE_SLOTS=16,
  parameter integer CREDITS=64, RAM_BYTES=268435456,
  parameter integer LT=$clog2(LOAD_SLOTS), ST=$clog2(STORE_SLOTS), CACHE_TREE=0
)(
  input logic clk,rst,
  input logic load_valid,
  input logic [31:0] load_address,
  input logic [LT-1:0] load_tag,
  output logic load_ready,load_hit,
  output logic [31:0] load_data,
  output logic result_valid,
  input logic result_ready,
  output logic [LT-1:0] result_tag,
  output logic [31:0] result_data,
  output logic result_error,
  input logic store_valid,
  output logic store_ready,
  input logic [31:0] store_address,store_data,
  input logic [3:0] store_mask,
  input logic [ST-1:0] store_tag,
  output logic store_done,store_error,
  output logic [ST-1:0] store_done_tag,
  output logic mem_req_valid,mem_req_write,
  input logic mem_req_ready,
  output logic [31:0] mem_req_addr,mem_req_data,
  output logic [3:0] mem_req_mask,
  input logic mem_rsp_valid,
  output logic mem_rsp_ready,
  input logic [31:0] mem_rsp_data,
  input logic mem_rsp_error,
  output logic idle,
  output logic [63:0] miss_count
);
  localparam integer OFFSET=$clog2(LINE_BYTES), WORDS=LINE_BYTES/4, WW=OFFSET-2;
  localparam integer SETS=CACHE_BYTES/(2*LINE_BYTES), SB=$clog2(SETS), LB=SB+1, LINES=2*SETS;
  localparam integer RB=$clog2(RAM_BYTES), TB=RB-SB-OFFSET, MB=$clog2(MSHRS);
  localparam integer FW=$clog2(CREDITS);
  localparam integer WRITE_BANKS=CACHE_BYTES/4>=128 ? 8:2;
  localparam integer BANK_WORDS=CACHE_BYTES/(4*WRITE_BANKS);
  localparam integer BANK_BITS=$clog2(WRITE_BANKS), BANK_WORD_BITS=$clog2(BANK_WORDS);
  localparam integer PENDING_BITS=37+BANK_WORD_BITS;
  localparam integer WRITE_GROUP_WORDS=CACHE_TREE ? 16:BANK_WORDS;
  localparam integer WRITE_GROUPS=(BANK_WORDS+WRITE_GROUP_WORDS-1)/WRITE_GROUP_WORDS;
  localparam integer WRITE_CONTROL_BITS=36+BANK_WORD_BITS;
  logic [WRITE_CONTROL_BITS*WRITE_GROUPS-1:0] distributed_writes [WRITE_BANKS];
  typedef struct packed {
    logic valid;
    logic [LB-1:0] physical;
    logic [RB-OFFSET-1:0] address;
    logic [WW-1:0] critical;
    logic [WW:0] issued,returned;
    logic [WORDS-1:0] failed;
  } miss_t;
  typedef struct packed {logic valid,error;logic [LB-1:0] physical;logic [WW-1:0] word_index;} waiter_t;
  typedef struct packed {logic write;logic [ST-1:0] tag;logic [MB-1:0] slot;logic [WW-1:0] word_index;} owner_t;
  miss_t misses [MSHRS];
  waiter_t waiters [LOAD_SLOTS];
  owner_t owners [CREDITS],out_owner;
  logic [FW-1:0] head,tail;
  logic [FW:0] count;
  logic out_valid;
  logic [31:0] out_address,out_data;
  logic [3:0] out_mask;
  (* ram_style="registers" *) logic [31:0] data [CACHE_BYTES/4];
  logic [TB-1:0] tags [LINES];
  logic [LINES-1:0] tag_valid;
  logic [WORDS-1:0] word_valid [LINES];
  wire [WORDS-1:0] word_valid_next [LINES];
  waiter_t waiter_next [LOAD_SLOTS];
  logic return_valid_next,return_error_next;
  logic return_pending;
  logic [LT-1:0] return_tag_next;
  logic [LB+WW-1:0] return_address_next,return_address;
  logic [SETS-1:0] replacement;
  logic [LINES-1:0] locked;
  logic [SB-1:0] load_set,store_set;
  logic [LB-1:0] load_line,store_line,selected_line;
  logic load_tag_hit,store_tag_hit;
  logic [1:0] load_matches,store_matches;
  logic victim_valid,free_valid,merge_valid,allocate;
  logic [MB-1:0] free_slot,merge_slot,selected_slot,send_slot;
  logic send_valid,send_fill,load_accept,store_accept,request_fire,response_fire,out_space;
  logic [MB-1:0] round_robin;
  logic [WW-1:0] send_word;
  logic [LB-1:0] response_line;
  logic [WW-1:0] response_word;
  logic fill_fire,data_write_valid;
  logic [LB+WW-1:0] data_write_address,data_read_address;
  logic [31:0] data_write_value;
  logic [3:0] data_write_mask;
  logic [WRITE_BANKS-1:0] pending_valid;
  logic [BANK_WORD_BITS-1:0] pending_address [WRITE_BANKS];
  logic [31:0] pending_data [WRITE_BANKS];
  logic [3:0] pending_mask [WRITE_BANKS];
  wire [WRITE_BANKS*PENDING_BITS-1:0] pending_words;
  wire [PENDING_BITS-1:0] read_pending;
  logic [MSHRS-1:0] release_miss;
  assign load_set=load_address[SB+OFFSET-1:OFFSET];
  assign store_set=store_address[SB+OFFSET-1:OFFSET];
  for(genvar way=0;way<2;way=way+1) begin: tag_read

    assign store_matches[way]=tag_valid[{store_set,1'(way)}] && tags[{store_set,1'(way)}]==store_address[RB-1:SB+OFFSET];
  end
  assign load_tag_hit=|load_matches;
  assign store_tag_hit=|store_matches;
  assign load_line={load_set,!load_matches[0]};
  assign store_line={store_set,!store_matches[0]};
  wire [LINES*TB-1:0] lookup_tags;
  wire [LINES*WORDS-1:0] lookup_words;
  for(genvar line=0;line<LINES;line=line+1) begin: lookup_payload
    assign lookup_tags[line*TB+:TB]=tags[line];
    assign lookup_words[line*WORDS+:WORDS]=word_valid[line];
  end
  v2_cache_lookup #(.SETS(SETS),.TAG_BITS(TB),.WORDS(WORDS)) lookup (
    .address(load_address[RB-1:2]),.tags(lookup_tags),.valid(tag_valid),.word_valid(lookup_words),
    .match_bits(load_matches),.hit(load_hit));

  assign mem_req_valid=!rst && out_valid && int'(count)<CREDITS;
  assign mem_req_write=out_owner.write;
  assign mem_req_addr=out_address;
  assign mem_req_data=out_data;
  assign mem_req_mask=out_mask;
  assign request_fire=mem_req_valid && mem_req_ready;
  assign mem_rsp_ready=1;
  assign response_fire=mem_rsp_valid && count!=0;
  assign response_line=misses[owners[head].slot].physical;
  assign response_word=owners[head].word_index;
  assign fill_fire=response_fire && !owners[head].write;
  assign store_done=response_fire && owners[head].write;
  assign store_done_tag=owners[head].tag;
  assign store_error=store_done && mem_rsp_error;
  assign out_space=!out_valid || request_fire;
  // Select using the state that the cache publishes at the next edge.
  // The data remains combinational, but its late priority selection no
  // longer precedes the wide data read. This preserves the return cycle.
  wire [LOAD_SLOTS-1:0] return_candidates;
  logic incoming_word_ready;
  wire incoming_error=(merge_valid && misses[merge_slot].failed[load_address[OFFSET-1:2]]) ||
    (fill_fire && mem_rsp_error && response_line==selected_line && response_word==load_address[OFFSET-1:2]);
  always_comb begin
    incoming_word_ready=word_valid[selected_line][load_address[OFFSET-1:2]];
    if(allocate && !load_tag_hit) incoming_word_ready=0;
    if(fill_fire && response_line==selected_line && response_word==load_address[OFFSET-1:2])
      incoming_word_ready=!mem_rsp_error;
    if(store_accept && store_tag_hit && store_line==selected_line && store_mask==15 &&
        store_address[OFFSET-1:2]==load_address[OFFSET-1:2]) incoming_word_ready=1;
  end
  for(genvar waiter=0;waiter<LOAD_SLOTS;waiter=waiter+1) begin: return_lookahead
    logic resident_word_ready;
    wire publish=load_accept && !load_hit && load_tag==LT'(waiter);
    wire consumed=result_valid && result_ready && result_tag==LT'(waiter);
    wire resident_error=waiters[waiter].error ||
      (fill_fire && mem_rsp_error && waiters[waiter].valid &&
       waiters[waiter].physical==response_line && waiters[waiter].word_index==response_word);
    always_comb begin
      resident_word_ready=word_valid[waiters[waiter].physical][waiters[waiter].word_index];
      if(allocate && !load_tag_hit && selected_line==waiters[waiter].physical) resident_word_ready=0;
      if(fill_fire && response_line==waiters[waiter].physical && response_word==waiters[waiter].word_index)
        resident_word_ready=!mem_rsp_error;
      if(store_accept && store_tag_hit && store_line==waiters[waiter].physical && store_mask==15 &&
          store_address[OFFSET-1:2]==waiters[waiter].word_index) resident_word_ready=1;
    end
    assign return_candidates[waiter]=publish ? (incoming_error || incoming_word_ready):
      (waiters[waiter].valid && !consumed && (resident_error || resident_word_ready));
`ifndef SYNTHESIS
    always_ff @(posedge clk) if(!rst)
      assert((waiter_next[waiter].valid && return_candidates[waiter]) ===
        (waiter_next[waiter].valid && (waiter_next[waiter].error ||
          word_valid_next[waiter_next[waiter].physical][waiter_next[waiter].word_index])))
        else $fatal(1,"cache return eligibility differs");
`endif
  end
  always_comb begin: returning_load
    return_valid_next=0;return_tag_next=0;return_error_next=0;return_address_next=0;
    for(integer w=0;w<LOAD_SLOTS;w=w+1)
      if(!return_valid_next && waiter_next[w].valid &&
          return_candidates[w]) begin
        return_valid_next=1;return_tag_next=LT'(w);return_error_next=waiter_next[w].error;
        return_address_next={waiter_next[w].physical,waiter_next[w].word_index};
      end
  end
  always_ff @(posedge clk) begin
    if(rst) begin return_pending<=0;result_tag<=0;result_error<=0;return_address<=0;end
    else begin
      return_pending<=return_valid_next;result_tag<=return_tag_next;result_error<=return_error_next;
      return_address<=return_address_next;
    end
  end
  assign result_valid=!rst && return_pending;
  always_comb begin
    locked=0;
    free_valid=0;free_slot=0;merge_valid=0;merge_slot=0;
    release_miss=0;
    for(integer m=0;m<MSHRS;m=m+1) begin
      if(misses[m].valid) begin
        locked[misses[m].physical]=1;
        if(load_tag_hit && misses[m].physical==load_line) begin merge_valid=1;merge_slot=MB'(m);end
        release_miss[m]=misses[m].returned==(WW+1)'(WORDS);
        for(integer w=0;w<LOAD_SLOTS;w=w+1)
          if(waiters[w].valid && waiters[w].physical==misses[m].physical) release_miss[m]=0;
      end else if(!free_valid) begin free_valid=1;free_slot=MB'(m);end
    end
    selected_line=load_line;victim_valid=load_tag_hit;
    if(!load_tag_hit) begin
      if(!tag_valid[{load_set,1'b0}] && !locked[{load_set,1'b0}]) begin selected_line={load_set,1'b0};victim_valid=1;end
      else if(!tag_valid[{load_set,1'b1}] && !locked[{load_set,1'b1}]) begin selected_line={load_set,1'b1};victim_valid=1;end
      else if(!locked[{load_set,replacement[load_set]}]) begin selected_line={load_set,replacement[load_set]};victim_valid=1;end
      else if(!locked[{load_set,!replacement[load_set]}]) begin selected_line={load_set,!replacement[load_set]};victim_valid=1;end
    end
    selected_slot=merge_valid ? merge_slot:free_slot;
    load_ready=!rst && !result_valid && (load_hit || (!waiters[load_tag].valid &&
                (merge_valid || (free_valid && victim_valid))));
    load_accept=load_valid && load_ready;
    allocate=load_accept && !load_hit && !merge_valid;
    store_ready=!rst && out_space && int'(count)<CREDITS-1 && !fill_fire &&
                (!store_tag_hit || !locked[store_line]) &&
                !(allocate && store_tag_hit && selected_line==store_line);
    store_accept=store_valid && store_ready;
    send_valid=0;send_slot=0;
    for(integer offset=0;offset<MSHRS;offset=offset+1)
      if(!send_valid && misses[MB'(round_robin+MB'(offset))].valid &&
           misses[MB'(round_robin+MB'(offset))].issued<(WW+1)'(WORDS)) begin
        send_valid=1;send_slot=MB'(round_robin+MB'(offset));
      end
    send_fill=!rst && out_space && int'(count)<CREDITS-1 && !store_accept && send_valid;
    send_word=misses[send_slot].critical+misses[send_slot].issued[WW-1:0];
    // Prepare the write payload without waiting for load/recovery permission.
    // Only the pending valid bit publishes the write at the capture edge.
    data_write_valid=(fill_fire && !mem_rsp_error) || (!fill_fire && store_accept && store_tag_hit);
    data_write_address=fill_fire ? {response_line,response_word}:{store_line,store_address[OFFSET-1:2]};
    data_write_value=fill_fire ? mem_rsp_data:store_data;
    data_write_mask=fill_fire ? 4'b1111:store_mask;
    data_read_address=result_valid ? return_address:
                                     {load_line,load_address[OFFSET-1:2]};
  end
  always_comb begin: quiescent_state
    idle=!out_valid && count==0;
    for(integer m=0;m<MSHRS;m=m+1) if(misses[m].valid) idle=0;
    for(integer w=0;w<LOAD_SLOTS;w=w+1) if(waiters[w].valid) idle=0;
  end
  // Decode each word once, rather than letting the binary read mux make
  // every address bit drive thousands of bit-level gates.
  wire [(CACHE_BYTES/4)*32-1:0] data_words;
  wire [WRITE_BANKS*32-1:0] bank_words;
  wire [31:0] read_word;
  // Capture into the selected bank first. Each data register now drives only
  // BANK_WORDS storage rows. Forward this pending byte write on every read,
  // preserving the original visibility at the capture edge.
  for(genvar bank=0;bank<WRITE_BANKS;bank=bank+1) begin: write_stages
    v2_cache_read #(.ENTRIES(BANK_WORDS),.INDEX_GROUP(CACHE_TREE ? 16:0)) read_bank (
      .index(data_read_address[BANK_WORD_BITS-1:0]),
      .words(data_words[bank*BANK_WORDS*32+:BANK_WORDS*32]),.value(bank_words[bank*32+:32]));
    wire select_bank=data_write_address[LB+WW-1:BANK_WORD_BITS]==BANK_BITS'(bank);
    wire accept=data_write_valid && select_bank;
    always_ff @(posedge clk) begin
      if(rst) pending_valid[bank]<=0;
      else begin
        pending_valid[bank]<=accept;
        if(select_bank) begin
          pending_address[bank]<=data_write_address[BANK_WORD_BITS-1:0];
          pending_data[bank]<=data_write_value;
          pending_mask[bank]<=data_write_mask;
        end
      end
    end
    assign pending_words[bank*PENDING_BITS+:PENDING_BITS]=
      {pending_valid[bank],pending_address[bank],pending_mask[bank],pending_data[bank]};
    v2_distribution #(.WIDTH(WRITE_CONTROL_BITS),.LEAVES(WRITE_GROUPS)) write_tree (
      .data_in({pending_mask[bank] & {4{pending_valid[bank]}},pending_address[bank],pending_data[bank]}),
      .data_out(distributed_writes[bank]));
  end
  for(genvar row=0;row<CACHE_BYTES/4;row=row+1) begin: data_rows
    wire [WRITE_CONTROL_BITS-1:0] local_write=
      distributed_writes[row/BANK_WORDS][((row%BANK_WORDS)/WRITE_GROUP_WORDS)*WRITE_CONTROL_BITS+:WRITE_CONTROL_BITS];
    assign data_words[row*32+:32]=data[row];
    for(genvar byte_id=0;byte_id<4;byte_id=byte_id+1) begin: byte_write
      always_ff @(posedge clk)
        if(!rst && local_write[32+BANK_WORD_BITS+byte_id] &&
           local_write[32+:BANK_WORD_BITS]==BANK_WORD_BITS'(row%BANK_WORDS))
          data[row][byte_id*8+:8]<=local_write[byte_id*8+:8];
    end
  end
  v2_cache_read #(.ENTRIES(WRITE_BANKS)) read_data (
    .index(data_read_address[LB+WW-1:BANK_WORD_BITS]),.words(bank_words),.value(read_word));
  v2_read #(.ENTRIES(WRITE_BANKS),.WORD_BITS(PENDING_BITS)) read_write_stage (
    .index(data_read_address[LB+WW-1:BANK_WORD_BITS]),.words(pending_words),.value(read_pending));
  for(genvar byte_id=0;byte_id<4;byte_id=byte_id+1) begin: pending_forward
    wire bypass=read_pending[PENDING_BITS-1] && read_pending[32+byte_id] &&
                read_pending[36+:BANK_WORD_BITS]==data_read_address[BANK_WORD_BITS-1:0];
    assign load_data[byte_id*8+:8]=bypass ? read_pending[byte_id*8+:8]:read_word[byte_id*8+:8];
  end
  assign result_data=load_data;
  always_ff @(posedge clk) begin
    if(rst) begin
      head<=0;tail<=0;count<=0;out_valid<=0;out_owner<='0;
      out_address<=0;out_data<=0;out_mask<=0;round_robin<=0;miss_count<=0;
    end else begin
      case({request_fire,response_fire})
        2'b10:count<=count+1;
        2'b01:count<=count-1;
        default:;
      endcase
      if(request_fire) begin owners[tail]<=out_owner;tail<=tail+1'b1;out_valid<=0;end
      if(response_fire) head<=head+1'b1;
      if(store_accept) begin
        out_valid<=1;out_owner<='0;out_owner.write<=1;out_owner.tag<=store_tag;
        out_address<=store_address;out_data<=store_data;out_mask<=store_mask;
      end else if(send_fill) begin
        out_valid<=1;out_owner<='0;out_owner.slot<=send_slot;out_owner.word_index<=send_word;
        out_address<={{(32-RB){1'b0}},misses[send_slot].address,send_word,2'b0};
        out_data<=0;out_mask<=0;round_robin<=send_slot+1'b1;
      end
      if(allocate && !load_tag_hit) miss_count<=miss_count+1;
    end
  end
  for(genvar m=0;m<MSHRS;m=m+1) begin: miss_rows
    always_ff @(posedge clk) begin
      if(rst) misses[m]<='0;
      else begin
        if(release_miss[m]) misses[m].valid<=0;
        if(send_fill && send_slot==MB'(m)) misses[m].issued<=misses[m].issued+1;
        if(fill_fire && owners[head].slot==MB'(m)) begin
          misses[m].returned<=misses[m].returned+1;
          if(mem_rsp_error) misses[m].failed[response_word]<=1;
        end
        if(allocate && free_slot==MB'(m)) begin
          misses[m].valid<=1;misses[m].physical<=selected_line;
          misses[m].address<=load_address[RB-1:OFFSET];misses[m].critical<=load_address[OFFSET-1:2];
          misses[m].issued<=0;misses[m].returned<=0;misses[m].failed<=0;
        end
      end
    end
  end
  for(genvar w=0;w<LOAD_SLOTS;w=w+1) begin: waiter_rows
    always_comb begin
        waiter_next[w]=waiters[w];
        if(result_valid && result_ready && result_tag==LT'(w)) waiter_next[w].valid=0;
        if(fill_fire && mem_rsp_error && waiters[w].valid && waiters[w].physical==response_line &&
            waiters[w].word_index==response_word) waiter_next[w].error=1;
        if(load_accept && !load_hit && load_tag==LT'(w)) begin
          waiter_next[w].valid=1;waiter_next[w].physical=selected_line;waiter_next[w].word_index=load_address[OFFSET-1:2];
          waiter_next[w].error=(merge_valid && misses[merge_slot].failed[load_address[OFFSET-1:2]]) ||
            (fill_fire && mem_rsp_error && response_line==selected_line && response_word==load_address[OFFSET-1:2]);
        end
    end
    always_ff @(posedge clk) begin
      if(rst) waiters[w]<='0;
      else waiters[w]<=waiter_next[w];
    end
  end
  for(genvar line=0;line<LINES;line=line+1) begin: metadata
    logic [WORDS-1:0] valid_next;
    assign word_valid_next[line]=valid_next;
    always_comb begin
      valid_next=word_valid[line];
      if(allocate && !load_tag_hit && selected_line==LB'(line)) valid_next=0;
      if(fill_fire && response_line==LB'(line)) valid_next[response_word]=!mem_rsp_error;
      if(store_accept && store_tag_hit && store_line==LB'(line) && store_mask==15)
        valid_next[store_address[OFFSET-1:2]]=1;
    end
    always_ff @(posedge clk) begin
      if(rst) begin tag_valid[line]<=0;word_valid[line]<=0;end
      else begin
        word_valid[line]<=valid_next;
        if(allocate && !load_tag_hit && selected_line==LB'(line)) begin
          tag_valid[line]<=1;tags[line]<=load_address[RB-1:SB+OFFSET];
        end
      end
    end
  end
  for(genvar set_index=0;set_index<SETS;set_index=set_index+1) begin: lru
    always_ff @(posedge clk) begin
      if(rst) replacement[set_index]<=0;
      else begin
        if(load_accept && load_set==SB'(set_index)) replacement[set_index]<=!selected_line[0];
        if(store_accept && store_tag_hit && store_set==SB'(set_index)) replacement[set_index]<=!store_line[0];
      end
    end
  end
  initial begin
    if(LINE_BYTES<16 || (LINE_BYTES&(LINE_BYTES-1))!=0 || CACHE_BYTES<4*LINE_BYTES || (CACHE_BYTES&(CACHE_BYTES-1))!=0 || MSHRS<2 || (MSHRS&(MSHRS-1))!=0 ||
       CREDITS<2 || (CREDITS&(CREDITS-1))!=0) $fatal(1,"invalid cache dimensions");
  end
endmodule
