#!/usr/bin/env python3
"""Build a cycle-by-cycle AXI miter using the untouched final Verilog CPU.

Both complete CPUs see the same bus responses. The course simulator drives
the Chisel CPU; any mismatch in request timing/payload or response acceptance
is fatal. Idle request payloads are ignored because AXI does not transfer them.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

PROJECT = Path(__file__).resolve().parents[1]
ROOT = PROJECT.parent
OUT = PROJECT / "build/differential/sources"

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native-rtl", type=Path, default=PROJECT / "rtl/student_top.sv")
    parser.add_argument("--out", type=Path, default=OUT)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    refs = [ROOT / "verilog/area_v2_core.v", ROOT / "verilog/pararisc_axi_adapter.sv", ROOT / "verilog/student_top.sv"]
    original = "\n".join(p.read_text() for p in refs)
    names = re.findall(r"\bmodule\s+(\w+)", original)
    original = re.sub(r"\b(" + "|".join(map(re.escape, names)) + r")\b", lambda m: "ref_" + m[1], original)
    (out / "reference.sv").write_text(original)
    native = args.native_rtl.resolve()
    (out / "native.sv").write_text(re.sub(r"\bstudent_top\b", "chisel_student_top", native.read_text()))
    inputs = {"clock": 1, "reset": 1, "arready": 1, "rdata": 32, "rresp": 2, "rvalid": 1,
              "awready": 1, "wready": 1, "bresp": 2, "bvalid": 1}
    outputs = {"araddr": 32, "arvalid": 1, "rready": 1, "awaddr": 32, "awvalid": 1,
               "wdata": 32, "wstrb": 4, "wvalid": 1, "bready": 1}
    def declaration(direction, name, width):
        return direction + " wire " + (f"[{width-1}:0] " if width > 1 else "") + name
    lines = ["module student_top(\n" + ",\n".join(declaration("input", k, w) for k, w in inputs.items()) + ",\n" +
             ",\n".join(declaration("output", k, w) for k, w in outputs.items()) + ");"]
    lines += [declaration("", "ref_" + k, w).strip() + ";" for k, w in outputs.items()]
    lines += ["chisel_student_top native(" + ",".join(f".{k}({k})" for k in [*inputs, *outputs]) + ");",
              "ref_student_top reference(" + ",".join(f".{k}({k if k in inputs else 'ref_' + k})" for k in [*inputs, *outputs]) + ");"]
    lines += ["always @(posedge clock) if (!reset) begin"]
    for name in ("arvalid", "awvalid", "wvalid", "rready", "bready"):
        lines += [f'  if ({name} !== ref_{name}) $fatal(1,"Chisel/Verilog cycle mismatch: {name}");']
    for valid, payload in (("arvalid", "araddr"), ("awvalid", "awaddr"), ("wvalid", "wdata"), ("wvalid", "wstrb")):
        lines += [f'  if ({valid} && {payload} !== ref_{payload}) $fatal(1,"Chisel/Verilog payload mismatch: {payload}");']
    lines += ["end", "endmodule"]
    (out / "student_top.sv").write_text("\n".join(lines) + "\n")
    (out / "filelist.f").write_text("reference.sv\nnative.sv\nstudent_top.sv\n")
    manifest = {"property": "Identical AXI transfer timing, transferred payloads and R/B acceptance on a shared bus",
                "inputs_sha256": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in [*refs, native]},
                "sources_sha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(out.glob("*.sv"))}}
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print((out / "filelist.f").relative_to(ROOT))

if __name__ == "__main__":
    main()
