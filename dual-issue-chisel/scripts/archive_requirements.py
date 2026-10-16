#!/usr/bin/env python3
"""Freeze completed measurements and refuse acceptance until the full audit passes."""
import gzip
import io
import json
from pathlib import Path
import shutil
import subprocess
import tarfile

from check_parameters import PROJECT, ROOT, BASE, PROFILES, sha, sources
from check_architecture import PROBES
from audit_requirements import REPORT, VERIFIED, audit, testcase_manifest


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n")


def copy(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)


def compress(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(gzip.compress(source.read_bytes(), mtime=0))


def main():
    # Check required terminal artifacts before creating or replacing an archive.
    for name in PROFILES:
        result = json.loads((BASE / name / "result.json").read_text())
        assert result["source_sha256"] == sources() and result["correctness_lat20"], name
    assert (BASE / "default/perf-lat20.log").is_file()
    assert (PROJECT / "build/architecture-results.json").is_file()
    assert (PROJECT / "build/unit-results/associativity-results.json").is_file()
    assert (REPORT / "report.md").is_file() and (REPORT / "parameter-sensitivity.md").is_file()
    VERIFIED.mkdir(parents=True, exist_ok=True)
    for name in PROFILES:
        out = BASE / name
        for filename in ["result.json", "generation-receipt.json", "build-receipt.json", "elaboration.json"]:
            copy(out / filename, VERIFIED / "parameters" / name / filename)
        for log in out.glob("*.log"):
            if log.name == "build.log":
                compress(log, VERIFIED / "parameters" / name / "build.log.gz")
            else:
                copy(log, VERIFIED / "parameters" / name / log.name)
    copy(PROJECT / "build/architecture-results.json", VERIFIED / "architecture/results.json")
    for name in PROBES:
        out = PROJECT / "build" / ("probe-" + name)
        for filename in ["result.json", "build-receipt.json", "elaboration.json", "run-lat10.log", "run-lat40.log"]:
            copy(out / filename, VERIFIED / "architecture" / name / filename)
        compress(out / "student_top.sv", VERIFIED / "architecture" / name / "student_top.sv.gz")
        compress(out / "build.log", VERIFIED / "architecture" / name / "build.log.gz")
    unit_out = PROJECT / "build/unit-results"
    units = json.loads((unit_out / "associativity-results.json").read_text())
    write_json(VERIFIED / "units/results.json", units)
    for unit in units["cases"]:
        name = unit["case"]
        for extension in [".log", ".sv"]:
            copy(unit_out / (name + extension), VERIFIED / "units" / (name + extension))
        compress(unit_out / (name + "-compile.log"), VERIFIED / "units" / (name + "-compile.log.gz"))
        rtl = PROJECT / "build" / unit["generated_directory"]
        files = list(rtl.glob("*.sv"))
        assert len(files) == 1
        compress(files[0], VERIFIED / "units" / (name + "-rtl.sv.gz"))
    entry = PROJECT / "build/requirements-entry"
    assert (entry / "build-receipt.json").is_file()
    for filename in ["build-receipt.json", "correctness-lat10.log", "perf-lat10.log", "perf-lat20.log"]:
        copy(entry / filename, VERIFIED / "entry" / filename)
    compress(PROJECT / "build/requirements-entry-build.log", VERIFIED / "entry/build.log.gz")
    copy(ROOT / "verilog/filelist.f", VERIFIED / "entry/filelist.f")
    synth = entry / "synth/opt"
    for filename in ["report.json", "synth.log", "elaborate.log", "mapped.v", "timing.json", "critical_paths.json"]:
        compress(synth / filename, VERIFIED / "synthesis" / (filename + ".gz"))
    for filename in ["report.txt", "timing.rpt", "timing.log", "timing_values.json", "timing_checks.rpt",
                     "clock_checks.rpt", "abc.constr", "constraints.sdc", "synth.ys", "elaborate.ys", "timing.tcl"]:
        copy(synth / filename, VERIFIED / "synthesis" / filename)
    copy(synth / "ram/manifest.json", VERIFIED / "synthesis/ram-manifest.json")
    for path in (PROJECT / "build/requirements-programs").iterdir():
        if path.suffix in [".data", ".json"]:
            copy(path, VERIFIED / "programs" / path.name)
    copy(PROJECT / "build/requirements-generate.log", VERIFIED / "generate.log")
    compress(PROJECT / "rtl/student_top.sv", VERIFIED / "default-rtl.sv.gz")
    project_files = [*sorted((PROJECT / "scripts").glob("*.py")), PROJECT / "scripts/parameter_profiles.json",
                     PROJECT / "build.sbt", PROJECT / "project/build.properties", PROJECT / "Makefile",
                     PROJECT / "rtl/elaboration.json", PROJECT / "rtl/filelist.f"]
    source_files = [PROJECT / name for name in sources()]
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w") as archive:
        for path in sorted(set(source_files + project_files)):
            data = path.read_bytes()
            info = tarfile.TarInfo(str(path.relative_to(PROJECT)))
            info.size = len(data)
            info.mode = 0o644
            archive.addfile(info, io.BytesIO(data))
    (VERIFIED / "source.tar.gz").write_bytes(gzip.compress(buffer.getvalue(), mtime=0))
    framework = json.loads((REPORT / "framework-comparison.json").read_text())
    official = {row["path"]: sha(ROOT / row["path"]) for row in framework["files"]}
    official["cpu2026-tools-x86_64.AppImage"] = sha(ROOT / "cpu2026-tools-x86_64.AppImage")
    inputs = {"official_commit": framework["commit"],
              "testcases_commit": subprocess.check_output(["git", "-C", str(ROOT / "testcases"), "rev-parse", "HEAD"], text=True).strip(),
              "source_sha256": sources(), "rtl_sha256": sha(PROJECT / "rtl/student_top.sv"),
              "project_files_sha256": {str(p.relative_to(PROJECT)): sha(p) for p in project_files},
              "testcases_sha256": testcase_manifest(), "official_tools_sha256": official,
              "delivery_files_sha256": {str(p.relative_to(ROOT)): sha(p) for p in [ROOT / "verilog/filelist.f", ROOT / "verilog/reference_filelist.f"]},
              "programs_sha256": {p.name: sha(p) for p in sorted((VERIFIED / "programs").iterdir()) if p.is_file()},
              "reports_sha256": {name: sha(REPORT / name) for name in ["report.md", "parameter-sensitivity.md"]}}
    write_json(VERIFIED / "inputs.json", inputs)
    write_json(VERIFIED / "sha256.json", {str(p.relative_to(VERIFIED)): sha(p) for p in sorted(VERIFIED.rglob("*"))
                                         if p.is_file() and p.name != "sha256.json"})
    result = audit()
    write_json(REPORT / "acceptance.json", result)
    print(json.dumps({k: result[k] for k in ["accepted", "frequency_mhz", "area_um2", "correctness_per_latency", "architecture_probes", "unit_checks"]}, indent=2))


if __name__ == "__main__":
    main()
