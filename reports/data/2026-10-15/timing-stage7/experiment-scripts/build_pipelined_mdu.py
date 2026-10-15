from pathlib import Path
s=Path('verilog/area_v2/muldiv.sv').read_text()
s=s.replace('parameter integer DIV_STEP_BITS=4','parameter integer DIV_STEP_BITS=2')
s=s.replace('  assign request_mul=', '''
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
  wire [31:0] product_high=sum3+carry3;
  always_ff @(posedge clk) begin
    if(rst || kill) begin pipeline_valid_q<=0;pipeline_low_q<=0;pipeline_tag_q<=0;end
    else if(pipeline_ready) begin
      pipeline_valid_q<=pipeline_accept;
      if(pipeline_accept) begin pipeline_low_q<=req_op==OP_MUL;pipeline_tag_q<=req_tag;end
    end
  end
  assign request_mul=''',1)
s=s.replace('assign mul_ready=!rst && !kill && mul_ready0;', 'assign mul_ready=!rst && !kill && pipeline_ready;')
s=s.replace('assign grant_new_mul=out_space && !grant_mul && !grant_div && req_valid && req_ready && request_mul;', 'assign grant_new_mul=out_space && !grant_mul && !grant_div && pipeline_consume;')
s=s.replace('assign product=req_a*req_b;','')
s=s.replace("assign mul_computed=req_op==OP_MUL ? product[31:0] : product[63:32]-correction_a-correction_b;", "assign mul_computed=pipeline_low_q ? {product_middle[15:0],pp00_q[15:0]}:product_high;")
s=s.replace('out_result_q<=mul_computed;out_tag_q<=req_tag;', 'out_result_q<=mul_computed;out_tag_q<=pipeline_tag_q;')
s=s.replace('req_valid && req_ready && request_mul && !grant_new_mul', 'pipeline_consume && !grant_new_mul')
s=s.replace('mul_tag_q[0]<=req_tag;', 'mul_tag_q[0]<=pipeline_tag_q;')
extra='\n'
for name,expr in [('pp00_q','req_a[15:0]*req_b[15:0]'),('pp01_q','req_a[15:0]*req_b[31:16]'),('pp10_q','req_a[31:16]*req_b[15:0]'),('pp11_q','req_a[31:16]*req_b[31:16]'),('pcorr_a_q','correction_a'),('pcorr_b_q','correction_b')]:
    if '*' in expr:
        a,b=expr.split('*');expr="{16'b0,"+a+"}*{16'b0,"+b+"}"
    extra+=f'  v2_priority_register #(.PORTS(1)) stage_{name} (.clk,.clear(rst || kill),.enable(pipeline_accept),.data({expr}),.value({name}));\n'
s=s.replace('`ifndef SYNTHESIS',extra+'\n`ifndef SYNTHESIS',1)
Path('build/frequency-stage7/pipelined_muldiv.sv').write_text(s)
p=Path('build/frequency-stage7/build_address_trial.py')
b=p.read_text().replace('address-radix4/rtl','address-mul2/rtl')
b=b.replace("source=Path('verilog/area_v2/muldiv.sv').read_text().replace('parameter integer DIV_STEP_BITS=4','parameter integer DIV_STEP_BITS=2')", "source=Path('build/frequency-stage7/pipelined_muldiv.sv').read_text()")
b=b.replace('wire accept_mul=req_valid && req_ready && request_mul && !grant_new_mul;', 'wire accept_mul=pipeline_consume && !grant_new_mul;')
Path('build/frequency-stage7/build_mul2_trial.py').write_text(b)
