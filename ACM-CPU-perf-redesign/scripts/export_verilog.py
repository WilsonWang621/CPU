#!/usr/bin/env python3
"""Export synthesizable Verilog-2005 from the complete SystemVerilog CPU."""
import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def convert(sources, sv2v):
    """Convert an explicit, already snapshotted source list to plain Verilog."""
    command = [str(sv2v), "-DSYNTHESIS", "-E", "Always", *map(str, sources)]
    converted = subprocess.check_output(command, cwd=ROOT, text=True)
    # Preserve process kinds through sv2v, then use portable Verilog processes.
    # Explicit entire-array sensitivity lists are rejected by strict readers.
    converted = re.sub(r"\balways_comb\b", "always @*", converted)
    converted = re.sub(r"\balways_ff\b", "always", converted)
    converted = re.sub(r"\balways_latch\b", "always @*", converted)
    return converted, command


def export(output, sv2v, source_root=ROOT):
    sources = [source_root / "rtl/cpu_pkg.sv"] + sorted(
        path for path in (source_root / "rtl").glob("*.sv") if path.name != "cpu_pkg.sv")
    converted, command = convert(sources, sv2v)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(converted)
    metadata = {
        "rtl_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "source_root": str(source_root),
        "commit_scope": "workspace Git context; exact inputs are identified by sources_sha256",
        "sv2v": subprocess.check_output([str(sv2v), "--version"], text=True).strip(),
        "sources_sha256": {str(p.relative_to(source_root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
        "output_sha256": hashlib.sha256(output.read_bytes()).hexdigest(), "command": command,
    }
    output.with_suffix(".metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"Exported Verilog to {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/synth/cpu.v")
    parser.add_argument("--sv2v", type=Path, default=ROOT / "build/tools/sv2v-Linux/sv2v")
    parser.add_argument("--source-root", type=Path, default=ROOT)
    args = parser.parse_args()
    export(args.output.resolve(), args.sv2v.resolve(), args.source_root.resolve())
