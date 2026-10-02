#!/usr/bin/env python3
"""Bounded SAT audit of rotating versus fixed-entry byte forwarding."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(__file__).with_name("forwarding_equivalence.sv")


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--yosys", type=Path,
                        default=ROOT / "build/tools/oss-cad-suite/bin/yosys")
    parser.add_argument("--output", type=Path, default=ROOT / "build/forwarding-equivalence")
    parser.add_argument("--sizes", nargs="+", type=int, default=[4, 8])
    parser.add_argument("--timeout", type=int, default=60,
                        help="SAT solver seconds per size; a timeout is inconclusive")
    args = parser.parse_args()
    if args.timeout <= 0 or any(n < 2 or n > 16 or n & (n - 1) for n in args.sizes):
        parser.error("timeout must be positive and sizes powers of two from 2 through 16")
    yosys = args.yosys.resolve()
    if not yosys.is_file():
        parser.error("Yosys missing; run python3 scripts/bootstrap_modern_synth.py")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    source = output / "forwarding_equivalence.sv"
    source.write_bytes(SOURCE.read_bytes())
    env = dict(os.environ)
    env.pop("YOSYS_DATDIR", None)
    report = {
        "source": str(SOURCE.relative_to(ROOT)),
        "source_sha256": sha256(SOURCE),
        "yosys_version": subprocess.check_output([str(yosys), "-V"], env=env, text=True).strip(),
        "sat_timeout_seconds": args.timeout,
        "runs": [],
    }
    for size in args.sizes:
        directory = output / f"n{size}"
        directory.mkdir(exist_ok=True)
        script = directory / "prove.ys"
        script.write_text(
            f'read_slang --top forwarding_equivalence -G N={size} {source.name}\n'
            "opt -full\nwreduce\nopt -full\n"
            f"sat -verify -prove equivalent 1 -show-inputs -show-outputs -timeout {args.timeout}\n")
        started = time.monotonic()
        watchdog = False
        with (directory / "proof.log").open("w") as log:
            process = subprocess.Popen([str(yosys), "-Q", "-T", "-s", str(script)],
                                       env=env, cwd=output, stdout=log, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            try:
                process.wait(timeout=args.timeout + 30)
            except subprocess.TimeoutExpired:
                watchdog = True
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        contents = (directory / "proof.log").read_text()
        if process.returncode == 0 and "SUCCESS!" in contents:
            status = "proven"
        elif watchdog or "proof did time out" in contents:
            status = "inconclusive_timeout"
        else:
            status = "failed"
        row = {"entries": size, "status": status, "returncode": process.returncode,
               "elapsed_seconds": time.monotonic() - started,
               "external_watchdog": watchdog, "log_sha256": sha256(directory / "proof.log")}
        report["runs"].append(row)
        print(json.dumps(row), flush=True)
    (output / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    if any(row["status"] == "failed" for row in report["runs"]):
        return 1
    return 0 if any(row["status"] == "proven" for row in report["runs"]) else 2


if __name__ == "__main__":
    raise SystemExit(main())
