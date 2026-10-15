from pathlib import Path
import importlib.util,json,hashlib,re
root=Path('build/frequency-stage7/recovery-mdu-v2/rtl')
root.mkdir(parents=True,exist_ok=True)
source=Path('verilog/area_v2/muldiv.sv').read_text()
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
  wire accept_mul=req_valid && req_ready && request_mul && !grant_new_mul;
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
(root/'muldiv.sv').write_text(source)
spec=importlib.util.spec_from_file_location('export_plain','scripts/area_v2/export_plain.py')
converter=importlib.util.module_from_spec(spec);spec.loader.exec_module(converter)
package=Path('verilog/area_v2/cpu_pkg.sv').read_text()
output='// Frozen recovery + distributed MDU trial.\n'
for path in sorted(Path('verilog/area_v2').glob('*.sv')):
    if path.name=='cpu_pkg.sv': continue
    output+=converter.lower(source if path.name=='muldiv.sv' else path.read_text(),package)+'\n'
(root/'area_v2_core.v').write_text(output)
for name in ('student_top.sv','pararisc_axi_adapter.sv'):
    data=(Path('verilog')/name).read_text()
    if name=='student_top.sv': data=data.replace('parameter integer CONTROL_TREE=0','parameter integer CONTROL_TREE=1')
    (root/name).write_text(data)
(root/'filelist.f').write_text('area_v2_core.v\npararisc_axi_adapter.sv\nstudent_top.sv\n')
(root/'source-hashes.json').write_text(json.dumps({p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in root.glob('*') if p.suffix in ('.v','.sv')},indent=2)+'\n')
