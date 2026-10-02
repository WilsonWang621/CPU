#!/usr/bin/env python3
"""Freeze and measure a configuration using the unchanged course tools."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import subprocess
import sys

PROJECT = Path(__file__).resolve().parents[1]
FRAMEWORK = PROJECT.parent
sys.path.insert(0, str(FRAMEWORK / "scripts"))
from oj_io import prepare_case, compare_output

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def run(command, path, cwd=FRAMEWORK):
    with path.open("w") as log:
        subprocess.run([str(x) for x in command], cwd=cwd, stdout=log, stderr=subprocess.STDOUT, check=True)

def main():
    a = argparse.ArgumentParser(description=__doc__)
    a.add_argument("name")
    a.add_argument("--stage", type=int, choices=(1,2,3), default=1)
    for key, default in (("rob",16),("iq",8),("ic-bytes",4096),("dc-bytes",4096),("line-bytes",32),("ways",2),("banks",4),("early-recovery",1),("prefetch",1),("btb-entries",128),("history-bits",1),("l0-entries",0),("store-entries",0),("checkpoints",4),("fast-redirect",0)):
        a.add_argument("--"+key,type=int,default=default)
    a.add_argument("--jobs",type=int,default=8)
    a.add_argument("--skip-correctness",action="store_true")
    a.add_argument("--skip-perf",action="store_true")
    a.add_argument("--skip-synth",action="store_true")
    a.add_argument("--reuse-build",action="store_true")
    args = a.parse_args()
    if not re.fullmatch(r"[a-z0-9][a-z0-9_-]*",args.name):
        a.error("name must use lowercase letters, numbers, underscore or hyphen")
    out = PROJECT / "reports" / ("stage"+str(args.stage)) / args.name
    build = PROJECT / "build" / ("stage"+str(args.stage)) / args.name
    if out.exists() and not args.reuse_build:
        a.error("experiment already exists; choose a new name")
    out.mkdir(parents=True,exist_ok=True); build.mkdir(parents=True,exist_ok=True)
    config = {k:getattr(args,k.replace("-","_")) for k in ("rob","iq","ic-bytes","dc-bytes","line-bytes","ways","banks","early-recovery","prefetch","btb-entries","history-bits","l0-entries","store-entries","checkpoints","fast-redirect")}
    config["issue-width"] = 1
    if args.stage > 1:
        prior = PROJECT/"reports"/("stage"+str(args.stage-1))
        summaries = [json.loads(p.read_text()) for p in prior.glob("*/summary.json")]
        if not any(s.get("tier2_pass",False) for s in summaries):
            a.error("the preceding stage has no verified Tier2 baseline")
    sources = out/"source"; sources.mkdir(exist_ok=True)
    if args.reuse_build:
        manifest = json.loads((out/"manifest.json").read_text())
        config = manifest["parameters"]
        for p in sources.iterdir():
            if sha(p) != manifest["source_sha256"][p.name]:
                raise ValueError("frozen source hash changed: "+str(p))
    else:
      for p in (PROJECT/"src/main/scala/tier2").glob("*.scala"):
        shutil.copy2(p,sources/p.name)
      shutil.copy2(PROJECT/"build.sbt",sources/"build.sbt")
      shutil.copy2(PROJECT/"project/build.properties",sources/"build.properties")
      manifest = {"stage":args.stage,"experiment":args.name,"parameters":config,"latency":20,"max_cycles":30000000,
                "source_sha256":{p.name:sha(p) for p in sources.iterdir()},
                "source_commit":subprocess.check_output(["git","rev-parse","HEAD"],cwd=FRAMEWORK,text=True).strip(),
                "worktree_diff":subprocess.check_output(["git","diff","--","single-issue-chisel/src"],cwd=FRAMEWORK,text=True)}
      (out/"manifest.json").write_text(json.dumps(manifest,indent=2)+"\n")
    rtl = out/"rtl"; rtl.mkdir(exist_ok=True)
    if not args.reuse_build:
        # Elaborate the frozen sources, so concurrent worktree edits cannot
        # silently change the measured RTL after its source hashes were saved.
        generator = build/"generator"
        scala = generator/"src/main/scala/tier2"; scala.mkdir(parents=True,exist_ok=True)
        for p in sources.glob("*.scala"): shutil.copy2(p,scala/p.name)
        shutil.copy2(sources/"build.sbt",generator/"build.sbt")
        (generator/"project").mkdir(exist_ok=True)
        shutil.copy2(sources/"build.properties",generator/"project/build.properties")
        command = "run --out "+str(rtl)+" "+" ".join("--"+k+" "+str(v) for k,v in config.items() if k != "issue-width")
        run([Path.home()/".local/bin/sbt","-batch",command],out/"generate.log",generator)
        (rtl/"filelist.f").write_text("student_top.sv\n")
        run([sys.executable,FRAMEWORK/"scripts/build.py","--filelist",rtl/"filelist.f","--out",build/"sim","--jobs",args.jobs],out/"build.log")
    simulator = build/"sim/sim"
    result = {"stage":args.stage,"experiment":args.name,"parameters":config,"rtl_sha256":sha(rtl/"student_top.sv"),"performance":[],"correctness":{"status":"not_run"},"synthesis":{"status":"not_run"},"tier2_pass":False}
    if args.reuse_build and (out/"summary.json").exists():
        result = json.loads((out/"summary.json").read_text())
    result["simulator_sha256"] = sha(simulator)
    synthesis_pool = None
    synthesis_job = None
    if not args.skip_synth:
        synthesis_pool = ThreadPoolExecutor(max_workers=1)
        synthesis_job = synthesis_pool.submit(run,
            [sys.executable,FRAMEWORK/"scripts/synth.py","--filelist",rtl/"filelist.f","--out",build/"synth"],out/"synth.log")
    for kind in ("perf", "correctness"):
        if kind == "perf" and args.skip_perf:
            continue
        if kind == "correctness" and args.skip_correctness:
            continue
        records = []
        with (out/(kind+".log")).open("w") as log:
            for case in sorted((FRAMEWORK/"testcases").glob(kind+"_*")):
                if not case.is_dir(): continue
                data,answer = prepare_case(case,30000000,20)
                proc = subprocess.run([str(simulator)],input=data,text=True,capture_output=True)
                failure = compare_output(proc.stdout,answer) if not proc.returncode else "simulator exit "+str(proc.returncode)
                match = re.search(r"^CPU2026 cycles=(\d+)$",proc.stderr,re.M)
                row = {"case":case.name,"passed":failure is None,"cycles":int(match.group(1)) if match else None}
                if kind == "perf" and row["passed"] and match:
                    row["instructions"] = json.loads((case/"metrics.json").read_text())["dynamic_instructions"]
                    row["ipc"] = row["instructions"]/row["cycles"]
                log.write(json.dumps(row)+"\n"+proc.stdout+proc.stderr);log.flush();records.append(row)
                print(args.name,case.name,"PASS" if row["passed"] else failure,row["cycles"],flush=True)
                if failure: break
        if kind == "perf":
            result["performance"] = records
            if len(records)==6 and all("ipc" in r for r in records):
                result["ipc_geomean"] = math.exp(sum(math.log(r["ipc"]) for r in records)/6)
        else:
            result["correctness"] = {"status":"passed" if len(records)==19 and all(r["passed"] for r in records) else "failed","records":records}
        (out/"summary.json").write_text(json.dumps(result,indent=2)+"\n")
    if not args.skip_synth:
        synthesis_job.result()
        synthesis_pool.shutdown()
        for filename in ("report.json","report.txt","timing.rpt","constraints.sdc"):
            shutil.copy2(build/"synth/opt"/filename,out/filename)
        report = json.loads((out/"report.json").read_text())
        result["synthesis"] = {"status":"passed","fmax_mhz":report["timing"]["estimated_fmax_mhz"],"area_um2":report["area"]["area_um2"]}
    t = result["synthesis"]
    result["tier2_pass"] = (result["correctness"]["status"]=="passed" and result.get("ipc_geomean",0)>=0.845 and
        t.get("status")=="passed" and t["area_um2"]<=18000 and t["fmax_mhz"]>300)
    result["stage_frequency_pass"] = result["tier2_pass"] and t["fmax_mhz"] >= {1:300,2:400,3:500}[args.stage]
    (out/"summary.json").write_text(json.dumps(result,indent=2)+"\n")
    print(json.dumps({k:v for k,v in result.items() if k not in ("performance","correctness")},indent=2),flush=True)

if __name__ == "__main__": main()
