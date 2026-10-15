`timescale 1ns/1ps
// Independent architectural scoreboard for overlapping requests, selective
// cancellation, global flush and response backpressure. Tags have a reuse gap.
module v2_mdu_stream_tb;
  reg clk=0,rst=1,kill=0,req_valid=0,rsp_ready=0;
  always #5 clk=~clk;
  reg [31:0] a=0,b=0;
  reg [2:0] op=0;
  reg [7:0] tag=0;
  reg [255:0] kill_mask=0;
  wire req_ready,rsp_valid;
  wire [31:0] result;
  wire [7:0] result_tag;
  muldiv dut(.clk(clk),.rst(rst),.kill(kill),.kill_mask(kill_mask),
    .req_valid(req_valid),.req_ready(req_ready),.req_a(a),.req_b(b),
    .req_op({3'b0,op}+6'd22),.req_tag(tag),.rsp_valid(rsp_valid),
    .rsp_ready(rsp_ready),.rsp_result(result),.rsp_tag(result_tag),.mul_ready(),.div_ready());
  reg [255:0] live=0;
  reg [31:0] expected[0:255];
  integer released[0:255];
  integer cycle,i,j,candidate,chosen,active,peak=0;
  integer accepted=0,returned=0,canceled=0,flushed=0,holds=0;
  reg take,return_fire,held;
  reg [31:0] held_value;
  reg [7:0] held_tag;
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
  task consume;
    begin
      if(!live[result_tag] || result!==expected[result_tag])
        $fatal(1,"stream result mismatch cycle=%0d tag=%0d live=%b got=%h expected=%h",
          cycle,result_tag,live[result_tag],result,expected[result_tag]);
      live[result_tag]=0;released[result_tag]=cycle;returned=returned+1;
    end
  endtask
  initial begin
    for(i=0;i<256;i=i+1) released[i]=-10;
    repeat(3) @(negedge clk);
    rst=0;
    for(cycle=0;cycle<8000;cycle=cycle+1) begin
      @(negedge clk);
      kill=cycle%211==210;
      if(kill) begin
        req_valid=0;flushed=flushed+1;
        for(i=0;i<256;i=i+1) if(live[i]) begin live[i]=0;released[i]=cycle;canceled=canceled+1;end
      end else begin
        if(cycle%13==12) begin
          candidate=$urandom_range(0,255);chosen=-1;
          for(j=0;j<256;j=j+1) begin
            i=(candidate+j)%256;
            if(chosen<0 && live[i]) chosen=i;
          end
          if(chosen>=0) begin kill_mask[chosen]=1;live[chosen]=0;released[chosen]=cycle;canceled=canceled+1;end
        end
        if(!req_valid && $urandom_range(0,4)!=0) begin
          candidate=$urandom_range(0,255);chosen=-1;
          for(j=0;j<256;j=j+1) begin
            i=(candidate+j)%256;
            if(chosen<0 && !live[i] && cycle-released[i]>4) chosen=i;
          end
          if(chosen>=0) begin
            req_valid=1;tag=8'(chosen);kill_mask[chosen]=0;
            a=$urandom;b=$urandom;
            op=$urandom_range(0,7)==0 ? 3'($urandom_range(4,7)):3'($urandom_range(0,3));
          end
        end
      end
      rsp_ready=cycle%37<11 ? 0:$urandom_range(0,3)!=0;
      #1;
      take=req_valid && req_ready && !kill;
      return_fire=rsp_valid && rsp_ready;
      held=rsp_valid && !rsp_ready;held_tag=result_tag;held_value=result;
      @(posedge clk);
      if(return_fire) consume();
      if(take) begin
        if(live[tag]) $fatal(1,"test allocated a live tag");
        live[tag]=1;expected[tag]=reference(a,b,op);accepted=accepted+1;
      end
      active=0;for(i=0;i<256;i=i+1) if(live[i]) active=active+1;
      if(active>peak) peak=active;
      #1;
      if(take) req_valid=0;
      if(held && (!rsp_valid || result_tag!==held_tag || result!==held_value))
        $fatal(1,"stream response changed under backpressure cycle=%0d",cycle);
      if(held) holds=holds+1;
    end
    @(negedge clk);req_valid=0;kill=0;rsp_ready=1;
    repeat(200) begin
      #1;return_fire=rsp_valid;
      @(posedge clk);if(return_fire) consume();
      @(negedge clk);cycle=cycle+1;
    end
    if(live!=0 || accepted<500 || returned<300 || canceled<100 || peak<3 || holds<100)
      $fatal(1,"insufficient stream coverage accepted=%0d returned=%0d canceled=%0d peak=%0d holds=%0d live=%h",
        accepted,returned,canceled,peak,holds,live);
    $display("MDU stream: PASS accepted=%0d returned=%0d canceled=%0d flushes=%0d peak=%0d holds=%0d",
      accepted,returned,canceled,flushed,peak,holds);
    $finish;
  end
endmodule
