#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$project_root"
verilator_bin="${VERILATOR:-$project_root/RISC-V-CPU-2026-Toolchain/bin/verilator}"
build_root="${FRONTEND_TEST_BUILD_DIR:-$project_root/build/frontend-tests}"
mkdir -p "$build_root"
build_run() {
  local top="$1" source="$2" name="$3"
  shift 3
  mkdir -p "$build_root/$name"
  "$verilator_bin" --cc --exe --build --assert -j "${JOBS:-2}" --top-module "$top" \
    --Mdir "$build_root/$name" -o test -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
    --unroll-count 1024 --unroll-stmts 100000 -CFLAGS '-std=c++17 -O3' \
    -MAKEFLAGS 'OPT_FAST=-O3 OPT_GLOBAL=-O3' \
    rtl/cpu_pkg.sv rtl/branch_predictor.sv rtl/frontend.sv \
    "tests/frontend/$top.sv" "$project_root/tests/frontend/$source" "$@" \
    >"$build_root/$name/build.log" 2>&1 || { cat "$build_root/$name/build.log"; exit 1; }
  "$build_root/$name/test"
}
for mode in 0 1 2; do
  build_run predictor_test_top predictor_test.cpp "predictor-mode$mode" \
    -GPREDICTOR_MODE="$mode" -CFLAGS "-DPREDICTOR_MODE=$mode"
  build_run frontend_test_top frontend_test.cpp "fetch4-mode$mode" \
    -GPREDICTOR_MODE="$mode" -CFLAGS "-DPREDICTOR_MODE=$mode"
  build_run frontend_test_top frontend_test.cpp "fetch2-mode$mode" \
    -GPREDICTOR_MODE="$mode" -GFETCH_WIDTH=2 -GLINE_BYTES=16 \
    -CFLAGS "-DPREDICTOR_MODE=$mode -DFETCH_WIDTH=2 -DLINE_BYTES=16"
  build_run frontend_test_top frontend_test.cpp "fetch1-mode$mode" \
    -GPREDICTOR_MODE="$mode" -GFETCH_WIDTH=1 -GFETCH_REQUESTS=4 \
    -CFLAGS "-DPREDICTOR_MODE=$mode -DFETCH_WIDTH=1 -DFETCH_REQUESTS=4"
done
for config in '8 1024' '1 64' '16 1024' '1 2'; do
  read -r history entries <<<"$config"
  build_run predictor_test_top predictor_test.cpp "predictor-history$history-entries$entries" \
    -GHISTORY_BITS="$history" -GBHT_ENTRIES="$entries" \
    -CFLAGS "-DHISTORY_BITS=$history -DBHT_ENTRIES=$entries"
done
build_run frontend_test_top frontend_test.cpp fetch-minimum \
  -GFETCH_WIDTH=1 -GFETCH_REQUESTS=2 -GFETCH_QUEUE_ENTRIES=1 \
  -GHISTORY_BITS=1 -GBHT_ENTRIES=2 \
  -CFLAGS '-DFETCH_WIDTH=1 -DFETCH_REQUESTS=2'
