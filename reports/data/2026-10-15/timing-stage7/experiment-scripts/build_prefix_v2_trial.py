from pathlib import Path
import importlib.util,json,hashlib,re
root=Path('build/frequency-stage7/address-mul2-prefix-v2/rtl')
root.mkdir(parents=True,exist_ok=True)
source=Path('build/frequency-stage7/pipelined_muldiv.sv').read_text()
words=('out_result_q','div_result_q','quotient_q','divisor_q','remainder_q','div_a_q','div_b_q','cache_a_q','cache_b_q','cache_quotient_q','cache_remainder_q')
pattern=r'\b(?:'+ '|'.join(words)+r'|mul_result_q\[[^\]]+\])\s*<=.*?;'
source,count=re.subn(pattern,';',source)
assert count==36,count
extra='''
  wire data_clear=rst || kill;
  wire accept_div=req_valid && req_ready && request_div;
  wire finish_div=div_live && step_q==STEP_W'(DIV_STEPS-1);
  wire start_div=accept_div && !cache_hit && !shortcut;
  wire save_shortcut=accept_div && !cache_hit && shortcut;
  wire accept_mul=pipeline_consume && !grant_new_mul;
  wire [31:0] fresh_div_result=cache_hit ?
    ((req_op==OP_REM || req_op==OP_REMU) ? cache_remainder_q:cache_quotient_q):
    ((req_op==OP_REM || req_op==OP_REMU) ? shortcut_remainder:shortcut_quotient);
'''
def word(name,width,enables,data):
    global extra
    assert len(enables)==len(data)
    extra+=f'  v2_priority_register #(.WORD_BITS({width}),.PORTS({len(enables)})) data_{name} (\n'
    extra+=f'    .clk,.clear(data_clear),.enable({{{",".join(reversed(enables))}}}),\n'
    extra+=f'    .data({{{",".join(reversed(data))}}}),.value({name}));\n'
word('out_result_q',32,['grant_new_mul','grant_mul','grant_div'],['mul_computed','mul_result_q[mul_head]','div_result_q'])
word('div_result_q',32,['finish_div','accept_div && (cache_hit || shortcut)'],['remainder_operation_q ? completed_remainder:completed_quotient','fresh_div_result'])
word('quotient_q',32,['div_live','start_div'],['quotient_next','a_magnitude<<(leading_steps*DIV_STEP_BITS)'])
word('remainder_q',33,['div_live','start_div'],['remainder_next',"33'd0"])
word('divisor_q',32,['start_div'],['b_magnitude'])
for name,initial in [('div_a_q','req_a'),('div_b_q','req_b')]:
    word(name,32,['accept_div'],[initial])
for name,initial,complete in [('cache_a_q','req_a','div_a_q'),('cache_b_q','req_b','div_b_q'),('cache_quotient_q','shortcut_quotient','completed_quotient'),('cache_remainder_q','shortcut_remainder','completed_remainder')]:
    word(name,32,['finish_div','save_shortcut'],[complete,initial])
word('mul_result_q[0]',32,['mul_ready0 && accept_mul'],['mul_computed'])
word('mul_result_q[1]',32,['mul_ready1 && mul_remaining[0]'],['mul_result_q[0]'])
word('mul_result_q[2]',32,['mul_ready2 && mul_remaining[1]'],['mul_result_q[1]'])
extra=re.sub(r'data_mul_result_q\[(\d)\]',r'data_mul_result_\1',extra)
source=source.replace('`ifndef SYNTHESIS',extra+'\n`ifndef SYNTHESIS',1)
source=source.replace('wire [31:0] product_high=sum3+carry3;',
    'wire [31:0] product_high;\n'
    '  v2_prefix_adder #(.WIDTH(32)) product_final_add (.a(sum3),.b(carry3),.carry_in(1\'b0),.sum(product_high),.carry_out());')
(root/'muldiv.sv').write_text(source)

core=Path('verilog/area_v2/cpu_top.sv').read_text()
core=core.replace('logic [31:0] memory_address,memory_data,load_word,load_result;',
    'logic [31:0] memory_address,memory_data,load_word,load_result;\n'
    '  logic [31:0] prepared_address [IQ_ENTRIES];\n'
    '  wire [IQ_ENTRIES*32-1:0] prepared_address_words;')
