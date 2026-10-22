#!/usr/bin/env python3
"""Build the stable, evidence-backed experiment index.

This deliberately indexes the three adopted implementation baselines. Exploratory
rows remain in their stage reports unless they have the same complete evidence
shape; missing facts are emitted as ``unknown`` rather than inferred.
"""
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIELDS = [
    "experiment_id", "implementation_type", "source_identity", "archive_commit",
    "configuration_identity", "evaluation_flow", "correctness_lat10",
    "correctness_lat20", "ipc_lat10", "ipc_lat20", "area_um2", "fmax_mhz",
    "comparison_baseline", "comparable_with", "adopted", "report_path",
    "evidence_paths",
]


def load(path: str | Path):
    return json.loads((ROOT / path).read_text())


def build_rows():
    dual_accept = load("dual-issue-chisel/reports/requirements-2026-10-16/acceptance.json")
    dual_inputs = load("dual-issue-chisel/reports/requirements-2026-10-16/verified/inputs.json")
    dual_source = "; ".join(
        f"{k}={v}" for k, v in sorted(dual_inputs["source_sha256"].items())
    )
    single = load("single-issue-chisel/reports/area-recovery-2026-10-21/summary.json")
    single_manifest = load("single-issue-chisel/reports/area-recovery-2026-10-21/manifest.json")
    single_baseline = load("single-issue-chisel/baseline.json")
    verilog_identity = load("reports/data/2026-10-16/timing-stage10/clean-default/identity.json")
    verilog_export = load("reports/data/2026-10-16/timing-stage10/clean-default/export-manifest.json")
    verilog_source = "; ".join(
        f"{k}={v}" for k, v in sorted(verilog_export["sources_sha256"].items())
    )
    target = "official target: area<=36000 um2; Fmax>=500 MHz; IPC geomean>=1.0985"
    return [
        {
            "experiment_id": "dual-chisel-requirements-2026-10-16",
            "implementation_type": "dual-issue Chisel (default)",
            "source_identity": f"source_sha256 in verified/inputs.json; {dual_source}; rtl_sha256={dual_accept['rtl_sha256']}",
            "archive_commit": "unknown",
            "configuration_identity": "acceptance.json requirements; default tier3 parameters",
            "evaluation_flow": "official commit 302f0cf3; tool/input hashes in verified/inputs.json; constraints in verified/synthesis/",
            "correctness_lat10": "19/19",
            "correctness_lat20": "19/19",
            "ipc_lat10": dual_accept["performance"]["10"]["geomean_ipc"],
            "ipc_lat20": dual_accept["performance"]["20"]["geomean_ipc"],
            "area_um2": dual_accept["area_um2"],
            "fmax_mhz": dual_accept["frequency_mhz"],
            "comparison_baseline": target,
            "comparable_with": "dual Chisel records using the same official flow; not directly with single v110 or Verilog because source/tool/archive inputs differ",
            "adopted": "yes",
            "report_path": "dual-issue-chisel/reports/requirements-2026-10-16/report.md",
            "evidence_paths": "dual-issue-chisel/reports/requirements-2026-10-16/acceptance.json; dual-issue-chisel/reports/requirements-2026-10-16/verified/inputs.json; dual-issue-chisel/reports/requirements-2026-10-16/verified/synthesis/report.json.gz",
        },
        {
            "experiment_id": "single-chisel-v110-2026-10-21",
            "implementation_type": "single-issue Chisel v110",
            "source_identity": f"source_sha256 in manifest.json; source_commit={single_manifest['source_commit']}; rtl_sha256={single['rtl_sha256']}",
            "archive_commit": single_manifest["source_commit"],
            "configuration_identity": f"manifest.json parameters (issue-width=1; v110-flat-payload); baseline.json report={single_baseline['report']}",
            "evaluation_flow": f"official commit {single_manifest['official_commit']}; testcases {single_manifest['testcases_commit']}; Yosys {single_manifest['tools']['yosys']}; OpenSTA {single_manifest['tools']['opensta']}; ABC constraints in summary.json",
            "correctness_lat10": "19/19",
            "correctness_lat20": "19/19",
            "ipc_lat10": single["latencies"]["10"]["performance"]["ipc_geomean"],
            "ipc_lat20": single["latencies"]["20"]["performance"]["ipc_geomean"],
            "area_um2": single["synthesis"]["area_um2"],
            "fmax_mhz": single["synthesis"]["fmax_mhz"],
            "comparison_baseline": "single Chisel v109 new-flow remeasurement (area/fmax comparison in summary.json)",
            "comparable_with": "single Chisel stage records using the same official flow; not directly with dual Chisel or Verilog due to implementation/configuration differences",
            "adopted": "yes",
            "report_path": "single-issue-chisel/reports/area-recovery-2026-10-21/report.md",
            "evidence_paths": "single-issue-chisel/reports/area-recovery-2026-10-21/summary.json; single-issue-chisel/reports/area-recovery-2026-10-21/manifest.json; single-issue-chisel/reports/area-recovery-2026-10-21/performance-lat10.csv; single-issue-chisel/reports/area-recovery-2026-10-21/performance-lat20.csv",
        },
        {
            "experiment_id": "verilog-reference-stage10-2026-10-16",
            "implementation_type": "dual-issue Verilog reference",
            "source_identity": f"export-manifest.json sources_sha256; {verilog_source}; exported RTL_sha256={verilog_identity['rtl_sha256']}",
            "archive_commit": "unknown",
            "configuration_identity": "reports/data/.../clean-default/rtl/filelist.f and stage10 default input",
            "evaluation_flow": f"official commit {verilog_identity['official_commit']}; simulator identity in identity.json; ABC constraints driving={verilog_identity['abc_constraints']['driving_cell']}, load={verilog_identity['abc_constraints']['output_load_ff']}fF",
            "correctness_lat10": "unknown",
            "correctness_lat20": f"{verilog_identity['correctness_passed']}/19",
            "ipc_lat10": verilog_identity["ipc_latency_10"],
            "ipc_lat20": verilog_identity["ipc_latency_20"],
            "area_um2": verilog_identity["area_um2"],
            "fmax_mhz": verilog_identity["fmax_mhz"],
            "comparison_baseline": "stage 10 Verilog reference selected default at measurement time",
            "comparable_with": "directly comparable only to records with the same stage10 official flow and constraints; implementation differs from native Chisel",
            "adopted": "yes (reference only)",
            "report_path": "reports/dual-issue/frequency-stage10.md",
            "evidence_paths": "reports/data/2026-10-16/timing-stage10/clean-default/identity.json; reports/data/2026-10-16/timing-stage10/clean-default/export-manifest.json; reports/data/2026-10-16/timing-stage10/clean-default/timing.json; reports/data/2026-10-16/timing-stage10/clean-default/rtl/source-hashes.json",
        },
    ]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", type=Path, default=ROOT / "reports/experiments")
    args = parser.parse_args()
    out = args.out_dir if args.out_dir.is_absolute() else ROOT / args.out_dir
    out.mkdir(parents=True, exist_ok=True)
    rows = sorted(build_rows(), key=lambda r: r["experiment_id"])
    csv_path = out / "index.csv"
    json_path = out / "index.json"
    with csv_path.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=FIELDS, lineterminator="\n")
        writer.writeheader()
        writer.writerows({k: row[k] for k in FIELDS} for row in rows)
    payload = {"schema_version": 1, "generated_by": "scripts/build_experiment_index.py", "rows": rows}
    json_path.write_text(json.dumps(payload, indent=2, ensure_ascii=False, sort_keys=False) + "\n")
    print(f"wrote {csv_path.relative_to(ROOT)} and {json_path.relative_to(ROOT)} ({len(rows)} rows)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
