#!/usr/bin/env python3
"""Build and test real parameter configurations with unchanged course tools."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess

PROJECT = Path(__file__).resolve().parents[1]
ROOT = PROJECT.parent
PROFILES = json.loads((PROJECT / "scripts/parameter_profiles.json").read_text())
BASE = PROJECT / "build/parameters"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def command(args, log):
    env = dict(os.environ, APPIMAGE_EXTRACT_AND_RUN="1", PYTHONUNBUFFERED="1")
    with log.open("w") as output:
        subprocess.run(args, cwd=ROOT, env=env, stdout=output, stderr=subprocess.STDOUT, check=True)


def check(name, jobs):
    out = BASE / name
    rtl = out / "student_top.sv"
    assert rtl.is_file(), f"Generate {name} first"
    (out / "filelist.f").write_text("student_top.sv\n")
    binary = out / "sim/sim"
    receipt = out / "build-receipt.json"
    prior = json.loads(receipt.read_text()) if receipt.exists() else {}
    if not binary.exists() or prior.get("rtl_sha256") != sha(rtl) or prior.get("sim_sha256") != sha(binary):
        print(name + ": building", flush=True)
        command(["make", "build", f"FILELIST={out / 'filelist.f'}", f"BUILD={out / 'sim'}", f"JOBS={jobs}"], out / "build.log")
        prior = {"rtl_sha256": sha(rtl), "sim_sha256": sha(binary), "build_origin": str(out)}
        receipt.write_text(json.dumps(prior, indent=2) + "\n")
    make = ["make", f"SIM={binary}", "MAX_CYCLES=20000000", "LATENCY=20"]
    for program, expected in [("rv32im", "0x600d600d"), ("upper-memory", "0x0fffffc0")]:
        command([*make, "run", f"PROGRAM={PROJECT / 'build/requirements-programs' / (program + '.data')}", f"EXPECTED={expected}"], out / (program + ".log"))
        assert "PASS cycles=" in (out / (program + ".log")).read_text()
    command([*make, "test", "Case=correctness_basicopt1"], out / "basicopt.log")
    assert "Results: 1 passed, 0 failed" in (out / "basicopt.log").read_text()
    print(name + ": ISA/memory/basicopt passed; measuring IPC", flush=True)
    command(["make", "perf", f"SIM={binary}", "LATENCY=10", "MAX_CYCLES=20000000"], out / "perf-lat10.log")
    rows = re.findall(r"^perf_(\w+)\s+(\d+)\s+(\d+)\s+([\d.]+)\s*$", (out / "perf-lat10.log").read_text(), re.M)
    assert len(rows) == 6
    performance = {n: {"instructions": int(i), "cycles": int(c)} for n, i, c, _ in rows}
    gm = math.exp(sum(math.log(r["instructions"] / r["cycles"]) for r in performance.values()) / 6)
    result = {"profile": name, "arguments": PROFILES[name], "config": json.loads((out / "elaboration.json").read_text())["config"],
              "rtl_sha256": sha(rtl), "sim_sha256": sha(binary), "latency": 10, "geomean_ipc": gm,
              "performance": performance, "checks": {"rv32im_86_named_checks": True, "upper_RAM_instruction_address": True, "official_basicopt": True},
              "source_sha256": {str(p.relative_to(PROJECT)): sha(p) for p in sorted((PROJECT / "src/main/scala").rglob("*.scala"))}}
    (out / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(f"{name}: PASS, IPC GM={gm:.10f}", flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profiles", default=",".join(PROFILES))
    parser.add_argument("--workers", type=int, default=2)
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    names = args.profiles.split(",")
    assert set(names).issubset(PROFILES)
    results = []
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        for future in as_completed([pool.submit(check, name, args.jobs) for name in names]):
            results.append(future.result())
    results.sort(key=lambda r: list(PROFILES).index(r["profile"]))
    (BASE / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    print(f"All {len(results)} configurations passed", flush=True)


if __name__ == "__main__":
    main()
