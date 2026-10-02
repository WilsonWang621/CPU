#!/usr/bin/env python3
"""Freeze and measure a configuration using the unchanged course tools."""
import argparse
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
    for key, default in (("rob",16),("iq",8),("ic-bytes",4096),("dc-bytes",4096),("line-bytes",32),("ways",2),("banks",4)):
        a.add_argument("--"+key,type=int,default=default)
    a.add_argument("--jobs",type=int,default=8)
    a.add_argument("--skip-correctness",action="store_true")
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
    config = {k:getattr(args,k.replace("-","_")) for k in ("rob","iq","ic-bytes","dc-bytes","line-bytes","ways","banks")}
    config["issue-width"] = 1
    sources = out/"source"; sources.mkdir(exist_ok=True)
    for p in (PROJECT/"src/main/scala/tier2").glob("*.scala"):
        shutil.copy2(p,sources/p.name)
    shutil.copy2(PROJECT/"build.sbt",sources/"build.sbt")
    manifest = {"stage":args.stage,"experiment":args.name,"parameters":config,"latency":20,"max_cycles":30000000,
                "source_sha256":{p.name:sha(p) for p in sources.iterdir()},
                "source_commit":subprocess.check_output(["git","rev-parse","HEAD"],cwd=FRAMEWORK,text=True).strip(),
                "worktree_diff":subprocess.check_output(["git","diff","--","single-issue-chisel/src"],cwd=FRAMEWORK,text=True)}
    (out/"manifest.json").write_text(json.dumps(manifest,indent=2)+"\n")
    rtl = out/"rtl"; rtl.mkdir(exist_ok=True)
    if not args.reuse_build:
        command = "run --out "+str(rtl)+" "+" ".join("--"+k+" "+str(v) for k,v in config.items() if k != "issue-width")
        run([Path.home()/".local/bin/sbt","-batch",command],out/"generate.log",PROJECT)
        (rtl/"filelist.f").write_text("student_top.sv\n")
        run([sys.executable,FRAMEWORK/"scripts/build.py","--filelist",rtl/"filelist.f","--out",build/"sim","--jobs",args.jobs],out/"build.log")
    simulator = build/"sim/sim"
    result = {"stage":args.stage,"experiment":args.name,"parameters":config,"rtl_sha256":sha(rtl/"student_top.sv"),"performance":[],"correctness":{"status":"not_run"},"synthesis":{"status":"not_run"},"tier2_pass":False}
    for kind in ("perf", "correctness"):
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
        run([sys.executable,FRAMEWORK/"scripts/synth.py","--filelist",rtl/"filelist.f","--out",build/"synth"],out/"synth.log")
        for filename in ("report.json","report.txt","timing.rpt","constraints.sdc"):
            shutil.copy2(build/"synth/opt"/filename,out/filename)
        report = json.loads((out/"report.json").read_text())
        result["synthesis"] = {"status":"passed","fmax_mhz":report["timing"]["estimated_fmax_mhz"],"area_um2":report["area"]["area_um2"]}
        result["tier2_pass"] = result["correctness"]["status"]=="passed" and result.get("ipc_geomean",0)>=0.845 and result["synthesis"]["area_um2"]<=18000 and result["synthesis"]["fmax_mhz"]>300
        result["stage_frequency_pass"] = result["tier2_pass"] and result["synthesis"]["fmax_mhz"] >= {1:300,2:400,3:500}[args.stage]
    (out/"summary.json").write_text(json.dumps(result,indent=2)+"\n")
    print(json.dumps({k:v for k,v in result.items() if k not in ("performance","correctness")},indent=2),flush=True)

if __name__ == "__main__": main()
