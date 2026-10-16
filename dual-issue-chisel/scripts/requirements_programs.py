#!/usr/bin/env python3
"""Independent self-checking RV32IM programs for the course memory/ISA contract."""
import json
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]
OUT = PROJECT / "build/requirements-programs"
MASK = 0xffffffff


def signed(x):
    return (x & MASK) - (1 << 32) if x & (1 << 31) else x & MASK


def ri(rd, rs, immediate, f3=0, opcode=0x13):
    return ((immediate & 0xfff) << 20) | (rs << 15) | (f3 << 12) | (rd << 7) | opcode


def rr(rd, a, b, f3, f7=0):
    return (f7 << 25) | (b << 20) | (a << 15) | (f3 << 12) | (rd << 7) | 0x33


def store(rs, base, offset=0, f3=2):
    return ((offset & 0xfe0) << 20) | (rs << 20) | (base << 15) | (f3 << 12) | ((offset & 31) << 7) | 0x23


class Program:
    def __init__(self):
        self.code, self.labels, self.failures = [], {}, []

    def emit(self, value):
        self.code.append(value)

    def label(self, name):
        assert name not in self.labels
        self.labels[name] = len(self.code) * 4

    def constant(self, register, value):
        value &= MASK
        high = ((value + 0x800) >> 12) & 0xfffff
        self.emit((high << 12) | (register << 7) | 0x37)
        self.emit(ri(register, register, value))

    def address(self, register, label, offset=0):
        self.emit(lambda pc, labels: ((((labels[label] + offset + 0x800) >> 12) & 0xfffff) << 12) | (register << 7) | 0x37)
        self.emit(lambda pc, labels: ri(register, register, labels[label] + offset))

    def branch(self, f3, a, b, target):
        def encode(pc, labels):
            off = labels[target] - pc
            assert off % 2 == 0 and -4096 <= off < 4096
            return (((off >> 12) & 1) << 31) | (((off >> 5) & 63) << 25) | (b << 20) | (a << 15) | (f3 << 12) | (((off >> 1) & 15) << 8) | (((off >> 11) & 1) << 7) | 0x63
        self.emit(encode)

    def jump(self, target, rd=0):
        def encode(pc, labels):
            off = labels[target] - pc
            assert off % 2 == 0 and -(1 << 20) <= off < (1 << 20)
            return (((off >> 20) & 1) << 31) | (((off >> 1) & 1023) << 21) | (((off >> 11) & 1) << 20) | (((off >> 12) & 255) << 12) | (rd << 7) | 0x6f
        self.emit(encode)

    def failure(self, description):
        name = f"fail_{len(self.failures)+1}"
        self.failures.append((name, description))
        return name

    def check(self, register, expected, description):
        self.constant(30, expected)
        self.branch(1, register, 30, self.failure(description))

    def finish(self, expected):
        self.constant(10, expected)
        self.constant(6, 0x80000000)
        self.emit(store(10, 6))
        self.label("success_halt")
        self.jump("success_halt")
        for index, (name, _) in enumerate(self.failures, 1):
            self.label(name)
            self.constant(10, index)
            self.constant(6, 0x80000000)
            self.emit(store(10, 6))
            self.jump(name)

    def words(self):
        return [value(pc * 4, self.labels) if callable(value) else value for pc, value in enumerate(self.code)]


