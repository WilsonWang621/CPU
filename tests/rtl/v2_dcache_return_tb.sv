`timescale 1ns/1ps
// Check the return-port contract every cycle against published waiter/word
// state, with concurrent misses, response errors and consumer backpressure.
module v2_dcache_return_tb #(parameter integer CACHE_TREE=0,CACHE_BYTES=512);
  reg clk=0,rst=1,load_valid=0,result_ready=0,mem_req_ready=0,mem_rsp_valid=0,mem_rsp_error=0;
  always #5 clk=~clk;
  reg [31:0] load_address=0,mem_rsp_data=0;
  reg [2:0] load_tag=0;
  wire load_ready,load_hit,result_valid,result_error,mem_req_valid,mem_req_write,mem_rsp_ready,idle;
  wire [2:0] result_tag;
  wire [31:0] load_data,result_data,mem_req_addr;
  v2_dcache #(.CACHE_BYTES(CACHE_BYTES),.LINE_BYTES(16),.MSHRS(4),.LOAD_SLOTS(8),.CACHE_TREE(CACHE_TREE),
    .STORE_SLOTS(4),.CREDITS(16),.RAM_BYTES(16384)) dut (
    .clk(clk),.rst(rst),.load_valid(load_valid),.load_address(load_address),.load_tag(load_tag),
    .load_ready(load_ready),.load_hit(load_hit),.load_data(load_data),
    .result_valid(result_valid),.result_ready(result_ready),.result_tag(result_tag),
    .result_data(result_data),.result_error(result_error),
    .store_valid(1'b0),.store_address(32'b0),.store_data(32'b0),.store_mask(4'b0),.store_tag(2'b0),
    .mem_req_valid(mem_req_valid),.mem_req_write(mem_req_write),.mem_req_ready(mem_req_ready),
    .mem_req_addr(mem_req_addr),.mem_rsp_valid(mem_rsp_valid),.mem_rsp_ready(mem_rsp_ready),
    .mem_rsp_data(mem_rsp_data),.mem_rsp_error(mem_rsp_error),.idle(idle));
  reg [31:0] responses[0:1023],expected_data[0:7];
  reg response_errors[0:1023];
  reg [7:0] live=0;
  reg req_fire,rsp_fire,ret_fire,load_fire,was_hit,req_error;
  reg [31:0] req_address;
  integer head=0,tail=0,count=0,seed=32'h73cde612,step=0;
  integer r,physical,word_index,chosen,busy,slot,checks=0;
  integer accepted=0,misses=0,returns=0,errors=0,stalls=0,multiple=0;
  reg expected_valid,expected_error;
  function integer random_range(input integer limit);
    random_range=($random(seed)&32'h7fffffff)%limit;
  endfunction
  function [31:0] memory_word(input [31:0] address);
    memory_word=32'hcd730000 ^ ((address>>2)*32'h1030201);
  endfunction
  task check_port;
    begin
      expected_valid=0;expected_error=0;chosen=0;
      for(r=0;r<8;r=r+1) begin
        // A physical line is 16 bytes for both tested cache capacities.
        physical=dut.waiters[r][dut.WAITER_T_PHYSICAL_LSB+:$clog2(CACHE_BYTES/16)];
        word_index=dut.waiters[r][dut.WAITER_T_WORD_INDEX_LSB+:2];
        if(!expected_valid && dut.waiters[r][dut.WAITER_T_VALID_LSB] &&
           (dut.waiters[r][dut.WAITER_T_ERROR_LSB] || dut.word_valid[physical][word_index])) begin
          expected_valid=1;chosen=r;expected_error=dut.waiters[r][dut.WAITER_T_ERROR_LSB];
        end
      end
      if(result_valid!==expected_valid || (expected_valid &&
         (result_tag!==3'(chosen) || result_error!==expected_error)))
        $fatal(1,"return cycle/priority mismatch cycle=%0d tag=%0d expected=%0d",step,result_tag,chosen);
      if(result_valid && (!live[result_tag] || (!result_error && result_data!==expected_data[result_tag])))
        $fatal(1,"return ownership/data mismatch cycle=%0d tag=%0d got=%h expected=%h",
          step,result_tag,result_data,expected_data[result_tag]);
      checks=checks+1;
    end
  endtask
  task tick(input bit issue);
    begin
      @(negedge clk);
      slot=random_range(8);load_tag=3'(slot);
      load_valid=issue && !live[slot] && random_range(4)!=0;
      load_address=32'((((step/23+random_range(4))%128)*16)+random_range(4)*4);
      result_ready=random_range(4)!=0;mem_req_ready=random_range(4)!=0;
      mem_rsp_valid=count!=0 && random_range(4)!=0;
      mem_rsp_data=responses[head];mem_rsp_error=response_errors[head];
      #1;check_port();
      req_fire=mem_req_valid && mem_req_ready;rsp_fire=mem_rsp_valid && mem_rsp_ready;
      ret_fire=result_valid && result_ready;load_fire=load_valid && load_ready;was_hit=load_hit;
      req_address=mem_req_addr;req_error=random_range(17)==0;
      if(mem_req_valid && mem_req_write) $fatal(1,"unexpected store request");
      if(load_fire && was_hit && load_data!==memory_word(load_address))
        $fatal(1,"hit data mismatch cycle=%0d",step);
      if(result_valid && !result_ready) stalls=stalls+1;
      busy=0;for(r=0;r<8;r=r+1) busy=busy+int'(live[r]);
      if(busy>1) multiple=multiple+1;
      @(posedge clk);
      if(ret_fire) begin
        live[result_tag]=0;returns=returns+1;if(result_error) errors=errors+1;
      end
      if(load_fire) begin
        accepted=accepted+1;
        if(!was_hit) begin live[load_tag]=1;expected_data[load_tag]=memory_word(load_address);misses=misses+1;end
      end
      if(req_fire) begin
        responses[tail]=memory_word(req_address);response_errors[tail]=req_error;tail=(tail+1)%1024;
      end
      if(rsp_fire) head=(head+1)%1024;
      count=count+int'(req_fire)-int'(rsp_fire);
      if(count<0 || count>16) $fatal(1,"bus ownership overflow");
      #1;check_port();step=step+1;
    end
  endtask
  initial begin
    repeat(2) @(posedge clk);
    #1;rst=0;
    repeat(6000) tick(1);
    while((!idle || count!=0 || live!=0) && step<8000) tick(0);
    if(step>=8000 || accepted<500 || misses<200 || errors<10 || stalls<30 || multiple<100)
      $fatal(1,"insufficient coverage or drain timeout accepted=%0d misses=%0d errors=%0d",accepted,misses,errors);
    $display("Dcache returns: PASS checks=%0d accepted=%0d misses=%0d returns=%0d errors=%0d stalls=%0d multiple=%0d",
      checks,accepted,misses,returns,errors,stalls,multiple);
    $finish;
  end
endmodule
