#!/usr/bin/env python3
"""Prove the actual core stable-oldest macro against its original serial minimum.

The source macro is copied verbatim, including its signed integer return and
zero-valid shortcut. No eligibility assumptions are made: all age/valid input
combinations are checked, including out-of-range ages and ties. Exit 2 denotes
bounded timeout (unknown), 1 a failed proof, and 0 complete proof coverage.
"""
import argparse
import hashlib
import json
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CASES = [(1, 1, 1)] + [
    (n, 6, limit) for n in (1, 4, 5, 21, 24, 68) for limit in (32, 33)
] + [(132, 7, limit) for limit in (64, 65)]


def extract_macro(source):
    text = source.read_text()
    start = text.index("`define CPU_OLDEST_FUNCTION(")
    end = text.index("  endfunction", start) + len("  endfunction")
    return text[start:end] + "\n"


def wrapper(macro):
    return '''module actual_argmin_equivalence #(
  parameter integer N=21, RW=5, LIMIT=33
)(input logic [N-1:0] valid, input logic [N*(RW+1)-1:0] ages,
  output wire ok, output wire signed [31:0] tree_index,
  output logic signed [31:0] serial_index);
'''+macro+'''
  `CPU_OLDEST_FUNCTION(actual_oldest,N,LIMIT)
  `undef CPU_OLDEST_FUNCTION
  logic [RW:0] serial_age;
  always_comb begin
    serial_index=-1;serial_age=(RW+1)'(LIMIT);
    for(integer k=0;k<N;k=k+1)
      if(valid[k] && ages[k*(RW+1)+:RW+1]<serial_age) begin
        serial_index=k;serial_age=ages[k*(RW+1)+:RW+1];
      end
  end
  assign tree_index=actual_oldest(valid,ages);
  assign ok=tree_index==serial_index;
endmodule
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=ROOT / "rtl/core.sv")
    parser.add_argument("--output", type=Path, default=ROOT / "build/oldest-selection-proof")
    parser.add_argument("--yosys", type=Path, default=ROOT / "build/tools/oss-cad-suite/bin/yosys")
    parser.add_argument("--timeout", type=float, default=60)
    parser.add_argument("--case", action="append", default=[], metavar="N:AGE_WIDTH:LIMIT")
    args = parser.parse_args()
    cases = [tuple(map(int, item.split(":"))) for item in args.case] or DEFAULT_CASES
    if any(len(c) != 3 or c[0] < 1 or c[1] < 1 or not 0 <= c[2] < (1 << c[1]) for c in cases):
        parser.error("Each case needs positive N/AGE_WIDTH and an unsigned representable LIMIT")
    if args.timeout <= 0:
        parser.error("Timeout must be positive")
    source, out, yosys = args.source.resolve(), args.output.resolve(), args.yosys.resolve()
    out.mkdir(parents=True, exist_ok=True)
    macro = extract_macro(source)
    emitted = wrapper(macro)
    (out / "actual_macro.svh").write_text(macro)
    (out / "actual_argmin_equivalence.sv").write_text(emitted)
    report = {
        "scope": "Exact actual macro signed integer result versus strict serial argmin, for all valid/age inputs",
        "source": str(source),
        "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "macro_sha256": hashlib.sha256(macro.encode()).hexdigest(),
        "wrapper_sha256": hashlib.sha256(emitted.encode()).hexdigest(),
        "yosys": subprocess.check_output([str(yosys), "-V"], text=True).strip(),
        "results": [],
    }
    def save():
        (out / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    save()
    for n, width, limit in cases:
        name = f"n{n}-age{width}-limit{limit}"
        script = (
            "read_verilog -sv actual_argmin_equivalence.sv\n"
            f"chparam -set N {n} -set RW {width-1} -set LIMIT {limit} actual_argmin_equivalence\n"
            "prep -top actual_argmin_equivalence\nflatten\n"
            "sat -verify -prove ok 1 -show-inputs -show-outputs\n"
        )
        (out / f"{name}.ys").write_text(script)
        start = time.monotonic()
        try:
            with (out / f"{name}.log").open("w") as log:
                result = subprocess.run([str(yosys), "-TQ", "-s", name + ".ys"],
                    cwd=out, stdout=log, stderr=subprocess.STDOUT, timeout=args.timeout)
            log_text = (out / f"{name}.log").read_text()
            status = "pass" if result.returncode == 0 and "SUCCESS!" in log_text else "fail"
            code = result.returncode
        except subprocess.TimeoutExpired:
            status, code = "timeout", None
        row = {"candidates": n, "age_width": width, "limit": limit,
               "seconds": time.monotonic() - start, "timeout_seconds": args.timeout,
               "status": status, "returncode": code, "log": name + ".log"}
        report["results"].append(row)
        save()
        print(json.dumps(row), flush=True)
        if status == "fail":
            return 1
    return 2 if any(row["status"] == "timeout" for row in report["results"]) else 0


if __name__ == "__main__":
    raise SystemExit(main())
