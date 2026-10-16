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
  v2_dcache dut (
    .clk(clk),.rst(rst),.load_valid(load_valid),.load_address(load_address),.load_tag(load_tag),
    .load_ready(load_ready),.load_hit(load_hit),.load_data(load_data),
    .result_valid(result_valid),.result_ready(result_ready),.result_tag(result_tag),
    .result_data(result_data),.result_error(result_error),
    .store_valid(1'b0),.store_address(32'b0),.store_data(32'b0),.store_mask(4'b0),.store_tag(2'b0),
    .mem_req_valid(mem_req_valid),.mem_req_write(mem_req_write),.mem_req_ready(mem_req_ready),
    .mem_req_addr(mem_req_addr),.mem_rsp_valid(mem_rsp_valid),.mem_rsp_ready(mem_rsp_ready),
    .mem_rsp_data(mem_rsp_data),.mem_rsp_error(mem_rsp_error),.idle(idle));
wire [8:0] observed_waiters[0:7];
wire [3:0] observed_words[0:31];
assign observed_waiters[0]={dut.waiters_0_valid,dut.waiters_0_error,dut.waiters_0_physical,dut.waiters_0_word_index};
assign observed_waiters[1]={dut.waiters_1_valid,dut.waiters_1_error,dut.waiters_1_physical,dut.waiters_1_word_index};
assign observed_waiters[2]={dut.waiters_2_valid,dut.waiters_2_error,dut.waiters_2_physical,dut.waiters_2_word_index};
assign observed_waiters[3]={dut.waiters_3_valid,dut.waiters_3_error,dut.waiters_3_physical,dut.waiters_3_word_index};
assign observed_waiters[4]={dut.waiters_4_valid,dut.waiters_4_error,dut.waiters_4_physical,dut.waiters_4_word_index};
assign observed_waiters[5]={dut.waiters_5_valid,dut.waiters_5_error,dut.waiters_5_physical,dut.waiters_5_word_index};
assign observed_waiters[6]={dut.waiters_6_valid,dut.waiters_6_error,dut.waiters_6_physical,dut.waiters_6_word_index};
assign observed_waiters[7]={dut.waiters_7_valid,dut.waiters_7_error,dut.waiters_7_physical,dut.waiters_7_word_index};
assign observed_words[0]={dut.word_valid_0_3,dut.word_valid_0_2,dut.word_valid_0_1,dut.word_valid_0_0};
assign observed_words[1]={dut.word_valid_1_3,dut.word_valid_1_2,dut.word_valid_1_1,dut.word_valid_1_0};
assign observed_words[2]={dut.word_valid_2_3,dut.word_valid_2_2,dut.word_valid_2_1,dut.word_valid_2_0};
assign observed_words[3]={dut.word_valid_3_3,dut.word_valid_3_2,dut.word_valid_3_1,dut.word_valid_3_0};
assign observed_words[4]={dut.word_valid_4_3,dut.word_valid_4_2,dut.word_valid_4_1,dut.word_valid_4_0};
assign observed_words[5]={dut.word_valid_5_3,dut.word_valid_5_2,dut.word_valid_5_1,dut.word_valid_5_0};
assign observed_words[6]={dut.word_valid_6_3,dut.word_valid_6_2,dut.word_valid_6_1,dut.word_valid_6_0};
assign observed_words[7]={dut.word_valid_7_3,dut.word_valid_7_2,dut.word_valid_7_1,dut.word_valid_7_0};
assign observed_words[8]={dut.word_valid_8_3,dut.word_valid_8_2,dut.word_valid_8_1,dut.word_valid_8_0};
assign observed_words[9]={dut.word_valid_9_3,dut.word_valid_9_2,dut.word_valid_9_1,dut.word_valid_9_0};
assign observed_words[10]={dut.word_valid_10_3,dut.word_valid_10_2,dut.word_valid_10_1,dut.word_valid_10_0};
assign observed_words[11]={dut.word_valid_11_3,dut.word_valid_11_2,dut.word_valid_11_1,dut.word_valid_11_0};
assign observed_words[12]={dut.word_valid_12_3,dut.word_valid_12_2,dut.word_valid_12_1,dut.word_valid_12_0};
assign observed_words[13]={dut.word_valid_13_3,dut.word_valid_13_2,dut.word_valid_13_1,dut.word_valid_13_0};
assign observed_words[14]={dut.word_valid_14_3,dut.word_valid_14_2,dut.word_valid_14_1,dut.word_valid_14_0};
assign observed_words[15]={dut.word_valid_15_3,dut.word_valid_15_2,dut.word_valid_15_1,dut.word_valid_15_0};
assign observed_words[16]={dut.word_valid_16_3,dut.word_valid_16_2,dut.word_valid_16_1,dut.word_valid_16_0};
assign observed_words[17]={dut.word_valid_17_3,dut.word_valid_17_2,dut.word_valid_17_1,dut.word_valid_17_0};
assign observed_words[18]={dut.word_valid_18_3,dut.word_valid_18_2,dut.word_valid_18_1,dut.word_valid_18_0};
assign observed_words[19]={dut.word_valid_19_3,dut.word_valid_19_2,dut.word_valid_19_1,dut.word_valid_19_0};
assign observed_words[20]={dut.word_valid_20_3,dut.word_valid_20_2,dut.word_valid_20_1,dut.word_valid_20_0};
assign observed_words[21]={dut.word_valid_21_3,dut.word_valid_21_2,dut.word_valid_21_1,dut.word_valid_21_0};
assign observed_words[22]={dut.word_valid_22_3,dut.word_valid_22_2,dut.word_valid_22_1,dut.word_valid_22_0};
assign observed_words[23]={dut.word_valid_23_3,dut.word_valid_23_2,dut.word_valid_23_1,dut.word_valid_23_0};
assign observed_words[24]={dut.word_valid_24_3,dut.word_valid_24_2,dut.word_valid_24_1,dut.word_valid_24_0};
assign observed_words[25]={dut.word_valid_25_3,dut.word_valid_25_2,dut.word_valid_25_1,dut.word_valid_25_0};
assign observed_words[26]={dut.word_valid_26_3,dut.word_valid_26_2,dut.word_valid_26_1,dut.word_valid_26_0};
assign observed_words[27]={dut.word_valid_27_3,dut.word_valid_27_2,dut.word_valid_27_1,dut.word_valid_27_0};
assign observed_words[28]={dut.word_valid_28_3,dut.word_valid_28_2,dut.word_valid_28_1,dut.word_valid_28_0};
assign observed_words[29]={dut.word_valid_29_3,dut.word_valid_29_2,dut.word_valid_29_1,dut.word_valid_29_0};
assign observed_words[30]={dut.word_valid_30_3,dut.word_valid_30_2,dut.word_valid_30_1,dut.word_valid_30_0};
assign observed_words[31]={dut.word_valid_31_3,dut.word_valid_31_2,dut.word_valid_31_1,dut.word_valid_31_0};
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
        physical=observed_waiters[r][2+:$clog2(CACHE_BYTES/16)];
        word_index=observed_waiters[r][0+:2];
        if(!expected_valid && observed_waiters[r][8] &&
           (observed_waiters[r][7] || observed_words[physical][word_index])) begin
          expected_valid=1;chosen=r;expected_error=observed_waiters[r][7];
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
