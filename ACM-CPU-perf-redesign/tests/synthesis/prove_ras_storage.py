#!/usr/bin/env python3
"""Prove the RAS storage invariant and equivalent final FQ write selection."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/ras-storage-proof")
    parser.add_argument("--yosys", type=Path, default=ROOT / "build/tools/oss-cad-suite/bin/yosys")
    parser.add_argument("--depths", nargs="+", type=int, default=[0, 1, 4, 8, 16])
    parser.add_argument("--timeout", type=int, default=20)
    args = parser.parse_args()
    if any(depth < 0 or depth > 16 for depth in args.depths) or args.timeout <= 0:
        parser.error("RAS depths must be 0..16 and timeout must be positive")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    sources = {name: ROOT / "rtl" / name for name in ("branch_predictor.sv", "frontend.sv", "core.sv")}
    contents = {name: path.read_text() for name, path in sources.items()}
    required = {
        "branch_predictor.sv": ["ras_q<=ras_next&RAS_MASK;"],
        "frontend.sv": ["value.ras=packet.ras&RAS_MASK;", "value.ras_snapshot=packet.ras_snapshot&RAS_MASK;",
                        "queue_q[row]<=bounded_fetch(selected);"],
        "core.sv": ["ras_q[k]<=ras_d[k]&RAS_MASK;"],
    }
    for name, source in contents.items():
        compact = re.sub(r"\s+", "", source)
        for text in required[name] + ["RAS_MASK={512{1'b1}}>>(512-32*RAS_DEPTH);"]:
            if text not in compact:
                raise RuntimeError(f"RAS boundary changed in {name}; review/update proof binding: {text}")
        (output / name).write_text(source)
    pattern = r"  function automatic logic \[516:0\] update_ras\(.*?  endfunction"
    update = re.search(pattern, contents["branch_predictor.sv"], re.DOTALL)
    if not update:
        raise RuntimeError("update_ras changed; review its proof extraction")
    template = ROOT / "tests/synthesis/ras_storage_induction.sv"
    proof, count = re.subn(pattern, lambda _: update[0], template.read_text(), flags=re.DOTALL)
    if count != 1:
        raise RuntimeError("Expected one update_ras function in the proof template")
    proof_file = output / "ras_storage_induction.sv"
    proof_file.write_text(proof)
    fq_source = ROOT / "tests/synthesis/fq_write_equivalence.sv"
    (output / fq_source.name).write_bytes(fq_source.read_bytes())
    yosys = args.yosys.resolve()
    env = dict(os.environ)
    env.pop("YOSYS_DATDIR", None)
    report = {
        "sources_sha256": {"rtl/" + name: hashlib.sha256(text.encode()).hexdigest() for name, text in contents.items()},
        "runner_sha256": digest(Path(__file__)),
        "proof_source_sha256": digest(proof_file),
        "fq_proof_source_sha256": digest(fq_source),
        "yosys_version": subprocess.check_output([str(yosys), "-V"], text=True, env=env).strip(),
        "proof_method": "Reset base case and one-step inductive preservation of zero unused RAS bits across predictor, request, valid FQ and core snapshots; prove each added mask leaves next state unchanged. Independent source/destination payloads quantify arbitrary storage indices and reuse.",
        "protocol_assumption": "Core checkpoint writes read a currently valid FQ entry, as enforced by fetch_valid in rename. Invalid unreset FQ payloads are unconstrained. All other enables, invalidations, stack updates, counts and redirect payloads are arbitrary.",
        "implementation_binding": "update_ras extracted verbatim; check the four register/data mask sites and mask constant. Typed helpers preserve non-RAS fields. FQ selector proof allows arbitrary simultaneous lane writes and arbitrary full-word mask.",
        "scope_limit": "Projection onto RAS payloads and FQ write selection; complete pipeline behavior is separately checked by cycle-equivalence simulation and CPU regressions.",
        "runs": [],
    }
    jobs = [(f"depth{depth}", "ras_storage_induction", proof_file.name, f"-G RAS_DEPTH={depth}")
            for depth in args.depths]
    jobs.append(("fq-write", "fq_write_equivalence", fq_source.name, ""))
    for name, top, filename, parameters in jobs:
        script = output / f"{name}.ys"
        script.write_text(f"read_slang --top {top} {parameters} {filename}\n"
                          "opt -full\nwreduce\nopt -full\n"
                          f"sat -verify -prove equivalent 1 -show-inputs -show-outputs -timeout {args.timeout}\n")
        started = time.monotonic()
        log_file = output / f"{name}.log"
        with log_file.open("w") as log:
            process = subprocess.Popen([str(yosys), "-Q", "-T", "-s", str(script)], cwd=output,
                                       stdout=log, stderr=subprocess.STDOUT, env=env, start_new_session=True)
            try:
                status = process.wait(timeout=args.timeout + 15)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait()
                status = 124
        log = log_file.read_text()
        passed = status == 0 and "SUCCESS!" in log
        timed_out = status == 124 or "proof did time out" in log
        row = {"case": name, "status": "proven" if passed else "timeout" if timed_out else "failed",
               "returncode": status, "elapsed_seconds": time.monotonic() - started, "log_sha256": digest(log_file)}
        report["runs"].append(row)
        (output / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(row), flush=True)
    return int(any(row["status"] != "proven" for row in report["runs"]))


if __name__ == "__main__":
    raise SystemExit(main())
