#!/usr/bin/env python3
"""Run supplied or generated cases, checking exit, retired count and full RAM."""
import argparse
import concurrent.futures
import hashlib
import json
import subprocess
import sys
from pathlib import Path
from differential import compare

ROOT = Path(__file__).resolve().parents[1]


def run_case(case, args):
    metrics = json.loads((case / "metrics.json").read_text())
    trace = args.output / f"{case.name}.csv"
    command = [str(args.binary.resolve()), "--image", str(case / "program.data"),
               "--latency", str(args.latency), "--max-cycles", str(args.max_cycles),
               "--seed", str(args.seed), "--random-wait", str(args.random_wait),
               "--request-wait", str(args.request_wait), "--max-outstanding", str(args.max_outstanding)]
    fault = metrics.get("fault")
    if fault:
        command += ["--expect-fault"]
        for field, value in fault.items():
            command += ["--fault-" + field, str(value)]
        if "dynamic_instructions" in metrics:
            command += ["--instructions", str(metrics["dynamic_instructions"])]
    else:
        command += ["--expected", str(case / "expected.txt"), "--memory", str(case / "expected.memory"),
                    "--instructions", str(metrics["dynamic_instructions"])]
    command += list(map(str, metrics.get("sim_args", [])))
    if args.differential and not fault:
        command += ["--trace", str(trace)]
    result = subprocess.run(command, capture_output=True, text=True, timeout=args.timeout)
    if result.returncode:
        raise RuntimeError((result.stderr or result.stdout).strip())
    lines = result.stdout.strip().splitlines()
    data = json.loads(next(line for line in reversed(lines) if line.startswith('{')))
    data["case"] = case.name
    if args.differential and not fault:
        compare(case / "program.data", trace)
        data["differential"] = "pass"
        if not args.keep_traces:
            trace.unlink()
    (args.output / f"{case.name}.json").write_text(json.dumps(data, indent=2) + "\n")
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cases", nargs="*")
    parser.add_argument("--root", type=Path, default=ROOT / "RISC-V-CPU-2026-Testcases")
    parser.add_argument("--binary", type=Path, default=ROOT / "build/cpu_sim")
    parser.add_argument("--output", type=Path, default=ROOT / "build/results")
    parser.add_argument("--latency", type=int, default=3)
    parser.add_argument("--max-cycles", type=int, default=100_000_000)
    parser.add_argument("--timeout", type=float, default=300, help="local process watchdog in seconds (not the course runtime limit)")
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--random-wait", type=int, default=0)
    parser.add_argument("--request-wait", type=int, default=0)
    parser.add_argument("--max-outstanding", type=int, default=64)
    parser.add_argument("--jobs", type=int, default=1)
    parser.add_argument("--differential", action="store_true")
    parser.add_argument("--keep-traces", action="store_true")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    cases = [args.root / name for name in args.cases] if args.cases else sorted(
        path.parent for path in args.root.glob("*/program.data") if (path.parent / "metrics.json").is_file())
    if not cases:
        parser.error("no testcase directories found")
    results, failures = [], []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        tasks = {pool.submit(run_case, case, args): case for case in cases}
        for task in concurrent.futures.as_completed(tasks):
            case = tasks[task]
            try:
                data = task.result()
                results.append(data)
                print(f"PASS {case.name}: instructions={data['instructions']} cycles={data['cycles']} IPC={data['ipc']:.6f}", flush=True)
            except Exception as error:
                failures.append({"case": case.name, "error": str(error)})
                print(f"FAIL {case.name}: {error}", file=sys.stderr, flush=True)
    summary = {"latency": args.latency, "seed": args.seed, "random_wait": args.random_wait,
               "request_wait": args.request_wait, "max_outstanding": args.max_outstanding, "passed": len(results), "failed": len(failures),
               "results": sorted(results, key=lambda x: x['case']), "failures": failures}
    summary["binary_sha256"] = hashlib.sha256(args.binary.read_bytes()).hexdigest()
    build_record = args.binary.resolve().parent / "build.json"
    if build_record.is_file():
        built = json.loads(build_record.read_text())
        if "sources_sha256" in built:
            if built.get("binary_sha256") != summary["binary_sha256"]:
                raise RuntimeError("Test binary differs from its build record")
            summary["measurement_build"] = built
    if results:
        summary["aggregate_ipc"] = sum(row["instructions"] for row in results) / sum(row["cycles"] for row in results)
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"{len(results)}/{len(cases)} passed; results: {args.output / 'summary.json'}")
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())
