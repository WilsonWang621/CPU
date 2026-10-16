#!/usr/bin/env python3
"""Check current delivery against the complete, archived course acceptance evidence.

This reads raw results and checks their input identities. It does not rerun
simulation or STA; reproduction commands are in the accompanying report.
"""
import argparse
import gzip
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess
import tarfile

from check_parameters import PROJECT, ROOT, PROFILES, sha, sources
from check_architecture import PROBES
from verify_default_identity import tokens

REPORT = PROJECT / "reports/requirements-2026-10-16"
VERIFIED = REPORT / "verified"


def load(path):
    return json.loads(path.read_text())


def testcase_manifest():
    return {str(p.relative_to(ROOT)): sha(p) for p in sorted((ROOT / "testcases").glob("*/*"))
            if p.is_file() and p.parent.name.startswith(("correctness_", "perf_"))}


def correctness(path):
    text = path.read_text()
    names = {p.name.removeprefix("correctness_") for p in (ROOT / "testcases").glob("correctness_*") if p.is_dir()}
    rows = re.findall(r"\[correctness_(\w+)\]\s+PASS cycles=(\d+)", text)
    assert names and len(rows) == len(names) and {n for n, _ in rows} == names, path
    assert f"Results: {len(names)} passed, 0 failed" in text, path
    return {n: int(c) for n, c in rows}


def performance(path):
    text = path.read_text()
    cases = {p.name.removeprefix("perf_"): p for p in (ROOT / "testcases").glob("perf_*") if p.is_dir()}
    rows = re.findall(r"^perf_(\w+)\s+(\d+)\s+(\d+)\s+([\d.]+)\s*$", text, re.M)
    assert cases and len(rows) == len(cases) and {r[0] for r in rows} == set(cases), path
    results = {n: {"instructions": int(i), "cycles": int(c)} for n, i, c, _ in rows}
    for name, result in results.items():
        assert result["instructions"] == load(cases[name] / "metrics.json")["dynamic_instructions"]
        assert result["cycles"] > 0
    gm = math.exp(sum(math.log(r["instructions"] / r["cycles"]) for r in results.values()) / len(cases))
    assert "GEOMEAN" in text
    return {"geomean_ipc": gm, "benchmarks": results}


