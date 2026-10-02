import json, re, subprocess, sys
from pathlib import Path
sys.path.insert(0, str(Path.cwd()/'scripts'))
from oj_io import prepare_case, compare_output
results=[]
for case in sorted(Path('testcases').glob('perf_*')):
    data,answer=prepare_case(case,30000000,20)
    run=subprocess.run(['build/frequency-stage2/native-sim/sim'],input=data,text=True,capture_output=True)
    coverage=[line for line in run.stdout.splitlines() if line.startswith('V2_COVERAGE ')]
    output='\n'.join(line for line in run.stdout.splitlines() if not line.startswith('V2_COVERAGE '))+'\n'
    error=compare_output(output,answer)
    if run.returncode or error or len(coverage)!=1:
        raise RuntimeError(f'{case.name}: status={run.returncode} error={error} stderr={run.stderr}')
    cycles=int(re.search(r'CPU2026 cycles=(\d+)',run.stderr)[1])
    counts={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',coverage[0])}
    results.append({'benchmark':case.name,'cycles':cycles,'coverage':counts,'status':'pass'})
    print(case.name,cycles,coverage[0],flush=True)
Path('build/frequency-stage2/native-results.json').write_text(json.dumps(results,indent=2)+'\n')
