#!/usr/bin/env python3
"""Prove the scalar-node selection tree equals its frozen array representation."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts"))
from export_verilog import convert


def main():
    output = ROOT / "build/area-v2/selection-equivalence"
    output.mkdir(parents=True, exist_ok=True)
    sources = [Path(__file__).with_name("v2_select_reference.sv"), ROOT / "designs/area_v2/rtl/v2_select.sv"]
    verilog, command = convert(sources, ROOT / "build/tools/sv2v-Linux/sv2v")
    (output / "selectors.v").write_text(verilog)
    results = []
    for entries, width, young in ((8, 5, 0), (8, 4, 0), (16, 4, 0), (16, 4, 1)):
        name = f"n{entries}w{width}y{young}"
        wrapper = f"""module compare(input [{entries-1}:0] ready,input [{entries*width-1}:0] owner,
input [{width-1}:0] rob_head,output ok);
wire va,vb;wire [{(entries-1).bit_length()-1}:0] ia,ib;
v2_select_reference #(.ENTRIES({entries}),.SLOT_BITS({width}),.YOUNGEST({young})) a(ready,owner,rob_head,va,ia);
v2_select #(.ENTRIES({entries}),.SLOT_BITS({width}),.YOUNGEST({young})) b(ready,owner,rob_head,vb,ib);
assign ok=(va==vb)&&(ia==ib);
endmodule
"""
        (output / (name + ".v")).write_text(wrapper)
        script = f"read_verilog {output}/selectors.v {output}/{name}.v\nprep -top compare -flatten\nsat -verify -prove ok 1\n"
        (output / (name + ".ys")).write_text(script)
        with (output / (name + ".log")).open("w") as log:
            result = subprocess.run([str(ROOT / "build/tools/oss-cad-suite/bin/yosys"), "-Q", "-s", str(output / (name + ".ys"))],
                                    stdout=log, stderr=subprocess.STDOUT, timeout=60)
        results.append(dict(entries=entries, slot_bits=width, youngest=young, returncode=result.returncode))
    report = dict(sources_sha256={str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
                  export_command=command, results=results, passed=all(r["returncode"] == 0 for r in results))
    (output / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))
    return not report["passed"]


if __name__ == "__main__":
    raise SystemExit(main())
