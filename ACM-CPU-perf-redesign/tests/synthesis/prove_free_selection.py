#!/usr/bin/env python3
"""Prove the actual lowest-free helper versus the original descending scan.

Unconstrained free/release/occupied masks feed 1/2/4 ordered rename lanes. Each
lane may allocate or leave its choice unconsumed. Both index and resulting mask
are compared. PRF mode excludes x0 even when arbitrary inputs mark it free.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import threading
import time

ROOT=Path(__file__).resolve().parents[2]


def extract_macro(source):
    start=source.index('`define CPU_LOWEST_FUNCTION(')
    end=source.index('  endfunction',start)+len('  endfunction')
    return source[start:end]+'\n'


def wrapper(macro,n,lanes,exclude):
    return f'''module free_selection_equivalence(
 input logic [{n}-1:0] initial_free,released_before,occupied_before,
 input logic [{lanes}-1:0] allocate,
 output logic ok);
 localparam integer N={n},LANES={lanes},EXCLUDE_ZERO={exclude};
'''+macro+'''
 `CPU_LOWEST_FUNCTION(actual_lowest,N)
 `undef CPU_LOWEST_FUNCTION
 logic [N-1:0] serial_mask,actual_mask;
 integer serial_index,actual_index;
 always_comb begin
   serial_mask=(initial_free | released_before) & ~occupied_before;
   actual_mask=serial_mask;
   if(EXCLUDE_ZERO) begin serial_mask[0]=0;actual_mask[0]=0;end
   ok=1;serial_index=-1;actual_index=-1;
   for(integer lane=0;lane<LANES;lane=lane+1) begin
     serial_index=-1;
     for(integer k=N-1;k>=EXCLUDE_ZERO;k=k-1)
       if(serial_mask[k]) serial_index=k;
     actual_index=actual_lowest(actual_mask);
     if(actual_index!=serial_index) ok=0;
     if(allocate[lane]) begin
       if(serial_index>=0) serial_mask[serial_index]=0;
       if(actual_index>=0) actual_mask[actual_index]=0;
     end
     if(actual_mask!=serial_mask) ok=0;
   end
 end
endmodule
'''


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,default=ROOT/'rtl/core.sv')
    parser.add_argument('--output',type=Path,default=ROOT/'build/free-selection-proof')
    parser.add_argument('--yosys',type=Path,default=ROOT/'build/tools/oss-cad-suite/bin/yosys')
    parser.add_argument('--timeout',type=float,default=60)
    parser.add_argument('--jobs',type=int,default=2)
    parser.add_argument('--capacities',nargs='+',type=int,default=[1,4,6,16,24,32,64,128])
    args=parser.parse_args()
    if not 0<args.timeout<=60 or args.jobs<1 or any(n<1 for n in args.capacities):parser.error('Invalid limits')
    source=args.source.resolve();text=source.read_text();macro=extract_macro(text);out=args.output.resolve();out.mkdir(parents=True,exist_ok=True)
    (out/'source-core.sv').write_text(text);(out/'actual_macro.svh').write_text(macro)
    report={'source':str(source),'source_sha256':hashlib.sha256(text.encode()).hexdigest(),
            'actual_macro_sha256':hashlib.sha256(macro.encode()).hexdigest(),
            'scope':'All free/release/occupied bitmasks, empty masks, arbitrary per-lane allocation enables; exact signed index and post-allocation masks for 1/2/4 sequential lanes, with and without physical index zero excluded.',
            'timeout_seconds':args.timeout,'runs':[]}
    env=dict(os.environ);env.pop('YOSYS_DATDIR',None);yosys=args.yosys.resolve();report['yosys']=subprocess.check_output([str(yosys),'-V'],text=True,env=env).strip();lock=threading.Lock()
    def run(case):
        n,lanes,exclude=case;name=f'n{n}-lanes{lanes}-exclude0-{exclude}';directory=out/name;directory.mkdir(exist_ok=True);code=wrapper(macro,*case);(directory/'miter.sv').write_text(code)
        (directory/'proof.ys').write_text('read_verilog -sv miter.sv\nprep -top free_selection_equivalence\nflatten\nopt -full\nsat -verify -prove ok 1 -show-inputs -show-outputs\n')
        start=time.monotonic();returncode=None;status='unknown'
        with (directory/'proof.log').open('w') as log:
            process=subprocess.Popen([str(yosys),'-TQ','-s','proof.ys'],cwd=directory,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
            try:
                returncode=process.wait(timeout=args.timeout);contents=(directory/'proof.log').read_text();status='proven' if returncode==0 and 'SUCCESS!' in contents else 'failed'
            except subprocess.TimeoutExpired:
                os.killpg(process.pid,signal.SIGKILL);process.wait()
        row={'capacity':n,'lanes':lanes,'exclude_zero':bool(exclude),'status':status,'returncode':returncode,'seconds':time.monotonic()-start,'wrapper_sha256':hashlib.sha256(code.encode()).hexdigest(),'log_sha256':hashlib.sha256((directory/'proof.log').read_bytes()).hexdigest(),'artifacts':str(directory.relative_to(ROOT))}
        with lock:
            report['runs'].append(row);(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(row),flush=True)
    cases=[(n,lanes,exclude) for n in args.capacities for lanes in [1,2,4] for exclude in [0,1]]
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:list(pool.map(run,cases))
    return 1 if any(r['status']=='failed' for r in report['runs']) else 2 if any(r['status']=='unknown' for r in report['runs']) else 0


if __name__=='__main__':
    raise SystemExit(main())
