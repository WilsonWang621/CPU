#!/usr/bin/env python3
"""Regression for a retired ROB forwarding owner suppressing a later store replay.

This standalone regression leaves the main LSU fixture set unchanged. Build with
forward_owner_monitor.sv to check the retiring-owner event explicitly, or use an
ordinary cpu_sim for architectural retirement/full-RAM checking only.
"""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path

from generate import Program, ROOT, dependency_chain, i, r, s
from differential import compare


def generate(cases):
    for narrow in (False, True):
        p = Program()
        for reg, value in [(30, 0x10000), (29, 0x18000), (1, 0x80000000),
                           (2, 7), (3, 0x11223344), (4, 0xaabbccdd), (6, 0x8000)]:
            p.li(reg, value)
        p.seed(0x10000, 0x55667788)
        p.emit(i(0x03, 2, 9, 30, 0))
        p.align()
        # DIV0 keeps ready F in the ROB while L issues. DIV1 starts after DIV0,
        # allowing F to retire before S resolves. The pairs differ, so divider
        # memoization cannot remove this ordering. Real ADDIs restore the address.
        p.emit(r(5, 20, 1, 2, 1))
        f_pc = p.pc
        p.emit(s(0 if narrow else 2, 30, 3, 0))
        p.emit(r(5, 10, 1, 6, 1))
        dependency_chain(p, 10, 4)
        s_pc = p.pc
        p.emit(s(0 if narrow else 2, 10, 4, 0))
        l_pc = p.pc
        p.emit(i(0x03, 2, 5, 30, 0))
        p.emit(s(2, 29, 5, 0))
        p.exit(5)
        name = "retired_forward_owner_byte" if narrow else "retired_forward_owner_full"
        p.save(cases, name)
        (cases / name / "pcs.json").write_text(json.dumps(
            {"forward_store": f_pc, "resolving_store": s_pc, "load": l_pc}, indent=2) + "\n")


def parse_events(stdout):
    result = []
    for line in stdout.splitlines():
        if line.startswith("OWNER_"):
            event, *fields = line.split()
            # PC and mask fields are emitted in hex, other fields in decimal.
            row = {key: int(value, 16 if key.endswith("_pc") or key == "mask" else 10)
                   for key, value in (field.split("=") for field in fields)}
            result.append(dict(event=event, **row))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "build/forward-owner-regression")
    parser.add_argument("--require-monitor", action="store_true")
    args = parser.parse_args()
    binary = args.binary.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    cases = output / "cases"
    generate(cases)
    results, failures = [], []
    for case in sorted(cases.iterdir()):
        count = json.loads((case / "metrics.json").read_text())["dynamic_instructions"]
        for latency in (3, 20):
            for waits in (False, True):
                name = f"{case.name}-lat{latency}-wait{int(waits)}"
                trace = output / f"{name}.csv"
                command = [str(binary), "--image", str(case / "program.data"),
                           "--expected", str(case / "expected.txt"),
                           "--memory", str(case / "expected.memory"),
                           "--instructions", str(count), "--latency", str(latency),
                           "--trace", str(trace), "--max-cycles", "100000",
                           "--seed", "19", "--random-wait", "7" if waits else "0",
                           "--request-wait", "2" if waits else "0"]
                process = subprocess.run(command, capture_output=True, text=True, timeout=30)
                (output / f"{name}.log").write_text(process.stdout + process.stderr)
                row = dict(case=case.name, latency=latency, waits=waits,
                           returncode=process.returncode, events=parse_events(process.stdout))
                try:
                    compare(case / "program.data", trace)
                    row["differential"] = "pass"
                    if process.returncode:
                        raise RuntimeError(process.stderr.strip())
                    row["metrics"] = json.loads(next(line for line in process.stdout.splitlines()
                                                     if line.startswith("{")))
                except (RuntimeError, ValueError, StopIteration) as error:
                    row["error"] = str(error)
                    failures.append(name)
                results.append(row)
                print(("FAIL " if "error" in row else "PASS ") + name, flush=True)
    old_owner_events = [event for row in results for event in row["events"]
                        if event["event"] == "OWNER_CONFLICT" and
                        event["owner_age"] > event["load_age"] > event["store_age"]]
    if args.require_monitor:
        if not old_owner_events:
            failures.append("missing retired-or-reused forwarding-owner coverage")
        if any(not event["replay"] for event in old_owner_events):
            failures.append("old forwarding owner incorrectly suppressed replay")
    report = {"binary": str(binary), "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
              "monitor_required": args.require_monitor, "old_owner_conflicts": len(old_owner_events),
              "passed": sum("error" not in row for row in results), "failures": failures,
              "runs": results}
    (output / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    return int(bool(failures))


if __name__ == "__main__":
    raise SystemExit(main())
