#!/usr/bin/env python3
"""Prove the core's fixed-entry RAT reconstruction against chronological replay."""
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


def extract(pattern, source):
    match = re.search(pattern, source, re.DOTALL)
    if not match:
        raise RuntimeError("RAT reconstruction changed; update the proof extractor explicitly: " + pattern)
    return match.group(1)


def harness(core):
    distance = extract(r"(function automatic logic \[RW:0\] distance\(.*?endfunction)", core)
    survivor = extract(r"(assign recovery_survivor\[row\]=.*?;)", core)
    body = extract(r"begin: nonzero_register\s+always_comb begin\n(.*?)\n      end\n    end\n  end", core)
    if "assign recovery_map[arch]='0;" not in core:
        raise RuntimeError("The x0 mapping changed; update its proof explicitly")
    body = body.replace("recovery_map[arch]", "reconstructed").replace("rrat_q[arch]", "committed")
    return r'''// Generated from the actual core formulas by prove_rat_reconstruction.py.
// Mapping each architectural register is independent, so one arbitrary 5-bit
// register index quantifies all 32 without duplicating the SAT search.
module rat_reconstruction_equivalence #(
  parameter integer ROB_ENTRIES=4, PW=7, RW=$clog2(ROB_ENTRIES)
)(
  input logic [RW-1:0] head_q,
  input logic [RW:0] recovery_age,
  input logic recovery_keep,redirect,
  input logic [4:0] arch,
  input logic [ROB_ENTRIES-1:0] valid_raw,writes_raw,
  input logic [ROB_ENTRIES*5-1:0] rd_raw,
  input logic [ROB_ENTRIES*PW-1:0] pdst_raw,
  input logic [PW-1:0] committed,
  output logic equivalent
);
  typedef logic [RW-1:0] rid_t;
  typedef logic [PW-1:0] preg_t;
  logic [ROB_ENTRIES-1:0] rob_col_valid,rob_col_dec_writes_rd,recovery_survivor;
  logic [4:0] rob_col_dec_rd [ROB_ENTRIES];
  preg_t rob_col_pdst [ROB_ENTRIES];
  logic [RW:0] rob_age [ROB_ENTRIES];
  preg_t reconstructed,chronological;
  integer index,cutoff;
''' + distance + r'''
  assign rob_col_valid=valid_raw;
  assign rob_col_dec_writes_rd=writes_raw;
  for(genvar row=0;row<ROB_ENTRIES;row=row+1) begin: columns
    assign rob_col_dec_rd[row]=rd_raw[row*5+:5];
    assign rob_col_pdst[row]=pdst_raw[row*PW+:PW];
    assign rob_age[row]=distance(rid_t'(row),head_q);
''' + survivor + r'''
  end
  always_comb begin
''' + body + r'''
    if(arch==0) reconstructed='0;
  end
  // The reference advances a circular pointer in chronological order. It does
  // not use the two physical segments or the core's circular-age function.
  always_comb begin
    chronological=arch==0 ? preg_t'(0):committed;
    index=int'(head_q);cutoff=int'(recovery_age)+int'(recovery_keep);
    for(integer age=0;age<ROB_ENTRIES;age=age+1) begin
      if(redirect && arch!=0 && age<cutoff && valid_raw[index] && writes_raw[index] &&
         rd_raw[index*5+:5]==arch) chronological=pdst_raw[index*PW+:PW];
      index=index==ROB_ENTRIES-1 ? 0:index+1;
    end
    equivalent=1;
    if(int'(head_q)<ROB_ENTRIES && cutoff<=ROB_ENTRIES)
      equivalent=reconstructed==chronological;
  end
endmodule
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--core", type=Path, default=ROOT / "rtl/core.sv")
    parser.add_argument("--yosys", type=Path, default=ROOT / "build/tools/oss-cad-suite/bin/yosys")
    parser.add_argument("--output", type=Path, default=ROOT / "build/rat-reconstruction-proof")
    parser.add_argument("--capacities", nargs="+", type=int, default=[4, 5, 8, 9])
    parser.add_argument("--timeout", type=int, default=30)
    args = parser.parse_args()
    if any(n < 4 or n > 128 for n in args.capacities) or args.timeout <= 0:
        parser.error("capacities must be 4..128 and timeout must be positive")
    core = args.core.read_text()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    source = output / "rat_reconstruction_equivalence.sv"
    source.write_text(harness(core))
    (output / "core-source.sv").write_text(core)
    env = dict(os.environ)
    env.pop("YOSYS_DATDIR", None)
    yosys = args.yosys.resolve()
    report = {
        "core_sha256": hashlib.sha256(core.encode()).hexdigest(),
        "proof_source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "runner_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "yosys_version": subprocess.check_output([str(yosys), "-V"], env=env, text=True).strip(),
        "physical_register_bits": 7,
        "scope": "Every architectural register, valid head, surviving-prefix length, keep/redirect flag, and arbitrary committed map, valid holes, WAWs and physical destinations.",
        "formula_source": "distance(), recovery_survivor assignment and nonzero-register reconstruction body extracted from core.sv; only per-register signal names substituted.",
        "reference": "Independent chronological circular pointer scan, with x0 fixed to physical zero.",
        "limitation": "Combinational recovery equivalence; full CPU state/occupancy invariants remain the responsibility of monitored regressions.",
        "runs": [],
    }
    for capacity in args.capacities:
        directory = output / f"n{capacity}"
        directory.mkdir(exist_ok=True)
        script = directory / "prove.ys"
        script.write_text(f"read_slang --top rat_reconstruction_equivalence -G ROB_ENTRIES={capacity} {source.name}\n"
                          "opt -full\nwreduce\nopt -full\n"
                          f"sat -verify -prove equivalent 1 -show-inputs -show-outputs -timeout {args.timeout}\n")
        started = time.monotonic()
        with (directory / "proof.log").open("w") as log:
            process = subprocess.Popen([str(yosys), "-Q", "-T", "-s", str(script)],
                                       env=env, cwd=output, stdout=log, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            try:
                status = process.wait(timeout=args.timeout + 15)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait()
                status = 124
        contents = (directory / "proof.log").read_text()
        passed = status == 0 and "SUCCESS!" in contents
        timed_out = status == 124 or "proof did time out" in contents
        row = {"capacity": capacity, "status": "proven" if passed else "timeout" if timed_out else "failed",
               "returncode": status, "elapsed_seconds": time.monotonic() - started,
               "log_sha256": hashlib.sha256(contents.encode()).hexdigest()}
        report["runs"].append(row)
        (output / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(row), flush=True)
    return int(any(row["status"] != "proven" for row in report["runs"]))


if __name__ == "__main__":
    raise SystemExit(main())
