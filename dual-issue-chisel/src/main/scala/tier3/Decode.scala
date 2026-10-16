package tier3

import chisel3._
import chisel3.util._
import tier3.Bits._
import ISA._

object DecodeTable {
  // The case arms in the reference are mutually exclusive. Express their
  // parallel data selection explicitly rather than a chain of priority muxes.
  def apply[T <: Data](key: UInt, choices: Seq[(UInt, T)]): T =
    Mux1H(choices.map { case (encoding, data) => (key === encoding) -> data })
}

/** The reference operation enum re-decoded at dispatch. These predicates
  * are Boolean factoring of that same enum, including illegal encodings;
  * they do not add an instruction class or a pipeline edge.
  */
object InstructionClass {
  def memory(inst: UInt): Bool = inst(6, 0) === "h03".U || inst(6, 0) === "h23".U
  def branch(inst: UInt): Bool = inst(6, 0) === "h6f".U || inst(6, 0) === "h67".U ||
    (inst(6, 0) === "h63".U && inst(14, 12) =/= 2.U && inst(14, 12) =/= 3.U)
  def mdu(inst: UInt): Bool = inst(6, 0) === "h33".U && inst(31, 25) === 1.U
}

class DecodeClassProof extends Logic {
  override def desiredName = "decode_class_proof"
  val inst = in(32); val correct = outBool()
  val d = Module(new Decoder); d.inst := inst
  val op = d.dec.asTypeOf(new Decoded).op
  correct := (InstructionClass.memory(inst) === (op === LOAD || op === STORE)) &&
    (InstructionClass.branch(inst) === isBranch(op)) && (InstructionClass.mdu(inst) === isMdu(op))
}

class Decoder extends Logic {
  override def desiredName = "decoder"
  keepHierarchy()
  val inst = in(32); val dec = out((new Decoded).getWidth)
  val opcode = inst(6, 0); val f3 = inst(14, 12); val f7 = inst(31, 25)
  val lui = opcode === "h37".U; val auipc = opcode === "h17".U
  val jal = opcode === "h6f".U; val jalr = opcode === "h67".U
  val branch = opcode === "h63".U; val load = opcode === "h03".U
  val store = opcode === "h23".U; val immediate = opcode === "h13".U
  val register = opcode === "h33".U
  val known = lui || auipc || jal || jalr || branch || load || store || immediate || register
  val shift = f3 === 1.U || f3 === 5.U
  val arithmeticImmediate = DecodeTable(f3, Seq(0.U -> ADD, 2.U -> SLT, 3.U -> SLTU, 4.U -> XOR,
    6.U -> OR, 7.U -> AND, 1.U -> SLL, 5.U -> Mux(inst(30), SRA, SRL)))
  val arithmeticRegister = DecodeTable(f3, Seq(0.U -> Mux(inst(30), SUB, ADD), 1.U -> SLL, 2.U -> SLT,
    3.U -> SLTU, 4.U -> XOR, 5.U -> Mux(inst(30), SRA, SRL), 6.U -> OR, 7.U -> AND))
  val multiplyDivide = DecodeTable(f3, Seq(0.U -> MUL, 1.U -> MULH, 2.U -> MULHSU, 3.U -> MULHU,
    4.U -> DIV, 5.U -> DIVU, 6.U -> REM, 7.U -> REMU))
  val branchOperation = DecodeTable(f3, Seq(0.U -> BEQ, 1.U -> BNE, 4.U -> BLT,
    5.U -> BGE, 6.U -> BLTU, 7.U -> BGEU))
  val badRegister = f7 =/= 1.U && f7 =/= 0.U && !(f7 === "h20".U && (f3 === 0.U || f3 === 5.U))
  val badImmediate = (f3 === 1.U && f7 =/= 0.U) || (f3 === 5.U && f7 =/= 0.U && f7 =/= "h20".U)
  val illegal = !known || (jalr && f3 =/= 0.U) || (branch && (f3 === 2.U || f3 === 3.U)) ||
    (load && !(f3 === 0.U || f3 === 1.U || f3 === 2.U || f3 === 4.U || f3 === 5.U)) ||
    (store && f3 > 2.U) || (immediate && badImmediate) || (register && badRegister)
  val d = Wire(new Decoded)
  // These opcode arms are mutually exclusive, exactly like the reference
  // case statement. Keep opcode priority out of both payload and permission.
  d.op := Mux1H(Seq(lui -> LUI, auipc -> AUIPC, jal -> JAL, jalr -> JALR,
    branch -> branchOperation, load -> LOAD, store -> STORE, immediate -> arithmeticImmediate,
    register -> Mux(f7 === 1.U, multiplyDivide, arithmeticRegister)))
  d.rs1 := inst(19, 15); d.rs2 := inst(24, 20); d.rd := inst(11, 7)
  d.uses_rs1 := !illegal && (jalr || branch || load || store || immediate || register)
  d.uses_rs2 := !illegal && (branch || store || register)
  d.writes_rd := !illegal && inst(11, 7) =/= 0.U && (lui || auipc || jal || jalr || load || immediate || register)
  d.use_imm := !illegal && (jalr || load || store || immediate)
  d.imm := Mux1H(Seq(
    (lui || auipc) -> Cat(inst(31, 12), 0.U(12.W)),
    jal -> sext(Cat(inst(31), inst(19, 12), inst(20), inst(30, 21), 0.U(1.W))),
    branch -> sext(Cat(inst(31), inst(7), inst(30, 25), inst(11, 8), 0.U(1.W))),
    store -> sext(Cat(inst(31, 25), inst(11, 7))),
    (jalr || load || (immediate && !shift)) -> sext(inst(31, 20)),
    (immediate && shift) -> inst(24, 20).pad(32)))
  d.mem_size := Mux(load || store, inst(13, 12), 0.U(2.W))
  d.load_signed := load && !inst(14); d.illegal := illegal
  dec := d.asUInt
}

