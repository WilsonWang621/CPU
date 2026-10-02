#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
root_dir="$PWD"
verilator_bin="${VERILATOR:-$root_dir/RISC-V-CPU-2026-Toolchain/bin/verilator}"
build_dir="${ISA_BUILD_DIR:-build/isa}"
mkdir -p "$build_dir"
build_dir="$(cd "$build_dir" && pwd)"
"$verilator_bin" --cc --exe --build -j "${JOBS:-2}" --top-module isa_top \
  --Mdir "$build_dir" -GDIV_STEP_BITS="${DIV_STEP_BITS:-4}" --assert -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
  -CFLAGS "-std=c++17 -O2 -DTEST_DIV_STEP_BITS=${DIV_STEP_BITS:-4}" \
  rtl/cpu_pkg.sv rtl/decoder.sv rtl/alu.sv rtl/branch_unit.sv rtl/muldiv.sv \
  tests/isa/isa_top.sv "$root_dir/tests/isa/test_isa.cpp" \
  >"$build_dir/build.log" 2>&1 || { cat "$build_dir/build.log"; exit 1; }
"$build_dir/Visa_top"
