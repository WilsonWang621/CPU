#!/usr/bin/env bash
# Run from the repository root. Keep the new workspace: it contains raw evidence.
set -euo pipefail
repo=$(pwd -P)
work=$(mktemp -d /tmp/pararisc-single-remeasure-XXXXXX)
export APPIMAGE_EXTRACT_AND_RUN=1 PYTHONUNBUFFERED=1
python3 - "$repo" "$work" <<'PY'
from pathlib import Path
import hashlib,json,shutil,sys
repo,work=map(Path,sys.argv[1:])
summary=json.loads((repo/'single-issue-chisel/reports/area-recovery-2026-10-21/summary.json').read_text())
assert hashlib.sha256((repo/'single-issue-chisel/rtl/student_top.sv').read_bytes()).hexdigest()==summary['rtl_sha256'], 'Regenerate the selected v110 RTL before measuring.'
shutil.copytree(repo/'scripts',work/'scripts',ignore=shutil.ignore_patterns('__pycache__'))
shutil.copytree(repo/'single-issue-chisel/rtl',work/'single-issue-chisel/rtl')
for file in ['Makefile','config.mk']:shutil.copy2(repo/file,work/file)
for file in ['student_top.sv','filelist.f']:
 a=repo/'single-issue-chisel/rtl'/file;b=work/'single-issue-chisel/rtl'/file
 assert hashlib.sha256(a.read_bytes()).digest()==hashlib.sha256(b.read_bytes()).digest()
PY
printf 'Measurement workspace: %s\n' "$work"
make -C "$work" build APPIMAGE="$repo/cpu2026-tools-x86_64.AppImage" \
  FILELIST=single-issue-chisel/rtl/filelist.f BUILD=build/sim JOBS=8 > "$work/build.log" 2>&1
for latency in 10 20; do
  make -C "$work" test SIM=build/sim/sim TESTCASES="$repo/testcases" \
    LATENCY="$latency" MAX_CYCLES=30000000 > "$work/correctness-lat$latency.log" 2>&1
  make -C "$work" perf SIM=build/sim/sim TESTCASES="$repo/testcases" \
    LATENCY="$latency" MAX_CYCLES=30000000 > "$work/perf-lat$latency.log" 2>&1
done
make -C "$work" synth APPIMAGE="$repo/cpu2026-tools-x86_64.AppImage" \
  FILELIST=single-issue-chisel/rtl/filelist.f SYNTH_OUT=build/synth \
  MODE=opt CLOCK_PERIOD_NS=2.0 ABC_DRIVING_CELL=INVx1_ASAP7_75t_R ABC_LOAD_FF=5.0 \
  > "$work/synth.log" 2>&1
cat "$work/build/synth/opt/report.txt"
