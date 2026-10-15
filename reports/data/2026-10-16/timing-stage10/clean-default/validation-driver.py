from pathlib import Path
import sys,json,hashlib,os,time
root=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(root/'scripts'))
from testcase import correctness,cases_of
out=root/'build/frequency-stage10/clean-default/validation-01'
sim=root/'build/frequency-stage10/clean-default/sim/sim'
cases=cases_of(root/'testcases','correctness',None)
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
identity={'pid':os.getpid(),'simulator_sha256':digest(sim),'rtl_sha256':digest(root/'verilog/area_v2_core.v'),'latency':20,'max_cycles':20000000,'cases':[p.name for p in cases],'started_unix':time.time(),'finished':False}
(out/'state.json').write_text(json.dumps(identity,indent=2)+'\n')
try:
 status=correctness(sim.parent,cases,20000000,20,sim)
 identity.update(finished=True,exit_code=status,finished_unix=time.time())
except BaseException as error:
 identity.update(finished=True,exit_code=2,error=repr(error),finished_unix=time.time())
 raise
finally:
 temp=out/'state.json.tmp';temp.write_text(json.dumps(identity,indent=2)+'\n');temp.replace(out/'state.json')
sys.exit(status)
