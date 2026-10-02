#!/usr/bin/env python3
"""Directed rename/recovery programs; architectural answers come from reference."""
import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests/system"))
from generate import Program, b, i, r, s


def addi(rd, rs, imm):
    return i(0x13, 0, rd, rs, imm)


def generate(root):
    p = Program()
    p.li(30, 0x10000)
    p.emit(addi(0, 0, 0))
    p.emit(addi(0, 0, 0))
    for reg in range(1, 5):
        p.emit(addi(reg, 0, reg))
    for _ in range(64):
        for reg in range(1, 5):
            p.emit(addi(reg, reg, 1))
    for reg in range(1, 5):
        p.emit(s(2, 30, reg, 4*reg))
    p.exit(4)
    p.save(root, "four_independent_dependency_streams")

    p = Program()
    p.li(30, 0x10000)
    p.li(1, 7)
    p.li(2, 3)
    for n in range(128):
        p.emit(addi(1, 1, 1))
        p.emit(addi(1, 1, 2))  # Same fetch pair RAW + WAW.
        p.emit(r(0, 3, 1, 2))
        p.emit(addi(1, 3, 4))
        p.emit(s(2, 30, 1, n*4))
        p.emit(addi(0, 1, 123))
    p.exit(1)
    p.save(root, "rename_waw_wraparound")

    p = Program()
    p.li(30, 0x10000)
    p.li(1, 0x80000000)
    p.li(2, 3)
    p.li(3, 17)
    for n in range(20):
        p.emit(addi(1, 1, 3))  # Full-width, distinct DIVU operands each time.
        p.emit(r(5, 5, 1, 2, 1))
        p.emit(r(0, 10, 5, 3))  # Waits on DIV, retains the old x3 mapping.
        for k in range(8):
            p.emit(addi(3, 3, k+1))
        p.emit(s(2, 30, 10, n*4))
    p.exit(10)
    p.save(root, "rename_delayed_old_source")

    p = Program()
    p.li(30, 0x10000)
    p.li(1, 0x80000000)
    p.li(2, 0x8000)
    p.li(3, 0x1234)
    p.emit(i(0x03, 2, 9, 30, 0))  # Complete the cache warm-up before DIVU.
    p.emit(r(4, 9, 9, 9))
    p.emit(r(0, 1, 1, 9))
    while p.pc % 32:
        p.emit(addi(0, 0, 0))
    p.emit(r(5, 6, 1, 2, 1))  # Delayed older Store address.
    p.emit(s(2, 6, 3, 0))
    p.emit(i(0x03, 2, 3, 30, 0))  # Replay must restore x3's pre-load map.
    p.emit(addi(3, 3, 7))
    p.emit(addi(3, 3, 11))
    p.emit(s(2, 30, 3, 4))
    p.exit(3)
    p.save(root, "load_replay_pre_map_waw")

    # Vary producer delay to exercise nested branch checkpoint restoration.
    # Predictor is disabled so repeated loops warm I-cache while continuing to
    # exercise recovery every time.
    for old_chain, chain in [(0, n) for n in range(3, 11)] + [(2, 2)]:
        p = Program()
        p.li(30, 0x10000)
        p.li(1, 0x80000000)
        p.li(2, 3)
        p.li(3, 17)
        p.li(6, 1)
        p.li(20, 12)
        loop = p.pc
        for _ in range(old_chain):
            p.emit(addi(1, 1, 1))  # True dependency, not an eliminated move.
        p.emit(r(5, 5, 1, 2, 1))
        older = p.pc
        p.emit(0)  # Patch older branch target after emitting younger work.
        for _ in range(chain):
            p.emit(addi(6, 6, 1))
        younger = p.pc
        p.emit(0)
        for k in range(18):
            p.emit(addi(3, 3, k+1))
        inner = p.pc
        for _ in range(8):
            p.emit(addi(3, 3, 1))
        target = p.pc
        p.emit(s(2, 30, 3, 0))
        p.emit(addi(1, 1, 3))  # Keep the completed-operand cache enabled.
        p.emit(addi(20, 20, -1))
        p.emit(b(1, 20, 0, loop-p.pc))
        p.exit(3)
        for pc, word in [(older, b(0, 5, 5, target-older)),
                         (younger, b(0, 6, 6, inner-younger))]:
            p.memory[pc:pc+4] = word.to_bytes(4, "little")
            p.listing[pc//4] = f"{pc:08x}: {word:08x}"
        name = "older_recovery_overlap" if old_chain else f"older_recovery_chain{chain}"
        p.save(root, name)

    for chain in (5, 7, 9):
        p = Program()
        p.li(30, 0x10000)
        p.li(1, 0x80000000)
        p.li(2, 3)
        p.li(3, 17)
        p.li(6, 1)
        p.li(20, 12)
        loop = p.pc
        for _ in range(chain):
            p.emit(addi(6, 6, 1))
        branch = p.pc
        p.emit(0)
        p.emit(r(5, 3, 1, 2, 1))  # Speculative MDU overwrites live x3.
        for k in range(12):
            p.emit(addi(3, 3, k+1))
        target = p.pc
        p.emit(addi(3, 3, 1))  # Must read the restored committed x3.
        p.emit(s(2, 30, 3, 0))
        p.emit(addi(1, 1, 3))
        p.emit(addi(20, 20, -1))
        p.emit(b(1, 20, 0, loop-p.pc))
        p.emit(r(5, 3, 1, 2, 1))  # Reuse the MDU after cancellation.
        p.exit(3)
        word = b(0, 6, 6, target-branch)
        p.memory[branch:branch+4] = word.to_bytes(4, "little")
        p.listing[branch//4] = f"{branch:08x}: {word:08x}"
        p.save(root, f"mdu_cancel_waw_chain{chain}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/core/tests")
    args = parser.parse_args()
    generate(args.output)
    print(f"Generated core cases in {args.output}")