def write(path, sections):
    lines = []
    for address, words in sections:
        lines.append(f"@{address:08x}")
        for word in words:
            lines.append(" ".join(f"{b:02x}" for b in (word & MASK).to_bytes(4, "little")))
    path.write_text("\n".join(lines) + "\n")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    p = Program()
    p.emit(ri(0, 0, 12)); p.check(0, 0, "x0 ignores writes")
    a, b = 0xf1234567, 33
    operations = [(0, 0, a+b, "ADD"), (0, 0x20, a-b, "SUB"), (1, 0, a << (b & 31), "SLL"),
                  (2, 0, int(signed(a) < signed(b)), "SLT"), (3, 0, int(a < b), "SLTU"),
                  (4, 0, a ^ b, "XOR"), (5, 0, a >> (b & 31), "SRL"),
                  (5, 0x20, signed(a) >> (b & 31), "SRA"), (6, 0, a | b, "OR"), (7, 0, a & b, "AND")]
    p.constant(1, a); p.constant(2, b)
    for f3, f7, result, name in operations:
        p.emit(rr(3, 1, 2, f3, f7)); p.check(3, result, name)
    immediates = [(0, -1, a-1, "ADDI"), (2, -1, int(signed(a) < -1), "SLTI"),
                  (3, -1, int(a < MASK), "SLTIU"), (4, 5, a ^ 5, "XORI"),
                  (6, 5, a | 5, "ORI"), (7, 5, a & 5, "ANDI"),
                  (1, 31, a << 31, "SLLI"), (5, 31, a >> 31, "SRLI"),
                  (5, 0x400 | 31, signed(a) >> 31, "SRAI")]
    for f3, imm, result, name in immediates:
        p.emit(ri(3, 1, imm, f3)); p.check(3, result, name)
    for a, b in [(0x80000000, MASK), (MASK, 2), (0x80000001, 0xfffffffd), (0xdeadbeef, 0), (0x7fffffff, MASK)]:
        p.constant(1, a); p.constant(2, b)
        sa, sb = signed(a), signed(b)
        q = (-1 if (sa < 0) != (sb < 0) else 1) * (abs(sa) // abs(sb)) if b else -1
        rem = sa - q * sb if b else sa
        uq, ur = (a // b, a % b) if b else (MASK, a)
        values = [a*b, (sa*sb) >> 32, (sa*b) >> 32, (a*b) >> 32, q, uq, rem, ur]
        for f3, value in enumerate(values):
            p.emit(rr(3, 1, 2, f3, 1)); p.check(3, value, f"M extension f3={f3} a={a:08x} b={b:08x}")
    p.constant(1, 0x10000)
    p.emit(ri(3, 1, 0, 2, 3)); p.check(3, 0, "uninitialized external RAM is zero")
    p.constant(2, 0x80ff7f01); p.emit(store(2, 1))
    for f3, off, expected, name in [(0, 2, MASK, "LB"), (4, 2, 255, "LBU"), (1, 2, 0xffff80ff, "LH"), (5, 2, 0x80ff, "LHU"), (2, 0, 0x80ff7f01, "LW")]:
        p.emit(ri(3, 1, off, f3, 3)); p.check(3, expected, name)
    p.constant(2, 0x80); p.emit(store(2, 1, 1, 0))
    p.emit(ri(3, 1, 0, 2, 3)); p.check(3, 0x80ff8001, "SB lane 1 little endian")
    p.constant(2, 0x1122); p.emit(store(2, 1, 2, 1))
    p.emit(ri(3, 1, 0, 2, 3)); p.check(3, 0x11228001, "SH upper half little endian")
    p.constant(1, 0x0ffffffc); p.constant(2, 0x12345678); p.emit(store(2, 1))
    p.emit(ri(3, 1, 0, 2, 3)); p.check(3, 0x12345678, "last word of 256 MiB RAM")
    for f3, a, b, taken in [(0, 7, 7, True), (0, 7, 8, False), (1, 7, 8, True), (1, 7, 7, False),
                           (4, MASK, 1, True), (4, 1, MASK, False), (5, 1, MASK, True), (5, MASK, 1, False),
                           (6, 1, MASK, True), (6, MASK, 1, False), (7, MASK, 1, True), (7, 1, MASK, False)]:
        p.constant(1, a); p.constant(2, b)
        fail = p.failure(f"branch f3={f3} taken={taken}")
        if taken:
            ok = f"branch_ok_{len(p.failures)}"; p.branch(f3, 1, 2, ok); p.jump(fail); p.label(ok)
        else:
            p.branch(f3, 1, 2, fail)
    p.label("auipc_pc"); p.emit((8 << 7) | 0x17); p.address(30, "auipc_pc")
    p.branch(1, 8, 30, p.failure("AUIPC"))
    p.label("jal_pc"); p.jump("jal_target", 5); p.jump(p.failure("JAL target")); p.label("jal_target")
    p.address(30, "jal_pc", 4); p.branch(1, 5, 30, p.failure("JAL link"))
    p.address(1, "jalr_target", 1); p.label("jalr_pc"); p.emit(ri(5, 1, 0, 0, 0x67))
    p.jump(p.failure("JALR target / bit 0 clearing")); p.label("jalr_target")
    p.address(30, "jalr_pc", 4); p.branch(1, 5, 30, p.failure("JALR link"))
    p.finish(0x600d600d)
    write(OUT / "rv32im.data", [(0, p.words())])
    q = Program(); q.constant(1, 0x0fffffc0); q.emit(ri(0, 1, 0, 0, 0x67))
    write(OUT / "upper-memory.data", [(0, q.words()), (0x0fffffc0, [(10 << 7) | 0x17, 0x80000337, store(10, 6), 0x0000006f])])
    ooo = [0x000100b7, ri(2, 1, 0, 2, 3), ri(3, 0, 7), ri(4, 0, 9), rr(5, 3, 4, 0),
           ri(7, 2, 4), ri(8, 2, 8), ri(9, 2, 0, 2, 3), rr(10, 7, 8, 0), rr(10, 10, 9, 0),
           0x80000337, store(10, 6), 0x0000006f]
    write(OUT / "out-of-order.data", [(0, ooo), (0x10000, [0x10010]), (0x10010, [5])])
    (OUT / "checks.json").write_text(json.dumps({"rv32im_expected": 0x600d600d, "failures": dict(p.failures),
        "upper_memory_expected": 0x0fffffc0, "out_of_order_expected": 0x20031}, indent=2) + "\n")
    print(f"Generated independent RV32IM/memory program with {len(p.failures)} named checks")


if __name__ == "__main__":
    main()
