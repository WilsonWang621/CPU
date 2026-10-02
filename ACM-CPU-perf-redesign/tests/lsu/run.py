#!/usr/bin/env python3
"""Run LSU directed tests with differential checking and measured event coverage."""
import argparse
import json
import subprocess
from pathlib import Path

from generate import ROOT, case_names, generate
from differential import compare


def run_case(binary, case, output, latency, waits, check_coverage):
    metadata = json.loads((case / "metrics.json").read_text())
    trace = output / f"{case.name}.csv"
    command = [str(binary), "--image", str(case / "program.data"),
               "--expected", str(case / "expected.txt"), "--memory", str(case / "expected.memory"),
               "--instructions", str(metadata["dynamic_instructions"]),
               "--latency", str(latency), "--max-cycles", "1000000", "--trace", str(trace),
               "--seed", "19", "--random-wait", "7" if waits else "0",
               "--request-wait", "2" if waits else "0"] + metadata.get("sim_args", [])
    result = subprocess.run(command, capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise RuntimeError(f"{case.name}: {result.stderr or result.stdout}")
    metrics = json.loads(next(line for line in result.stdout.splitlines() if line.startswith("{")))
    compare(case / "program.data", trace)
    for name, minimum in metadata.get("required_metrics", {}).items():
        if metrics.get(name, 0) < minimum:
            raise RuntimeError(f"{case.name}: required {name}>={minimum}, got {metrics.get(name, 0)}")
    for name, maximum in metadata.get("maximum_metrics", {}).items():
        if metrics.get(name, 0) > maximum:
            raise RuntimeError(f"{case.name}: required {name}<={maximum}, got {metrics.get(name, 0)}")
    coverage = {}
    for line in result.stdout.splitlines():
        if line.startswith("LSU_COVERAGE "):
            coverage = {key: int(value) for key, value in
                        (field.split("=") for field in line.split()[1:])}
    if check_coverage and not coverage:
        raise RuntimeError("Missing bound LSU coverage monitor; use --no-coverage for a production binary")
    metrics.update(case=case.name, differential="pass", coverage=coverage)
    (output / f"{case.name}.json").write_text(json.dumps(metrics, indent=2) + "\n")
    trace.unlink()
    print(f"PASS {case.name}: latency={latency} waits={int(waits)} instructions={metrics['instructions']}")
    return metrics


def require_events(results):
    # Every architectural answer is checked per run. Event requirements aggregate
    # scheduling variants, rather than relying on the removed reverse-walk state.
    fields = ["partial_forwarded", "canceled_responses", "canceled_errors",
              "canceled_preaccept", "physical_reuse", "rob_reuse",
              "pending_cancellations", "speculative_bypasses", "replays",
              "nested_recovery_with_load", "shadow_forwarded", "shadow_replay_avoided", "deferred_wait_release", "wait_owner_reuse"]
    totals = {field: sum(row["coverage"].get(field, 0) for row in results.values()) for field in fields}
    missing = [field for field, count in totals.items() if not count]
    if missing:
        raise RuntimeError("Coverage missing across LSU schedules: " + ", ".join(missing))
    return totals


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, default=ROOT / "build/lsu")
    parser.add_argument("--binary", type=Path)
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--no-coverage", action="store_true")
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    build = args.build_dir.resolve()
    build.mkdir(parents=True, exist_ok=True)
    binary = (args.binary or build / "cpu_sim").resolve()
    if not args.skip_build:
        rtl = [ROOT / "rtl/cpu_pkg.sv"] + sorted(path for path in (ROOT / "rtl").glob("*.sv")
                                                  if path.name != "cpu_pkg.sv")
        rtl.append(ROOT / "tests/lsu/lsu_monitor.sv")
        with (build / "build.log").open("w") as log:
            subprocess.run(["make", "build", f"BUILD_DIR={build}", f"JOBS={args.jobs}",
                            "PARAMS=-GPREDICTOR=0", "RTL=" + " ".join(map(str, rtl))],
                           cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
    cases = build / "cases"
    generate(cases)
    results = {}
    for latency in (3, 20):
        for waits in (False, True):
            output = build / f"latency{latency}-waits{int(waits)}"
            output.mkdir(exist_ok=True)
            for name in case_names():
                results[(name, latency, waits)] = run_case(
                    binary, cases / name, output, latency, waits, not args.no_coverage)
    if not args.no_coverage:
        totals = require_events(results)
        print("PASS required LSU events: partial forwarding, canceled preaccept/error responses, "
              "physical/ROB reuse, checkpoint redirects, speculative replay, per-byte shadows and wait-owner reuse")
    (build / "summary.json").write_text(json.dumps({"passed": len(results),
        "coverage": totals if not args.no_coverage else {},
        "coverage_checked": not args.no_coverage,
        "runs": [dict(value, latency=key[1], waits=key[2]) for key, value in results.items()]},
        indent=2) + "\n")
    print(f"{len(results)}/{len(results)} LSU runs passed; {build / 'summary.json'}")


if __name__ == "__main__":
    main()
