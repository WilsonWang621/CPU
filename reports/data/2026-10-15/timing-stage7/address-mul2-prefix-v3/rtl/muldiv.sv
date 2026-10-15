module muldiv #(
  parameter integer DIV_STEP_BITS=2
)(
  input logic clk, rst, kill,
  input logic [255:0] kill_mask,
  input logic req_valid,
  output logic req_ready,
  output logic mul_ready,div_ready,
  input cpu_pkg::op_t req_op,
  input logic [31:0] req_a, req_b,
  input logic [7:0] req_tag,
  output logic rsp_valid,
  input logic rsp_ready,
  output logic [31:0] rsp_result,
  output logic [7:0] rsp_tag
);
  import cpu_pkg::*;
  localparam integer DIV_STEPS=32/DIV_STEP_BITS;
  localparam integer STEP_W=$clog2(DIV_STEPS);

  // Complete the arithmetic in one cycle, then retain up to three pending
  // results independently of the shared output register. Empty queues bypass
  // directly into that output; blocked results retain oldest-first ordering.
  logic [2:0] mul_valid_q,mul_live,mul_remaining;
  logic mul_ready0,mul_ready1,mul_ready2;
  logic [1:0] mul_head;
  logic [7:0] mul_tag_q [3];
  logic [31:0] mul_result_q [3];
  logic [31:0] mul_computed,correction_a,correction_b;
  logic [63:0] product;
  logic grant_new_mul;

  logic div_busy_q,div_done_q;
  logic [7:0] div_tag_q;
  logic [31:0] quotient_q,divisor_q,div_result_q;
  logic [32:0] remainder_q;
  logic [STEP_W-1:0] step_q;
  logic quotient_negative_q,remainder_negative_q,remainder_operation_q;
  logic [31:0] quotient_next;
  logic [32:0] remainder_next,shifted;
  logic [31:0] div_a_q,div_b_q,completed_quotient,completed_remainder;
  logic div_signed_q;
  logic cache_valid_q,cache_signed_q,cache_hit;
  logic [31:0] cache_a_q,cache_b_q,cache_quotient_q,cache_remainder_q;
  logic shortcut;
  logic [31:0] shortcut_quotient,shortcut_remainder;
  integer leading_steps;

  logic out_valid_q,prefer_div_q,out_space,grant_mul,grant_div;
  logic [31:0] out_result_q;
  logic [7:0] out_tag_q;
  logic request_mul,request_div,signed_divide,a_negative,b_negative;
  logic [31:0] a_magnitude,b_magnitude;
  logic div_live,div_result_live;


  logic pipeline_valid_q,pipeline_low_q;
  logic [7:0] pipeline_tag_q;
  wire pipeline_live=pipeline_valid_q && !kill_mask[pipeline_tag_q];
  wire pipeline_ready=!pipeline_live || mul_ready0;
  wire pipeline_consume=pipeline_live && mul_ready0;
  wire pipeline_accept=req_valid && req_ready && request_mul;
  wire [31:0] pp00_q,pp01_q,pp10_q,pp11_q,pcorr_a_q,pcorr_b_q;
  wire [17:0] product_middle={2'b0,pp00_q[31:16]}+{2'b0,pp01_q[15:0]}+{2'b0,pp10_q[15:0]};
  wire [31:0] term0=pp11_q,term1={16'b0,pp01_q[31:16]},term2={16'b0,pp10_q[31:16]};
  wire [31:0] term3={30'b0,product_middle[17:16]}+32'd2;
  wire [31:0] term4=~pcorr_a_q,term5=~pcorr_b_q;
  wire [31:0] sum0=term0^term1^term2;
  wire [31:0] carry0=((term0&term1)|(term0&term2)|(term1&term2))<<1;
  wire [31:0] sum1=term3^term4^term5;
  wire [31:0] carry1=((term3&term4)|(term3&term5)|(term4&term5))<<1;
  wire [31:0] sum2=sum0^carry0^sum1;
  wire [31:0] carry2=((sum0&carry0)|(sum0&sum1)|(carry0&sum1))<<1;
  wire [31:0] sum3=sum2^carry2^carry1;
  wire [31:0] carry3=((sum2&carry2)|(sum2&carry1)|(carry2&carry1))<<1;
  wire [31:0] product_high;
  v2_prefix_adder #(.WIDTH(32)) product_final_add (.a(sum3),.b(carry3),.carry_in(1'b0),.sum(product_high),.carry_out());
  always_ff @(posedge clk) begin
    if(rst || kill) begin pipeline_valid_q<=0;pipeline_low_q<=0;pipeline_tag_q<=0;end
    else if(pipeline_ready) begin
      pipeline_valid_q<=pipeline_accept;
      if(pipeline_accept) begin pipeline_low_q<=req_op==OP_MUL;pipeline_tag_q<=req_tag;end
    end
  end
  assign request_mul=req_op>=OP_MUL && req_op<=OP_MULHU;
  assign request_div=req_op>=OP_DIV && req_op<=OP_REMU;
  assign signed_divide=req_op==OP_DIV || req_op==OP_REM;
  assign a_negative=signed_divide && req_a[31];
  assign b_negative=signed_divide && req_b[31];
  assign a_magnitude=a_negative ? (~req_a+32'd1) : req_a;
  assign b_magnitude=b_negative ? (~req_b+32'd1) : req_b;
  assign div_live=div_busy_q && !kill_mask[div_tag_q];
  assign div_result_live=div_done_q && !kill_mask[div_tag_q];
  assign rsp_valid=out_valid_q && !kill_mask[out_tag_q] && !kill && !rst;
  assign rsp_result=out_result_q;
  assign rsp_tag=out_tag_q;
  assign out_space=!out_valid_q || kill_mask[out_tag_q] || rsp_ready;
  for(genvar stage=0;stage<3;stage=stage+1) begin : g_live
    assign mul_live[stage]=mul_valid_q[stage] && !kill_mask[mul_tag_q[stage]];
    assign mul_remaining[stage]=mul_live[stage] && !(grant_mul && mul_head==2'(stage));
  end
  assign mul_head=mul_live[2] ? 2'd2 : mul_live[1] ? 2'd1 : 2'd0;
  assign grant_div=out_space && div_result_live && (!(|mul_live) || prefer_div_q);
  assign grant_mul=out_space && (|mul_live) && (!div_result_live || !prefer_div_q);
  assign mul_ready2=!mul_remaining[2];
  assign mul_ready1=!mul_remaining[1] || mul_ready2;
  assign mul_ready0=!mul_remaining[0] || mul_ready1;
  // Scheduler hints describe unit capacity before a request opcode/tag is chosen.
  assign mul_ready=!rst && !kill && pipeline_ready;
  assign div_ready=!rst && !kill && !div_live && (!div_result_live || grant_div);
  assign req_ready=!kill_mask[req_tag] &&
    ((request_mul && mul_ready) || (request_div && div_ready));
  // Fresh requests affect only the registered output/data inputs, never the
  // structural ready hints or arbitration of already-buffered results.
  assign grant_new_mul=out_space && !grant_mul && !grant_div && pipeline_consume;
  
  assign correction_a=req_a[31] && (req_op==OP_MULH || req_op==OP_MULHSU) ? req_b:32'd0;
  assign correction_b=req_b[31] && req_op==OP_MULH ? req_a:32'd0;
  assign mul_computed=pipeline_low_q ? {product_middle[15:0],pp00_q[15:0]}:product_high;
  assign cache_hit=cache_valid_q && cache_a_q==req_a && cache_b_q==req_b && cache_signed_q==signed_divide;
  assign completed_quotient=quotient_negative_q ? (~quotient_next+32'd1) : quotient_next;
  assign completed_remainder=remainder_negative_q ? (~remainder_next[31:0]+32'd1) : remainder_next[31:0];

  // Skip only whole zero radix groups: those restoring steps produce neither
  // quotient bits nor a remainder. Preserve at least one group for nonzero a.
  always_comb begin
    leading_steps=0;
    for(integer groups=1;groups<DIV_STEPS;groups=groups+1)
      if((a_magnitude>>(32-DIV_STEP_BITS*groups))==0) leading_steps=groups;
    shortcut=1;shortcut_quotient=0;shortcut_remainder=0;
    if(req_b==0) begin shortcut_quotient=32'hffffffff;shortcut_remainder=req_a;end
    else if(signed_divide && req_a==32'h80000000 && req_b==32'hffffffff)
      shortcut_quotient=32'h80000000;
    else if(a_magnitude<b_magnitude || a_magnitude==0) shortcut_remainder=req_a;
    else if(b_magnitude==1)
      shortcut_quotient=(a_negative^b_negative) ? (~a_magnitude+32'd1) : a_magnitude;
    else shortcut=0;
  end

  // Radix 16 by four restoring steps per cycle. DIV_STEP_BITS=2 selects radix 4.
  always_comb begin
    quotient_next=quotient_q;
    remainder_next=remainder_q;
    shifted=0;
    if(div_live) for(integer bit_step=0;bit_step<DIV_STEP_BITS;bit_step=bit_step+1) begin
      shifted={remainder_next[31:0],quotient_next[31]};
      quotient_next={quotient_next[30:0],1'b0};
      if(shifted>={1'b0,divisor_q}) begin
        remainder_next=shifted-{1'b0,divisor_q};
        quotient_next[0]=1'b1;
      end else remainder_next=shifted;
    end
  end

  always_ff @(posedge clk) begin
    if(rst || kill) begin
      mul_valid_q<=0;
      for(integer stage=0;stage<3;stage=stage+1) begin
        mul_tag_q[stage]<=0;;
      end
      div_busy_q<=0;div_done_q<=0;div_tag_q<=0;;
      ;;;step_q<=0;
      quotient_negative_q<=0;remainder_negative_q<=0;remainder_operation_q<=0;
      ;;div_signed_q<=0;
      cache_valid_q<=0;cache_signed_q<=0;;;
      ;;
      out_valid_q<=0;;out_tag_q<=0;prefer_div_q<=1;
    end else begin
      // Output arbitration only replaces a free/accepted/canceled response.
      if(out_space) begin
        out_valid_q<=grant_div || grant_mul || grant_new_mul;
        if(grant_div) begin
          ;out_tag_q<=div_tag_q;prefer_div_q<=0;
        end else if(grant_mul) begin
          ;out_tag_q<=mul_tag_q[mul_head];prefer_div_q<=1;
        end else if(grant_new_mul) begin
          ;out_tag_q<=pipeline_tag_q;prefer_div_q<=1;
        end
      end

      if(mul_ready2) begin
        mul_valid_q[2]<=mul_remaining[1];
        if(mul_remaining[1]) begin
          mul_tag_q[2]<=mul_tag_q[1];;
        end
      end
      if(mul_ready1) begin
        mul_valid_q[1]<=mul_remaining[0];
        if(mul_remaining[0]) begin
          mul_tag_q[1]<=mul_tag_q[0];;
        end
      end
      if(mul_ready0) begin
        mul_valid_q[0]<=pipeline_consume && !grant_new_mul;
        if(pipeline_consume && !grant_new_mul) begin
          mul_tag_q[0]<=pipeline_tag_q;;
        end
      end

      if(kill_mask[div_tag_q]) begin div_busy_q<=0;div_done_q<=0;end
      if(grant_div) div_done_q<=0;
      if(div_live) begin
        ;;
        step_q<=step_q+1'b1;
        if(step_q==STEP_W'(DIV_STEPS-1)) begin
          div_busy_q<=0;div_done_q<=1;
          ;
          // This point is unreachable for a selectively killed partial divide.
          // Completed arithmetic is pure and may remain cached after tag cancel.
          cache_valid_q<=1;;;cache_signed_q<=div_signed_q;
          ;;
        end
      end
      if(req_valid && req_ready && request_div) begin
        div_tag_q<=req_tag;
        ;;div_signed_q<=signed_divide;
        quotient_negative_q<=a_negative^b_negative;remainder_negative_q<=a_negative;
        remainder_operation_q<=req_op==OP_REM || req_op==OP_REMU;
        div_busy_q<=0;div_done_q<=1;
        if(cache_hit)
          ;
        else if(shortcut) begin
          ;
          cache_valid_q<=1;;;cache_signed_q<=signed_divide;
          ;;
        end else begin
          div_busy_q<=1;div_done_q<=0;step_q<=STEP_W'(leading_steps);
          ;
          ;;
        end
      end
    end
  end

  v2_priority_register #(.PORTS(1)) stage_pp00_q (.clk,.clear(rst || kill),.enable(pipeline_accept),.data({16'b0,req_a[15:0]}*{16'b0,req_b[15:0]}),.value(pp00_q));
  v2_priority_register #(.PORTS(1)) stage_pp01_q (.clk,.clear(rst || kill),.enable(pipeline_accept),.data({16'b0,req_a[15:0]}*{16'b0,req_b[31:16]}),.value(pp01_q));
  v2_priority_register #(.PORTS(1)) stage_pp10_q (.clk,.clear(rst || kill),.enable(pipeline_accept),.data({16'b0,req_a[31:16]}*{16'b0,req_b[15:0]}),.value(pp10_q));
  v2_priority_register #(.PORTS(1)) stage_pp11_q (.clk,.clear(rst || kill),.enable(pipeline_accept),.data({16'b0,req_a[31:16]}*{16'b0,req_b[31:16]}),.value(pp11_q));
  v2_priority_register #(.PORTS(1)) stage_pcorr_a_q (.clk,.clear(rst || kill),.enable(pipeline_accept),.data(correction_a),.value(pcorr_a_q));
  v2_priority_register #(.PORTS(1)) stage_pcorr_b_q (.clk,.clear(rst || kill),.enable(pipeline_accept),.data(correction_b),.value(pcorr_b_q));


  wire data_clear=rst || kill;
  wire accept_div=req_valid && req_ready && request_div;
  wire finish_div=div_live && step_q==STEP_W'(DIV_STEPS-1);
  wire start_div=accept_div && !cache_hit && !shortcut;
  wire save_shortcut=accept_div && !cache_hit && shortcut;
  wire accept_mul=pipeline_consume && !grant_new_mul;
  wire [31:0] fresh_div_result=cache_hit ?
    ((req_op==OP_REM || req_op==OP_REMU) ? cache_remainder_q:cache_quotient_q):
    ((req_op==OP_REM || req_op==OP_REMU) ? shortcut_remainder:shortcut_quotient);
  v2_priority_register #(.WORD_BITS(32),.PORTS(3)) data_out_result_q (
    .clk,.clear(data_clear),.enable({grant_div,grant_mul,grant_new_mul}),
    .data({div_result_q,mul_result_q[mul_head],mul_computed}),.value(out_result_q));
  v2_priority_register #(.WORD_BITS(32),.PORTS(2)) data_div_result_q (
    .clk,.clear(data_clear),.enable({accept_div && (cache_hit || shortcut),finish_div}),
    .data({fresh_div_result,remainder_operation_q ? completed_remainder:completed_quotient}),.value(div_result_q));
  v2_priority_register #(.WORD_BITS(32),.PORTS(2)) data_quotient_q (
    .clk,.clear(data_clear),.enable({start_div,div_live}),
    .data({a_magnitude<<(leading_steps*DIV_STEP_BITS),quotient_next}),.value(quotient_q));
  v2_priority_register #(.WORD_BITS(33),.PORTS(2)) data_remainder_q (
    .clk,.clear(data_clear),.enable({start_div,div_live}),
    .data({33'd0,remainder_next}),.value(remainder_q));
  v2_priority_register #(.WORD_BITS(32),.PORTS(1)) data_divisor_q (
    .clk,.clear(data_clear),.enable({start_div}),
    .data({b_magnitude}),.value(divisor_q));
  v2_priority_register #(.WORD_BITS(32),.PORTS(1)) data_div_a_q (
    .clk,.clear(data_clear),.enable({accept_div}),
    .data({req_a}),.value(div_a_q));
  v2_priority_register #(.WORD_BITS(32),.PORTS(1)) data_div_b_q (
    .clk,.clear(data_clear),.enable({accept_div}),
    .data({req_b}),.value(div_b_q));
  v2_priority_register #(.WORD_BITS(32),.PORTS(2)) data_cache_a_q (
    .clk,.clear(data_clear),.enable({save_shortcut,finish_div}),
    .data({req_a,div_a_q}),.value(cache_a_q));
  v2_priority_register #(.WORD_BITS(32),.PORTS(2)) data_cache_b_q (
    .clk,.clear(data_clear),.enable({save_shortcut,finish_div}),
    .data({req_b,div_b_q}),.value(cache_b_q));
  v2_priority_register #(.WORD_BITS(32),.PORTS(2)) data_cache_quotient_q (
    .clk,.clear(data_clear),.enable({save_shortcut,finish_div}),
    .data({shortcut_quotient,completed_quotient}),.value(cache_quotient_q));
  v2_priority_register #(.WORD_BITS(32),.PORTS(2)) data_cache_remainder_q (
    .clk,.clear(data_clear),.enable({save_shortcut,finish_div}),
    .data({shortcut_remainder,completed_remainder}),.value(cache_remainder_q));
  v2_priority_register #(.WORD_BITS(32),.PORTS(1)) data_mul_result_0 (
    .clk,.clear(data_clear),.enable({mul_ready0 && accept_mul}),
    .data({mul_computed}),.value(mul_result_q[0]));
  v2_priority_register #(.WORD_BITS(32),.PORTS(1)) data_mul_result_1 (
    .clk,.clear(data_clear),.enable({mul_ready1 && mul_remaining[0]}),
    .data({mul_result_q[0]}),.value(mul_result_q[1]));
  v2_priority_register #(.WORD_BITS(32),.PORTS(1)) data_mul_result_2 (
    .clk,.clear(data_clear),.enable({mul_ready2 && mul_remaining[1]}),
    .data({mul_result_q[1]}),.value(mul_result_q[2]));

`ifndef SYNTHESIS
  always_ff @(posedge clk) if(!rst && !kill) begin
    assert(!(div_busy_q && div_done_q)) else $fatal(1,"divider owns both compute and result slots");
  end
`endif
  initial begin
    if(DIV_STEP_BITS!=2 && DIV_STEP_BITS!=4) $fatal(1,"DIV_STEP_BITS must be 2 or 4");
  end
endmodule