def audit():
    manifest = load(VERIFIED / "sha256.json")
    assert set(manifest) == {str(p.relative_to(VERIFIED)) for p in VERIFIED.rglob("*")
                             if p.is_file() and p.name != "sha256.json"}, "Archive file list changed"
    for name, digest in manifest.items():
        assert sha(VERIFIED / name) == digest, "Archive changed: " + name
    inputs = load(VERIFIED / "inputs.json")
    assert inputs["source_sha256"] == sources(), "Regenerate and revalidate changed sources"
    assert inputs["testcases_sha256"] == testcase_manifest(), "Official tests changed"
    assert inputs["testcases_commit"] == "29f980727f7d99a1842a58f34091c7579ba3fe85"
    assert subprocess.check_output(["git", "-C", str(ROOT / "testcases"), "rev-parse", "HEAD"], text=True).strip() == inputs["testcases_commit"]
    assert not subprocess.check_output(["git", "-C", str(ROOT / "testcases"), "status", "--porcelain"], text=True).strip()
    for name, digest in inputs["project_files_sha256"].items():
        assert sha(PROJECT / name) == digest, name
    for name, digest in inputs["official_tools_sha256"].items():
        assert sha(ROOT / name) == digest, "Official evaluation file changed: " + name
    for name, digest in inputs["delivery_files_sha256"].items():
        assert sha(ROOT / name) == digest, "Delivery entry changed: " + name
    for name, digest in inputs["reports_sha256"].items():
        assert sha(REPORT / name) == digest, "Report changed: " + name
    for name, digest in inputs["programs_sha256"].items():
        assert sha(VERIFIED / "programs" / name) == digest
    isa_checks = load(VERIFIED / "programs/checks.json")
    assert len(isa_checks["failures"]) == 86 and isa_checks["rv32im_expected"] == 0x600d600d
    with tarfile.open(VERIFIED / "source.tar.gz") as archive:
        for name, digest in inputs["source_sha256"].items():
            assert hashlib.sha256(archive.extractfile(name).read()).hexdigest() == digest
    rtl = PROJECT / "rtl/student_top.sv"
    rtl_hash = sha(rtl)
    header = re.search(r"module student_top\s*\((.*?)\);", rtl.read_text(), re.S)
    assert header, "Missing official top-level module"
    ports = {}
    direction, width = None, 1
    for declaration in re.sub(r"//[^\n]*", "", header[1]).split(","):
        declaration = declaration.strip()
        kind = re.match(r"(input|output)\s+(?:\[(\d+):0\]\s*)?(\w+)$", declaration)
        if kind:
            direction, width, name = kind[1], int(kind[2]) + 1 if kind[2] else 1, kind[3]
        else:
            assert re.fullmatch(r"\w+", declaration) and direction
            name = declaration
        ports[name] = [direction, width]
    expected_ports = {n: [d, w] for d, w, names in [
        ("input", 1, "clock reset arready rvalid awready wready bvalid"),
        ("input", 32, "rdata"), ("input", 2, "rresp bresp"),
        ("output", 32, "araddr awaddr wdata"), ("output", 4, "wstrb"),
        ("output", 1, "arvalid rready awvalid wvalid bready")
    ] for n in names.split()}
    assert ports == expected_ports, "Official student_top port mismatch"
    assert rtl_hash == inputs["rtl_sha256"]
    assert gzip.decompress((VERIFIED / "default-rtl.sv.gz").read_bytes()) == rtl.read_bytes()
    entry = VERIFIED / "entry"
    filelist = ROOT / "verilog/filelist.f"
    assert filelist.read_bytes() == (entry / "filelist.f").read_bytes()
    paths = [line.split("#", 1)[0].strip() for line in filelist.read_text().splitlines()]
    paths = [p for p in paths if p]
    assert len(paths) == 1 and (filelist.parent / paths[0]).resolve() == rtl.resolve()
    entry_receipt = load(entry / "build-receipt.json")
    assert entry_receipt["rtl_sha256"] == rtl_hash and entry_receipt["filelist_sha256"] == sha(filelist)
    assert entry_receipt["source_sha256"] == inputs["source_sha256"]
    entry_build_log = gzip.decompress((entry / "build.log.gz").read_bytes())
    assert hashlib.sha256(entry_build_log).hexdigest() == entry_receipt["build_log_sha256"]
    assert '"verilog/filelist.f"' in entry_build_log.decode()
    identity = load(REPORT / "default-circuit-equivalence.json")
    baseline = gzip.decompress((REPORT / "baseline-v13.sv.gz").read_bytes())
    assert hashlib.sha256(baseline).hexdigest() == identity["old_rtl_sha256"]
    assert tokens(baseline.decode()) == tokens(rtl.read_text())
    assert identity["new_rtl_sha256"] == rtl_hash
    assert identity["normalized_sha256"] == hashlib.sha256("\n".join(tokens(rtl.read_text())).encode()).hexdigest()
    framework = load(REPORT / "framework-comparison.json")
    upstream_meta = load(REPORT / "upstream.json")
    assert framework["commit"] == upstream_meta["commit"] == inputs["official_commit"]
    for name, meta in upstream_meta["files"].items():
        assert sha(REPORT / "upstream" / name) == meta["sha256"]
    for row in framework["files"]:
        raw = (ROOT / row["path"]).read_bytes()
        blob = hashlib.sha1(f"blob {len(raw)}\0".encode() + raw).hexdigest()
        assert blob == row["local_git_blob_sha"]
        if row["path"] != "Makefile":
            assert row["identical"] and blob == row["upstream_git_blob_sha"]
        else:
            upstream = (REPORT / "upstream/Makefile").read_bytes()
            assert hashlib.sha1(f"blob {len(upstream)}\0".encode() + upstream).hexdigest() == row["upstream_git_blob_sha"]
            assert raw == upstream + b"\ninclude $(FRAMEWORK_DIR)/scripts/area_v2/targets.mk\n"
    parameters = {}
    covered = {name: set() for name in ["issueWidth", "robEntries", "prfEntries", "iqEntries", "icacheBytes", "dcacheBytes", "icacheWays", "dcacheWays"]}
    default_config = load(PROJECT / "rtl/elaboration.json")["config"]
    option_fields = {"--issue-width": "issueWidth", "--integer-ports": "integerPorts", "--rob": "robEntries",
                     "--prf": "prfEntries", "--iq": "iqEntries", "--dispatch-width": "renameWidth",
                     "--commit-width": "commitWidth", "--icache-bytes": "icacheBytes", "--dcache-bytes": "dcacheBytes",
                     "--icache-ways": "icacheWays", "--dcache-ways": "dcacheWays"}
    for name, arguments in PROFILES.items():
        out = VERIFIED / "parameters" / name
        result = load(out / "result.json")
        generation = load(out / "generation-receipt.json")
        binary = load(out / "build-receipt.json")
        assert result["source_sha256"] == generation["source_sha256"] == inputs["source_sha256"], name
        assert result["arguments"] == generation["arguments"] == arguments
        assert result["config"] == load(out / "elaboration.json")["config"]
        expected_config = dict(default_config)
        options = dict(zip(arguments[::2], arguments[1::2]))
        for option, value in options.items():
            expected_config[option_fields[option]] = int(value)
        if "--integer-ports" in options and "--issue-width" not in options:
            expected_config["issueWidth"] = int(options["--integer-ports"]) + 1
        assert result["config"] == expected_config, "Wrong parameter configuration: " + name
        for field in covered:
            covered[field].add(result["config"][field])
        assert generation["elaboration_sha256"] == sha(out / "elaboration.json")
        assert result["rtl_sha256"] == generation["rtl_sha256"] == binary["rtl_sha256"]
        assert result["sim_sha256"] == binary["sim_sha256"]
        assert correctness(out / "correctness-lat20.log") == result["correctness_lat20"]
        for program, expected in [("rv32im", 0x600d600d), ("upper-memory", 0x0fffffc0)]:
            assert re.search(rf"PASS cycles=\d+ result={expected} expected={expected}", (out / (program + ".log")).read_text())
        measured = {str(latency): performance(out / f"perf-lat{latency}.log")
                    for latency in [10, 20] if (out / f"perf-lat{latency}.log").exists()}
        assert measured == result["performance_by_latency"]
        assert measured["10"]["geomean_ipc"] == result["geomean_ipc"]
        for log, digest in result["logs_sha256"].items():
            assert sha(out / log) == digest
        parameters[name] = {"ipc_lat10": measured["10"]["geomean_ipc"], "correctness": len(result["correctness_lat20"])}
    default = VERIFIED / "parameters/default"
    default_result = load(default / "result.json")
    assert default_result["rtl_sha256"] == rtl_hash
    assert default_result["config"] == load(PROJECT / "rtl/elaboration.json")["config"]
    correctness(default / "correctness-lat10.log")
    assert correctness(entry / "correctness-lat10.log") == correctness(default / "correctness-lat10.log")
    assert set(default_result["performance_by_latency"]) == {"10", "20"}
    assert min(r["geomean_ipc"] for r in default_result["performance_by_latency"].values()) >= 1.0985
    for latency in [10, 20]:
        assert performance(entry / f"perf-lat{latency}.log") == default_result["performance_by_latency"][str(latency)]
    with gzip.open(VERIFIED / "synthesis/report.json.gz", "rt") as stream:
        synthesis = json.load(stream)
    assert any(p["sha256"] == rtl_hash for p in synthesis["inputs"])
    assert synthesis["abc_constraints"] == {"driving_cell": "INVx1_ASAP7_75t_R", "output_load_ff": 5.0}
    timing, area = synthesis["timing"], synthesis["area"]
    assert timing["timing_analyzed"] and timing["estimated_fmax_mhz"] >= 500
    assert timing["estimated_fmax_mhz"] == 1000 / timing["minimum_period_ns"]
    assert timing["clock_period_ns"] == 2 and timing["worst_setup_slack_ns"] >= 0
    assert timing["input_delay_ns"] == timing["output_delay_ns"] == 0.2
    assert timing["clock_uncertainty_ns"] == 0.05 and timing["interconnect"] == "no_parasitics"
    assert area["area_um2"] == area["logic_area_um2"] + area["sram_area_um2"] <= 36000
    assert area["sram_instances"] == [] and area["sram_area_um2"] == 0
    ram_manifest = load(VERIFIED / "synthesis/ram-manifest.json")
    assert ram_manifest["macros"] == {} and ram_manifest["configurations"] == []
    assert ram_manifest["model"] == synthesis["sram_model"]
    assert synthesis["libraries"] == load(PROJECT / "reports/candidates/v13/result.json")["libraries"]
    assert "slack" in (VERIFIED / "synthesis/timing.rpt").read_text().lower()
    architecture = load(VERIFIED / "architecture/results.json")
    assert {r["profile"] for r in architecture} == set(PROBES) and len(architecture) == len(PROBES)
    for result in architecture:
        name = result["profile"]
        assert result["source_sha256"] == inputs["source_sha256"] and result["arguments"] == PROBES[name]
        assert set(result["runs"]) == {"10", "40"}
        if name == "default":
            assert result["config"] == default_result["config"]
        for latency, run in result["runs"].items():
            log = VERIFIED / "architecture" / name / f"run-lat{latency}.log"
            assert sha(log) == run["log_sha256"]
            assert run["ooo"] and run["retired_in_order"] == 12
            assert run["maximum_issue"] == result["config"]["issueWidth"]
            assert re.search(rf"Architecture probe: PASS ooo=1 max_issue={run['maximum_issue']} retired_bytes=\s*48", log.read_text())
            assert "PASS cycles=" in log.read_text()
        probe = VERIFIED / "architecture" / name
        binary = load(probe / "build-receipt.json")
        assert binary["rtl_sha256"] == result["rtl_sha256"]
        assert binary["sim_sha256"] == result["sim_sha256"]
        assert hashlib.sha256(gzip.decompress((probe / "student_top.sv.gz").read_bytes())).hexdigest() == result["rtl_sha256"]
    units = load(VERIFIED / "units/results.json")
    assert units["source_sha256"] == inputs["source_sha256"] and len(units["cases"]) == 13
    expected_units = {f"{unit}-ways{ways}" for unit in ["frontend", "frontend-targets", "dcache-return", "dcache-write"] for ways in [1, 2, 4]} | {"axi"}
    assert {r["case"] for r in units["cases"]} == expected_units
    for result in units["cases"]:
        name = result["case"]
        assert result["status"] == "passed"
        assert sha(VERIFIED / "units" / (name + ".log")) == result["log_sha256"]
        assert sha(VERIFIED / "units" / (name + ".sv")) == result["adapted_testbench_sha256"]
        assert sha(ROOT / result["testbench"]) == result["testbench_sha256"]
        assert hashlib.sha256(gzip.decompress((VERIFIED / "units" / (name + "-rtl.sv.gz")).read_bytes())).hexdigest() == result["generated_rtl_sha256"]
        assert "PASS" in (VERIFIED / "units" / (name + ".log")).read_text()
    expected_coverage = {"issueWidth": [1, 2, 3], "robEntries": [16, 32], "prfEntries": [8, 32, 64],
                         "iqEntries": [2, 4], "icacheBytes": [512, 1024], "dcacheBytes": [1024, 2048],
                         "icacheWays": [1, 2, 4], "dcacheWays": [1, 2, 4]}
    assert {name: sorted(values) for name, values in covered.items()} == expected_coverage
    return {"accepted": True, "rtl_sha256": rtl_hash, "frequency_mhz": timing["estimated_fmax_mhz"],
            "area_um2": area["area_um2"], "performance": default_result["performance_by_latency"],
            "correctness_per_latency": {"10": len(correctness(default / "correctness-lat10.log")), "20": len(default_result["correctness_lat20"])},
            "parameter_configurations": parameters, "architecture_probes": len(architecture), "unit_checks": len(units["cases"]),
            "requirements": {"student_top_ports": ports, "validated_parameter_values": expected_coverage,
                             "official_default_filelist_uses_native_Chisel": True,
                             "rv32im_named_checks": 86, "out_of_order_execution": True, "ordered_retirement": True,
                             "AXI_backpressure_errors_and_MMIO": True, "reports_with_reproduction_commands": True},
            "scope": "Official synthesis/STA with ideal clock and no wire parasitics; directed architecture checks and official software regression, not full-CPU formal proof"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    result = audit()
    assert result == load(REPORT / "acceptance.json"), "Acceptance summary differs from raw evidence"
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
