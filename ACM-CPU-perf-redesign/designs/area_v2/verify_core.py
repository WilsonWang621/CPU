#!/usr/bin/env python3
"""Architectural differential plus measured v2-specific mechanism coverage."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from differential import compare


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "build/area-v2/mechanisms")
    args = parser.parse_args()
    directory = args.output.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    commands = [
        [sys.executable, str(ROOT / "tests/core/generate.py"), "--output", str(directory / "core")],
        [sys.executable, str(ROOT / "tests/lsu/generate.py"), "--output", str(directory / "lsu")],
        [sys.executable, str(ROOT / "designs/area_v2/tests/generate_v2.py"), "--output", str(directory / "cache")],
    ]
    for command in commands:
        subprocess.run(command, check=True, cwd=ROOT)
    cases = sorted(p.parent for p in directory.glob("*/*/metrics.json"))
    results, totals = [], Counter()
    for latency, wait in ((3, 0), (20, 0), (20, 7), (97, 0)):
        for case in cases:
            metadata = json.loads((case / "metrics.json").read_text())
            trace = directory / "retirement.csv"
            command = [str(args.binary.resolve()), "--image", str(case / "program.data"),
                       "--expected", str(case / "expected.txt"), "--memory", str(case / "expected.memory"),
                       "--instructions", str(metadata["dynamic_instructions"]), "--latency", str(latency),
                       "--random-wait", str(wait), "--request-wait", "2" if wait else "0", "--seed", "19",
                       "--trace", str(trace), "--max-cycles", "1000000"] + metadata.get("sim_args", [])
            result = subprocess.run(command, capture_output=True, text=True, timeout=60)
            if result.returncode:
                raise RuntimeError(f"{case.name} latency={latency} wait={wait}: {result.stderr or result.stdout}")
            metrics = json.loads(next(line for line in result.stdout.splitlines() if line.startswith("{")))
            line = next(line for line in result.stdout.splitlines() if line.startswith("V2_COVERAGE "))
            coverage = {key: int(value) for key, value in (item.split("=") for item in line.split()[1:])}
            compare(case / "program.data", trace)
            trace.unlink()
            assert metrics["load_replay_count"] == 0, "v2 must not depend on speculative memory replay"
            totals.update(coverage)
            results.append(dict(case=case.name, latency=latency, wait=wait, metrics=metrics,
                                coverage=coverage, differential="pass"))
        print(f"PASS {len(cases)} cases: latency={latency} random_wait={wait}", flush=True)
    required = ["redirects", "dual_commit", "load_cancel", "canceled_response", "canceled_error",
                "live_tag_reuse", "forward", "partial_wait", "multi_load", "mdu_cancel", "victim_store_collision"]
    missing = [name for name in required if not totals[name]]
    report = dict(passed=len(results), missing_events=missing, coverage=dict(totals), results=results,
                  binary_sha256=hashlib.sha256(args.binary.read_bytes()).hexdigest(),
                  scope="Architectural differential plus v2 RAT invariants and event coverage; old four-wide/replay event requirements do not apply.")
    (directory / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(dict(passed=len(results), coverage=dict(totals), missing=missing)))
    return bool(missing)


if __name__ == "__main__":
    raise SystemExit(main())
