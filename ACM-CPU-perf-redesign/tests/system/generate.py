#!/usr/bin/env python3
"""Generate toolchain-independent directed and random RV32IM programs."""
import argparse
import json
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from reference import MEMORY_SIZE, memory_text, run


def r(funct3, rd, rs1, rs2, funct7=0):
    return funct7 << 25 | rs2 << 20 | rs1 << 15 | funct3 << 12 | rd << 7 | 0x33


def i(opcode, funct3, rd, rs1, imm):
    return (imm & 0xfff) << 20 | rs1 << 15 | funct3 << 12 | rd << 7 | opcode


def s(funct3, rs1, rs2, imm):
    imm &= 0xfff
    return (imm >> 5) << 25 | rs2 << 20 | rs1 << 15 | funct3 << 12 | (imm & 31) << 7 | 0x23


def b(funct3, rs1, rs2, imm):
    imm &= 0x1fff
    return (imm >> 12) << 31 | ((imm >> 5) & 63) << 25 | rs2 << 20 | rs1 << 15 | funct3 << 12 | ((imm >> 1) & 15) << 8 | ((imm >> 11) & 1) << 7 | 0x63


def j(rd, imm):
    imm &= 0x1fffff
    return (imm >> 20) << 31 | ((imm >> 1) & 1023) << 21 | ((imm >> 11) & 1) << 20 | ((imm >> 12) & 255) << 12 | rd << 7 | 0x6f


class Program:
    def __init__(self):
        self.memory = bytearray(MEMORY_SIZE)
        self.pc = 0
        self.listing = []

    def emit(self, word):
        self.memory[self.pc:self.pc+4] = word.to_bytes(4, "little")
        self.listing.append(f"{self.pc:08x}: {word:08x}")
        self.pc += 4

    def li(self, rd, value):
        value &= 0xffffffff
        upper = ((value + 0x800) >> 12) & 0xfffff
        self.emit(upper << 12 | rd << 7 | 0x37)
        self.emit(i(0x13, 0, rd, rd, value & 0xfff))

    def exit(self, rd=0):
        self.emit(0x80000000 | 31 << 7 | 0x37)
        self.emit(s(2, 31, rd, 0))

    def save(self, root, name, fault=None, sim_args=None, fault_retired=None):
        case = root / name
        case.mkdir(parents=True, exist_ok=True)
        (case / "program.data").write_text(memory_text(self.memory))
        (case / "program.S").write_text("# Encoded words, generated without a RISC-V compiler\n" + "\n".join(self.listing) + "\n")
        if fault:
            metrics = {"fault": fault}
            if fault_retired is not None:
                metrics["dynamic_instructions"] = fault_retired
        else:
            result, count, final = run(self.memory[:], 100_000)
            (case / "expected.txt").write_text(str(result) + "\n")
            (case / "expected.memory").write_text(memory_text(final))
            metrics = {"dynamic_instructions": count}
        if sim_args:
            metrics["sim_args"] = sim_args
        (case / "metrics.json").write_text(json.dumps(metrics, indent=2) + "\n")


