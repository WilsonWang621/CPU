`timescale 1ns/1ps
module circular_grant_case #(parameter ENTRIES=16, BITS=$clog2(ENTRIES))(output reg done=0);
  reg [ENTRIES-1:0] ready;
  reg [BITS-1:0] head;
  wire valid;
  wire [BITS-1:0] index;
  integer expected,oldest_distance,distance,checks=0;
  wire [ENTRIES-1:0] grant;
  wire [ENTRIES*36-1:0] words;
  wire [35:0] value;
  reg [ENTRIES-1:0] expected_grant;
  reg [35:0] expected_value;
  for(genvar q=0;q<ENTRIES;q=q+1) begin: payload
    assign words[q*36+:36]={4'(q),32'h98520000+32'(q)};
  end
  v2_grant_read #(.ENTRIES(ENTRIES),.WORD_BITS(36)) read_payload(.grant,.words,.value);
  v2_circular_grant #(.ENTRIES(ENTRIES),.INDEX_BITS(BITS)) dut(ready,head,valid,index,grant);
  initial begin
    for(integer start=0;start<ENTRIES;start=start+1) begin
      head=BITS'(start);
      for(integer mask=0;mask<(1<<ENTRIES);mask=mask+1) begin
        ready=ENTRIES'(mask);expected=-1;oldest_distance=-1;
        for(integer slot=0;slot<ENTRIES;slot=slot+1) begin
          distance=(slot+ENTRIES-start)%ENTRIES;
          if(ready[slot] && distance>oldest_distance) begin
            expected=slot;oldest_distance=distance;
          end
        end
        expected_grant=0;expected_value=0;
        if(expected>=0) begin expected_grant[expected]=1;expected_value=words[expected*36+:36];end
        #1;
        if(valid!==(expected>=0) || grant!==expected_grant || value!==expected_value || (valid && index!==BITS'(expected)))
          $fatal(1,"circular priority mismatch entries=%0d head=%0d mask=%h index=%0d expected=%0d",ENTRIES,start,ready,index,expected);
        checks=checks+1;
      end
    end
    $display("Circular grant and payload: PASS entries=%0d checks=%0d",ENTRIES,checks);done=1;
  end
endmodule
module v2_circular_grant_tb;
  wire [2:0] done;
  circular_grant_case #(.ENTRIES(4)) case4(done[0]);
  circular_grant_case #(.ENTRIES(8)) case8(done[1]);
  circular_grant_case #(.ENTRIES(16)) case16(done[2]);
  initial begin wait(&done);$finish;end
endmodule
