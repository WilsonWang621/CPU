#!/usr/bin/env python3
"""Recover named RTL registers for mapped critical paths; synthesis stays unchanged."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/"scripts"))
from toolchain import DEFAULT_APPIMAGE, enter_appimage, packaged_tool

enter_appimage(DEFAULT_APPIMAGE)
out = Path(sys.argv[1]).resolve()
trace = out/"trace-renames.log"
with trace.open("w") as log:
    subprocess.run([packaged_tool("yosys"),"-Q","-T","-p",
      f'read_json "{out}/design.json"; write_verilog -v -noattr -noexpr "{out}/trace-mapped.v"'],stdout=log,check=True)
recipe = (out/"synth.ys").read_text().split("abc -exe",1)[0]
recipe = re.sub(r"/tmp/\.mount_cpu202[^/]+",os.environ["CPU2026_APPDIR"],recipe)
recipe += f'write_json "{out}/preabc.json"\n'
(out/"preabc.ys").write_text(recipe)
subprocess.run([packaged_tool("yosys"),"-Q","-T","-q","-s",str(out/"preabc.ys")],check=True)
mapped = json.loads((out/"design.json").read_text())["modules"]["student_top"]
before = json.loads((out/"preabc.json").read_text())["modules"]["student_top"]
reverse = {b:a for a,b in re.findall(r"renaming `([^']+)' to `([^']+)'",trace.read_text())}
timing = json.loads((out/"timing.json").read_text())
origins = []
for path in timing["critical_paths"][:3]:
    for label in ("startpoint","endpoint"):
        pin = path[label]; cell,pname = pin.rsplit("/",1); original = reverse.get(cell,cell)
        c = before["cells"].get(original)
        if not c: continue
        output = c["connections"].get("QN",c["connections"].get("Q",[]))
        bits = set(output)
        for inv in before["cells"].values():
            if inv["type"]=="$_NOT_" and any(x in bits for x in inv["connections"]["A"]):
                bits.update(inv["connections"]["Y"])
        aliases = [{"name":n,"bits":[i for i,b in enumerate(v["bits"]) if b in bits]}
                   for n,v in before["netnames"].items() if not n.startswith("$") and any(b in bits for b in v["bits"])]
        origins.append({"role":label,"pin":pin,"original":original,"source":c["attributes"].get("src"),"aliases":aliases})
(out/"critical-origin.json").write_text(json.dumps(origins,indent=2)+"\n")
print(json.dumps(origins,indent=2))
