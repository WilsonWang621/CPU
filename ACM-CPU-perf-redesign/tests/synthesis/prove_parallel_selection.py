#!/usr/bin/env python3
"""Prove the actual parallel ordering/ranking macros and capped issue selection.

Decomposition does not assume rank correctness: order is checked against the
strict (unsigned age, original slot) key, and the actual balanced rank function
is checked against an independent sequential count for arbitrary older matrices.
Then both actual-rank selection and serial greedy selection operate on arbitrary
ready/class bits in canonical strict-order position. Relabeling a strict total
order preserves selected identities, so this covers every age ordering and tie.
Small/full-size unsorted miters additionally exercise the composition directly.
A process reaching its bounded wall timeout is UNKNOWN, never a proof failure.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
import re
from pathlib import Path
import signal
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parents[2]


def extract_macro(text, name):
    start = text.index('`define ' + name + '(')
    end = text.index('  endfunction', start) + len('  endfunction')
    return text[start:end] + '\n'


def header(macros, n, width):
    return f'''module selection_equivalence(
 input logic [{n}-1:0] ready,
 input logic [{n}*{width}-1:0] ages,
 input logic [{n}*{n}-1:0] arbitrary_older,
 input logic [2*{n}-1:0] classes,
 input logic [3:0] free_lanes,
 input logic enabled,mdu_occupied,mul_ready,div_ready,div_accepted,
 output logic ok);
 localparam integer N={n},RW={width-1},CW=$clog2(N+1),LIMIT=(1<<RW)+1;
''' + macros + '''
 `CPU_ORDER_FUNCTION(actual_order,N)
 `CPU_RANK_FUNCTION(actual_rank,N)
 `undef CPU_ORDER_FUNCTION
 `undef CPU_RANK_FUNCTION
 logic [N*N-1:0] older;
 logic [N*CW-1:0] rank_value;
'''


def wrapper(macros, kind, n, width, lanes, integration):
    if kind == 'rank_cap':
        predicate=integration['memory_predicate'].replace('issue_mem_rank[k*IQRW+:IQRW]','rank').replace('IQRW','CW')
        return f"module selection_equivalence(input logic [{n}-1:0] rank,output logic ok);\nlocalparam integer CW={n};\nassign ok=(rank<=CW'(1))==({predicate});\nendmodule\n"
    body = header(macros, n, width)
    if kind == 'order':
        return body + '''
 always_comb begin
   older=actual_order(ages);ok=1;
   for(integer a=0;a<N;a=a+1)
     for(integer b=0;b<N;b=b+1)
       if(older[a*N+b] != ((ages[b*(RW+1)+:RW+1]<ages[a*(RW+1)+:RW+1]) ||
          (ages[b*(RW+1)+:RW+1]==ages[a*(RW+1)+:RW+1] && b<a))) ok=0;
 end
 endmodule
'''
    if kind == 'rank':
        return body + '''
 integer count;
 always_comb begin
   rank_value=actual_rank(ready,arbitrary_older);ok=1;count=0;
   for(integer a=0;a<N;a=a+1) begin
     count=0;
     for(integer b=0;b<N;b=b+1)
       if(ready[b] && arbitrary_older[a*N+b]) count=count+1;
     if(rank_value[a*CW+:CW]!=CW'(count)) ok=0;
   end
 end
 endmodule
'''
    iq = kind.startswith('iq')
    canonical = kind.endswith('_ordered')
    memory_predicate=integration['memory_predicate'].replace('issue_mem_rank','memory_rank').replace('IQRW','CW')
    lane_predicate=integration['lane_predicate'].replace('issue_final_rank','rank_value').replace('issue_port_rank','port_rank').replace('IQRW','CW') if iq else "rank_value[k*CW+:CW]==CW'(port_rank)"
    body += f'''
 localparam integer IQ={int(iq)},CANONICAL={int(canonical)},LANES={lanes};
 logic [N-1:0] eligible,memory_class,mdu_class,filtered,remaining;
 logic [N*CW-1:0] memory_rank;
 logic [4*N-1:0] serial_picks,parallel_picks;
 integer best,mem_used,mdu_used,port_rank;
 logic [RW:0] best_age;
 always_comb begin
   older='0;eligible='0;memory_class='0;mdu_class='0;filtered='0;
   remaining='0;memory_rank='0;rank_value='0;
   serial_picks='0;parallel_picks='0;
   best=-1;mem_used=0;mdu_used=0;port_rank=0;best_age='0;
   if(CANONICAL) begin
     for(integer a=0;a<N;a=a+1)
       for(integer b=0;b<N;b=b+1) older[a*N+b]=(b<a);
   end else older=actual_order(ages);
   for(integer k=0;k<N;k=k+1) begin
     eligible[k]=ready[k] && (CANONICAL || ages[k*(RW+1)+:RW+1]<(RW+1)'(LIMIT));
     if(IQ && classes[2*k+:2]>=2)
       eligible[k]=eligible[k] && !mdu_occupied &&
         (classes[2*k+:2]==3 ? div_ready && !div_accepted:mul_ready);
     memory_class[k]=IQ && eligible[k] && classes[2*k+:2]==1;
     mdu_class[k]=IQ && eligible[k] && classes[2*k+:2]>=2;
   end
   memory_rank=actual_rank(memory_class,older);
   for(integer k=0;k<N;k=k+1)
     filtered[k]=eligible[k] &&
       (!memory_class[k] || {memory_predicate}) &&
       (!mdu_class[k] || !(|(mdu_class & older[k*N+:N])));
   rank_value=actual_rank(filtered,older);
   for(integer lane=0;lane<LANES;lane=lane+1) begin
     if(enabled && (!IQ || free_lanes[lane])) begin
       for(integer k=0;k<N;k=k+1)
         if(filtered[k] && {lane_predicate})
           parallel_picks[lane*N+k]=1;
       port_rank=port_rank+1;
     end
   end
   remaining=eligible;
   for(integer lane=0;lane<LANES;lane=lane+1) begin
     if(enabled && (!IQ || free_lanes[lane])) begin
       best=-1;best_age=(RW+1)'(LIMIT);
       for(integer k=0;k<N;k=k+1)
         if(remaining[k] && (!memory_class[k] || mem_used<2) &&
            (!mdu_class[k] || mdu_used<1) &&
            (CANONICAL ? best<0 : ages[k*(RW+1)+:RW+1]<best_age)) begin
           best=k;best_age=ages[k*(RW+1)+:RW+1];
         end
       if(best>=0) begin
         serial_picks[lane*N+best]=1;remaining[best]=0;
         if(memory_class[best]) mem_used=mem_used+1;
         if(mdu_class[best]) mdu_used=mdu_used+1;
       end
     end
   end
   ok=serial_picks==parallel_picks;
 end
 endmodule
'''
    return body


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=ROOT/'rtl/core.sv')
    parser.add_argument('--output', type=Path, default=ROOT/'build/parallel-selection-proof')
    parser.add_argument('--yosys', type=Path, default=ROOT/'build/tools/oss-cad-suite/bin/yosys')
    parser.add_argument('--timeout', type=float, default=60)
    parser.add_argument('--jobs', type=int, default=2)
    parser.add_argument('--case', action='append', default=[], metavar='KIND:N:AGE_WIDTH:LANES')
    args = parser.parse_args()
    if not 0 < args.timeout <= 60: parser.error('Timeout must be at most 60 seconds')
    source=args.source.resolve();text=source.read_text();out=args.output.resolve();out.mkdir(parents=True,exist_ok=True)
    macros=''.join(extract_macro(text,name) for name in ['CPU_ORDER_FUNCTION','CPU_RANK_FUNCTION'])
    (out/'actual_macros.svh').write_text(macros)
    memory_matches=re.findall(r"^\s*\(!issue_memory\[k\] \|\| (.*?)\) &&\s*$",text,re.MULTILINE)
    lane_forms=["int'(issue_final_rank[k*IQRW+:IQRW])==int'(issue_port_rank)","issue_final_rank[k*IQRW+:IQRW]==IQRW'(issue_port_rank)"]
    lane_matches=[form for form in lane_forms if form in text]
    if len(memory_matches)!=1 or len(lane_matches)!=1:raise RuntimeError('Integration predicates changed; update extraction explicitly')
    integration={'memory_predicate':memory_matches[0],'lane_predicate':lane_matches[0]}
    (out/'source-core.sv').write_text(text)
    cases=[(kind,n,6,lanes) for n in [21,24] for kind,lanes in
           [('order',1),('rank',1),('wb_ordered',1),('wb_ordered',2),('wb_ordered',4),
            ('iq_ordered',1),('iq_ordered',2),('iq_ordered',4)]]
    cases += [(kind,1,6,lanes) for kind in ['order','rank','iq_full','iq_ordered'] for lanes in ([4] if kind.startswith('iq') else [1])]
    cases += [('iq_full',2,6,4),('iq_full',1,3,4),('iq_full',2,3,4),('wb_full',6,3,4)]
    cases += [('wb_full',5,6,k) for k in [1,2,4]]+[('iq_full',5,6,k) for k in [1,2,4]]
    cases += [('rank_cap',w,6,1) for w in range(1,9)]
    cases += [('wb_full',21,6,1),('wb_full',21,6,4),('iq_full',24,6,4)]
    if args.case:cases=[(x[0],int(x[1]),int(x[2]),int(x[3])) for x in (s.split(':') for s in args.case)]
    allowed={'rank_cap','order','rank','wb_ordered','iq_ordered','wb_full','iq_full'}
    if any(kind not in allowed or n<1 or width<3 or width>8 or lanes not in [1,2,3,4] for kind,n,width,lanes in cases):
        parser.error('Cases need known KIND, positive N, AGE_WIDTH 3..8 and LANES 1..4')
    env=dict(os.environ);env.pop('YOSYS_DATDIR',None);yosys=args.yosys.resolve()
    report={'source':str(source),'source_sha256':hashlib.sha256(text.encode()).hexdigest(),
            'actual_macros_sha256':hashlib.sha256(macros.encode()).hexdigest(),'integration_predicates':integration,
            'yosys':subprocess.check_output([str(yosys),'-V'],text=True,env=env).strip(),
            'decomposition':'Actual order versus strict (age,index); actual rank versus sequential count for arbitrary matrix; actual-rank capped scheduler versus serial greedy over arbitrary ready/classes in canonical strict priority order. Canonical relabeling is justified by permutation invariance. Full unsorted miters separately test composition including all age ties and out-of-range values.',
            'age_contract':'RW=age_width-1; ROB_ENTRIES=2**RW, strict sentinel ROB_ENTRIES+1. All encoded age values are unconstrained in full/order miters.',
            'timeout_seconds':args.timeout,'runs':[]}
    lock=threading.Lock()
    def run(case):
        kind,n,width,lanes=case;name=f'{kind}-n{n}-a{width}-k{lanes}';directory=out/name;directory.mkdir(exist_ok=True)
        code=wrapper(macros,*case,integration);(directory/'miter.sv').write_text(code)
        script='read_verilog -sv miter.sv\nprep -top selection_equivalence\nflatten\nopt -full\nsat -verify -prove ok 1 -show-inputs -show-outputs\n'
        (directory/'proof.ys').write_text(script);start=time.monotonic();status='unknown';returncode=None
        with (directory/'proof.log').open('w') as log:
            process=subprocess.Popen([str(yosys),'-TQ','-s','proof.ys'],cwd=directory,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
            try:
                returncode=process.wait(timeout=args.timeout)
                contents=(directory/'proof.log').read_text();status='proven' if returncode==0 and 'SUCCESS!' in contents else 'failed'
            except subprocess.TimeoutExpired:
                os.killpg(process.pid,signal.SIGKILL);process.wait()
        elapsed=time.monotonic()-start;contents=(directory/'proof.log').read_bytes()
        row={'kind':kind,'candidates':n,'age_width':width,'lanes':lanes,'status':status,
             'returncode':returncode,'seconds':elapsed,'wrapper_sha256':hashlib.sha256(code.encode()).hexdigest(),
             'log_sha256':hashlib.sha256(contents).hexdigest(),'artifacts':str(directory.relative_to(ROOT))}
        if kind=='rank_cap':row['rank_width']=n
        with lock:
            report['runs'].append(row);(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
            print(json.dumps(row),flush=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:list(pool.map(run,cases))
    return 1 if any(r['status']=='failed' for r in report['runs']) else 2 if any(r['status']=='unknown' for r in report['runs']) else 0


if __name__=='__main__':
    raise SystemExit(main())
