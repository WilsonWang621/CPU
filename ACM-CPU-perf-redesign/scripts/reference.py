#!/usr/bin/env python3
"""RV32IM architectural reference with retirement observation.

Adapted from the supplied Testcases/tools/generate_expected_memory.py. Instruction
semantics remain independent of the RTL; observer additions expose architectural
retirements without changing the original supplied repository.
"""

import argparse
import json
import sys
import tempfile
from pathlib import Path


MEMORY_SIZE = 256 * 1024
EXIT_ADDRESS = 0x80000000
MASK32 = 0xFFFFFFFF


class ExecutionError(RuntimeError):
    pass


def signed(value, bits=32):
    value &= (1 << bits) - 1
    sign = 1 << (bits - 1)
    return value - (1 << bits) if value & sign else value


def load_image(path):
    memory = bytearray(MEMORY_SIZE)
    address = 0
    for line_number, raw_line in enumerate(path.read_text().splitlines(), 1):
        line = raw_line.split("//", 1)[0].split("#", 1)[0]
        for token in line.split():
            try:
                if token.startswith("@"):
                    address = int(token[1:], 16)
                    if not 0 <= address < MEMORY_SIZE:
                        raise ValueError("address outside RAM")
                else:
                    value = int(token, 16)
                    if not 0 <= value <= 0xFF or address >= MEMORY_SIZE:
                        raise ValueError("byte or address outside RAM")
                    memory[address] = value
                    address += 1
            except ValueError as error:
                raise ExecutionError(f"{path}:{line_number}: invalid token {token!r}: {error}") from error
    return memory


def read(memory, address, size):
    if address % size:
        raise ExecutionError(f"misaligned {size}-byte load at 0x{address:08x}")
    if address < 0 or address + size > len(memory):
        raise ExecutionError(f"load outside RAM at 0x{address:08x}")
    return int.from_bytes(memory[address:address + size], "little")


def write(memory, address, size, value):
    if address % size:
        raise ExecutionError(f"misaligned {size}-byte store at 0x{address:08x}")
    if address < 0 or address + size > len(memory):
        raise ExecutionError(f"store outside RAM at 0x{address:08x}")
    memory[address:address + size] = (value & MASK32).to_bytes(4, "little")[:size]


def trunc_div(dividend, divisor):
    quotient = abs(dividend) // abs(divisor)
    return -quotient if (dividend < 0) != (divisor < 0) else quotient


