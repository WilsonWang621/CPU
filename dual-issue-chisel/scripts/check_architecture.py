#!/usr/bin/env python3
"""Observe issue and retirement inside the production core, using course AXI simulation."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import re

from check_parameters import PROJECT, ROOT, command, sha, sources

PROBES = {"default": [], "width1": ["--issue-width", "1"],
          "width2": ["--issue-width", "2"], "int1": ["--integer-ports", "1", "--prf", "8"]}


def check(name, jobs):
    out = PROJECT / "build" / ("probe-" + name)
    rtl = out / "student_top.sv"
    assert rtl.exists(), "Generate architecture-probe " + name + " first"
    (out / "filelist.f").write_text("student_top.sv\n")
    receipt = out / "build-receipt.json"
    binary = out / "sim/sim"
    prior = json.loads(receipt.read_text()) if receipt.exists() else {}
    if not binary.exists() or prior.get("rtl_sha256") != sha(rtl) or prior.get("sim_sha256") != sha(binary):
        print(name + ": building architecture probe", flush=True)
        command(["make", "build", f"FILELIST={out / 'filelist.f'}", f"BUILD={out / 'sim'}", f"JOBS={jobs}"], out / "build.log")
        receipt.write_text(json.dumps({"rtl_sha256": sha(rtl), "sim_sha256": sha(binary)}, indent=2) + "\n")
    runs = {}
    width = json.loads((out / "elaboration.json").read_text())["config"]["issueWidth"]
    for latency in [10, 40]:
        log = out / f"run-lat{latency}.log"
        command(["make", "run", f"SIM={binary}",
                 f"PROGRAM={PROJECT / 'build/requirements-programs/out-of-order.data'}",
                 "EXPECTED=0x20031", f"LATENCY={latency}"], log)
        match = re.search(r"Architecture probe: PASS ooo=1 max_issue=(\d+) retired_bytes=\s*48", log.read_text())
        assert match and int(match[1]) == width, log.read_text()
        assert "PASS cycles=" in log.read_text()
        runs[str(latency)] = {"ooo": True, "maximum_issue": width, "retired_in_order": 12, "log_sha256": sha(log)}
    result = {"profile": name, "arguments": PROBES[name], "source_sha256": sources(),
              "rtl_sha256": sha(rtl), "sim_sha256": sha(binary),
              "config": json.loads((out / "elaboration.json").read_text())["config"], "runs": runs}
    (out / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(name + ": OoO, issue width and ordered retirement PASS", flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--generate", action="store_true")
    parser.add_argument("--workers", type=int, default=2)
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    if args.generate:
        commands = ["run --module architecture-probe --out build/probe-" + name + " " + " ".join(options)
                    for name, options in PROBES.items()]
        command(["sbt", "-batch", *commands], PROJECT / "build/architecture-generate.log", PROJECT)
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        results = list(pool.map(lambda n: check(n, args.jobs), PROBES))
    (PROJECT / "build/architecture-results.json").write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
