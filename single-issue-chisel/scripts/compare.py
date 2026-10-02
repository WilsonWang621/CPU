#!/usr/bin/env python3
"""Generate the committed before/after and parameter comparison from measurements."""
import csv
import json
from pathlib import Path

project = Path(__file__).resolve().parents[1]
benchmarks = ["median","multiply","qsort","rsort","towers","vvadd"]
for stage in (1,2,3):
    directory = project/"reports"/("stage"+str(stage))
    directory.mkdir(exist_ok=True)
    rows=[]
    for path in sorted(directory.glob("*/summary.json")):
        s=json.loads(path.read_text());p=s.get("parameters",s.get("config",{}));t=s.get("synthesis",{})
        if not p and (path.parent/"manifest.json").exists():
            p=json.loads((path.parent/"manifest.json").read_text()).get("parameters",{})
        c=s.get("correctness",{})
        status=c.get("status",str(c.get("passed","not_run")))
        row={"experiment":path.parent.name,"status":s.get("status","measured"),"debug":p.get("debug",0),"rob":p.get("rob"),"iq":p.get("iq"),"line_bytes":p.get("line-bytes",p.get("line_bytes")),
             "ic_bytes":p.get("ic-bytes",p.get("ic_bytes")),"dc_bytes":p.get("dc-bytes",p.get("dc_bytes")),
             "banks":p.get("banks",1),"btb":p.get("btb-entries",64),"history_bits":p.get("history-bits",0),
             "l0_entries":p.get("l0-entries",0),"l0_fill_stages":p.get("l0-fill-stages",0),"l0_replacement":p.get("l0-replacement",0),"l0_store_stages":p.get("l0-store-stages",0),"ram_read_ahead":p.get("ram-read-ahead",0),
             "store_entries_per_bank":p.get("store-entries",0),"store_slots":p.get("store-slots",p.get("rob")),"load_entries":p.get("load-entries",4),"checkpoints":p.get("checkpoints",0),"fast_redirect":p.get("fast-redirect",0),
             "prefetch":p.get("prefetch",0),"ipc":s.get("ipc_geomean"),"frequency_mhz":t.get("fmax_mhz",s.get("fmax_mhz")),
             "area_um2":t.get("area_um2",s.get("area_um2")),"correctness":status,"tier2_pass":s.get("tier2_pass",False)}
        perf=s.get("performance",[])
        for b in benchmarks:
            row[b+"_ipc"]=next((x.get("ipc") for x in perf if x["case"]=="perf_"+b),None)
        rows.append(row)
    if not rows: continue
    with (directory/"comparison.csv").open("w",newline="") as f:
        w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)
    def fmt(v): return "—" if v is None else (f"{v:.5f}" if isinstance(v,float) else str(v))
    header=["experiment","status","debug","rob","iq","line_bytes","ic_bytes","dc_bytes","banks","btb","history_bits","l0_entries","l0_fill_stages","l0_replacement","l0_store_stages","ram_read_ahead","store_entries_per_bank","store_slots","load_entries","checkpoints","fast_redirect","prefetch","ipc","frequency_mhz","area_um2","correctness","tier2_pass"]
    text="参数、正确性和默认综合对照。未运行项目用 `—` / `not_run` 标记；原始报告在对应实验目录。\n\n"
    text+="| "+" | ".join(header)+" |\n|"+"---|"*len(header)+"\n"
    for row in rows: text+="| "+" | ".join(fmt(row[k]) for k in header)+" |\n"
    text+="\n六项 IPC 明细见 [comparison.csv](comparison.csv)。\n"
    (directory/"comparison.md").write_text(text)
