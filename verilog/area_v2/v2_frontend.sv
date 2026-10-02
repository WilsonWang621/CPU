module v2_frontend #(
  parameter integer CACHE_BYTES=1024, QUEUE_ENTRIES=8, BHT_ENTRIES=256, BTB_ENTRIES=32,
  parameter integer LOCAL_HISTORY_BITS=1, HISTORY_ENTRIES=64,
  parameter integer RAM_BYTES=268435456, HB=(LOCAL_HISTORY_BITS>0 ? LOCAL_HISTORY_BITS:1)
)(
  input logic clk,rst,stop,redirect,
  input logic [31:0] redirect_pc,
  input logic [1:0] pop_count,
  output logic [1:0] packet_valid,
  output logic [63:0] packet_pc,packet_inst,packet_prediction,
  output logic [7:0] packet_fault,
  output logic [1:0] packet_inst_valid,
  output logic [2*HB-1:0] packet_history,
  input logic [HB-1:0] train_history,
  input logic train_valid,train_taken,
  input cpu_pkg::op_t train_op,
  input logic [31:0] train_pc,train_target,
  output logic mem_req_valid,
  input logic mem_req_ready,
  output logic [31:0] mem_req_addr,
  input logic mem_rsp_valid,
  output logic mem_rsp_ready,
  input logic [31:0] mem_rsp_data,
  input logic mem_rsp_error,
  output logic idle,
  output logic [63:0] miss_count
);
  import cpu_pkg::*;
  localparam integer CB=$clog2(CACHE_BYTES), LINES=CACHE_BYTES/32, LB=$clog2(LINES);
  localparam integer QW=$clog2(QUEUE_ENTRIES), BW=$clog2(BHT_ENTRIES), TW=$clog2(BTB_ENTRIES);
  typedef struct packed {logic [3:0] fault;logic iv;logic [HB-1:0] history;logic [31:0] pc,inst,pred;} packet_t;
  localparam integer PACKET_BITS=$bits(packet_t);
  packet_t fifo [QUEUE_ENTRIES],incoming[2],read_packet[2];
  wire [QUEUE_ENTRIES*PACKET_BITS-1:0] queue_words;
  wire [(CACHE_BYTES/8)*32-1:0] even_words,odd_words;
  logic [QW-1:0] head,tail;
  logic [QW:0] count;
  logic [1:0] push;
  logic [31:0] pc,next_pc;
  logic blocked,next_blocked;
  (* ram_style="registers" *) logic [31:0] even_data [CACHE_BYTES/8],odd_data [CACHE_BYTES/8];
  logic [31:CB] tags [LINES];
  logic [LINES-1:0] tag_valid;
  logic [7:0] valid_words [LINES],failed_words [LINES];
  logic busy;
  logic [31:0] fill_line;
  logic [2:0] critical;
  logic [3:0] issued,returned;
  logic [2:0] send_word,return_word;
  logic [31:0] return_address;
  logic allocate;
  logic [LB-1:0] fetch_line;
  logic line_hit,word_ready[2],word_error[2];
  logic [31:0] fetch_pc[2],fetch_inst[2],prediction[2];
  logic [31:0] even_read,odd_read;
  logic [CB-4:0] even_index,odd_index;
  (* ram_style="registers" *) logic [1:0] bht [BHT_ENTRIES];
  logic [BHT_ENTRIES-1:0] bht_valid;
  (* ram_style="registers" *) logic [29:TW] btb_tag [BTB_ENTRIES];
  (* ram_style="registers" *) logic [29:0] btb_target [BTB_ENTRIES];
  logic [BTB_ENTRIES-1:0] btb_valid;
  logic [1:0] counter[2],train_counter;
  logic [31:0] immediate[2];
  localparam integer HI=$clog2(HISTORY_ENTRIES);
  logic [HB-1:0] local_history [HISTORY_ENTRIES];
  logic [HB-1:0] fetch_history [2];
  logic [BW-1:0] fetch_bht [2];
  logic [BW-1:0] train_bht;
  logic [TW-1:0] train_btb;
  assign train_bht=LOCAL_HISTORY_BITS==0 ? train_pc[BW+1:2]:
    (train_pc[BW+1:2]<<LOCAL_HISTORY_BITS) | BW'(train_history);
  assign train_btb=train_pc[TW+1:2];
  assign train_counter=bht_valid[train_bht] ? bht[train_bht]:2'd1;
  assign fetch_pc[0]=pc;
  assign fetch_pc[1]=pc+4;
  assign even_index=pc[2] ? fetch_pc[1][CB-1:3]:pc[CB-1:3];
  assign odd_index=pc[CB-1:3];
  for(genvar row=0;row<CACHE_BYTES/8;row=row+1) begin: instruction_words
    assign even_words[row*32+:32]=even_data[row];
    assign odd_words[row*32+:32]=odd_data[row];
  end
  v2_read #(.ENTRIES(CACHE_BYTES/8)) read_even (.index(even_index),.words(even_words),.value(even_read));
  v2_read #(.ENTRIES(CACHE_BYTES/8)) read_odd (.index(odd_index),.words(odd_words),.value(odd_read));
  assign fetch_inst[0]=pc[2] ? odd_read:even_read;
  assign fetch_inst[1]=pc[2] ? even_read:odd_read;
  assign fetch_line=pc[CB-1:5];
  wire [LINES-1:0] line_matches;
  for(genvar row=0;row<LINES;row=row+1) begin: instruction_tags
    assign line_matches[row]=fetch_line==LB'(row) && tag_valid[row] && tags[row]==pc[31:CB];
  end
  assign line_hit=|line_matches;
  for(genvar row=0;row<QUEUE_ENTRIES;row=row+1) begin: packet_words
    assign queue_words[row*PACKET_BITS+:PACKET_BITS]=fifo[row];
  end
  for(genvar p=0;p<2;p=p+1) begin: predict
    wire [QW-1:0] read_index=head+QW'(p);
    v2_read #(.ENTRIES(QUEUE_ENTRIES),.WORD_BITS(PACKET_BITS)) read_queue (
      .index(read_index),.words(queue_words),.value(read_packet[p]));
    wire [BTB_ENTRIES-1:0] target_hits;
    wire [BTB_ENTRIES*30-1:0] target_words;
    wire [29:0] target;
    for(genvar row=0;row<BTB_ENTRIES;row=row+1) begin: target_row
      assign target_hits[row]=fetch_pc[p][TW+1:2]==TW'(row) && btb_valid[row] &&
                              btb_tag[row]==fetch_pc[p][31:TW+2];
      assign target_words[row*30+:30]=btb_target[row];
    end
    v2_read #(.ENTRIES(BTB_ENTRIES),.WORD_BITS(30)) read_target (
      .index(fetch_pc[p][TW+1:2]),.words(target_words),.value(target));
    assign word_ready[p]=line_hit && (valid_words[fetch_line][fetch_pc[p][4:2]] || failed_words[fetch_line][fetch_pc[p][4:2]]);
    assign word_error[p]=failed_words[fetch_line][fetch_pc[p][4:2]];
    assign fetch_history[p]=LOCAL_HISTORY_BITS==0 ? '0:local_history[fetch_pc[p][HI+1:2]];
    assign fetch_bht[p]=LOCAL_HISTORY_BITS==0 ? fetch_pc[p][BW+1:2]:
      (fetch_pc[p][BW+1:2]<<LOCAL_HISTORY_BITS) | BW'(fetch_history[p]);
    assign counter[p]=bht_valid[fetch_bht[p]] ? bht[fetch_bht[p]]:2'd1;
    always_comb begin
      prediction[p]=fetch_pc[p]+4;
      immediate[p]=0;
      case(fetch_inst[p][6:0])
        7'h6f: begin
          immediate[p]={{11{fetch_inst[p][31]}},fetch_inst[p][31],fetch_inst[p][19:12],fetch_inst[p][20],fetch_inst[p][30:21],1'b0};
          prediction[p]=fetch_pc[p]+immediate[p];
        end
        7'h63: begin
          immediate[p]={{19{fetch_inst[p][31]}},fetch_inst[p][31],fetch_inst[p][7],fetch_inst[p][30:25],fetch_inst[p][11:8],1'b0};
          if(counter[p][1]) prediction[p]=fetch_pc[p]+immediate[p];
        end
        7'h67: if(|target_hits) prediction[p]={target,2'b0};
        default: ;
      endcase
    end
  end
  always_comb begin
    packet_valid=0;packet_pc=0;packet_inst=0;packet_prediction=0;packet_fault=0;packet_inst_valid=0;packet_history=0;
    for(integer p=0;p<2;p=p+1) begin
      // The consumer gates publication on stop/redirect. Keep those global
      // controls off the payload preparation of free backend rows.
      packet_valid[p]=int'(count)>p;
      packet_pc[p*32+:32]=read_packet[p].pc;
      packet_inst[p*32+:32]=read_packet[p].inst;
      packet_prediction[p*32+:32]=read_packet[p].pred;
      packet_fault[p*4+:4]=read_packet[p].fault;
      packet_inst_valid[p]=read_packet[p].iv;
      packet_history[p*HB+:HB]=read_packet[p].history;
    end
  end
  always_comb begin: fetch_next
    push=0;next_pc=pc;next_blocked=blocked;allocate=0;
    for(integer p=0;p<2;p=p+1) begin
      incoming[p]='0;incoming[p].pc=fetch_pc[p];incoming[p].pred=prediction[p];
      incoming[p].history=fetch_history[p];
      incoming[p].inst=fetch_inst[p];incoming[p].iv=1;
    end
    if(!stop && !redirect && !blocked && int'(count)-int'(pop_count)<QUEUE_ENTRIES) begin
      if(pc[1:0]!=0 || pc>=RAM_BYTES) begin
        incoming[0].fault=pc[1:0]!=0 ? FAULT_FETCH_ALIGN:FAULT_FETCH_RANGE;
        incoming[0].iv=0;incoming[0].inst=0;push=1;next_blocked=1;
      end else if(word_ready[0]) begin
        push=1;next_pc=prediction[0];
        if(word_error[0]) begin
          incoming[0].fault=FAULT_FETCH_BUS;incoming[0].iv=0;incoming[0].inst=0;next_blocked=1;
        end else if(prediction[0]==pc+4 && pc[4:2]!=7 && word_ready[1] &&
                    int'(count)-int'(pop_count)<QUEUE_ENTRIES-1) begin
          push=2;next_pc=prediction[1];
          if(word_error[1]) begin
            incoming[1].fault=FAULT_FETCH_BUS;incoming[1].iv=0;incoming[1].inst=0;next_blocked=1;
          end
        end
      end else if(!busy) allocate=1;
    end
  end
  assign send_word=critical+issued[2:0];
  assign return_word=critical+returned[2:0];
  assign return_address=fill_line+{27'b0,return_word,2'b0};
  assign mem_req_valid=!rst && busy && issued<8;
  assign mem_req_addr=fill_line+{27'b0,send_word,2'b0};
  assign mem_rsp_ready=1;
  assign idle=!busy;
  always_ff @(posedge clk) begin
    if(rst) begin
      head<=0;tail<=0;count<=0;pc<=0;blocked<=0;
      busy<=0;issued<=0;returned<=0;critical<=0;fill_line<=0;miss_count<=0;
      bht_valid<=0;btb_valid<=0;
    end else begin
      if(redirect) begin head<=0;tail<=0;count<=0;pc<=redirect_pc;blocked<=0;end
      else begin
        head<=head+QW'(pop_count);tail<=tail+QW'(push);
        count<=count+(QW+1)'(push)-(QW+1)'(pop_count);
        pc<=next_pc;blocked<=next_blocked;
      end
      if(allocate) begin
        busy<=1;fill_line<={pc[31:5],5'b0};critical<=pc[4:2];issued<=0;returned<=0;
        miss_count<=miss_count+1;
      end
      if(mem_req_valid && mem_req_ready) issued<=issued+1;
      if(mem_rsp_valid) begin
        returned<=returned+1;
        if(returned==7) busy<=0;
      end
      if(train_valid && train_op>=OP_BEQ && train_op<=OP_BGEU) begin
        bht_valid[train_bht]<=1;
        bht[train_bht]<=train_taken ? (train_counter==3 ? 2'd3:train_counter+2'd1):
                                                    (train_counter==0 ? 2'd0:train_counter-2'd1);
      end
      if(train_valid && train_op==OP_JALR && train_target<RAM_BYTES && train_target[1:0]==0) begin
        btb_valid[train_btb]<=1;btb_tag[train_btb]<=train_pc[31:TW+2];btb_target[train_btb]<=train_target[31:2];
      end
    end
  end
  for(genvar row=0;row<CACHE_BYTES/8;row=row+1) begin: instruction_write
    always_ff @(posedge clk)
      if(!rst && mem_rsp_valid && !mem_rsp_error &&
         return_address[CB-1:3]==(CB-3)'(row)) begin
        if(return_address[2]) odd_data[row]<=mem_rsp_data;
        else even_data[row]<=mem_rsp_data;
      end
  end
  for(genvar row=0;row<QUEUE_ENTRIES;row=row+1) begin: queue_write
    always_ff @(posedge clk)
      for(integer p=0;p<2;p=p+1)
        // Only start-of-cycle free slots are prepared. A full queue can still
        // push on a pop edge; such a reused slot requires the actual push.
        if((int'(count)+p<QUEUE_ENTRIES || (!rst && !redirect && int'(push)>p)) &&
           QW'(tail+QW'(p))==QW'(row)) fifo[row]<=incoming[p];
  end
  for(genvar row=0;row<LINES;row=row+1) begin: tag_write
    logic [7:0] valid_next,failed_next;
    always_comb begin
      valid_next=valid_words[row];failed_next=failed_words[row];
      if(allocate && fetch_line==LB'(row)) begin valid_next=0;failed_next=0;end
      if(mem_rsp_valid && fill_line[CB-1:5]==LB'(row)) begin
        valid_next[return_word]=!mem_rsp_error;failed_next[return_word]=mem_rsp_error;
      end
    end
    always_ff @(posedge clk) begin
      if(rst) tag_valid[row]<=0;
      else begin
        valid_words[row]<=valid_next;failed_words[row]<=failed_next;
        if(allocate && fetch_line==LB'(row)) begin
          tag_valid[row]<=1;tags[row]<=pc[31:CB];
        end
      end
    end
  end
  // Resolved local outcomes select a separate counter per recent pattern.
  // Carry the lookup history through the pipeline so training updates exactly
  // the counter used at fetch, even when another branch has since resolved.
  for(genvar h=0;h<HISTORY_ENTRIES;h=h+1) begin: history_write
    always_ff @(posedge clk) begin
      if(rst) local_history[h]<='0;
      else if(LOCAL_HISTORY_BITS>0 && train_valid && train_op>=OP_BEQ && train_op<=OP_BGEU &&
              train_pc[HI+1:2]==HI'(h)) local_history[h]<=(local_history[h]<<1) | HB'(train_taken);
    end
  end
  initial begin
    if(LOCAL_HISTORY_BITS<0 || LOCAL_HISTORY_BITS>=BW || HISTORY_ENTRIES<2 ||
       (HISTORY_ENTRIES&(HISTORY_ENTRIES-1))!=0) $fatal(1,"invalid local predictor dimensions");
    if(CACHE_BYTES<64 || (CACHE_BYTES&(CACHE_BYTES-1))!=0 || QUEUE_ENTRIES<2 || (QUEUE_ENTRIES&(QUEUE_ENTRIES-1))!=0)
      $fatal(1,"invalid frontend dimensions");
  end
endmodule
