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


def sources():
    return {str(p.relative_to(PROJECT)): sha(p)
            for p in sorted((PROJECT / "src/main/scala").rglob("*.scala"))}


def command(args, log, cwd=ROOT):
    env = dict(os.environ, APPIMAGE_EXTRACT_AND_RUN="1", PYTHONUNBUFFERED="1")
    with log.open("w") as output:
        subprocess.run(args, cwd=cwd, env=env, stdout=output, stderr=subprocess.STDOUT, check=True)


def generate(names):
    BASE.mkdir(parents=True, exist_ok=True)
    before = sources()
    commands = ["run --out " + str(BASE / name) + " " + " ".join(PROFILES[name]) for name in names]
    command([os.environ.get("SBT", "sbt"), "-batch", *commands], BASE / "generate.log", PROJECT)
    assert sources() == before, "Sources changed during generation"
    for name in names:
        out = BASE / name
        (out / "generation-receipt.json").write_text(json.dumps({
            "arguments": PROFILES[name], "source_sha256": before,
            "rtl_sha256": sha(out / "student_top.sv"),
            "elaboration_sha256": sha(out / "elaboration.json"),
        }, indent=2) + "\n")


def check(name, jobs, full_correctness, latencies, collect_only=False):
    out = BASE / name
    rtl = out / "student_top.sv"
    assert rtl.is_file(), f"Generate {name} first"
    generation = json.loads((out / "generation-receipt.json").read_text())
    assert generation["source_sha256"] == sources(), f"Regenerate {name} after source changes"
    assert generation["arguments"] == PROFILES[name]
    assert generation["rtl_sha256"] == sha(rtl)
    assert generation["elaboration_sha256"] == sha(out / "elaboration.json")
    (out / "filelist.f").write_text("student_top.sv\n")
    binary = out / "sim/sim"
    receipt = out / "build-receipt.json"
    prior = json.loads(receipt.read_text()) if receipt.exists() else {}
    if not binary.exists() or prior.get("rtl_sha256") != sha(rtl) or prior.get("sim_sha256") != sha(binary):
        assert not collect_only, "Cannot collect results for an unbuilt or changed simulator"
        print(name + ": building", flush=True)
        command(["make", "build", f"FILELIST={out / 'filelist.f'}", f"BUILD={out / 'sim'}", f"JOBS={jobs}"], out / "build.log")
        prior = {"rtl_sha256": sha(rtl), "sim_sha256": sha(binary), "build_origin": str(out)}
        receipt.write_text(json.dumps(prior, indent=2) + "\n")
    def run(args, log):
        if collect_only:
            assert log.is_file(), f"Missing evidence: {log}"
        else:
            command(args, log)
    make = ["make", f"SIM={binary}", "MAX_CYCLES=20000000", "LATENCY=20"]
    for program, expected in [("rv32im", "0x600d600d"), ("upper-memory", "0x0fffffc0")]:
        run([*make, "run", f"PROGRAM={PROJECT / 'build/requirements-programs' / (program + '.data')}", f"EXPECTED={expected}"], out / (program + ".log"))
        assert "PASS cycles=" in (out / (program + ".log")).read_text()
    run([*make, "test", "Case=correctness_basicopt1"], out / "basicopt.log")
    assert "Results: 1 passed, 0 failed" in (out / "basicopt.log").read_text()
    print(name + ": ISA/memory/basicopt passed; measuring IPC", flush=True)
    correctness = None
    if full_correctness:
        run([*make, "test"], out / "correctness-lat20.log")
        names = {p.name.removeprefix("correctness_") for p in (ROOT / "testcases").glob("correctness_*") if p.is_dir()}
        log = (out / "correctness-lat20.log").read_text()
        rows = re.findall(r"\[correctness_(\w+)\]\s+PASS cycles=(\d+)", log)
        assert len(rows) == len(names) and {n for n, _ in rows} == names
        assert f"Results: {len(names)} passed, 0 failed" in log
        correctness = {n: int(c) for n, c in rows}
    all_performance = {}
    for latency in latencies:
        log = out / f"perf-lat{latency}.log"
        run(["make", "perf", f"SIM={binary}", f"LATENCY={latency}", "MAX_CYCLES=20000000"], log)
        rows = re.findall(r"^perf_(\w+)\s+(\d+)\s+(\d+)\s+([\d.]+)\s*$", log.read_text(), re.M)
        cases = {p.name.removeprefix("perf_"): p for p in (ROOT / "testcases").glob("perf_*") if p.is_dir()}
        assert len(rows) == len(cases) and {r[0] for r in rows} == set(cases)
        performance = {n: {"instructions": int(i), "cycles": int(c)} for n, i, c, _ in rows}
        for n, row in performance.items():
            assert row["instructions"] == json.loads((cases[n] / "metrics.json").read_text())["dynamic_instructions"]
        gm = math.exp(sum(math.log(r["instructions"] / r["cycles"]) for r in performance.values()) / len(cases))
        all_performance[str(latency)] = {"geomean_ipc": gm, "benchmarks": performance}
    primary = all_performance[str(latencies[0])]
    result = {"profile": name, "arguments": PROFILES[name], "config": json.loads((out / "elaboration.json").read_text())["config"],
              "rtl_sha256": sha(rtl), "sim_sha256": sha(binary), "latency": latencies[0], "geomean_ipc": primary["geomean_ipc"],
              "performance": primary["benchmarks"], "performance_by_latency": all_performance,
              "correctness_lat20": correctness,
              "checks": {"rv32im_86_named_checks": True, "upper_RAM_instruction_address": True, "official_basicopt": True},
              "source_sha256": sources(),
              "logs_sha256": {f.name: sha(f) for f in sorted(out.glob("*.log")) if f.name != "build.log"}}
    (out / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(f"{name}: PASS, IPC GM={primary['geomean_ipc']:.10f}", flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profiles", default=",".join(PROFILES))
    parser.add_argument("--workers", type=int, default=2)
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--generate", action="store_true", help="Regenerate selected CPUs and record source/RTL identities first")
    parser.add_argument("--full-correctness", action="store_true", help="Run every official correctness case per profile at latency 20")
    parser.add_argument("--latencies", default="10", help="Comma-separated performance memory latencies")
    parser.add_argument("--collect-only", action="store_true", help="Validate and summarize existing logs without rerunning tests")
    args = parser.parse_args()
    names = args.profiles.split(",")
    assert set(names).issubset(PROFILES)
    assert len(names) == len(set(names)) and args.workers > 0 and args.jobs > 0
    latencies = [int(n) for n in args.latencies.split(",")]
    assert latencies and min(latencies) > 0 and len(latencies) == len(set(latencies))
    if args.generate:
        assert not args.collect_only
        generate(names)
    results = []
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        for future in as_completed([pool.submit(check, name, args.jobs, args.full_correctness, latencies, args.collect_only) for name in names]):
            results.append(future.result())
    results.sort(key=lambda r: list(PROFILES).index(r["profile"]))
    (BASE / ("results-" + "-".join(names) + ".json")).write_text(json.dumps(results, indent=2) + "\n")
    print(f"All {len(results)} configurations passed", flush=True)


if __name__ == "__main__":
    main()
