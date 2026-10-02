`timescale 1ns/1ps
// Compare the distributed lookup with the original flat BHT address rule.
module v2_predictor_read_case #(
  parameter integer HISTORY_BITS=1,HISTORY_ENTRIES=4,BHT_ENTRIES=16
)(output reg done=0);
  localparam integer HB=HISTORY_BITS>0 ? HISTORY_BITS:1;
  reg clk=0,rst=1;
  always #5 clk=~clk;
  v2_frontend #(.CACHE_BYTES(128),.QUEUE_ENTRIES(4),.BHT_ENTRIES(BHT_ENTRIES),
    .BTB_ENTRIES(4),.LOCAL_HISTORY_BITS(HISTORY_BITS),.HISTORY_ENTRIES(HISTORY_ENTRIES)) dut (
    .clk(clk),.rst(rst),.stop(1'b1),.redirect(1'b0),.redirect_pc(32'b0),.pop_count(2'b0),
    .train_history({HB{1'b0}}),.train_valid(1'b0),.train_taken(1'b0),.train_op(6'd0),
    .train_pc(32'b0),.train_target(32'b0),.mem_req_ready(1'b0),.mem_rsp_valid(1'b0),
    .mem_rsp_data(32'b0),.mem_rsp_error(1'b0));
  integer seed=32'h71381901+HISTORY_BITS+HISTORY_ENTRIES,step,row,port,index,history;
  integer defaults=0,taken=0,aliased=0;
  reg [31:0] address;
  reg [1:0] expected;
  initial begin
    repeat(2) @(negedge clk);
    rst=0;
    for(step=0;step<2000;step=step+1) begin
      @(negedge clk);
      for(row=0;row<BHT_ENTRIES;row=row+1) begin
        dut.bht_valid[row]=$random(seed);
        dut.bht[row]=$random(seed);
      end
      for(row=0;row<HISTORY_ENTRIES;row=row+1) dut.local_history[row]=$random(seed);
      // Include carry boundaries and the full 32-bit address wrap.
      dut.pc=step%5==0 ? (32'hfffffffc-(step/5)*4):($random(seed)&32'hfffffffc);
      #1;
      for(port=0;port<2;port=port+1) begin
        address=dut.pc+port*4;
        history=HISTORY_BITS==0 ? 0:dut.local_history[(address/4)%HISTORY_ENTRIES];
        index=(((address/4)<<HISTORY_BITS)|history)&(BHT_ENTRIES-1);
        expected=dut.bht_valid[index] ? dut.bht[index]:2'd1;
        if(dut.counter[port]!==expected)
          $fatal(1,"BHT lookup mismatch H=%0d rows=%0d step=%0d port=%0d address=%h index=%0d got=%d expected=%d",
            HISTORY_BITS,HISTORY_ENTRIES,step,port,address,index,dut.counter[port],expected);
        defaults=defaults+!dut.bht_valid[index];taken=taken+expected[1];
        aliased=aliased+(address/4>=BHT_ENTRIES);
      end
    end
    if(defaults<1000 || taken<500 || aliased<1000) $fatal(1,"insufficient predictor coverage");
    $display("Predictor lookup: PASS history_bits=%0d history_rows=%0d BHT=%0d checks=%0d defaults=%0d taken=%0d",
      HISTORY_BITS,HISTORY_ENTRIES,BHT_ENTRIES,2*step,defaults,taken);
    done=1;
  end
endmodule

module v2_predictor_read_tb;
  wire [5:0] done;
  v2_predictor_read_case #(.HISTORY_BITS(0),.HISTORY_ENTRIES(4)) no_history(done[0]);
  v2_predictor_read_case #(.HISTORY_BITS(1),.HISTORY_ENTRIES(4)) aliased(done[1]);
  v2_predictor_read_case #(.HISTORY_BITS(2),.HISTORY_ENTRIES(4)) exact_rows(done[2]);
  v2_predictor_read_case #(.HISTORY_BITS(2),.HISTORY_ENTRIES(8)) extended_rows(done[3]);
  v2_predictor_read_case #(.HISTORY_BITS(1),.HISTORY_ENTRIES(64),.BHT_ENTRIES(256)) defaults(done[4]);
  v2_predictor_read_case #(.HISTORY_BITS(3),.HISTORY_ENTRIES(2)) multi_bit(done[5]);
  initial begin
    wait(&done);
    $finish;
  end
endmodule
