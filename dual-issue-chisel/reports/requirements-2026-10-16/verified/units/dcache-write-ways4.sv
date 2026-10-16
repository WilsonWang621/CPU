`timescale 1ns/1ps
module v2_dcache_write_tb #(parameter integer CACHE_TREE=0,CACHE_BYTES=2048);
  reg clk=0; always #5 clk=~clk;
  reg rst=1,load_valid=0,store_valid=0;
  reg [31:0] load_address=0,store_address=0,store_data=0;
  reg [3:0] store_mask=0;
  wire load_ready,load_hit,result_valid,result_error,store_ready,store_done,store_error;
  wire [31:0] load_data,result_data;
  wire [1:0] result_tag,store_done_tag;
  wire mem_req_valid,mem_req_write,mem_rsp_ready,idle;
  wire [31:0] mem_req_addr,mem_req_data;
  wire [3:0] mem_req_mask;
  reg mem_req_ready=0,mem_rsp_valid=0;
  reg [31:0] mem_rsp_data=0;
  wire [63:0] miss_count;
  v2_dcache dut (
    .clk(clk),.rst(rst),.load_valid(load_valid),.load_address(load_address),.load_tag(2'd0),
    .load_ready(load_ready),.load_hit(load_hit),.load_data(load_data),
    .result_valid(result_valid),.result_ready(1'b1),.result_tag(result_tag),.result_data(result_data),.result_error(result_error),
    .store_valid(store_valid),.store_ready(store_ready),.store_address(store_address),.store_data(store_data),
    .store_mask(store_mask),.store_tag(2'd0),.store_done(store_done),.store_done_tag(store_done_tag),.store_error(store_error),
    .mem_req_valid(mem_req_valid),.mem_req_ready(mem_req_ready),.mem_req_write(mem_req_write),.mem_req_addr(mem_req_addr),
    .mem_req_data(mem_req_data),.mem_req_mask(mem_req_mask),.mem_rsp_valid(mem_rsp_valid),.mem_rsp_ready(mem_rsp_ready),
    .mem_rsp_data(mem_rsp_data),.mem_rsp_error(1'b0),.idle(idle),.miss_count(miss_count));
  reg [31:0] shadow[0:127],backing[0:127],responses[0:255];
  reg pending=0,accepted=0,read_fire,write_fire,request_fire,response_fire,return_fire;
  reg [31:0] expected_result,request_address,request_data;
  reg [3:0] request_mask;
  reg request_write;
  integer head=0,tail=0,count=0,seed=32'h602dcc42;
  integer step=0,loads=0,writes=0,partial=0,collisions=0,consecutive=0,previous_word=-1;
  integer b,r,wait_cycles;
  function integer random_range(input integer limit);
    random_range=($random(seed)&32'h7fffffff)%limit;
  endfunction
  task tick;
    begin
      @(negedge clk);
      mem_req_ready=random_range(4)!=0;
      mem_rsp_valid=count!=0 && random_range(3)!=0;
      mem_rsp_data=responses[head];
      #1;
      read_fire=load_valid && load_ready;
      write_fire=store_valid && store_ready;
      request_fire=mem_req_valid && mem_req_ready;
      response_fire=mem_rsp_valid && mem_rsp_ready;
      return_fire=result_valid;
      request_address=mem_req_addr;request_data=mem_req_data;request_mask=mem_req_mask;request_write=mem_req_write;
      if(return_fire) begin
        if(!pending || result_tag!=0 || result_error || result_data!==expected_result)
          $fatal(1,"miss result mismatch step=%0d got=%h expected=%h",step,result_data,expected_result);
      end
      if(read_fire) begin
        accepted=1;loads=loads+1;
        if(load_hit) begin
          if(load_data!==shadow[load_address[8:2]]) $fatal(1,"hit mismatch before edge step=%0d",step);
        end else begin
          if(pending) $fatal(1,"duplicate load ownership");
          pending=1;expected_result=shadow[load_address[8:2]];
        end
      end
      @(posedge clk);
      if(return_fire) pending=0;
      if(write_fire) begin
        writes=writes+1;
        if(store_mask!=15) partial=partial+1;
        if(store_address==load_address) collisions=collisions+1;
        if(previous_word==int'(store_address[8:2])) consecutive=consecutive+1;
        previous_word=int'(store_address[8:2]);
        for(b=0;b<4;b=b+1) if(store_mask[b]) shadow[store_address[8:2]][b*8+:8]=store_data[b*8+:8];
      end else previous_word=-1;
      if(request_fire) begin
        if(request_write)
          for(b=0;b<4;b=b+1) if(request_mask[b]) backing[request_address[8:2]][b*8+:8]=request_data[b*8+:8];
        responses[tail]=backing[request_address[8:2]];tail=(tail+1)%256;
      end
      if(response_fire) head=(head+1)%256;
      count=count+int'(request_fire)-int'(response_fire);
      if(count<0 || count>8 || store_error) $fatal(1,"invalid bus ownership");
      #1;
      if(load_hit && !result_valid && load_data!==shadow[load_address[8:2]])
        $fatal(1,"write visibility mismatch after edge step=%0d address=%h got=%h expected=%h",step,load_address,load_data,shadow[load_address[8:2]]);
      step=step+1;
    end
  endtask
  initial begin
    for(r=0;r<128;r=r+1) begin shadow[r]=32'hbad00000 ^ (32'(r)*32'h1020304);backing[r]=shadow[r];end
    repeat(2) @(posedge clk);
    #1;rst=0;
    for(r=0;r<128;r=r+1) begin
      load_address=32'(r*4);load_valid=1;accepted=0;wait_cycles=0;
      while(!accepted) begin tick();wait_cycles=wait_cycles+1;if(wait_cycles>200) $fatal(1,"load request timeout");end
      load_valid=0;
      while(pending || !idle || count!=0) begin tick();wait_cycles=wait_cycles+1;if(wait_cycles>400) $fatal(1,"fill timeout");end
    end
    for(r=0;r<4000;r=r+1) begin
      load_valid=random_range(2)==0;store_valid=random_range(4)!=0;
      if(r%5!=0) load_address=32'(random_range(128)*4);
      store_address=random_range(2)==0 ? load_address:32'(random_range(128)*4);
      store_data=$random(seed);store_mask=4'(random_range(16));
      tick();
      if(!load_hit) $fatal(1,"resident cache word lost");
    end
    load_valid=0;store_valid=0;
    while(!idle || count!=0) tick();
    for(r=0;r<128;r=r+1) if(backing[r]!==shadow[r]) $fatal(1,"write-through mismatch word=%0d",r);
    if(writes<1000 || partial<800 || collisions<400 || consecutive<20) $fatal(1,"insufficient write coverage");
    $display("Dcache writes: PASS cycles=%0d loads=%0d stores=%0d partial=%0d same_word=%0d consecutive=%0d",step,loads,writes,partial,collisions,consecutive);
    $finish;
  end
endmodule
