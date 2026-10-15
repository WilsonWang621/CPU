#!/usr/bin/env python3
"""Experimental ordinary RTL regeneration with explicit inverter distribution.

Input mapping is an implementation hint only. The output contains behavioral
logic/FF definitions, no external cells or inherited cell timing/area metadata.
It must pass the unmodified course synthesis and simulation flow again.
"""
import argparse,collections,copy,hashlib,json,re
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('raw',type=Path);p.add_argument('out',type=Path);p.add_argument('--fanout',type=int,default=8);p.add_argument('--models',type=Path,default=Path('build/frequency-stage7/structural-probe/models-rtl.v'))
a=p.parse_args();assert a.fanout>=2
r=json.loads((a.raw/'report.json').read_text())
for i in r['inputs']:assert hashlib.sha256(Path(i['path']).read_bytes()).hexdigest()==i['sha256'],i['path']
d=json.loads((a.raw/'design.json').read_text())['modules']
model_text=re.sub(r'\(\*.*?\*\)','',a.models.read_text(),flags=re.S)
models={m[1]:m[0] for m in re.finditer(r'\bmodule\s+(\w+)\s*\(.*?\bendmodule\b',model_text,re.S)}
required=set();logic=set()
def visit(n):
 if n in required:return
 if n in models:logic.add(n);return
 assert n in d and not int(d[n].get('attributes',{}).get('blackbox','0'),2),n
 required.add(n)
 for c in d[n]['cells'].values():visit(c['type'])
visit('student_top')
names={n:('student_top' if n=='student_top' else 'pr_stage_'+str(i)) for i,n in enumerate(sorted(required))}
names.update({n:'pr_logic_'+n for n in logic})
def ident(n):return n if re.fullmatch('[a-zA-Z_][a-zA-Z0-9_$]*',n) else '\\'+n+' '
def bit(b):return 'b'+str(b) if isinstance(b,int) else "1'b"+b
def bus(bits):return bit(bits[0]) if len(bits)==1 else '{'+','.join(bit(b) for b in reversed(bits))+'}'
output=['// Generated structural ordinary RTL. Regenerate and re-synthesize; no library blackboxes.\n']
output.append('''(* keep_hierarchy=1 *) module pr_distribution_inv(input wire A,output wire Y);
assign Y=~A;
endmodule
(* keep_hierarchy=1 *) module pr_distribution_buffer(input wire A,output wire Y);
wire inverted;
(* keep=1 *) pr_distribution_inv first(.A(A),.Y(inverted));
(* keep=1 *) pr_distribution_inv second(.A(inverted),.Y(Y));
endmodule
''')
for n in sorted(logic):
 body=re.sub(r'\bmodule\s+'+re.escape(n)+r'\b','module '+names[n],models[n],count=1)
 if n.startswith('DFFHQN'):
  assert set(d[n]['ports'])=={'CLK','D','QN'},n
  body='module '+names[n]+'(input wire CLK,D,output wire QN);\nreg positive_state;\nalways @(posedge CLK) positive_state<=D;\nassign QN=~positive_state;\nendmodule'
 if set(d[n]['ports'])=={'A','Y'} and re.search(r'assign\s+Y\s*=\s*A\s*;',body):
  assert re.search(r'assign\s+Y\s*=\s*A\s*;',body),n
  body='module '+names[n]+'(input wire A,output wire Y);\n(* keep=1 *) pr_distribution_buffer physical_identity(.A(A),.Y(Y));\nendmodule'
 assert not re.search(r'blackbox|abc9_box|\\\$_',body),n
 output.append(('' if n.startswith('DFFHQN') else '(* keep_hierarchy=1 *) ')+body+'\n')
