from pathlib import Path
import argparse,importlib.util,re,json,hashlib
p=argparse.ArgumentParser();p.add_argument('name');p.add_argument('--wb-tree',action='store_true');p.add_argument('--operand',action='store_true');p.add_argument('--wake-qualified',action='store_true');p.add_argument('--wake-tree',action='store_true');a=p.parse_args()
out=Path('build/frequency-stage8')/a.name/'rtl';out.mkdir(parents=True,exist_ok=True)
changed={}
if a.operand:
 changed['v2_operand.sv']='''// Parallel, mutually exclusive operand source selection.
(* keep_hierarchy=1 *)
module v2_operand #(parameter integer SLOT_BITS=5)(
  input wire live,prepare,old_ready,initial_ready,
  input wire [SLOT_BITS-1:0] source,
  input wire [31:0] old_value,initial_value,
  input wire [2:0] wb_good,
  input wire [3*SLOT_BITS-1:0] wb_slots,
  input wire [95:0] wb_values,
  output wire next_ready,
  output wire [31:0] next_value
);
  wire [2:0] hit,chosen;
  for(genvar w=0;w<3;w=w+1) begin: matching
    assign hit[w]=live && !old_ready && wb_good[w] && source==wb_slots[w*SLOT_BITS+:SLOT_BITS];
  end
  assign chosen[2]=hit[2];
  assign chosen[1]=hit[1] && !hit[2];
  assign chosen[0]=hit[0] && !(hit[1] || hit[2]);
  wire initializing=!live && prepare;
  wire holding=!(initializing || |chosen);
  assign next_ready=live ? (old_ready || |hit):(prepare ? initial_ready:old_ready);
  assign next_value=(old_value & {32{holding}}) | (initial_value & {32{initializing}}) |
                    (wb_values[31:0] & {32{chosen[0]}}) |
                    (wb_values[63:32] & {32{chosen[1]}}) |
                    (wb_values[95:64] & {32{chosen[2]}});
endmodule
'''
if a.wb_tree or a.wake_qualified or a.wake_tree:
 core=Path('verilog/area_v2/cpu_top.sv').read_text()
if a.wb_tree:
 needle='  wire [95:0] wb_values;'
 assert core.count(needle)==1
 core=core.replace(needle,needle+'''
  wire [6*96-1:0] wb_value_copies;
  v2_distribution #(.WIDTH(96),.LEAVES(6)) distribute_wb_values (
    .data_in(wb_values),.data_out(wb_value_copies));
''')
 assert core.count('.wb_good,.wb_slots,.wb_values,.next_ready(')==2
 core=core.replace('.wb_good,.wb_slots,.wb_values,.next_ready(','.wb_good,.wb_slots,.wb_values(wb_value_copies[(2+bank)*96+:96]),.next_ready(')
 core=core.replace('source_value=wb_value[w];','source_value=wb_value_copies[5*96+w*32+:32];')
 core=core.replace('values[r]<=wb_value[w];','values[r]<=wb_value_copies[(2*r/ROB_ENTRIES)*96+w*32+:32];')
 core=core.replace('values[r][bit_id]<=wb_value[w][bit_id];','values[r][bit_id]<=wb_value_copies[(2*r/ROB_ENTRIES)*96+w*32+bit_id];')
if a.wake_qualified:
 old='assign wb_good[w]=wb_valid[w] && wb_fault[w]==0 && rob[wb_rid[w]].rd!=0;'
 assert core.count(old)==1
 core=core.replace(old,'''// Only JAL/JALR among branches have a register consumer. Compute their
    // alignment directly so conditional-branch comparisons do not gate wakeup.
    assign wb_good[w]=wb_valid[w] && rob[wb_rid[w]].rd!=0 &&
      (w!=0 ? wb_fault[w]==0 :
       (mdu_result_valid || is_alu(executing[0].op) ||
        (executing[0].op==OP_JAL && executing[0].imm[1:0]==0) ||
        (executing[0].op==OP_JALR &&
         !(executing[0].a[1]^executing[0].imm[1]^(executing[0].a[0]&executing[0].imm[0])))));''')
 core=core.replace('`ifndef SYNTHESIS','''`ifndef SYNTHESIS
  // Verify exact equivalence of wakeup eligibility in reachable CPU states.
  always_ff @(posedge clk) if(!rst)
    assert(wb_good[0] === (wb_valid[0] && wb_fault[0]==0 && rob[wb_rid[0]].rd!=0))
      else $fatal(1,"specialized integer wakeup qualification differs");
''',1)
if a.wake_tree:
 needle='  wire [95:0] wb_values;'
 assert core.count(needle)==1
 core=core.replace(needle,needle+'''
  localparam integer WAKE_BITS=3+3*RW;
  wire [6*WAKE_BITS-1:0] wake_copies;
  v2_distribution #(.WIDTH(WAKE_BITS),.LEAVES(6)) distribute_wakeup (
    .data_in({wb_good,wb_slots}),.data_out(wake_copies));
''')
 assert core.count('.wb_good,.wb_slots,')==2
 core=core.replace('.wb_good,.wb_slots,',
   '.wb_good(wake_copies[(bank*2+2*q/IQ_ENTRIES)*WAKE_BITS+3*RW+:3]),'
   '.wb_slots(wake_copies[(bank*2+2*q/IQ_ENTRIES)*WAKE_BITS+:3*RW]),')
if a.wb_tree or a.wake_qualified or a.wake_tree:
 changed['cpu_top.sv']=core
spec=importlib.util.spec_from_file_location('export_plain','scripts/area_v2/export_plain.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
package=Path('verilog/area_v2/cpu_pkg.sv').read_text();result='// Frozen stage8 experiment.\n'
for source in sorted(Path('verilog/area_v2').glob('*.sv')):
 if source.name=='cpu_pkg.sv':continue
 data=changed.get(source.name,source.read_text())
 result+=m.lower(data,package)+'\n'
 if source.name in changed:(out/source.name).write_text(data)
(out/'area_v2_core.v').write_text(result)
for name in ('student_top.sv','pararisc_axi_adapter.sv'):(out/name).write_bytes((Path('verilog')/name).read_bytes())
(out/'filelist.f').write_text('area_v2_core.v\npararisc_axi_adapter.sv\nstudent_top.sv\n')
(out/'source-hashes.json').write_text(json.dumps({p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in out.iterdir() if p.suffix in ('.v','.sv')},indent=2)+'\n')
print(out/'filelist.f')
