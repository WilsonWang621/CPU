`timescale 1ns/1ps
module v2_frontend_prepare_tb #(parameter integer TARGETS=0);
  reg clk=0;
  always #5 clk=~clk;
  reg rst=1,stop=0,redirect=0;
  reg [31:0] redirect_pc=0;
  reg [1:0] pop_count=0;
  wire [1:0] packet_valid,packet_inst_valid;
  wire [63:0] packet_pc,packet_inst,packet_prediction;
  wire [7:0] packet_fault;
  wire [1:0] packet_history;
  wire mem_req_valid,mem_rsp_ready,idle;
  wire [31:0] mem_req_addr;
  reg mem_req_ready=0,mem_rsp_valid=0,mem_rsp_error=0;
  reg [31:0] mem_rsp_data=0;
  wire [63:0] miss_count;
  v2_frontend #(.CACHE_BYTES(128),.QUEUE_ENTRIES(4),.BHT_ENTRIES(16),.BTB_ENTRIES(4),.HISTORY_ENTRIES(4)) dut (
    .clk(clk),.rst(rst),.stop(stop),.redirect(redirect),.redirect_pc(redirect_pc),.pop_count(pop_count),
    .packet_valid(packet_valid),.packet_pc(packet_pc),.packet_inst(packet_inst),.packet_prediction(packet_prediction),
    .packet_fault(packet_fault),.packet_inst_valid(packet_inst_valid),.packet_history(packet_history),
    .train_history(1'b0),.train_valid(1'b0),.train_taken(1'b0),.train_op(6'd0),.train_pc(32'd0),.train_target(32'd0),
    .mem_req_valid(mem_req_valid),.mem_req_ready(mem_req_ready),.mem_req_addr(mem_req_addr),
    .mem_rsp_valid(mem_rsp_valid),.mem_rsp_ready(mem_rsp_ready),.mem_rsp_data(mem_rsp_data),.mem_rsp_error(mem_rsp_error),
    .idle(idle),.miss_count(miss_count));

  reg [31:0] requests[0:63];
  integer req_head=0,req_tail=0,req_count=0;
  reg [31:0] expected_pc=0,address;
  integer seed=32'h602fca19,step,p,consumed=0,redirects=0,full_cycles=0,dual_pops=0,errors=0;
  integer target_checks=0,backward_checks=0,sequential_checks=0;
  reg request_fire,response_fire;
  function integer random_range(input integer limit);
    random_range=($random(seed)&32'h7fffffff)%limit;
  endfunction
  function [31:0] instruction(input [31:0] pc);
    begin
      instruction={pc[13:2],20'h00093}; // addi x1,x0,pc[13:2]
      if(TARGETS) case(pc[5:2])
        3: instruction=32'h00c0006f; // jal x0,+12
        11:instruction=32'hfedff06f; // jal x0,-20
        7: instruction=32'hfe000ae3; // beq x0,x0,-12
        5: instruction=32'h0040006f; // jal x0,+4
        9: instruction=32'h00000263; // beq x0,x0,+4
        default: ;
      endcase
    end
  endfunction
  // The oracle follows the program's fixed semantics, independently of the
  // cached target representation and its instruction-immediate decoder.
  function [31:0] predicted_next(input [31:0] pc);
    begin
      predicted_next=pc+4;
      if(TARGETS && !bus_error(pc)) case(pc[5:2])
        3: predicted_next=pc+12;
        11:predicted_next=pc-20;
        7: predicted_next=pc-12;
        default: ;
      endcase
    end
  endfunction
  function bus_error(input [31:0] pc);
    bus_error=pc[8:2]==63;
  endfunction
  task check_packet(input integer lane,input [31:0] pc);
    begin
      if(packet_pc[lane*32+:32]!==pc || ((!TARGETS || !bus_error(pc)) && packet_prediction[lane*32+:32]!==predicted_next(pc)))
        $fatal(1,"packet address mismatch step=%0d lane=%0d pc=%h expected=%h",step,lane,packet_pc[lane*32+:32],pc);
      if(bus_error(pc)) begin
        if(packet_fault[lane*4+:4]!==4'd4 || packet_inst_valid[lane]!==0 || packet_inst[lane*32+:32]!==0)
          $fatal(1,"lost fetch error step=%0d pc=%h",step,pc);
      end else if(packet_fault[lane*4+:4]!==0 || packet_inst_valid[lane]!==1 ||
                  packet_inst[lane*32+:32]!==instruction(pc))
        $fatal(1,"packet data mismatch step=%0d pc=%h",step,pc);
      if(TARGETS && !bus_error(pc) && predicted_next(pc)!=pc+4) begin
        target_checks=target_checks+1;
        if(predicted_next(pc)<pc) backward_checks=backward_checks+1;
      end
      if(TARGETS && !bus_error(pc) && (pc[5:2]==5 || pc[5:2]==9)) sequential_checks=sequential_checks+1;
    end
  endtask
  initial begin
    repeat(2) @(posedge clk);
    @(negedge clk);rst=0;
    if(TARGETS) begin
      dut.bht_valid=16'hffff;
      for(p=0;p<16;p=p+1) dut.bht[p]=3;
    end
    for(step=0;step<10000;step=step+1) begin
      @(negedge clk);
      stop=random_range(8)==0;
      redirect=random_range(40)==0;
      // Cross index aliases and full-address tags while old fills are pending.
      redirect_pc=(random_range(2)==0 ? 32'h40000:0)+32'(random_range(256)*4);
      mem_req_ready=random_range(4)!=0;
      mem_rsp_valid=req_count!=0 && random_range(3)!=0;
      mem_rsp_data=instruction(requests[req_head]);mem_rsp_error=bus_error(requests[req_head]);
      pop_count=0;
      #1;
      if(!stop && !redirect && packet_valid[0]) begin
        pop_count=packet_valid[1] && random_range(2)==0 ? 2:2'(random_range(2));
        address=expected_pc;
        for(p=0;p<int'(pop_count);p=p+1) begin
          check_packet(p,address);
          if(bus_error(address)) errors=errors+1;
          address=predicted_next(address);
        end
      end
      #1;
      request_fire=mem_req_valid && mem_req_ready;
      response_fire=mem_rsp_valid && mem_rsp_ready;
      if(dut.count==4) full_cycles=full_cycles+1;
      if(pop_count==2) dual_pops=dual_pops+1;
      @(posedge clk);
      if(request_fire) begin requests[req_tail]=mem_req_addr;req_tail=(req_tail+1)%64;end
      if(response_fire) req_head=(req_head+1)%64;
      req_count=req_count+int'(request_fire)-int'(response_fire);
      if(req_count<0 || req_count>16) $fatal(1,"invalid memory ownership count");
      if(redirect) begin expected_pc=redirect_pc;redirects=redirects+1;end
      else begin
        for(p=0;p<int'(pop_count);p=p+1) expected_pc=predicted_next(expected_pc);
        consumed=consumed+int'(pop_count);
      end
      #1;
      if(dut.count>4) $fatal(1,"queue overflow");
      if(packet_valid[0]) check_packet(0,expected_pc);
      if(packet_valid[1]) check_packet(1,predicted_next(expected_pc));
    end
    if(consumed<1000 || full_cycles<100 || dual_pops<100 || redirects<100 || (!TARGETS && errors<10) ||
       (TARGETS && (target_checks<1000 || backward_checks<100 || sequential_checks<100)))
      $fatal(1,"insufficient queue ownership coverage");
    $display("Frontend preparation: PASS 10000 cycles; instructions=%0d full=%0d dual_pop=%0d redirects=%0d errors=%0d",
      consumed,full_cycles,dual_pops,redirects,errors);
    if(TARGETS) $display("Cached prediction targets: PASS checked=%0d backward=%0d sequential=%0d",target_checks,backward_checks,sequential_checks);
    $finish;
  end
endmodule

module v2_frontend_target_tb;
  v2_frontend_prepare_tb #(.TARGETS(1)) test();
endmodule