core=core.replace('assign memory_address=executing[2].a+executing[2].imm;',"""
  for(genvar q=0;q<IQ_ENTRIES;q=q+1) begin: memory_address_words
    assign prepared_address_words[q*32+:32]=prepared_address[q];
  end
  v2_iq_read #(.ENTRIES(IQ_ENTRIES),.WORD_BITS(32)) read_memory_address (
    .index(selected[2]),.words(prepared_address_words),.value(memory_address));
""")
needle='      always_ff @(posedge clk) begin\n        queue[bank][q].ready_a<=next_ready_a;queue[bank][q].a<=next_value_a;\n        queue[bank][q].ready_b<=next_ready_b;queue[bank][q].b<=next_value_b;\n      end\n'
assert core.count(needle)==1
core=core.replace(needle,needle+"""
      if(bank==2) begin: address_prepare
        wire [31:0] address_immediate=queue[bank][q].valid ? queue[bank][q].imm:
          (prepare_lane[1] ? dispatch_payload[1].imm:dispatch_payload[0].imm);
        wire address_update=(!queue[bank][q].valid && |prepare_lane) ||
                            (queue[bank][q].valid && !queue[bank][q].ready_a);
        always_ff @(posedge clk)
          if(address_update) prepared_address[q]<=next_value_a+address_immediate;
      end
""")

core=core.replace('if(address_update) prepared_address[q]<=next_value_a+address_immediate;',
    'if(address_update) prepared_address[q]<=address_sum;')
core=core.replace('wire address_update=',
    "wire [31:0] address_sum;\n"
    "        v2_prefix_adder #(.WIDTH(32)) effective_address_add (.a(next_value_a),.b(address_immediate),.carry_in(1'b0),.sum(address_sum),.carry_out());\n"
    '        wire address_update=')
(root/'cpu_top.sv').write_text(core)
alu=Path('verilog/area_v2/alu.sv').read_text()
alu=alu.replace('  always_comb begin',"""
  wire subtract=op==OP_SUB || op==OP_SLT || op==OP_SLTU;
  wire [31:0] arithmetic_value,pc_value;
  wire no_borrow;
  v2_prefix_adder #(.WIDTH(32)) add_operands (
    .a(a),.b(b^{32{subtract}}),.carry_in(subtract),.sum(arithmetic_value),.carry_out(no_borrow));
  v2_prefix_adder #(.WIDTH(32)) add_pc (
    .a(pc),.b(imm),.carry_in(1'b0),.sum(pc_value),.carry_out());
  always_comb begin""")
alu=alu.replace('result = a + b;', 'result = arithmetic_value;').replace('result = a - b;', 'result = arithmetic_value;')
alu=alu.replace("result = {31'b0, $signed(a) < $signed(b)};", "result = {31'b0, a[31]!=b[31] ? a[31]:!no_borrow};")
alu=alu.replace("result = {31'b0, a < b};", "result = {31'b0, !no_borrow};")
alu=alu.replace('result = pc + imm;', 'result = pc_value;')
(root/'alu.sv').write_text(alu)


spec=importlib.util.spec_from_file_location('export_plain','scripts/area_v2/export_plain.py')
converter=importlib.util.module_from_spec(spec);spec.loader.exec_module(converter)
package=Path('verilog/area_v2/cpu_pkg.sv').read_text()
output='// Frozen recovery + distributed MDU trial.\n'
for path in sorted(Path('verilog/area_v2').glob('*.sv')):
    if path.name=='cpu_pkg.sv': continue
    output+=converter.lower(source if path.name=='muldiv.sv' else core if path.name=='cpu_top.sv' else alu if path.name=='alu.sv' else path.read_text(),package)+'\n'
(root/'area_v2_core.v').write_text(output)
for name in ('student_top.sv','pararisc_axi_adapter.sv'):
    data=(Path('verilog')/name).read_text()
    if name=='student_top.sv': data=re.sub(r'\b(CONTROL_TREE|ROB_WRITE_TREE|CACHE_TREE|COMMIT_TREE|REGISTER_REDIRECT)=0\b',r'\1=1',data)
    (root/name).write_text(data)
(root/'filelist.f').write_text('area_v2_core.v\npararisc_axi_adapter.sv\nstudent_top.sv\n')
(root/'source-hashes.json').write_text(json.dumps({p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in root.glob('*') if p.suffix in ('.v','.sv')},indent=2)+'\n')
