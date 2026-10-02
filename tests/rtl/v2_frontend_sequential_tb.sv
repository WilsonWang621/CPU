`timescale 1ns/1ps
// BTB fallthrough classification must follow the full-address owner, so a
// stale flag at the same index cannot change one- versus two-instruction push.
module v2_frontend_sequential_tb;
  reg clk=0,rst=1,stop=1,train_valid=0;
  always #5 clk=~clk;
  reg [31:0] train_pc=0,train_target=0;
  v2_frontend #(.CACHE_BYTES(128),.QUEUE_ENTRIES(4),.BHT_ENTRIES(16),
    .BTB_ENTRIES(4),.HISTORY_ENTRIES(4)) dut (
    .clk(clk),.rst(rst),.stop(stop),.redirect(1'b0),.redirect_pc(32'b0),.pop_count(2'b0),
    .train_valid(train_valid),.train_pc(train_pc),.train_target(train_target),.train_op(6'(dut.OP_JALR)),
    .train_taken(1'b1),.train_history(1'b0),.mem_req_ready(1'b0),
    .mem_rsp_valid(1'b0),.mem_rsp_data(32'b0),.mem_rsp_error(1'b0));
  task check_btb(input bit train,input [31:0] owner,target,expected);
    begin
      @(negedge clk);rst=1;stop=1;train_valid=0;
      repeat(3) @(negedge clk);
      rst=0;
      dut.tag_valid=1;dut.tags[0]=0;dut.valid_words[0]=3;dut.failed_words[0]=0;
      dut.even_data[0]=32'h00000067;dut.odd_data[0]=32'h00000067;
      dut.even_target[0]=0;dut.odd_target[0]=0;
      train_pc=owner;train_target=target;train_valid=train;
      @(posedge clk);#1;
      train_valid=0;stop=0;
      #1;
      if(dut.prediction[0]!=expected ||
         dut.push!=(expected==4 ? 2:1))
        $fatal(1,"BTB owner/fallthrough classification incorrect owner=%h target=%h prediction=%h push=%d",owner,target,dut.prediction[0],dut.push);
    end
  endtask
  initial begin
    check_btb(0,0,0,4);
    check_btb(1,0,4,4);
    check_btb(1,0,64,64);
    check_btb(1,16,20,4);
    $display("Frontend fallthrough: PASS BTB miss, sequential target, taken target and full-address alias");
    $finish;
  end
endmodule
