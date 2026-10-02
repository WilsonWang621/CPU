#!/usr/bin/env python3
"""Prove actual two-port Load compaction under the separately checked <=2 bound."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

ROOT=Path(__file__).resolve().parents[2]


def extract(source):
    marker=source.index('always_comb begin : load_port_compaction')
    start=source.index("    for(integer port=0;port<2;port=port+1) load_agu[port]=",marker)
    end=source.index('\n  end\n',start)
    loop=source[start:end]
    if 'selected=selected+1;' not in loop:raise RuntimeError('Compactor shape changed')
    matches=re.findall(r'typedef struct packed \{[^{}]*\} load_agu_t;',source)
    if len(matches)!=1:raise RuntimeError('Expected one actual load_agu_t declaration')
    return loop,matches[0]


def miter(loop,packet,rw):
    bits=rw+64
    return f'''module compaction_equivalence(input logic [3:0] load_eligible_mask,
 input logic [4*{bits}-1:0] raw,output logic ok);
 typedef logic [{rw}-1:0] rid_t;
 typedef struct packed {{rid_t rid;logic [31:0] a,imm;}} execute_t;
 {packet}
 execute_t ex_q[4];load_agu_t load_agu[2];logic [1:0] load_port_valid;
 integer selected,total,position;
 always_comb begin
   for(integer lane=0;lane<4;lane=lane+1) ex_q[lane]=execute_t'(raw[lane*{bits}+:{bits}]);
   selected=0;load_port_valid=0;
'''+loop+'''
   total=$countones(load_eligible_mask);position=0;ok=1;
   if(total<=2) begin
     for(integer port=0;port<2;port=port+1)
       if(load_port_valid[port]!=(port<total)) ok=0;
     for(integer lane=0;lane<4;lane=lane+1) begin
       position=$countones(load_eligible_mask & ((4'b0001<<lane)-4'b0001));
       if(load_eligible_mask[lane]) begin
         if(!load_port_valid[position] || load_agu[position].source_lane!=2'(lane) ||
            load_agu[position].rid!=ex_q[lane].rid || load_agu[position].a!=ex_q[lane].a ||
            load_agu[position].imm!=ex_q[lane].imm) ok=0;
       end
     end
   end
 end
endmodule
'''


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,default=ROOT/'rtl/core.sv')
    parser.add_argument('--output',type=Path,default=ROOT/'build/load-port-compaction-proof')
    parser.add_argument('--yosys',type=Path,default=ROOT/'build/tools/oss-cad-suite/bin/yosys')
    parser.add_argument('--rid-widths',type=int,nargs='+',default=list(range(2,8)))
    args=parser.parse_args();source=args.source.resolve();out=args.output.resolve();out.mkdir(parents=True,exist_ok=True)
    text=source.read_text();loop,packet=extract(text);(out/'source-core.sv').write_text(text)
    env=dict(os.environ);env.pop('YOSYS_DATDIR',None)
    report={'core_sha256':hashlib.sha256(text.encode()).hexdigest(),'selection_sha256':hashlib.sha256(loop.encode()).hexdigest(),'packet_type_sha256':hashlib.sha256(packet.encode()).hexdigest(),'scope':'Actual selector and packet type, all 11 four-lane masks with <=2 active Loads, arbitrary RID/A/IMM payloads. Exact output validity, original source-lane order/identity and payload. The <=2 reachable-state bound is a separate source argument and runtime assertion; it is not proved by this combinational miter.','runs':[]}
    for rw in args.rid_widths:
        if rw<2 or rw>7:parser.error('RID widths must be2..7 (ROB4..128)')
        directory=out/f'rid{rw}';directory.mkdir(exist_ok=True);code=miter(loop,packet,rw);(directory/'miter.sv').write_text(code)
        (directory/'proof.ys').write_text('read_slang --top compaction_equivalence miter.sv\nopt -full\nwreduce\nopt -full\nsat -verify -prove ok 1 -show-inputs -show-outputs\n');start=time.monotonic();status='unknown';returncode=None
        try:
            with (directory/'proof.log').open('w') as log:p=subprocess.run([str(args.yosys.resolve()),'-TQ','-s','proof.ys'],cwd=directory,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=60)
            returncode=p.returncode;status='proven' if not returncode and 'SUCCESS!' in (directory/'proof.log').read_text() else 'failed'
        except subprocess.TimeoutExpired:pass
        row={'rid_width':rw,'status':status,'returncode':returncode,'seconds':time.monotonic()-start,'miter_sha256':hashlib.sha256(code.encode()).hexdigest(),'log_sha256':hashlib.sha256((directory/'proof.log').read_bytes()).hexdigest()};report['runs'].append(row);print(json.dumps(row),flush=True)
    (out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
    return 1 if any(r['status']=='failed' for r in report['runs']) else 2 if any(r['status']=='unknown' for r in report['runs']) else 0


if __name__=='__main__':
    raise SystemExit(main())
