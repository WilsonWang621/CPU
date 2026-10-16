#!/usr/bin/env python3
"""Archive a completed official measurement and its frozen Chisel inputs."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import shutil
import tarfile

PROJECT = Path(__file__).resolve().parents[1]

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("version", type=int)
    args = p.parse_args()
    name = f"v{args.version}"
    frozen = PROJECT / "build" / f"candidate-{name}"
    measured = PROJECT / "build" / f"{name}-synth/opt"
    report = json.loads((measured / "report.json").read_text())
    rtl = PROJECT / "build" / f"{name}-rtl/student_top.sv"
    digest = sha(rtl)
    assert any(i["sha256"] == digest for i in report["inputs"]), "Report does not measure this RTL"
    assert (frozen / "src").is_dir(), "Missing frozen Chisel source"
    out = PROJECT / "reports" / "candidates" / name
    out.mkdir(parents=True, exist_ok=True)
    summary = {"candidate": name, "complete": False,
        "frequency_mhz": report["timing"]["estimated_fmax_mhz"], "area_um2": report["area"]["area_um2"],
        "meets_frequency": report["timing"]["estimated_fmax_mhz"] >= 500,
        "meets_area": report["area"]["area_um2"] <= 36000,
        "source_sha256": {str(f.relative_to(frozen)): sha(f) for f in sorted((frozen / "src").rglob("*.scala"))},
        "generated_rtl_sha256": digest,
        "firtool_optimization": args.version != 5,
        "tools": report["tools"], "inputs": report["inputs"], "libraries": report["libraries"],
        "abc_constraints": report["abc_constraints"],
        "timing_constraints": {k: v for k, v in report["timing"].items() if k != "critical_paths"}}
    (out / "result.json").write_text(json.dumps(summary, indent=2) + "\n")
    with tarfile.open(out / "source.tar.gz", "w:gz") as archive:
        archive.add(frozen / "src", arcname="src")
        archive.add(PROJECT / "build.sbt", arcname="build.sbt")
        archive.add(PROJECT / "project/build.properties", arcname="project/build.properties")
    for name in ("timing.rpt", "timing.json", "constraints.sdc", "abc.constr", "stat.json", "synth.ys"):
        shutil.copyfile(measured / name, out / name)
    with gzip.open(out / "synth.log.gz", "wb") as log:
        log.write((measured / "synth.log").read_bytes())
    manifest = {f.name: sha(f) for f in sorted(out.iterdir()) if f.is_file() and f.name != "sha256.json"}
    (out / "sha256.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"{summary['candidate']}: {summary['frequency_mhz']:.5f} MHz, {summary['area_um2']:.5f} um^2")

if __name__ == "__main__":
    main()
