#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build/integration
clang --target=riscv32 -march=rv32im -mabi=ilp32 -nostdlib \
  -c tests/integration/rv32m.S -o build/integration/rv32m.o
llvm-objcopy -O binary --only-section=.text.init \
  build/integration/rv32m.o build/integration/rv32m.bin
make --no-print-directory build
python3 scripts/run.py build/integration/rv32m.bin --build build \
  --expected 0 --max-cycles 10000 --latency 3
