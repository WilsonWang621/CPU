#!/usr/bin/env python3
"""Prove the current core's narrowed ages/counters against integer arithmetic."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
CAPACITIES = [4, 6, 16, 30, 32, 33, 64, 127, 128]


def extract(pattern, source):
    match = re.search(pattern, source, re.DOTALL)
    if not match:
        raise RuntimeError("Core formula changed; update the proof extractor explicitly: " + pattern)
    return match.group(0)


def harness(core):
    distance = extract(r"function automatic logic \[RW:0\] distance\(.*?endfunction", core)
    killed = extract(r"function automatic logic killed\(.*?endfunction", core)
    csb = extract(r"assign csb_age\[row\]=.*?;", core)
    sq_width = extract(r"localparam integer SQW=.*?;", core)
    for declaration in ("logic [SQW-1:0] sq_count_q,sq_count_d;",
                        "logic [CSW:0] csb_count_q,csb_count_d;"):
        if declaration not in core:
            raise RuntimeError("Core counter declaration changed: " + declaration)
    return r'''module age_equivalence #(parameter integer N=4) (
  input logic [7:0] r_raw,h_raw,
  input logic [8:0] recovery_raw,sq_raw,csb_raw,
  input logic recovery_keep,recovering,
  output logic equivalent
);
  localparam integer ROB_ENTRIES=N,CSB_ENTRIES=N,SQ_ENTRIES=N;
  localparam integer RW=$clog2(ROB_ENTRIES);
  localparam integer CSW=(CSB_ENTRIES>1 ? $clog2(CSB_ENTRIES):1);
''' + sq_width + r'''
  typedef logic [RW-1:0] rid_t;
  rid_t r,h,recovery_tail;
  logic [CSW-1:0] csb_head_q,next_head;
  logic [RW:0] recovery_age,cutoff,selection_sentinel;
  logic [CSW:0] csb_age [CSB_ENTRIES];
  logic [SQW-1:0] sq_count_q,sq_count_d,sq_increment,sq_decrement;
  logic [CSW:0] csb_count_q,csb_count_d,csb_increment,csb_decrement;
  integer original_delta,original_age;
''' + distance + "\n" + killed + r'''
  for(genvar row=0;row<CSB_ENTRIES;row=row+1) begin: csb_ages
''' + csb + r'''
  end
  always_comb begin
    r=rid_t'(r_raw);h=rid_t'(h_raw);csb_head_q=CSW'(h_raw);
    original_delta=int'(r_raw)-int'(h_raw);
    original_age=original_delta<0 ? original_delta+ROB_ENTRIES:original_delta;
    recovery_age=(RW+1)'(recovery_raw);
    cutoff=recovery_age+(RW+1)'(recovery_keep);
    selection_sentinel=(RW+1)'(ROB_ENTRIES+1);
    next_head=CSW'((int'(csb_head_q)+1)%CSB_ENTRIES);
    recovery_tail=rid_t'((int'(r)+int'(recovery_keep))%ROB_ENTRIES);
    sq_count_q=SQW'(sq_raw);sq_count_d=sq_count_q;
    sq_increment=sq_count_d+1;sq_decrement=sq_count_d-1;
    csb_count_q=(CSW+1)'(csb_raw);csb_count_d=csb_count_q;
    csb_increment=csb_count_d+1;csb_decrement=csb_count_d-1;
    equivalent=int'(selection_sentinel)==ROB_ENTRIES+1;
    if(r_raw<ROB_ENTRIES && h_raw<ROB_ENTRIES) begin
      if(int'(distance(r,h))!=original_age) equivalent=0;
      if(int'(recovery_tail)!=(int'(r_raw)+int'(recovery_keep))%ROB_ENTRIES) equivalent=0;
      if(recovery_raw<=ROB_ENTRIES) begin
        if(int'(cutoff)!=int'(recovery_raw)+int'(recovery_keep)) equivalent=0;
        if(killed(r,h,recovering,cutoff) !=
          (recovering && original_age>=int'(recovery_raw)+int'(recovery_keep))) equivalent=0;
      end
    end
    if(h_raw<CSB_ENTRIES) begin
      if(int'(next_head)!=(int'(h_raw)+1)%CSB_ENTRIES) equivalent=0;
      for(integer row=0;row<CSB_ENTRIES;row=row+1)
        if(int'(csb_age[row])!=(row>=int'(h_raw) ? row-int'(h_raw):row+CSB_ENTRIES-int'(h_raw))) equivalent=0;
    end
    if(sq_raw<=SQ_ENTRIES) begin
      if(int'(sq_count_q)!=int'(sq_raw)) equivalent=0;
      if(sq_raw<SQ_ENTRIES && int'(sq_increment)!=int'(sq_raw)+1) equivalent=0;
      if(sq_raw>0 && int'(sq_decrement)!=int'(sq_raw)-1) equivalent=0;
      if(sq_raw==0 && int'(sq_decrement)<=SQ_ENTRIES) equivalent=0;
      if(sq_raw==SQ_ENTRIES && int'(sq_increment)<=SQ_ENTRIES) equivalent=0;
    end
    if(csb_raw<=CSB_ENTRIES) begin
      if(int'(csb_count_q)!=int'(csb_raw)) equivalent=0;
      if(csb_raw<CSB_ENTRIES && int'(csb_increment)!=int'(csb_raw)+1) equivalent=0;
      if(csb_raw>0 && int'(csb_decrement)!=int'(csb_raw)-1) equivalent=0;
      if(csb_raw==0 && int'(csb_decrement)<=CSB_ENTRIES) equivalent=0;
      if(csb_raw==CSB_ENTRIES && int'(csb_increment)<=CSB_ENTRIES) equivalent=0;
    end
  end
endmodule
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--core", type=Path, default=ROOT / "rtl/core.sv")
    parser.add_argument("--yosys", type=Path, default=ROOT / "build/tools/oss-cad-suite/bin/yosys")
    parser.add_argument("--output", type=Path, default=ROOT / "build/age-equivalence")
    parser.add_argument("--capacities", nargs="+", type=int, default=CAPACITIES)
    args = parser.parse_args()
    if any(n < 4 or n > 128 for n in args.capacities):
        parser.error("capacities must be in the core's supported range 4..128")
    core = args.core.read_text()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    source = output / "age_equivalence.sv"
    source.write_text(harness(core))
    (output / "core-source.sv").write_text(core)
    env = dict(os.environ)
    env.pop("YOSYS_DATDIR", None)
    yosys = args.yosys.resolve()
    report = {
        "core_sha256": hashlib.sha256(core.encode()).hexdigest(),
        "proof_source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "yosys_version": subprocess.check_output([str(yosys), "-V"], text=True, env=env).strip(),
        "scope": "All valid positions, recovery ages through capacity inclusive, both keep/recovering values, and all legal queue-count increments/decrements.",
        "formula_source": "distance(), killed(), and static CSB age assignment extracted verbatim from core.sv; counters checked against the current declarations.",
        "runs": [],
    }
    for capacity in args.capacities:
        directory = output / f"n{capacity}"
        directory.mkdir(exist_ok=True)
        script = directory / "prove.ys"
        script.write_text(f'read_slang --top age_equivalence -G N={capacity} {source.name}\n'
                          "opt -full\nwreduce\nopt -full\n"
                          "sat -verify -prove equivalent 1 -show-inputs -show-outputs -timeout 30\n")
        started = time.monotonic()
        with (directory / "proof.log").open("w") as log:
            result = subprocess.run([str(yosys), "-Q", "-T", "-s", str(script)],
                                    env=env, cwd=output, stdout=log, stderr=subprocess.STDOUT, timeout=45)
        contents = (directory / "proof.log").read_text()
        passed = result.returncode == 0 and "SUCCESS!" in contents
        row = {"capacity": capacity, "status": "proven" if passed else "failed",
               "returncode": result.returncode, "elapsed_seconds": time.monotonic() - started,
               "position_pairs": capacity * capacity,
               "log_sha256": hashlib.sha256(contents.encode()).hexdigest()}
        report["runs"].append(row)
        print(json.dumps(row), flush=True)
    (output / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    return int(any(row["status"] != "proven" for row in report["runs"]))


if __name__ == "__main__":
    raise SystemExit(main())