def run(memory, instruction_limit=100_000_000, on_retire=None):
    registers = [0] * 32
    pc = 0
    retired = 0

    while retired < instruction_limit:
        if pc & 3:
            raise ExecutionError(f"misaligned instruction fetch at 0x{pc:08x}")
        instruction = read(memory, pc, 4)
        opcode = instruction & 0x7F
        rd = (instruction >> 7) & 31
        funct3 = (instruction >> 12) & 7
        rs1 = (instruction >> 15) & 31
        rs2 = (instruction >> 20) & 31
        funct7 = instruction >> 25
        a, b = registers[rs1], registers[rs2]
        immediate_i = signed(instruction >> 20, 12)
        next_pc = (pc + 4) & MASK32
        result = None
        store, address, store_data, strobe = 0, 0, 0, 0

        if opcode == 0x37:  # LUI
            result = instruction & 0xFFFFF000
        elif opcode == 0x17:  # AUIPC
            result = pc + (instruction & 0xFFFFF000)
        elif opcode == 0x6F:  # JAL
            result = pc + 4
            immediate = signed(
                ((instruction >> 31) << 20)
                | (((instruction >> 12) & 0xFF) << 12)
                | (((instruction >> 20) & 1) << 11)
                | (((instruction >> 21) & 0x3FF) << 1), 21)
            next_pc = (pc + immediate) & MASK32
        elif opcode == 0x67 and funct3 == 0:  # JALR
            result = pc + 4
            next_pc = (a + immediate_i) & ~1 & MASK32
        elif opcode == 0x63:  # BRANCH
            immediate = signed(
                ((instruction >> 31) << 12)
                | (((instruction >> 7) & 1) << 11)
                | (((instruction >> 25) & 0x3F) << 5)
                | (((instruction >> 8) & 0xF) << 1), 13)
            comparisons = {
                0: a == b, 1: a != b,
                4: signed(a) < signed(b), 5: signed(a) >= signed(b),
                6: a < b, 7: a >= b,
            }
            if funct3 not in comparisons:
                raise ExecutionError(f"illegal branch at 0x{pc:08x}")
            if comparisons[funct3]:
                next_pc = (pc + immediate) & MASK32
        elif opcode == 0x03:  # LOAD
            modes = {0: (1, True), 1: (2, True), 2: (4, False),
                     4: (1, False), 5: (2, False)}
            if funct3 not in modes:
                raise ExecutionError(f"illegal load at 0x{pc:08x}")
            size, extend = modes[funct3]
            result = read(memory, (a + immediate_i) & MASK32, size)
            if extend:
                result = signed(result, size * 8)
        elif opcode == 0x23:  # STORE
            sizes = {0: 1, 1: 2, 2: 4}
            if funct3 not in sizes:
                raise ExecutionError(f"illegal store at 0x{pc:08x}")
            size = sizes[funct3]
            immediate = signed(((instruction >> 25) << 5) | ((instruction >> 7) & 31), 12)
            address = (a + immediate) & MASK32
            store = 1
            strobe = ((1 << size) - 1) << (address & 3)
            store_data = (b << (8 * (address & 3))) & MASK32
            if address == EXIT_ADDRESS:
                if size != 4:
                    raise ExecutionError(f"partial exit store at 0x{pc:08x}")
                if on_retire:
                    on_retire((pc, instruction, 0, 0, 1, address, store_data, strobe))
                return b, retired + 1, memory
            write(memory, address, size, b)
        elif opcode == 0x13:  # OP-IMM
            shift = (instruction >> 20) & 31
            if funct3 == 0:
                result = a + immediate_i
            elif funct3 == 2:
                result = int(signed(a) < immediate_i)
            elif funct3 == 3:
                result = int(a < (immediate_i & MASK32))
            elif funct3 == 4:
                result = a ^ immediate_i
            elif funct3 == 6:
                result = a | immediate_i
            elif funct3 == 7:
                result = a & immediate_i
            elif funct3 == 1 and funct7 == 0:
                result = a << shift
            elif funct3 == 5 and funct7 in (0, 0x20):
                result = signed(a) >> shift if funct7 == 0x20 else a >> shift
            else:
                raise ExecutionError(f"illegal immediate operation at 0x{pc:08x}")
        elif opcode == 0x33:  # OP / M extension
            shift = b & 31
            if funct7 == 0:
                operations = {
                    0: a + b, 1: a << shift, 2: int(signed(a) < signed(b)),
                    3: int(a < b), 4: a ^ b, 5: a >> shift, 6: a | b, 7: a & b,
                }
                result = operations[funct3]
            elif funct7 == 0x20 and funct3 in (0, 5):
                result = a - b if funct3 == 0 else signed(a) >> shift
            elif funct7 == 1:
                if funct3 == 0:  # MUL
                    result = a * b
                elif funct3 == 1:  # MULH
                    result = (signed(a) * signed(b)) >> 32
                elif funct3 == 2:  # MULHSU
                    result = (signed(a) * b) >> 32
                elif funct3 == 3:  # MULHU
                    result = (a * b) >> 32
                elif funct3 == 4:  # DIV
                    result = MASK32 if b == 0 else (
                        0x80000000 if a == 0x80000000 and b == MASK32
                        else trunc_div(signed(a), signed(b)))
                elif funct3 == 5:  # DIVU
                    result = MASK32 if b == 0 else a // b
                elif funct3 == 6:  # REM
                    result = a if b == 0 else (
                        0 if a == 0x80000000 and b == MASK32
                        else signed(a) - trunc_div(signed(a), signed(b)) * signed(b))
                elif funct3 == 7:  # REMU
                    result = a if b == 0 else a % b
            else:
                raise ExecutionError(f"illegal register operation at 0x{pc:08x}")
        elif opcode == 0x0F and funct3 in (0, 1):  # FENCE / FENCE.I
            pass
        else:
            raise ExecutionError(
                f"unsupported instruction 0x{instruction:08x} at 0x{pc:08x}")

        if result is not None and rd:
            registers[rd] = result & MASK32
        if on_retire:
            on_retire((pc, instruction, rd if result is not None and rd else 0,
                       (result & MASK32) if result is not None and rd else 0,
                       store, address, store_data, strobe))
        registers[0] = 0
        pc = next_pc
        retired += 1

    raise ExecutionError(f"instruction limit exceeded ({instruction_limit})")


def memory_text(memory):
    lines = []
    for address in range(0, len(memory), 16):
        chunk = memory[address:address + 16]
        if any(chunk):
            lines.append(f"@{address:08x} " + " ".join(f"{byte:02x}" for byte in chunk))
    return "\n".join(lines) + "\n"

