`timescale 1ns/1ps
module parallel_select_case #(parameter ENTRIES=4, BITS=6, INDEX_BITS=$clog2(ENTRIES))(output reg done=0);
  reg [ENTRIES-1:0] ready;
  reg [ENTRIES*BITS-1:0] owner;
  reg [ENTRIES*32-1:0] words;
  wire valid;
  wire [INDEX_BITS-1:0] index;
  wire [ENTRIES-1:0] grant;
  wire [31:0] value;
  integer offsets[ENTRIES];
  integer base,expected,min_offset,seed=32'h4129e8;
  reg [ENTRIES-1:0] expected_grant;
  reg [31:0] expected_value;
  v2_parallel_select #(.ENTRIES(ENTRIES),.SLOT_BITS(BITS)) dut (
    .ready,.owner,.rob_head({BITS{1'b0}}),.valid,.index,.grant);
  v2_grant_read #(.ENTRIES(ENTRIES)) read_value(.grant,.words,.value);
  initial begin
    for(integer sample=0;sample<30000;sample=sample+1) begin
      base=$unsigned($random(seed))%(1<<BITS);ready=$random(seed);
      expected=-1;min_offset=(1<<BITS);expected_grant=0;expected_value=0;
      for(integer row=0;row<ENTRIES;row=row+1) begin
        offsets[row]=(sample%8==0) ? 0:$unsigned($random(seed))%(1<<(BITS-1));
        owner[row*BITS+:BITS]=BITS'(base+offsets[row]);
        words[row*32+:32]=$random(seed);
        if(ready[row] && offsets[row]<min_offset) begin
          expected=row;min_offset=offsets[row];
        end
      end
      if(expected>=0) begin
        expected_grant[expected]=1;expected_value=words[expected*32+:32];
      end
      #1;
      if(valid!==(expected>=0) || grant!==expected_grant || value!==expected_value ||
         (valid && index!==INDEX_BITS'(expected)))
        $fatal(1,"parallel age selection mismatch entries=%0d sample=%0d base=%0d",ENTRIES,sample,base);
    end
    $display("Parallel issue: PASS entries=%0d tag_bits=%0d checks=30000",ENTRIES,BITS);done=1;
  end
endmodule
module v2_parallel_select_tb;
  wire [2:0] done;
  parallel_select_case #(.ENTRIES(3),.BITS(6)) case3(done[0]);
  parallel_select_case #(.ENTRIES(4),.BITS(6)) case4(done[1]);
  parallel_select_case #(.ENTRIES(8),.BITS(7)) case8(done[2]);
  initial begin wait(&done);$finish;end
endmodule
