#!/usr/bin/env python3
"""Run course cases with the simulation-only memory selection invariant."""
import argparse
import json
import math
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from testcase import CYCLES, cases_of, execute

CHECK = re.compile(r"Memory selection invariant: PASS checks=(\d+) waiting=(\d+)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sim", type=Path, required=True)
    parser.add_argument("--kind", choices=("correctness", "perf"), required=True)
    parser.add_argument("--latency", type=int, default=20)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    cases = cases_of(ROOT / "testcases", args.kind, None)
    if not cases:
        parser.error("course testcases are missing")
    results = []
    for case in cases:
        run = execute(Path("build"), case, 30_000_000, args.latency, args.sim)
        check = CHECK.search(run.stderr)
        cycles = CYCLES.search(run.stderr)
        if not check or not cycles:
            raise RuntimeError(f"{case.name}: invariant or cycle report missing")
        row = {"case": case.name, "cycles": int(cycles[1]),
               "selection_checks": int(check[1]), "waiting_cycles": int(check[2])}
        if args.kind == "perf":
            row["instructions"] = json.loads((case / "metrics.json").read_text())["dynamic_instructions"]
            row["ipc"] = row["instructions"] / row["cycles"]
        results.append(row)
        print(f"PASS {case.name}: cycles={row['cycles']} checks={row['selection_checks']} waiting={row['waiting_cycles']}", flush=True)
    report = {"kind": args.kind, "latency": args.latency, "results": results,
              "selection_checks": sum(r["selection_checks"] for r in results),
              "waiting_cycles": sum(r["waiting_cycles"] for r in results)}
    if args.kind == "perf":
        if report["selection_checks"] < 1000 or report["waiting_cycles"] < 10:
            raise RuntimeError("insufficient memory selection coverage")
        report["ipc_geomean"] = math.exp(sum(math.log(r["ipc"]) for r in results) / len(results))
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Results: {len(results)} passed, 0 failed", flush=True)


if __name__ == "__main__":
    main()
