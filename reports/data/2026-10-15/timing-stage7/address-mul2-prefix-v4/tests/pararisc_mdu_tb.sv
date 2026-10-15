module pararisc_mdu_tb;
  reg clock=0, reset=1, flush=0, req_valid=0, resp_ready=0;
  reg [31:0] req_a=0, req_b=0;
  reg [2:0] req_op=0;
  reg [7:0] req_tag=0;
  reg [255:0] kill_mask=0;
  wire req_ready, resp_valid;
  wire [31:0] resp_value;
  wire [7:0] resp_tag;
  muldiv dut(.clk(clock),.rst(reset),.kill(flush),.kill_mask(kill_mask),
    .req_valid(req_valid),.req_ready(req_ready),.req_a(req_a),.req_b(req_b),.req_op({3'b0,req_op}+6'd22),.req_tag(req_tag),
    .rsp_valid(resp_valid),.rsp_ready(resp_ready),.rsp_result(resp_value),.rsp_tag(resp_tag),.mul_ready(),.div_ready());
  always #5 clock=~clock;
  integer checks=0;
  function automatic [31:0] reference(input [31:0] a,b,input [2:0] op);
    reg signed [63:0] sa,sb,sp;
    reg [63:0] up;
    begin
      sa={{32{a[31]}},a}; sb={{32{b[31]}},b}; up={32'b0,a}*{32'b0,b};
      case(op)
        0: reference=up[31:0];
        1: begin sp=sa*sb; reference=sp[63:32]; end
        2: begin sp=sa*$signed({32'b0,b}); reference=sp[63:32]; end
        3: reference=up[63:32];
        4: begin
          if(b==0) reference=32'hffffffff;
          else if(a==32'h80000000 && b==32'hffffffff) reference=a;
          else reference=$signed(a)/$signed(b);
        end
        5: reference=b==0 ? 32'hffffffff : a/b;
        6: begin
          if(b==0) reference=a;
          else if(a==32'h80000000 && b==32'hffffffff) reference=0;
          else reference=$signed(a)%$signed(b);
        end
        7: reference=b==0 ? a : a%b;
      endcase
    end
  endfunction
  task automatic check(input [31:0] a,b,input [2:0] op);
    reg [31:0] expected;
    reg [7:0] tag;
    integer cycles;
    begin
      expected=reference(a,b,op);tag=8'(checks);
      @(negedge clock);
      if(!req_ready) $fatal(1,"unit not ready");
      req_a=a;req_b=b;req_op=op;req_tag=tag;req_valid=1;
      @(negedge clock);req_valid=0;cycles=0;
      while(!resp_valid && cycles<80) begin @(negedge clock);cycles=cycles+1;end
      if(!resp_valid || resp_value!==expected || resp_tag!==tag)
        $fatal(1,"op=%0d a=%h b=%h expected=%h got=%h tag=%h cycles=%0d",op,a,b,expected,resp_value,resp_tag,cycles);
      // Output must remain stable under response backpressure.
      repeat(3) begin
        @(negedge clock);
        if(!resp_valid || resp_value!==expected || resp_tag!==tag) $fatal(1,"unstable response");
      end
      resp_ready=1;@(negedge clock);resp_ready=0;checks=checks+1;
    end
  endtask
  task automatic cancel(input [2:0] op,input integer delay_cycles);
    begin
      @(negedge clock);req_a=32'h81234567;req_b=3;req_op=op;req_valid=1;
      @(negedge clock);req_valid=0;
      repeat(delay_cycles) @(negedge clock);
      flush=1;@(negedge clock);flush=0;
      repeat(45) begin @(negedge clock);if(resp_valid) $fatal(1,"response survived flush");end
      if(!req_ready) $fatal(1,"flush did not release unit");
    end
  endtask
  initial begin
    repeat(2) @(negedge clock);reset=0;
    for(integer op=0;op<8;op=op+1) begin
      check(0,0,3'(op)); check(32'h80000000,32'hffffffff,3'(op));
      check(32'hffffffff,1,3'(op)); check(32'h80000000,1,3'(op));
      check(1,32'hffffffff,3'(op)); check(0,123,3'(op));
      check(32'hffffffff,32'hffffffff,3'(op)); check(123,0,3'(op));
      for(integer bitno=0;bitno<32;bitno=bitno+1) begin
        check(32'b1<<bitno,3,3'(op)); check(32'hffffffff,32'b1<<bitno,3'(op));
      end
      repeat(250) check($urandom,$urandom,3'(op));
    end
    for(integer delay_cycles=0;delay_cycles<12;delay_cycles=delay_cycles+1) begin
      cancel(0,delay_cycles);cancel(4,delay_cycles);
    end
    check(12345,67,4);
    $display("Area-v2 muldiv: PASS %0d arithmetic cases, 24 flush cases",checks);$finish;
  end
endmodule
