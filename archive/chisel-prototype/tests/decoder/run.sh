#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
rtl_dir="$PWD/build/decoder"
"${MILL:-mill}" --no-server chisel.runMain cpu2026.GenerateDatapath decode "$rtl_dir"
"${VERILATOR:-verilator}" --cc --exe --build --top-module InstructionDecoder \
  --Mdir "$rtl_dir/obj" "$rtl_dir/InstructionDecoder.sv" \
  "$PWD/tests/decoder/decoder_test.cpp"
"$rtl_dir/obj/VInstructionDecoder"
