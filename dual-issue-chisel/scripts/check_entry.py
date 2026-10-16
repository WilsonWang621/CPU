#!/usr/bin/env python3
"""Build and validate the course's default filelist, without FILELIST overrides."""
import argparse
import json

from check_parameters import PROJECT, ROOT, command, sha, sources
from audit_requirements import correctness, performance


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reuse-build", action="store_true", help="Use the just-completed external make build and its log")
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    out = PROJECT / "build/requirements-entry"
    out.mkdir(parents=True, exist_ok=True)
    filelist = ROOT / "verilog/filelist.f"
    entries = [line.split("#", 1)[0].strip() for line in filelist.read_text().splitlines()]
    entries = [line for line in entries if line]
    assert len(entries) == 1 and (filelist.parent / entries[0]).resolve() == PROJECT / "rtl/student_top.sv"
    before = sources()
    build_log = PROJECT / "build/requirements-entry-build.log"
    if not args.reuse_build:
        command(["make", "build", f"BUILD={out / 'sim'}", f"JOBS={args.jobs}"], build_log)
    binary = out / "sim/sim"
    assert binary.is_file() and '"verilog/filelist.f"' in build_log.read_text()
    receipt = {"rtl_sha256": sha(PROJECT / "rtl/student_top.sv"), "sim_sha256": sha(binary),
               "filelist_sha256": sha(filelist), "source_sha256": before, "build_log_sha256": sha(build_log)}
    (out / "build-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    for target, latency, filename in [("test", 10, "correctness-lat10.log"),
                                      ("perf", 10, "perf-lat10.log"), ("perf", 20, "perf-lat20.log")]:
        print("Default course entry: " + filename, flush=True)
        command(["make", target, f"SIM={binary}", f"LATENCY={latency}", "MAX_CYCLES=20000000"], out / filename)
        if target == "test":
            correctness(out / filename)
        else:
            performance(out / filename)
    assert before == sources() and receipt["sim_sha256"] == sha(binary)
    print("Default course entry: complete correctness and performance PASS", flush=True)


if __name__ == "__main__":
    main()
