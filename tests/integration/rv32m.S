  .section .text.init
  .globl _start
_start:
  li s0, 0
  li t4, 1
  li t0, -2
  li t1, 3

  mul t2, t0, t1
  li t3, -6
  xor t2, t2, t3
  sltu t2, zero, t2
  mul t2, t2, t4
  or s0, s0, t2
  slli t4, t4, 1

  mulh t2, t0, t1
  li t3, -1
  xor t2, t2, t3
  sltu t2, zero, t2
  mul t2, t2, t4
  or s0, s0, t2
  slli t4, t4, 1

  mulhsu t2, t0, t1
  xor t2, t2, t3
  sltu t2, zero, t2
  mul t2, t2, t4
  or s0, s0, t2
  slli t4, t4, 1

  mulhu t2, t0, t1
  li t3, 2
  xor t2, t2, t3
  sltu t2, zero, t2
  mul t2, t2, t4
  or s0, s0, t2
  slli t4, t4, 1

  li t0, -7
  div t2, t0, t1
  li t3, -2
  xor t2, t2, t3
  sltu t2, zero, t2
  mul t2, t2, t4
  or s0, s0, t2
  slli t4, t4, 1

  divu t2, t0, t1
  li t3, 0x55555553
  xor t2, t2, t3
  sltu t2, zero, t2
  mul t2, t2, t4
  or s0, s0, t2
  slli t4, t4, 1

  rem t2, t0, t1
  li t3, -1
  xor t2, t2, t3
  sltu t2, zero, t2
  mul t2, t2, t4
  or s0, s0, t2
  slli t4, t4, 1

  remu t2, t0, t1
  sltu t2, zero, t2
  mul t2, t2, t4
  or s0, s0, t2
  slli t4, t4, 1

  # Division by zero returns all ones; remainder returns the dividend.
  li t1, 0
  div t2, t0, t1
  li t3, -1
  xor t2, t2, t3
  sltu t2, zero, t2
  mul t2, t2, t4
  or s0, s0, t2
  slli t4, t4, 1
  divu t2, t0, t1
  xor t2, t2, t3
  sltu t2, zero, t2
  mul t2, t2, t4
  or s0, s0, t2
  slli t4, t4, 1
  rem t2, t0, t1
  xor t2, t2, t0
  sltu t2, zero, t2
  mul t2, t2, t4
  or s0, s0, t2
  slli t4, t4, 1
  remu t2, t0, t1
  xor t2, t2, t0
  sltu t2, zero, t2
  mul t2, t2, t4
  or s0, s0, t2
  slli t4, t4, 1

  # The one signed-overflow case is defined by the RISC-V ISA.
  li t0, 0x80000000
  li t1, -1
  div t2, t0, t1
  xor t2, t2, t0
  sltu t2, zero, t2
  mul t2, t2, t4
  or s0, s0, t2
  slli t4, t4, 1
  rem t2, t0, t1
  sltu t2, zero, t2
  mul t2, t2, t4
  or s0, s0, t2

  li t0, 0x80000000
  sw s0, 0(t0)