def generate(root, random_cases=8):
    p = Program()
    p.li(30, 0x10000)
    vectors = [(0, 0), (0xffffffff, 0), (0x80000000, 0xffffffff),
               (0x80000000, 0x80000000), (0xffffffff, 2), (7, 0xfffffffd),
               (0xfffffff9, 3), (0x7fffffff, 0xffffffff), (0x12345678, 0x9abcdef0)]
    for n, (a, v) in enumerate(vectors):
        p.li(1, a)
        p.li(2, v)
        for f in range(8):
            p.emit(r(f, 3, 1, 2, 1))
            p.emit(s(2, 30, 3, 4*(n*8+f)))
    p.exit(3)
    p.save(root, "directed_m_extension")

    p = Program()
    p.li(30, 0x10000)
    p.li(1, 0x12345678)
    p.emit(s(2, 30, 1, 0))
    p.li(2, 0xab)
    p.emit(s(0, 30, 2, 1))
    p.emit(i(0x03, 2, 3, 30, 0))
    p.emit(s(2, 30, 3, 4))
    p.li(2, 0xcdef)
    p.emit(s(1, 30, 2, 2))
    p.emit(i(0x03, 2, 3, 30, 0))
    p.emit(s(2, 30, 3, 8))
    for f, offset in [(0, 3), (4, 3), (1, 2), (5, 2)]:
        p.emit(i(0x03, f, 4, 30, offset))
        p.emit(s(2, 30, 4, 12 + f*4))
    p.exit(3)
    p.save(root, "directed_narrow_forward")

    for name, wrong_word in [("store", s(2, 30, 1, 0)), ("exit", s(2, 31, 1, 0)),
                             ("illegal", 0xffffffff), ("load_fault", i(0x03, 2, 7, 31, 0))]:
        p = Program()
        p.li(30, 0x10000)
        p.li(31, 0x80000000)
        p.li(1, 123)
        p.li(2, 3)
        p.emit(r(4, 3, 1, 2, 1))  # Delayed producer makes wrong path speculative.
        p.emit(b(0, 3, 3, 12))
        p.emit(wrong_word)
        p.emit(wrong_word)
        p.emit(i(0x13, 0, 3, 3, 1))
        p.exit(3)
        p.save(root, "directed_wrongpath_" + name)

    p = Program()
    p.li(1, MEMORY_SIZE-4)
    p.emit(i(0x67, 0, 0, 1, 0))
    p.pc = 32
    p.li(2, 17)
    p.exit(2)
    p.pc = MEMORY_SIZE-4
    p.emit(j(0, 32-p.pc))
    p.save(root, "directed_fetch_last_word")

    p = Program()
    for n in range(20):
        p.li(30, 0x10000 + 0x1000*n)
        p.li(1, 0x87650000+n)
        p.emit(s(2, 30, 1, 0))
        p.emit(i(0x03, 2, 2, 30, 0))
        p.emit(i(0x13, 0, 2, 2, 1))
        p.emit(s(2, 30, 2, 4))
    p.exit(2)
    p.save(root, "directed_dirty_eviction_exit")

    for name, word, cause, addr in [
        ("illegal", 0xffffffff, 1, 0),
        ("target_align", j(1, 2), 5, 2),
        ("load_align", i(0x03, 2, 2, 0, 1), 6, 1),
        ("store_align", s(2, 0, 0, 2), 8, 2),
        ("load_range", i(0x03, 2, 2, 0, -4), 7, 0xfffffffc),
        ("store_range", s(2, 0, 0, -4), 9, 0xfffffffc),
    ]:
        p = Program()
        p.emit(word)
        p.exit()
        fault = {"pc": 0, "cause": cause, "inst": word}
        if name != "illegal":
            fault["address"] = addr
        p.save(root, "fault_" + name, fault, fault_retired=0)
    p = Program()
    p.li(1, MEMORY_SIZE)
    p.emit(i(0x67, 0, 0, 1, 0))
    p.save(root, "fault_fetch_range", {"pc": MEMORY_SIZE, "cause": 3, "address": MEMORY_SIZE, "inst-valid": 0}, fault_retired=3)
    p = Program()
    p.exit()
    p.save(root, "fault_fetch_bus", {"pc": 0, "cause": 4, "address": 0, "inst-valid": 0}, ["--error-address", "0", "--error-read"], fault_retired=0)
    p = Program()
    p.li(1, 0x10000)
    fault_pc = p.pc
    p.emit(i(0x03, 2, 2, 1, 0))
    p.exit(2)
    p.save(root, "fault_load_bus", {"pc": fault_pc, "cause": 10, "address": 0x10000}, ["--error-address", "0x10000", "--error-read"], fault_retired=2)

    p = Program()
    p.li(30, 0x10000)
    p.li(1, 0x76543210)
    p.emit(s(2, 30, 1, 0))
    p.exit(1)
    p.save(root, "fault_exit_flush_bus", {"cause": 11}, ["--error-address", "0x10000", "--error-write"])

    p = Program()
    p.li(1, 0x80000000)
    instruction = s(1, 1, 0, 0)
    p.emit(instruction)
    p.save(root, "fault_partial_exit", {"pc": 8, "cause": 9, "address": 0x80000000, "inst": instruction}, fault_retired=2)

    p = Program()
    p.emit(i(0x13, 0, 1, 0, 1))
    p.emit(b(0, 0, 1, 2))  # Untaken branch does not fault on its unused target.
    p.emit(i(0x13, 0, 1, 1, 1))
    p.exit(1)
    p.save(root, "directed_untaken_misaligned")

    p = Program()
    p.li(1, 64)
    p.emit(r(4, 3, 0, 0, 1))
    p.emit(b(0, 3, 3, 64-p.pc))
    p.pc = 64
    p.exit(1)
    p.save(root, "directed_wrongpath_fetch_bus", sim_args=["--error-address", "32", "--error-read"])

    for seed in range(random_cases):
        random_source = random.Random(seed)
        p = Program()
        p.li(30, 0x10000)
        for reg in range(1, 29):
            p.li(reg, random_source.getrandbits(32))
        for _ in range(400):
            rd, rs1, rs2 = [random_source.randrange(0, 29) for _ in range(3)]
            choice = random_source.randrange(10)
            if choice < 4:
                f = random_source.randrange(8)
                f7 = random_source.choice([0, 0x20]) if f in (0, 5) else 0
                p.emit(r(f, rd, rs1, rs2, f7))
            elif choice < 6:
                f = random_source.choice([0, 2, 3, 4, 6, 7])
                p.emit(i(0x13, f, rd, rs1, random_source.randrange(-2048, 2048)))
            elif choice == 6:
                p.emit(r(random_source.randrange(8), rd, rs1, rs2, 1))
            elif choice == 7:
                p.emit(s(2, 30, rs2, random_source.randrange(64)*4))
            elif choice == 8:
                p.emit(i(0x03, 2, rd, 30, random_source.randrange(64)*4))
            else:
                p.emit(b(random_source.choice([0, 1, 4, 5, 6, 7]), rs1, rs2, 8))
                p.emit(i(0x13, 0, rd, rs1, 1))
        for reg in range(1, 29):
            p.emit(s(2, 30, reg, 256+reg*4))
        p.exit(1)
        p.save(root, f"random_dependencies_{seed}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/system_tests")
    parser.add_argument("--random-cases", type=int, default=8)
    args = parser.parse_args()
    generate(args.output, args.random_cases)
    print(f"Generated {len(list(args.output.glob('*/program.data')))} cases in {args.output}")


if __name__ == "__main__":
    main()
