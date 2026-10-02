#!/usr/bin/env python3
"""Conflict/collision tests specific to a two-way no-write-allocate cache."""
import argparse
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("system_cases", ROOT / "tests/system/generate.py")
helpers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helpers)
Program, i, s = helpers.Program, helpers.i, helpers.s
lsu_spec = importlib.util.spec_from_file_location("lsu_helpers", ROOT / "tests/lsu/generate.py")
lsu = importlib.util.module_from_spec(lsu_spec)
lsu_spec.loader.exec_module(lsu)


def generate(output):
    for delay in range(5):
        p = Program()
        for number, address in enumerate((0x10000, 0x10400, 0x10800, 0x10c00)):
            p.li(20+number, address)
            for word in range(16):
                p.memory[address+4*word:address+4*word+4] = (0x10203040+number*0x11111111+word).to_bytes(4, "little")
        p.li(5, 0x78654321)
        for turn in range(16):
            a, b, c = 20+turn%4, 20+(turn+1)%4, 20+(turn+2)%4
            p.emit(i(3, 2, 1, a, 0))
            p.emit(i(3, 2, 2, b, 0))
            p.emit(helpers.r(0, 3, 1, 2))
            for _ in range(12):
                p.emit(i(0x13, 0, 3, 3, 1))
            p.emit(s(2, a, 5, 0))
            p.emit(i(0x13, 0, 24, c, 0))
            for _ in range(delay):
                p.emit(i(0x13, 0, 24, 24, 0))
            p.emit(i(3, 2, 4, 24, 0))
            p.emit(s(0, b, 5, 1))
            p.emit(i(3, 2, 6, b, 0))
            p.emit(s(2, c, 6, 4))
            p.emit(i(3, 2, 7, a, 0))
            p.emit(s(2, c, 7, 8))
            p.emit(i(0x13, 0, 5, 5, 1))
        p.exit(7)
        p.save(output, f"cache_store_victim_collision_{delay}")
    # Start at the upper critical word, wrap through the lower half, then
    # touch both sides of a 64-byte boundary and a partially updated word.
    p = Program()
    p.li(20, 0x10000)
    p.li(5, 0x78654321)
    for word in range(32):
        address = 0x10000 + 4*word
        p.memory[address:address+4] = (0x10203040+word).to_bytes(4, "little")
    for offset in (60, 0, 32, 28, 60, 64, 124, 68):
        p.emit(i(3, 2, 1, 20, offset))
        p.emit(s(2, 20, 1, 128+offset))
    p.emit(s(0, 20, 5, 61))
    p.emit(i(3, 2, 7, 20, 60))
    p.exit(7)
    p.save(output, "cache_upper_critical_wrap")
    for length in (4, 6, 8, 10):
        p = lsu.Program()
        p.li(20, 0x80000000)
        p.li(21, 7)
        p.li(24, 0)
        p.align()
        p.label("warm_region")
        p.emit(i(0x13, 0, 20, 20, 13))  # Defeat DIV result reuse on pass two.
        p.emit(i(0x13, 0, 1, 24, 0))
        for _ in range(length):
            p.emit(i(0x13, 0, 1, 1, 0))
        p.branch(1, 1, 0, "after_div")
        p.emit(helpers.r(5, 10, 20, 21, 1))
        p.label("after_div")
        p.emit(i(0x13, 0, 10, 0, 123))
        p.branch(1, 24, 0, "exit")
        p.emit(i(0x13, 0, 24, 0, 1))
        p.jump("warm_region")
        p.label("exit")
        p.exit(10)
        p.save(output, f"cancel_busy_divider_{length}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/area-v2/v2-cases")
    args = parser.parse_args()
    generate(args.output)
