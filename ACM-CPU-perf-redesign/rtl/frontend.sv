// Tagged, pipelined fetch. Canceled requests keep ownership of their tags until
// their response drains; a separate order FIFO contains only the current path.
module frontend #(
  parameter integer FETCH_WIDTH=4, FETCH_QUEUE_ENTRIES=32, RAM_BYTES=262144,
  parameter integer BHT_ENTRIES=2048, BTB_ENTRIES=256, RAS_DEPTH=16,
  parameter integer LINE_BYTES=32, FETCH_REQUESTS=16,
  parameter integer PREDICTOR_MODE=2, HISTORY_BITS=8,
  parameter bit PREDICTOR=1
)(
  input logic clk,rst,stop,redirect_valid,
  input logic [31:0] redirect_pc,redirect_branch_pc,redirect_inst,
  input logic [15:0] redirect_history,
  input logic [511:0] redirect_ras_snapshot,
  input logic [4:0] redirect_ras_count,
  input logic redirect_taken,
  output logic [3:0] out_valid,
  output cpu_pkg::fetch_t out_packet [4],
  input logic [2:0] pop_count,
  input logic [3:0] train_valid,
  input logic [127:0] train_pc,train_inst,train_next_pc,
  input logic [3:0] train_taken,
  input logic [3:0] train_bimodal_taken,train_gshare_taken,
  input logic [63:0] train_history,
  output logic req_valid,
  input logic req_ready,
  output logic [31:0] req_addr,
  output logic [2:0] req_count,
  output logic [7:0] req_tag,
  input logic rsp_valid,
  output logic rsp_ready,
  input logic [127:0] rsp_data,
  input logic [7:0] rsp_tag,
  input logic rsp_error,
  input logic [3:0] rsp_error_mask,
  output logic idle
);
  import cpu_pkg::*;
  localparam logic [511:0] RAS_MASK={512{1'b1}} >> (512-32*RAS_DEPTH);
  localparam integer QW=(FETCH_QUEUE_ENTRIES>1 ? $clog2(FETCH_QUEUE_ENTRIES):1);
  localparam integer SW=(FETCH_REQUESTS>1 ? $clog2(FETCH_REQUESTS):1);
  typedef logic [SW-1:0] slot_t;
  typedef struct packed {
    logic valid,accepted,canceled,responded;
    logic [31:0] pc;
    logic [2:0] count;
    logic [127:0] prediction;
    logic [3:0] taken;
    logic [3:0] bimodal_taken,gshare_taken;
    logic [63:0] history;
    logic [511:0] ras;
    logic [4:0] ras_count;
    logic [127:0] data;
    logic [3:0] fault;
    logic [3:0] error_mask;
  } request_t;
  // A configured RAS depth is also a physical storage limit. These upper
  // bits are already zero for every reachable snapshot; make the invariant
  // explicit at each storage input so synthesis need not discover feedback.
  function automatic request_t bounded_request(input request_t packet);
    request_t value;
    begin value=packet;value.ras=packet.ras & RAS_MASK;return value;end
  endfunction
  function automatic fetch_t bounded_fetch(input fetch_t packet);
    fetch_t value;
    begin value=packet;value.ras_snapshot=packet.ras_snapshot & RAS_MASK;return value;end
  endfunction
  request_t request_q [FETCH_REQUESTS],request_d [FETCH_REQUESTS];
  slot_t order_q [FETCH_REQUESTS],order_d [FETCH_REQUESTS];
  logic [SW-1:0] order_head_q,order_head_d,order_tail_q,order_tail_d;
  logic [SW:0] order_count_q,order_count_d;
  fetch_t queue_q [FETCH_QUEUE_ENTRIES];
  logic [QW-1:0] head_q,head_d,tail_q,tail_d;
  logic [QW:0] count_q,count_d;
  logic [31:0] pc_q,pc_d;
  logic presented_q,presented_d,blocked_q,blocked_d;
  slot_t presented_slot_q,presented_slot_d;
  logic [2:0] query_count,predicted_count;
  logic [31:0] prediction [4],next_pc;
  logic [3:0] predicted_taken;
  logic [3:0] bimodal_taken,gshare_taken;
  logic [15:0] history [4];
  logic [511:0] ras_snapshot [4];
  logic [4:0] ras_count [4];
  logic predictor_advance,predictor_redirect;
  logic [31:0] predictor_branch_pc,predictor_inst;
  logic [15:0] predictor_history;
  logic [511:0] predictor_ras;
  logic [4:0] predictor_ras_count;
  logic predictor_taken;
  fetch_t enqueue [4];
  logic [2:0] enqueue_count;
  logic local_redirect,terminal_fault,any_request;
  logic [31:0] local_pc,local_branch_pc,local_inst;
  logic [15:0] local_history;
  logic [511:0] local_ras;
  logic [4:0] local_ras_count;
  integer free_slot,oldest,response_slot,words_to_line,available,deliver_count;
  logic [31:0] word,word_pc,target;
  request_t completed,allocated;

  assign req_valid=presented_q && !rst;
  assign req_addr=request_q[presented_slot_q].pc;
  assign req_count=request_q[presented_slot_q].count;
  assign req_tag=8'(presented_slot_q);
  assign rsp_ready=!rst;
  assign idle=!any_request && !presented_q;
  always_comb begin
    any_request=0;
    for(integer n=0;n<FETCH_REQUESTS;n=n+1) any_request=any_request || request_q[n].valid;
    words_to_line=(LINE_BYTES-int'(pc_q & 32'(LINE_BYTES-1)))/4;
    query_count=3'(FETCH_WIDTH);
    if(words_to_line<FETCH_WIDTH) query_count=3'(words_to_line);
  end
  for(genvar g=0;g<4;g=g+1) begin: output_lanes
    assign out_valid[g]=(int'(count_q)>g) && !stop && !rst;
    assign out_packet[g]=queue_q[(int'(head_q)+g)%FETCH_QUEUE_ENTRIES];
  end
  branch_predictor #(.BHT_ENTRIES(BHT_ENTRIES),.BTB_ENTRIES(BTB_ENTRIES),
    .RAS_DEPTH(RAS_DEPTH),.ENABLE(PREDICTOR),.PREDICTOR_MODE(PREDICTOR_MODE),.HISTORY_BITS(HISTORY_BITS)) predictor (
    .clk,.rst,.advance(predictor_advance),.query_pc(pc_q),.query_count,
    .predicted_pc(prediction),.predicted_taken,.bimodal_taken,.gshare_taken,.history,.ras_snapshot,.ras_count,
    .predicted_count,.next_pc,.redirect_valid(predictor_redirect),
    .redirect_branch_pc(predictor_branch_pc),.redirect_inst(predictor_inst),
    .redirect_history(predictor_history),.redirect_ras_snapshot(predictor_ras),
    .redirect_ras_count(predictor_ras_count),.redirect_taken(predictor_taken),
    .train_valid,.train_pc,.train_inst,.train_next_pc,.train_taken,.train_history,
    .train_bimodal_taken,.train_gshare_taken
  );

  // External recovery takes precedence over cold-JAL repair. Both restore a
  // pre-instruction snapshot and then apply the resolved instruction once.
  always_comb begin
    predictor_redirect=redirect_valid || local_redirect;
    predictor_branch_pc=local_branch_pc;predictor_inst=local_inst;
    predictor_history=local_history;predictor_ras=local_ras;
    predictor_ras_count=local_ras_count;predictor_taken=1;
    if(redirect_valid) begin
      predictor_branch_pc=redirect_branch_pc;predictor_inst=redirect_inst;
      predictor_history=redirect_history;predictor_ras=redirect_ras_snapshot;
      predictor_ras_count=redirect_ras_count;predictor_taken=redirect_taken;
    end
  end

  always_comb begin
    for(integer n=0;n<FETCH_REQUESTS;n=n+1) begin
      request_d[n]=request_q[n];order_d[n]=order_q[n];
    end
    order_head_d=order_head_q;order_tail_d=order_tail_q;order_count_d=order_count_q;
    head_d=head_q;tail_d=tail_q;count_d=count_q;pc_d=pc_q;
    presented_d=presented_q;presented_slot_d=presented_slot_q;blocked_d=blocked_q;
    predictor_advance=0;enqueue_count=0;
    local_redirect=0;local_pc=0;local_branch_pc=0;local_inst=0;
    local_history=0;local_ras=0;local_ras_count=0;terminal_fault=0;
    free_slot=-1;oldest=0;response_slot=int'(rsp_tag);available=0;deliver_count=0;
    word=0;word_pc=0;target=0;completed='0;allocated='0;
    for(integer lane=0;lane<4;lane=lane+1) enqueue[lane]='0;

    if(req_valid && req_ready) presented_d=0;
    // Decode entry enables before changing fields. A dynamic partial write to
    // this packed-record array otherwise becomes a table-wide masked update.
    for(integer n=0;n<FETCH_REQUESTS;n=n+1) begin
      if(req_valid && req_ready && int'(presented_slot_q)==n) request_d[n].accepted=1;
      if(rsp_valid && !rst && response_slot==n && request_q[n].valid) begin
        if(request_q[n].canceled) request_d[n].valid=0;
        else begin
          request_d[n].responded=1;request_d[n].data=rsp_data;
          // The per-word mask is authoritative. An aggregate error must not
          // hide a valid earlier instruction, including a jump past the error.
          request_d[n].error_mask=rsp_error_mask;
        end
      end
    end
    if(!stop && !redirect_valid) begin
      if(pop_count!=0) begin
        head_d=QW'((int'(head_q)+int'(pop_count))%FETCH_QUEUE_ENTRIES);
        count_d=count_q-(QW+1)'(pop_count);
      end
      // Read responses may arrive out of order. Only the oldest current-path
      // packet enters the FQ; same-cycle response-to-FQ bypass removes a bubble.
      if(order_count_q!=0) begin
        oldest=int'(order_q[order_head_q]);completed=request_d[oldest];
        available=FETCH_QUEUE_ENTRIES-int'(count_d);
        deliver_count=completed.fault!=FAULT_NONE ? 1 : int'(completed.count);
        for(integer lane=3;lane>=0;lane=lane-1)
          if(lane<int'(completed.count) && completed.error_mask[lane]) deliver_count=lane+1;
        if(completed.valid && completed.responded && available>=deliver_count) begin
          for(integer lane=0;lane<4;lane=lane+1) begin
            word=completed.data[lane*32+:32];word_pc=completed.pc+32'(lane)*32'd4;
            if(lane<deliver_count) begin
              enqueue[lane].pc=word_pc;enqueue[lane].inst=word;
              enqueue[lane].inst_valid=completed.fault==FAULT_NONE && !completed.error_mask[lane];
              enqueue[lane].predicted_pc=completed.prediction[lane*32+:32];
              enqueue[lane].predicted_taken=completed.taken[lane];
              enqueue[lane].bimodal_taken=completed.bimodal_taken[lane];
              enqueue[lane].gshare_taken=completed.gshare_taken[lane];
              enqueue[lane].history=completed.history[lane*16+:16];
              enqueue[lane].ras_snapshot=completed.ras;enqueue[lane].ras_count=completed.ras_count;
              enqueue[lane].fault=completed.fault;enqueue[lane].fault_addr=word_pc;
              if(completed.error_mask[lane]) enqueue[lane].fault=FAULT_FETCH_BUS;
              if(!enqueue[lane].inst_valid) enqueue[lane].inst=0;
              // A direct JAL target is available without execution. Repair the
              // packet before dispatch and cancel all later speculative fetches.
              if(enqueue[lane].inst_valid && word[6:0]==7'h6f) begin
                target=word_pc+{{11{word[31]}},word[31],word[19:12],word[20],word[30:21],1'b0};
                if(!completed.taken[lane] || completed.prediction[lane*32+:32]!=target) begin
                  local_redirect=1;local_pc=target;local_branch_pc=word_pc;local_inst=word;
                  local_history=completed.history[lane*16+:16];local_ras=completed.ras;
                  local_ras_count=completed.ras_count;deliver_count=lane+1;
                  enqueue[lane].predicted_pc=target;enqueue[lane].predicted_taken=1;
                end
              end
            end
          end
          enqueue_count=3'(deliver_count);
          tail_d=QW'((int'(tail_q)+deliver_count)%FETCH_QUEUE_ENTRIES);
          count_d=count_d+(QW+1)'(deliver_count);
          for(integer n=0;n<FETCH_REQUESTS;n=n+1)
            if(oldest==n) request_d[n].valid=0;
          order_head_d=SW'((int'(order_head_q)+1)%FETCH_REQUESTS);order_count_d=order_count_q-1'b1;
          terminal_fault=enqueue[deliver_count-1].fault!=FAULT_NONE;
        end
      end
    end

    if(redirect_valid || stop || local_redirect || terminal_fault) begin
      order_head_d=0;order_tail_d=0;order_count_d=0;
      for(integer n=0;n<FETCH_REQUESTS;n=n+1) begin
        if(request_d[n].valid) begin
          if(request_d[n].responded) request_d[n].valid=0;
          else request_d[n].canceled=1;
        end
      end
      blocked_d=terminal_fault;
      if(local_redirect) pc_d=local_pc;
      if(redirect_valid || stop) begin
        head_d=0;tail_d=0;count_d=0;enqueue_count=0;blocked_d=0;
        if(redirect_valid) pc_d=redirect_pc;
      end
    end

    // Allocate the next packet while the previous request handshakes. The next
    // cycle can therefore issue another packet even with many misses pending.
    for(integer n=FETCH_REQUESTS-1;n>=0;n=n-1)
      if(!request_d[n].valid) free_slot=n;
    if(!rst && !stop && !redirect_valid && !local_redirect && !terminal_fault &&
       !blocked_d && !presented_d && free_slot>=0 && int'(order_count_d)<FETCH_REQUESTS) begin
      allocated.valid=1;allocated.pc=pc_q;allocated.count=predicted_count;
      allocated.taken=predicted_taken;
      allocated.bimodal_taken=bimodal_taken;allocated.gshare_taken=gshare_taken;
      allocated.ras=ras_snapshot[0];allocated.ras_count=ras_count[0];
      for(integer lane=0;lane<4;lane=lane+1) begin
        allocated.prediction[lane*32+:32]=prediction[lane];
        allocated.history[lane*16+:16]=history[lane];
      end
      order_d[order_tail_d]=slot_t'(free_slot);
      order_tail_d=SW'((int'(order_tail_d)+1)%FETCH_REQUESTS);order_count_d=order_count_d+1'b1;
      if(pc_q[1:0]!=0 || pc_q>32'(RAM_BYTES-4)) begin
        allocated.count=1;allocated.responded=1;
        allocated.fault=pc_q[1:0]!=0 ? FAULT_FETCH_ALIGN : FAULT_FETCH_RANGE;
        blocked_d=1;
      end else begin
        presented_d=1;presented_slot_d=slot_t'(free_slot);
        pc_d=next_pc;predictor_advance=1;
      end
      for(integer n=0;n<FETCH_REQUESTS;n=n+1)
        if(free_slot==n) request_d[n]=allocated;
    end
  end

  always_ff @(posedge clk) begin
    if(rst) begin
      head_q<=0;tail_q<=0;count_q<=0;pc_q<=0;blocked_q<=0;
      order_head_q<=0;order_tail_q<=0;order_count_q<=0;
      presented_q<=0;presented_slot_q<=0;
      for(integer n=0;n<FETCH_REQUESTS;n=n+1) begin request_q[n]<='0;order_q[n]<=0;end
    end else begin
      head_q<=head_d;tail_q<=tail_d;count_q<=count_d;pc_q<=pc_d;blocked_q<=blocked_d;
      order_head_q<=order_head_d;order_tail_q<=order_tail_d;order_count_q<=order_count_d;
      presented_q<=presented_d;presented_slot_q<=presented_slot_d;
      for(integer n=0;n<FETCH_REQUESTS;n=n+1) begin request_q[n]<=bounded_request(request_d[n]);order_q[n]<=order_d[n];end
    end
  end
  // Select the newest eligible lane before the register. The write enable is
  // separate from data, so masked constants are explicit at the FF data pins.
  for(genvar row=0;row<FETCH_QUEUE_ENTRIES;row=row+1) begin: queue_storage
    fetch_t selected;
    logic write_enable;
    always_comb begin
      selected='0;write_enable=0;
      for(integer lane=0;lane<4;lane=lane+1)
        if(lane<int'(enqueue_count) && (int'(tail_q)+lane)%FETCH_QUEUE_ENTRIES==row) begin
          selected=enqueue[lane];write_enable=1;
        end
    end
    always_ff @(posedge clk) if(!rst && write_enable) queue_q[row]<=bounded_fetch(selected);
  end
  initial begin
    if(FETCH_WIDTH!=1 && FETCH_WIDTH!=2 && FETCH_WIDTH!=4) $fatal(1,"FETCH_WIDTH must be 1, 2, or 4");
    if(FETCH_QUEUE_ENTRIES<FETCH_WIDTH || FETCH_REQUESTS<2 || FETCH_REQUESTS>256)
      $fatal(1,"Invalid frontend queue or request capacity");
    if(LINE_BYTES<4 || (LINE_BYTES & (LINE_BYTES-1))!=0 || RAM_BYTES<LINE_BYTES || RAM_BYTES%LINE_BYTES!=0)
      $fatal(1,"Frontend requires power-of-two lines and complete RAM lines");
  end
`ifndef SYNTHESIS
  always_ff @(posedge clk) if(!rst) begin
    assert(int'(count_q)<=FETCH_QUEUE_ENTRIES && int'(order_count_q)<=FETCH_REQUESTS)
      else $fatal(1,"Frontend queue overflow");
    if(!stop && !redirect_valid) assert(int'(pop_count)<=int'(count_q) && pop_count<=4)
      else $fatal(1,"Frontend popped unavailable instructions");
    if(rsp_valid) begin
      assert(int'(rsp_tag)<FETCH_REQUESTS) else $fatal(1,"Invalid fetch response tag");
      assert(request_q[int'(rsp_tag)].valid && !request_q[int'(rsp_tag)].responded)
        else $fatal(1,"Duplicate or stale fetch response");
      assert(request_q[int'(rsp_tag)].accepted || (req_valid && req_ready && req_tag==rsp_tag))
        else $fatal(1,"Fetch response before request acceptance");
    end
  end
`endif
endmodule
