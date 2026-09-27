#include "VInstructionDecoder.h"
#include "verilated.h"
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <random>

// Independent instruction table: opcode, funct3/funct7 (-1 = unconstrained),
// immediate format, unit, ALU operation, branch operation, operand flags, size.
// Flags: rs1=1, rs2=2, rd=4, PC operand=8, immediate operand=16, store=32, unsigned=64.
struct Spec { unsigned op; int f3, f7; char format; unsigned fu, alu, branch, flags, size; };
const Spec specs[] = {
  {0x37,-1,-1,'U',0,10,0,20,0}, {0x17,-1,-1,'U',0,0,0,28,0},
  {0x6f,-1,-1,'J',1,0,7,4,0}, {0x67,0,-1,'I',1,0,8,5,0},
  {0x63,0,-1,'B',1,0,1,3,0}, {0x63,1,-1,'B',1,0,2,3,0},
  {0x63,4,-1,'B',1,0,3,3,0}, {0x63,5,-1,'B',1,0,4,3,0},
  {0x63,6,-1,'B',1,0,5,3,0}, {0x63,7,-1,'B',1,0,6,3,0},
  {0x03,0,-1,'I',2,0,0,5,0}, {0x03,1,-1,'I',2,0,0,5,1},
  {0x03,2,-1,'I',2,0,0,5,2}, {0x03,4,-1,'I',2,0,0,69,0},
  {0x03,5,-1,'I',2,0,0,69,1},
  {0x23,0,-1,'S',2,0,0,35,0}, {0x23,1,-1,'S',2,0,0,35,1},
  {0x23,2,-1,'S',2,0,0,35,2},
  {0x13,0,-1,'I',0,0,0,21,0}, {0x13,2,-1,'I',0,2,0,21,0},
  {0x13,3,-1,'I',0,3,0,21,0}, {0x13,4,-1,'I',0,4,0,21,0},
  {0x13,6,-1,'I',0,5,0,21,0}, {0x13,7,-1,'I',0,6,0,21,0},
  {0x13,1,0,'H',0,7,0,21,0}, {0x13,5,0,'H',0,8,0,21,0},
  {0x13,5,32,'H',0,9,0,21,0},
  {0x33,0,0,'R',0,0,0,7,0}, {0x33,0,32,'R',0,1,0,7,0},
  {0x33,1,0,'R',0,7,0,7,0}, {0x33,2,0,'R',0,2,0,7,0},
  {0x33,3,0,'R',0,3,0,7,0}, {0x33,4,0,'R',0,4,0,7,0},
  {0x33,5,0,'R',0,8,0,7,0}, {0x33,5,32,'R',0,9,0,7,0},
  {0x33,6,0,'R',0,5,0,7,0}, {0x33,7,0,'R',0,6,0,7,0},
  {0x33,0,1,'R',3,0,0,7,0}, {0x33,1,1,'R',3,0,0,7,0},
  {0x33,2,1,'R',3,0,0,7,0}, {0x33,3,1,'R',3,0,0,7,0},
  {0x33,4,1,'R',3,0,0,7,0}, {0x33,5,1,'R',3,0,0,7,0},
  {0x33,6,1,'R',3,0,0,7,0}, {0x33,7,1,'R',3,0,0,7,0}
};
uint32_t signExtend(uint32_t value, unsigned bits) {
  const uint32_t sign = 1u << (bits - 1);
  return (value ^ sign) - sign;
}
uint32_t immediate(uint32_t w, char format) {
  switch (format) {
    case 'I': return signExtend(w >> 20, 12);
    case 'S': return signExtend(((w >> 25) << 5) | ((w >> 7) & 31), 12);
    case 'B': return signExtend(((w >> 31) << 12) | (((w >> 7) & 1) << 11) |
                               (((w >> 25) & 63) << 5) | (((w >> 8) & 15) << 1), 13);
    case 'U': return w & 0xfffff000u;
    case 'J': return signExtend(((w >> 31) << 20) | (((w >> 12) & 255) << 12) |
                               (((w >> 20) & 1) << 11) | (((w >> 21) & 1023) << 1), 21);
    case 'H': return (w >> 20) & 31;
    default: return 0;
  }
}
const Spec* lookup(uint32_t w) {
  for (const auto& s : specs)
    if ((w & 127) == s.op && (s.f3 < 0 || ((w >> 12) & 7) == unsigned(s.f3)) &&
        (s.f7 < 0 || (w >> 25) == unsigned(s.f7))) return &s;
  return nullptr;
}
unsigned count = 0;
void check(VInstructionDecoder& dut, uint32_t w) {
  dut.io_instruction = w;
  dut.eval();
  const auto* s = lookup(w);
  auto expect = [&](bool ok, const char* field) {
    if (!ok) {
      std::cerr << "FAIL instruction=0x" << std::hex << w << " field=" << field << '\n';
      std::exit(1);
    }
  };
  expect(bool(dut.io_decoded_decodeError) == (s == nullptr), "decodeError");
  expect(dut.io_decoded_rs1 == ((w >> 15) & 31), "rs1");
  expect(dut.io_decoded_rs2 == ((w >> 20) & 31), "rs2");
  expect(dut.io_decoded_rd == ((w >> 7) & 31), "rd");
  const unsigned flags = s ? s->flags : 0;
  expect(bool(dut.io_decoded_usesRs1) == bool(flags & 1), "usesRs1");
  expect(bool(dut.io_decoded_usesRs2) == bool(flags & 2), "usesRs2");
  expect(bool(dut.io_decoded_writesRd) == (bool(flags & 4) && ((w >> 7) & 31) != 0), "writesRd");
  expect(bool(dut.io_decoded_isStore) == bool(flags & 32), "isStore");
  if (s) {
    expect(dut.io_decoded_immediate == immediate(w, s->format), "immediate");
    expect(dut.io_decoded_fu == s->fu, "fu");
    expect(dut.io_decoded_aluOp == s->alu, "aluOp");
    expect(dut.io_decoded_branchOp == s->branch, "branchOp");
    expect(dut.io_decoded_mduOp == (s->fu == 3 ? unsigned(s->f3) : 0), "mduOp");
    expect(bool(dut.io_decoded_operandAIsPc) == bool(flags & 8), "operandAIsPc");
    expect(bool(dut.io_decoded_operandBIsImmediate) == bool(flags & 16), "operandBIsImmediate");
    expect(dut.io_decoded_accessSize == s->size, "accessSize");
    expect(bool(dut.io_decoded_loadUnsigned) == bool(flags & 64), "loadUnsigned");
  }
  ++count;
}
int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  VInstructionDecoder dut;
  std::mt19937 random(20260928);
  // All opcode/funct3/funct7 combinations, including compressed/reserved opcodes.
  for (unsigned op = 0; op < 128; ++op)
    for (unsigned f3 = 0; f3 < 8; ++f3)
      for (unsigned f7 = 0; f7 < 128; ++f7)
        check(dut, op | (f3 << 12) | (f7 << 25) | (3 << 7) | (4 << 15) | (5 << 20));
  // Vary every register/immediate bit, including zero destinations and sign boundaries.
  for (const auto& s : specs) {
    for (unsigned n = 0; n < 256; ++n) {
      uint32_t w = n == 0 ? 0 : n == 1 ? 0xffffffffu : n == 2 ? 0x80000000u : n == 3 ? 0x7fffffffu : random();
      w = (w & ~127u) | s.op;
      if (s.f3 >= 0) w = (w & ~(7u << 12)) | (unsigned(s.f3) << 12);
      if (s.f7 >= 0) w = (w & ~(127u << 25)) | (unsigned(s.f7) << 25);
      check(dut, w);
    }
  }
  // Unsupported fences, system instructions, and all-zero instruction.
  for (uint32_t w : {0u, 0x0000000fu, 0x0000100fu, 0x00000073u, 0x00100073u, 0x300110f3u}) check(dut, w);
  // Literal golden vectors pin sign extension and scattered B/J immediate bits.
  const uint32_t golden[][2] = {
    {0xfff00093u, 0xffffffffu}, {0x80000093u, 0xfffff800u},
    {0x7ff00093u, 0x000007ffu}, {0xfe20afa3u, 0xffffffffu},
    {0x80000063u, 0xfffff000u}, {0x7e000fe3u, 0x00000ffeu},
    {0x8000006fu, 0xfff00000u}, {0x7ffff06fu, 0x000ffffeu},
    {0x800000b7u, 0x80000000u}
  };
  for (const auto& v : golden) {
    check(dut, v[0]);
    if (dut.io_decoded_immediate != v[1]) {
      std::cerr << "FAIL golden immediate for 0x" << std::hex << v[0] << '\n';
      return 1;
    }
  }
  dut.final();
  std::cout << "InstructionDecoder: PASS (" << count << " vectors, 45 instructions)\n";
}
