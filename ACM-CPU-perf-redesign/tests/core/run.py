#!/usr/bin/env python3
"""Build a monitored CPU and require real rename/recovery coverage."""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from differential import compare


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, default=ROOT / "build/core")
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--no-build", action="store_true")
    args = parser.parse_args()
    directory = args.build_dir.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    subprocess.run([sys.executable, str(ROOT / "tests/core/generate.py"),
                    "--output", str(directory / "tests")], check=True, cwd=ROOT)
    if not args.no_build:
        rtl = [ROOT / "rtl/cpu_pkg.sv"] + sorted(
            path for path in (ROOT / "rtl").glob("*.sv") if path.name != "cpu_pkg.sv")
        rtl.append(ROOT / "tests/core/core_monitor.sv")
        sources = rtl + [ROOT / "sim/main.cpp", ROOT / "sim/memory_model.h", ROOT / "Makefile"]
        snapshot = directory / "source"
        for source in sources:
            copied = snapshot / source.relative_to(ROOT)
            copied.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, copied)
        copied_rtl = [snapshot / path.relative_to(ROOT) for path in rtl]
        requested_verilator = os.environ.get("VERILATOR", str(ROOT / "RISC-V-CPU-2026-Toolchain/bin/verilator"))
        verilator = str(Path(shutil.which(requested_verilator) or requested_verilator).resolve())
        command = ["make", "build", f"BUILD_DIR={directory}", f"JOBS={args.jobs}",
                   "PARAMS=-GPREDICTOR=0", f"VERILATOR={verilator}",
                   "RTL=" + " ".join(map(str, copied_rtl))]
        provenance = {
            "rtl_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
            "git_status": subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True).strip(),
            "sources_sha256": {str(path.relative_to(ROOT)): hashlib.sha256(
                (snapshot / path.relative_to(ROOT)).read_bytes()).hexdigest() for path in sources},
            "parameters": {"PREDICTOR": 0},
            "source_snapshot": str(snapshot),
            "verilator": subprocess.check_output([verilator, "--version"], text=True).strip(),
            "sim_flags": os.environ.get("SIM_FLAGS", ""),
            "build_command": command,
            "build_status": "running",
        }
        provenance_file = directory / "build-metadata.json"
        provenance_file.write_text(json.dumps(provenance, indent=2) + "\n")
        with (directory / "build.log").open("w") as log:
            built = subprocess.run(command, cwd=snapshot, stdout=log, stderr=subprocess.STDOUT)
        provenance["build_status"] = "pass" if built.returncode == 0 else "failed"
        provenance["build_returncode"] = built.returncode
        provenance_file.write_text(json.dumps(provenance, indent=2) + "\n")
        built.check_returncode()
        provenance["binary_sha256"] = hashlib.sha256((directory / "cpu_sim").read_bytes()).hexdigest()
        provenance_file.write_text(json.dumps(provenance, indent=2) + "\n")
    totals = {key: 0 for key in ("rename", "waw", "checkpoint", "replay", "mdu_cancel", "commit", "rename4", "commit4", "older_redirect")}
    results = []
    for case in sorted((directory / "tests").iterdir()):
        instructions = json.loads((case / "metrics.json").read_text())["dynamic_instructions"]
        trace = case / "trace.csv"
        command = [str(directory / "cpu_sim"), "--image", str(case / "program.data"),
                   "--expected", str(case / "expected.txt"), "--memory", str(case / "expected.memory"),
                   "--instructions", str(instructions), "--latency", "3", "--trace", str(trace)]
        run = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, check=True)
        compare(case / "program.data", trace)
        line = next(line for line in run.stdout.splitlines() if line.startswith("CORE_COVERAGE"))
        coverage = {key: int(value) for key, value in re.findall(r"(\w+)=(\d+)", line)}
        for key in totals:
            totals[key] += coverage[key]
        result = json.loads(next(line for line in run.stdout.splitlines() if line.startswith("{")))
        result.update(case=case.name, coverage=coverage, differential="pass")
        results.append(result)
        print(f"PASS {case.name}: {line}", flush=True)
    missing = [key for key, count in totals.items() if count == 0]
    if missing:
        raise RuntimeError("Required events not exercised: " + ", ".join(missing))
    provenance_file = directory / "build-metadata.json"
    provenance = json.loads(provenance_file.read_text()) if provenance_file.is_file() else {
        "source_state": "not recorded by earlier builder",
        "binary_sha256": hashlib.sha256((directory / "cpu_sim").read_bytes()).hexdigest(),
    }
    summary = {"passed": len(results), "coverage": totals, "results": results,
               "build_provenance": provenance, "parameters": {"PREDICTOR": 0}, "latency": 3}
    (directory / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"CORE PASS: {len(results)} cases with architectural differential and required coverage")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
