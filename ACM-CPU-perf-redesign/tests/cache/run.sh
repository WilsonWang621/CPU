#!/usr/bin/env bash
set -euo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
verilator_bin="${VERILATOR:-$project_root/RISC-V-CPU-2026-Toolchain/bin/verilator}"
build_root="${CACHE_TEST_BUILD_DIR:-$project_root/build/tests-cache}"
mkdir -p "$build_root"

build_run() {
    local name="$1" top="$2" source="$3" test="$4"
    shift 4
    local output="$build_root/$name"
    mkdir -p "$output"
    if ! "$verilator_bin" --cc --exe --build --assert -j "${JOBS:-2}" -Wall \
        --top-module "$top" --Mdir "$output" -o test \
        "$source" "$test" "$@" >"$output/build.log" 2>&1; then
        cat "$output/build.log"
        return 1
    fi
    "$output/test"
}

build_run controller memory_controller "$project_root/rtl/memory_controller.sv" \
    "$project_root/tests/cache/controller_test.cpp"
build_run controller-small memory_controller "$project_root/rtl/memory_controller.sv" \
    "$project_root/tests/cache/controller_test.cpp" -GMAX_MEM_OUTSTANDING=4 -CFLAGS '-DMAX_MEM_OUTSTANDING=4'

if [[ "${1:-}" == "--quick" ]]; then
    configs=("4 32 8 0" "1 16 1 1" "4 32 8 0 1" "2 32 4 0 2" "2 32 4 0 3" "2 32 4 1 4 8" "2 32 4 1 4 16")
else
    configs=()
    for ways in 1 2 4; do
        for line in 16 32 64; do
            for mshrs in 1 8; do configs+=("$ways $line $mshrs 0"); done
        done
    done
    configs+=("4 32 16 0" "1 16 1 1" "2 32 4 1" "4 64 8 1" "4 32 8 0 1" "2 32 4 0 2" "2 32 4 0 3" "2 32 4 1 4 8" "2 32 4 1 4 16")
fi
for config in "${configs[@]}"; do
    read -r ways line mshrs readonly cpu_words waiters <<<"$config"
    cpu_words="${cpu_words:-4}"
    waiters="${waiters:-32}"
    suffix=""
    if [[ "$cpu_words" != 4 ]]; then suffix="-c$cpu_words"; fi
    if [[ "$waiters" != 32 ]]; then suffix+="-q$waiters"; fi
    build_run "cache-w${ways}-l${line}-m${mshrs}-r${readonly}${suffix}" cache \
        "$project_root/rtl/cache.sv" "$project_root/tests/cache/cache_test.cpp" \
        -GWAYS="$ways" -GLINE_BYTES="$line" -GMSHRS="$mshrs" \
        -GREAD_ONLY="$readonly" -GMAX_CPU_WORDS="$cpu_words" -GWAITERS="$waiters" -GCACHE_BYTES="$((ways*line*16))" \
        -CFLAGS "-std=c++17 -O2 -DWAYS=$ways -DLINE_BYTES=$line -DMSHRS=$mshrs -DREAD_ONLY=$readonly -DMAX_CPU_WORDS=$cpu_words -DWAITERS=$waiters"
done