stats={};total_checked=0
for n in sorted(required):
 m=copy.deepcopy(d[n]);cells=m['cells'];ports=m['ports'];original=copy.deepcopy(cells);original_ports=copy.deepcopy(ports)
 all_bits={b for c in cells.values() for bits in c['connections'].values() for b in bits if isinstance(b,int)}
 all_bits.update(b for port in ports.values() for b in port['bits'] if isinstance(b,int))
 highest=max(all_bits,default=1);clocks={b for name,port in ports.items() if name.lower() in ('clk','clock') for b in port['bits']}
 for c in cells.values():
  if c['type'].startswith(('DFF','SDF')):clocks.update(c['connections'].get('CLK',[]))
 uses=collections.defaultdict(list)
 for name,c in cells.items():
  for pin,bits in c['connections'].items():
   if c['port_directions'][pin]=='input':
    for j,b in enumerate(bits):
     if isinstance(b,int) and b not in clocks:uses[b].append((name,pin,j))
 for name,port in ports.items():
  if port['direction']=='output':
   for j,b in enumerate(port['bits']):
    if isinstance(b,int) and b not in clocks:uses[b].append(('@port',name,j))
 parents={};inserted=[]
 def repair_sink(sink,new_bit):
  name,pin,j=sink
  if name=='@port':ports[pin]['bits'][j]=new_bit
  else:cells[name]['connections'][pin][j]=new_bit
 def add_buffer(source,loads):
  global highest
  highest+=1;new_bit=highest;all_bits.add(new_bit);name='distribution_'+str(len(inserted));assert name not in cells
  cells[name]={'type':'pr_distribution_buffer','connections':{'A':[source],'Y':[new_bit]},'port_directions':{'A':'input','Y':'output'}}
  for sink in loads:repair_sink(sink,new_bit)
  inserted.append(name);parents[new_bit]=source
  return name,'A',0
 for b,loads in list(uses.items()):
  while len(loads)>a.fanout:loads=[add_buffer(b,loads[j:j+a.fanout]) for j in range(0,len(loads),a.fanout)]
 def contract(b):
  visited=set()
  while b in parents:
   assert b not in visited;visited.add(b);b=parents[b]
  return b
 checked=0
 for name,c in original.items():
  for pin,bits in c['connections'].items():
   assert [contract(b) for b in cells[name]['connections'][pin]]==bits
   checked+=len(bits)
 for name,port in original_ports.items():assert [contract(b) for b in ports[name]['bits']]==port['bits']
 final_uses=collections.Counter(b for c in cells.values() for pin,bits in c['connections'].items() if c['port_directions'][pin]=='input' for b in bits if isinstance(b,int) and b not in clocks)
 for port in ports.values():
  if port['direction']=='output':final_uses.update(b for b in port['bits'] if isinstance(b,int) and b not in clocks)
 assert max(final_uses.values(),default=0)<=a.fanout
 stats[n]={'original_instances':len(original),'inverter_pairs':len(inserted),'max_fanout_before':max(map(len,uses.values()),default=0),'max_fanout_after':max(final_uses.values(),default=0),'contracted_pins_checked':checked};total_checked+=checked
 output.append('(* keep_hierarchy=1 *) module '+names[n]+'('+','.join(ident(p) for p in ports)+');\n')
 for name,port in ports.items():
  assert port['direction'] in ('input','output')
  output.append(port['direction']+' wire '+('['+str(len(port['bits'])-1)+':0] ' if len(port['bits'])>1 else '')+ident(name)+';\n')
 output.append('wire '+','.join(bit(b) for b in sorted(all_bits))+';\n')
 for name,port in ports.items():
  for j,b in enumerate(port['bits']):
   external=ident(name)+(f'[{j}]' if len(port['bits'])>1 else '')
   output.append('assign '+(bit(b)+'='+external if port['direction']=='input' else external+'='+bit(b))+';\n')
 for i,(name,c) in enumerate(cells.items()):
  kind='pr_distribution_buffer' if c['type']=='pr_distribution_buffer' else names[c['type']]
  assert not c.get('parameters'),(name,c.get('parameters'))
  output.append('(* keep=1 *) '+kind+' instance_'+str(i)+'('+','.join('.'+ident(pin)+'('+bus(bits)+')' for pin,bits in c['connections'].items())+');\n')
 output.append('endmodule\n')
a.out.mkdir(parents=True,exist_ok=True);rtl=a.out/'structural.v';rtl.write_text(''.join(output));(a.out/'filelist.f').write_text('structural.v\n')
manifest={'raw_report_sha256':hashlib.sha256((a.raw/'report.json').read_bytes()).hexdigest(),'raw_mapped_sha256':hashlib.sha256((a.raw/'mapped.v').read_bytes()).hexdigest(),'models_sha256':hashlib.sha256(a.models.read_bytes()).hexdigest(),'rtl_sha256':hashlib.sha256(rtl.read_bytes()).hexdigest(),'library_functions_recompiled_as_rtl':sorted(logic),'no_imported_timing_or_area_attributes':True,'no_blackboxes':True,'fanout_limit':a.fanout,'buffer_contraction_checked_pins':total_checked,'modules':stats}
(a.out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('generated',rtl,'inverter pairs',sum(s['inverter_pairs'] for s in stats.values()),'pins checked',total_checked)
