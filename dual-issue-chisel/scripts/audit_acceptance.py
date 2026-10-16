#!/usr/bin/env python3
"""Audit archived final evidence against the delivered native Chisel source/RTL.

This checks recorded results and input identities; it does not replace rerunning
the simulator, formal tools or synthesis. Run from any working directory.
"""
import argparse
import gzip
import hashlib
import json
import math
from pathlib import Path
import re

PROJECT = Path(__file__).resolve().parents[1]
ROOT = PROJECT.parent
FINAL = PROJECT / "reports/final"
INITIAL = PROJECT / "reports/initial-port"
CORRECTNESS = {
    "add_to_100", "array_test1", "array_test2", "basicopt1", "bulgarian",
    "expr", "gcd", "hanoi", "lvalue2", "magic", "manyarguments", "multiarray",
    "naive", "pi", "qsort", "queens", "statement_test", "superloop", "tak",
}
PERFORMANCE = {"median", "multiply", "qsort", "rsort", "towers", "vvadd"}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load(path):
    return json.loads(path.read_text())


def correctness(path):
    text = path.read_text()
    assert "Results: 19 passed, 0 failed" in text, f"Incomplete correctness: {path}"
    rows = re.findall(r"\[correctness_(\w+)\]\s+PASS cycles=(\d+)", text)
    assert len(rows) == 19 and {name for name, _ in rows} == CORRECTNESS
    return {name: int(cycles) for name, cycles in rows}


def perf(path):
    text = path.read_text()
    rows = re.findall(r"^perf_(\w+)\s+(\d+)\s+(\d+)\s+([\d.]+)\s*$", text, re.M)
    assert len(rows) == 6 and {r[0] for r in rows} == PERFORMANCE
    assert "GEOMEAN" in text
    results = {name: {"instructions": int(n), "cycles": int(c)} for name, n, c, _ in rows}
    gm = math.exp(sum(math.log(r["instructions"] / r["cycles"]) for r in results.values()) / 6)
    assert gm >= 1.0985
    return {"geomean_ipc": gm, "benchmarks": results}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="Write acceptance.json after all checks pass")
    args = parser.parse_args()
    receipt = load(FINAL / "final-input-receipt.json")
    rtl_hash = sha(PROJECT / "rtl/student_top.sv")
    assert receipt["byte_identical"] and receipt["generated_rtl_sha256"] == rtl_hash
    for name, digest in receipt["source_sha256"].items():
        assert sha(PROJECT / name) == digest, f"Source changed: {name}"
    assert receipt["source_sha256"] == {
        str(p.relative_to(PROJECT)): sha(p)
        for p in sorted((PROJECT / "src/main/scala").rglob("*.scala"))
    }
    frozen = load(PROJECT / "reports/candidates/v13/result.json")
    assert frozen["generated_rtl_sha256"] == rtl_hash
    assert frozen["source_sha256"] == receipt["source_sha256"]
    with gzip.open(FINAL / "synthesis/report.json.gz", "rt") as stream:
        synth = json.load(stream)
    assert any(row["sha256"] == rtl_hash for row in synth["inputs"])
    assert synth["abc_constraints"] == {"driving_cell": "INVx1_ASAP7_75t_R", "output_load_ff": 5.0}
    timing = synth["timing"]
    assert timing["clock_period_ns"] == 2.0
    assert timing["input_delay_ns"] == timing["output_delay_ns"] == 0.2
    assert timing["clock_uncertainty_ns"] == 0.05
    assert timing["interconnect"] == "no_parasitics"
    assert synth["libraries"] == frozen["libraries"]
    assert timing["estimated_fmax_mhz"] >= 500
    assert synth["area"]["area_um2"] <= 36000
    assert synth["area"]["sram_area_um2"] == 0
    assert timing["estimated_fmax_mhz"] == frozen["frequency_mhz"]
    assert synth["area"]["area_um2"] == frozen["area_um2"]

    manifest = load(FINAL / "differential/input-manifest.json")
    assert manifest["inputs_sha256"]["dual-issue-chisel/rtl/student_top.sv"] == rtl_hash
    reference = load(INITIAL / "v1-inputs.json")["reference_sha256"]
    for name, digest in reference.items():
        assert sha(ROOT / name) == digest == manifest["inputs_sha256"][name]
    native = correctness(FINAL / "final-correctness-lat20.log")
    assert native == correctness(FINAL / "differential/correctness-lat20.log")
    assert native == correctness(INITIAL / "differential/correctness-lat20.log")
    performance = {}
    for latency in [10, 20]:
        name = f"perf-lat{latency}.log"
        measured = perf(FINAL / ("final-" + name))
        assert measured == perf(FINAL / "differential" / name)
        assert measured == perf(INITIAL / "differential" / name)
        performance[str(latency)] = measured
    assert "PASS cycles=116 result=262400 expected=262400" in (FINAL / "final-high-address.log").read_text()
    decoder = load(FINAL / "combinational-proofs/decoder.json")
    assert decoder["chisel_rtl_sha256"] == rtl_hash
    assert decoder["status"] == "combinational-equivalent"
    for name in ["decode_class_proof", "rename_input_proof"]:
        proof = load(FINAL / f"combinational-proofs/{name}.json")
        assert proof["status"] == "combinational-proof-passed"
        assert proof["source_sha256"] == receipt["source_sha256"]
        assert proof["generated_proof_rtl_sha256"] == sha(FINAL / f"combinational-proofs/{name}.sv")
    rat = load(FINAL / "rat-equivalence/result.json")
    assert rat["native_rtl_sha256"] == rtl_hash and rat["status"] == "inductively-equivalent"
    assert rat["reference_sha256"] == reference["verilog/area_v2_core.v"]
    assert rat["state_bits"] == 764 and rat["checkpoints"] == 3
    binaries = load(FINAL / "simulator-receipt.json")
    assert binaries["native_sha256"] == receipt["native_simulator_sha256"]
    assert binaries["native_rtl_sha256"] == rtl_hash
    for name, digest in binaries["official_tools_sha256"].items():
        assert sha(ROOT / name) == digest, f"Official tool changed: {name}"
    inventory = load(FINAL / "synthesis/distribution-inventory.json")
    assert inventory["instances"] == 2016 and inventory["inverter_bits"] == 16008
    for name, digest in load(FINAL / "sha256.json").items():
        assert sha(FINAL / name) == digest, f"Archive changed: {name}"
    result = {
        "accepted": True, "candidate": "v13", "native_rtl_sha256": rtl_hash,
        "frequency_mhz": timing["estimated_fmax_mhz"],
        "area_um2": synth["area"]["area_um2"],
        "correctness": {"latency": 20, "passed": 19, "failed": 0, "cycles": native},
        "performance": performance,
        "reference_cycle_and_axi_identity": {"correctness": 19, "performance": 12, "passed": True},
        "high_address": {"cycles": 116, "result": 262400},
        "gates": {"frequency_ge_500MHz": True, "area_le_36000um2": True,
                  "ipc_ge_1_0985_both_latencies": True, "correctness_19_of_19": True,
                  "default_path_remeasurement_matches": True, "regeneration_byte_identical": True},
        "timing_scope": "Official ASAP7 RVT TT synthesis/STA, ideal clock, no interconnect parasitics",
        "equivalence_scope": "Cycle AXI regression on listed programs plus scoped component SAT/induction; no whole-CPU formal equivalence claim",
    }
    if args.write:
        (FINAL / "acceptance.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({k: result[k] for k in ["accepted", "frequency_mhz", "area_um2", "gates"]}, indent=2))


if __name__ == "__main__":
    main()
