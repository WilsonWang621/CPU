#!/usr/bin/env python3
"""Run existing RTL scoreboards against the native Chisel modules.

Only fixed module parameters and observation paths change: CIRCT scalarizes
unpacked registers, so read-only observation arrays reconstruct their names.
The stimulus, reference arithmetic, architectural model and checks are kept.
"""
from pathlib import Path
import hashlib
import json
import re
import subprocess

PROJECT = Path(__file__).resolve().parents[1]
ROOT = PROJECT.parent

def without_parameters(text, module):
    text, count = re.subn(r"\b" + module + r"\s*#\(.*?\)\s+dut", module + " dut", text, count=1, flags=re.S)
    assert count == 1
    return text

def rename_bench(text):
    text = without_parameters(text, "v2_rename")
    obs = ["wire [31:0] observed_pending;", "wire [4:0] observed_tag[0:31];",
           "wire [31:0] observed_cp_pending[0:3];", "wire [4:0] observed_cp_tag[0:127];"]
    for r in range(32):
        obs += [f"assign observed_pending[{r}]=" + ("1'b0" if r == 0 else f"dut.pending_q_{r}") + ";",
                f"assign observed_tag[{r}]=dut.tag_q_{r};"]
        for c in range(4):
            obs += [f"assign observed_cp_pending[{c}][{r}]=" + ("1'b0" if r == 0 else f"dut.checkpoint_pending_{c}_{r}") + ";",
                    f"assign observed_cp_tag[{c*32+r}]=dut.checkpoint_tag_{c}_{r};"]
    for a, b in {"dut.pending_q[r]": "observed_pending[r]", "dut.tag_q[r]": "observed_tag[r]",
                 "dut.checkpoint_pending[c][r]": "observed_cp_pending[c][r]",
                 "dut.checkpoint_tag[c*32+r]": "observed_cp_tag[c*32+r]"}.items():
        text = text.replace(a, b)
    return text.replace("  // Architectural mapping model:", "\n".join(obs) + "\n  // Architectural mapping model:")

def frontend_bench(text):
    text = without_parameters(text, "v2_frontend")
    return text.replace("dut.bht_valid=16'hffff;\n      for(p=0;p<16;p=p+1) dut.bht[p]=3;",
                        "\n".join(f"dut.bht_valid_{r}=1; dut.bht_{r}=3;" for r in range(16)))

def return_bench(text):
    text = without_parameters(text, "v2_dcache")
    obs = ["wire [8:0] observed_waiters[0:7];", "wire [3:0] observed_words[0:31];"]
    for w in range(8):
        fields = ",".join(f"dut.waiters_{w}_{field}" for field in ("valid", "error", "physical", "word_index"))
        obs += [f"assign observed_waiters[{w}]={{" + fields + "};"]
    for line in range(32):
        obs += [f"assign observed_words[{line}]={{" + ",".join(f"dut.word_valid_{line}_{w}" for w in reversed(range(4))) + "};"]
    text = text.replace("dut.waiters[r]", "observed_waiters[r]").replace("dut.word_valid[physical]", "observed_words[physical]")
    for name, offset in {"PHYSICAL": 2, "WORD_INDEX": 0, "VALID": 8, "ERROR": 7}.items():
        text = text.replace("dut.WAITER_T_" + name + "_LSB", str(offset))
    return text.replace("  reg [31:0] responses", "\n".join(obs) + "\n  reg [31:0] responses")

def main():
    out = PROJECT / "build/unit-results"
    out.mkdir(parents=True, exist_ok=True)
    cases = [
        ("mdu", "muldiv", "pararisc_mdu_tb", "pararisc_mdu_tb.sv", lambda s: s),
        ("mdu-stream", "muldiv", "v2_mdu_stream_tb", "v2_mdu_stream_tb.sv", lambda s: s),
        ("rename", "rename4", "v2_rename_prepare_tb", "v2_rename_prepare_tb.sv", rename_bench),
        ("frontend", "frontend-unit", "v2_frontend_prepare_tb", "v2_frontend_prepare_tb.sv", frontend_bench),
        ("frontend-targets", "frontend-unit", "v2_frontend_target_tb", "v2_frontend_prepare_tb.sv", frontend_bench),
        ("dcache-write", "dcache-write", "v2_dcache_write_tb", "v2_dcache_write_tb.sv",
         lambda s: without_parameters(s, "v2_dcache").replace("CACHE_BYTES=512", "CACHE_BYTES=2048")),
        ("dcache-return", "dcache-return", "v2_dcache_return_tb", "v2_dcache_return_tb.sv", return_bench),
    ]
    results = []
    sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    for name, directory, top, bench_name, adapt in cases:
        rtl = sorted((PROJECT / "build" / directory).glob("*.sv"))
        rtl = [p for p in rtl if not p.name.endswith("bench.sv") and p.name not in ("bench.sv", "adapted-bench.sv")]
        assert len(rtl) == 1, f"Generate {directory} first"
        original = ROOT / "tests/rtl" / bench_name
        bench = out / f"{name}.sv"
        bench.write_text(adapt(original.read_text()))
        binary = out / name
        with (out / f"{name}-compile.log").open("w") as f:
            subprocess.run(["iverilog", "-g2012", "-s", top, "-o", str(binary), str(bench), str(rtl[0])],
                           stdout=f, stderr=subprocess.STDOUT, check=True)
        log = out / f"{name}.log"
        with log.open("w") as f:
            subprocess.run(["vvp", str(binary)], stdout=f, stderr=subprocess.STDOUT, check=True)
        assert "PASS" in log.read_text(), f"No PASS marker for {name}"
        results.append({"case": name, "status": "passed", "testbench_sha256": sha(original),
                        "adapted_testbench_sha256": sha(bench), "generated_rtl_sha256": sha(rtl[0]), "log_sha256": sha(log)})
        print(log.read_text().strip(), flush=True)
    (out / "results.json").write_text(json.dumps(results, indent=2) + "\n")

if __name__ == "__main__":
    main()
