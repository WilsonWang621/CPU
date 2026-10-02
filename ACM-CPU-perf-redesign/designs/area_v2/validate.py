#!/usr/bin/env python3
"""Validate v2 design primitives and model contracts, not a complete CPU."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
OUTPUT = ROOT / "build/area-v2/validation"


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    rows = []
    commands = [("model_contracts", [sys.executable, str(HERE / "tests/test_model.py")])]
    verilator = ROOT / "build/tools/oss-cad-suite/bin/verilator"
    for name in ("rename", "load_hit"):
        top = f"v2_{name}_tb"
        build = OUTPUT / name
        commands += [(name + "_build", [str(verilator), "--binary", "-j", "2", "--timing", "--assert", "-Wall",
                                      "--top-module", top, "--Mdir", str(build),
                                      str(HERE / f"rtl/v2_{name}.sv"), str(HERE / f"tests/{top}.sv")]),
                     (name + "_test", [str(build / ("V" + top))])]
    for name, command in commands:
        with (OUTPUT / (name + ".log")).open("w") as log:
            result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=120)
        rows.append(dict(name=name, command=command, returncode=result.returncode))
        print(name, result.returncode, flush=True)
        if result.returncode:
            print((OUTPUT / (name + ".log")).read_text())
            break
    sources = [p for p in HERE.rglob("*") if p.suffix in (".sv", ".py")]
    report = dict(scope="Design primitive tests only. No integrated CPU or full architectural validation.",
                  source_sha256={str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
                  results=rows, passed=all(r["returncode"] == 0 for r in rows))
    (OUTPUT / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    return not report["passed"]


if __name__ == "__main__":
    raise SystemExit(main())
