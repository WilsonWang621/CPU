#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
build_dir="${BUILD_DIR:-build/memory-model}"
mkdir -p "$build_dir"
${CXX:-g++} -std=c++17 -O2 -Wall -Wextra -Werror tests/system/test_memory.cpp -o "$build_dir/test_memory"
"$build_dir/test_memory"