class Alu extends Logic {
  override def desiredName = "alu"
  val op = in(6); val a = in(32); val b = in(32); val pc = in(32); val imm = in(32); val result = out(32)
  val subtract = op === SUB || op === SLT || op === SLTU
  val (arithmeticValue, noBorrow) = PrefixAdder(a, b ^ Fill(32, subtract), subtract)
  val pcValue = PrefixAdder(pc, imm)._1
  result := DecodeTable(op, Seq(
    ADD -> arithmeticValue, SUB -> arithmeticValue, SLL -> (a << b(4, 0))(31, 0),
    SLT -> Cat(0.U(31.W), Mux(a(31) =/= b(31), a(31), !noBorrow)),
    SLTU -> Cat(0.U(31.W), !noBorrow), XOR -> (a ^ b), SRL -> (a >> b(4, 0)),
    SRA -> (a.asSInt >> b(4, 0)).asUInt, OR -> (a | b), AND -> (a & b), LUI -> imm, AUIPC -> pcValue))
}
class BranchUnit extends Logic {
  override def desiredName = "branch_unit"
  val op = in(6); val a = in(32); val b = in(32); val pc = in(32); val imm = in(32)
  val result = out(32); val next_pc = out(32); val taken = outBool(); val misaligned = outBool()
  result := pc + 4.U
  val target = Mux(op === JALR, (a + imm) & "hfffffffe".U(32.W), pc + imm)
  taken := DecodeTable(op, Seq(JAL -> true.B, JALR -> true.B, BEQ -> (a === b), BNE -> (a =/= b),
    BLT -> (a.asSInt < b.asSInt), BGE -> (a.asSInt >= b.asSInt), BLTU -> (a < b), BGEU -> (a >= b)))
  next_pc := Mux(taken, target, result); misaligned := taken && target(1, 0) =/= 0.U
}
