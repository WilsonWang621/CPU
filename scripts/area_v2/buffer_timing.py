#!/usr/bin/env python3
"""Counted fanout repair, then STA with the unchanged course I/O budgets.

Uses the same ASAP7 cells and timing.py/timing.tcl as make synth. Buffer
contraction must recover every original pin and top port. The raw report
remains separate and is never overwritten by the buffered implementation.
"""
import argparse
from collections import defaultdict
from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'scripts'))
from toolchain import enter_appimage,packaged_tool,DEFAULT_APPIMAGE
from synth import run_yosys,quote
from synth_report import area_report,format_report
from timing import analyze


def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--raw',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--fanout',type=int,default=8)
    parser.add_argument('--period',type=float,default=3.333)
    args=parser.parse_args()
    if args.fanout<2:parser.error('fanout must be at least 2')
    enter_appimage(DEFAULT_APPIMAGE)
    raw=args.raw.resolve();out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
    original_report=json.loads((raw/'report.json').read_text())
    for source in original_report['inputs']:
        if source['sha256']!=digest(Path(source['path'])):raise ValueError('RTL changed since raw mapping: '+source['path'])
    libs=sorted((Path(os.environ['CPU2026_APPDIR'])/'asap7/lib').glob('*.lib'))
    if {digest(p) for p in libs}!={p['sha256'] for p in original_report['libraries']}:
        raise ValueError('library mismatch (this implementation expects no SRAM macros)')
    design=json.loads((raw/'design.json').read_text());top=design['modules']['student_top'];cells=top['cells']
    initial=deepcopy({n:c['connections'] for n,c in cells.items()});ports=deepcopy(top['ports'])
    clocks=set(top['ports']['clock']['bits']);uses=defaultdict(list)
    highest=max(b for n in top['netnames'].values() for b in n['bits'] if isinstance(b,int))
    for n,c in cells.items():
        for p,bs in c['connections'].items():
            for i,b in enumerate(bs):
                if isinstance(b,int):
                    highest=max(highest,b)
                    if c['port_directions'][p]=='input' and b not in clocks:uses[b].append((n,p,i))
    kind='BUFx2_ASAP7_75t_R'
    if kind not in design['modules']:raise ValueError('missing physical buffer cell')
    text='\n'.join(p.read_text() for p in libs)
    start=text.index('cell ('+kind+')');start=text.index('{',start);depth=1;end=start+1
    while depth:depth+=(text[end]=='{')-(text[end]=='}');end+=1
    if not re.search(r'pin\s*\(Y\)\s*\{\s*direction\s*:\s*output;\s*function\s*:\s*"A";',text[start:end]):
        raise ValueError('buffer function is not Y=A')
    inserted=[]
    def buffer(source,loads):
        nonlocal highest
        highest+=1;name='pararisc_buffer_'+str(len(inserted));output=highest
        if name in cells:raise ValueError('buffer name collision')
        cells[name]={'hide_name':0,'type':kind,'parameters':{},'attributes':{},
                     'port_directions':{'A':'input','Y':'output'},'connections':{'A':[source],'Y':[output]}}
        top['netnames'][name+'_wire']={'hide_name':0,'bits':[output],'attributes':{}}
        inserted.append(name)
        for n,p,i in loads:cells[n]['connections'][p][i]=output
        return name,output
    max_before=max(map(len,uses.values()))
    for bit,loads in list(uses.items()):
        while len(loads)>args.fanout:
            next_level=[]
            for start in range(0,len(loads),args.fanout):
                name,_=buffer(bit,loads[start:start+args.fanout]);next_level.append((name,'A',0))
            loads=next_level
    parent={cells[n]['connections']['Y'][0]:cells[n]['connections']['A'][0] for n in inserted}
    def contract(bit):
        seen=set()
        while bit in parent:
            if bit in seen:raise ValueError('buffer loop')
            seen.add(bit);bit=parent[bit]
        return bit
    checked=0
    for n,connections in initial.items():
        for p,bs in connections.items():
            if [contract(b) for b in cells[n]['connections'][p]]!=bs:raise ValueError('connectivity mismatch '+n+'/'+p)
            checked+=len(bs)
    if top['ports']!=ports:raise ValueError('top-level interface changed')
    final_uses=defaultdict(int)
    for c in cells.values():
        for p,bs in c['connections'].items():
            if c['port_directions'][p]=='input':
                for b in bs:
                    if isinstance(b,int) and b not in clocks:final_uses[b]+=1
    max_after=max(final_uses.values())
    if max_after>args.fanout:raise ValueError('fanout limit missed')
    (out/'design.json').write_text(json.dumps(design,separators=(',',':')))
    run_yosys(packaged_tool('yosys'),out,'buffer',[
        'read_json '+quote(out/'design.json'),'hierarchy -check -top student_top','check -assert -mapped',
        'tee -o '+quote(out/'stat.json')+' stat -json '+' '.join('-liberty '+quote(p) for p in libs),
        'write_verilog -noattr -noexpr '+quote(out/'mapped.v')])
    area=area_report(design,json.loads((out/'stat.json').read_text()),{})
    timing=analyze(packaged_tool('sta'),out,libs,args.period,'clock')
    buffering={'buffer_type':kind,'inserted_buffers':len(inserted),'max_fanout_before':max_before,
               'max_fanout_after':max_after,'pins_checked':checked,'connectivity_contraction':'pass',
               'clock_and_ports_unchanged':True,'buffer_area_counted':True,
               'raw_netlist_sha256':digest(raw/'mapped.v'),'mapped_netlist_sha256':digest(out/'mapped.v')}
    report={**original_report,'mode':'opt','output_directory':str(out),'area':area,'timing':timing,
            'buffering':buffering,'scope':'Cell STA with counted buffer trees; course I/O constraints; no routing parasitics.'}
    for name,obj in [('report.json',report),('area.json',area),('timing.json',timing),('buffering.json',buffering)]:
        (out/name).write_text(json.dumps(obj,indent=2)+'\n')
    (out/'report.txt').write_text(format_report(report)+'\nPhysical buffers included; raw report: '+str(raw/'report.txt')+'\n')
    print(format_report(report),flush=True)
    print(json.dumps(buffering),flush=True)

if __name__=='__main__':main()
