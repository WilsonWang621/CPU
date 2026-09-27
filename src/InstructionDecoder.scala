package cpu2026

import chisel3._
import chisel3.util._

object DecodeFu {
  val ALU = 0.U(2.W)
  val BRANCH = 1.U(2.W)
  val MEMORY = 2.U(2.W)
  val MDU = 3.U(2.W)
}

/** Local leaf result; the frontend will wrap this in the agreed DecodedPacket. */
class DecodedInstruction extends Bundle {
  val rs1 = UInt(5.W)
  val rs2 = UInt(5.W)
  val rd = UInt(5.W)
  val usesRs1 = Bool()
  val usesRs2 = Bool()
  val writesRd = Bool()
  val immediate = UInt(32.W)
  val fu = UInt(2.W)
  val aluOp = UInt(4.W)
  val branchOp = UInt(4.W)
  val mduOp = UInt(3.W) // RV32M funct3: MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU
  val operandAIsPc = Bool()
  val operandBIsImmediate = Bool()
  val isStore = Bool()
  val accessSize = UInt(2.W)
  val loadUnsigned = Bool()
  val decodeError = Bool()
}

/** Combinational RV32IM decoder. Unsupported/reserved encodings have no effects. */
class InstructionDecoder extends Module {
  val io = IO(new Bundle {
    val instruction = Input(UInt(32.W))
    val decoded = Output(new DecodedInstruction)
  })
  val inst = io.instruction
  val opcode = inst(6, 0)
  val funct3 = inst(14, 12)
  val funct7 = inst(31, 25)
  val d = WireDefault(0.U.asTypeOf(new DecodedInstruction))
  val legal = WireDefault(false.B)
  val immI = Cat(Fill(20, inst(31)), inst(31, 20))
  val immS = Cat(Fill(20, inst(31)), inst(31, 25), inst(11, 7))
  val immB = Cat(Fill(19, inst(31)), inst(31), inst(7), inst(30, 25), inst(11, 8), 0.U(1.W))
  val immJ = Cat(Fill(11, inst(31)), inst(31), inst(19, 12), inst(20), inst(30, 21), 0.U(1.W))
  d.rs1 := inst(19, 15)
  d.rs2 := inst(24, 20)
  d.rd := inst(11, 7)

  switch(opcode) {
    is("h37".U, "h17".U) { // LUI / AUIPC
      legal := true.B
      d.writesRd := true.B
      d.immediate := Cat(inst(31, 12), 0.U(12.W))
      d.operandBIsImmediate := true.B
      d.operandAIsPc := opcode === "h17".U
      d.aluOp := Mux(opcode === "h37".U, AluOp.COPY_B, AluOp.ADD)
    }
    is("h13".U, "h33".U) {
      val immediate = opcode === "h13".U
      d.usesRs1 := true.B
      d.usesRs2 := !immediate
      d.writesRd := true.B
      d.operandBIsImmediate := immediate
      d.immediate := Mux(immediate, immI, 0.U)
      val aluOps = VecInit(AluOp.ADD, AluOp.SLL, AluOp.SLT, AluOp.SLTU,
        AluOp.XOR, AluOp.SRL, AluOp.OR, AluOp.AND)
      d.aluOp := aluOps(funct3)
      when(immediate) {
        legal := true.B
        when(funct3 === 1.U || funct3 === 5.U) {
          legal := funct7 === 0.U || (funct3 === 5.U && funct7 === "h20".U)
          d.immediate := Cat(0.U(27.W), inst(24, 20))
        }
        when(funct3 === 5.U && funct7 === "h20".U) { d.aluOp := AluOp.SRA }
      }.otherwise {
        legal := funct7 === 0.U || (funct7 === "h20".U && (funct3 === 0.U || funct3 === 5.U))
        when(funct7 === "h20".U) {
          d.aluOp := Mux(funct3 === 0.U, AluOp.SUB, AluOp.SRA)
        }
        when(funct7 === 1.U) {
          legal := true.B
          d.fu := DecodeFu.MDU
          d.aluOp := AluOp.ADD
          d.mduOp := funct3
        }
      }
    }
    is("h63".U) {
      d.fu := DecodeFu.BRANCH
      d.usesRs1 := true.B
      d.usesRs2 := true.B
      d.immediate := immB
      for ((code, op) <- Seq(0 -> BranchOp.BEQ, 1 -> BranchOp.BNE,
        4 -> BranchOp.BLT, 5 -> BranchOp.BGE, 6 -> BranchOp.BLTU, 7 -> BranchOp.BGEU)) {
        when(funct3 === code.U) { legal := true.B; d.branchOp := op }
      }
    }
    is("h6f".U, "h67".U) {
      val jalr = opcode === "h67".U
      legal := !jalr || funct3 === 0.U
      d.fu := DecodeFu.BRANCH
      d.usesRs1 := jalr
      d.writesRd := true.B
      d.immediate := Mux(jalr, immI, immJ)
      d.branchOp := Mux(jalr, BranchOp.JALR, BranchOp.JAL)
    }
    is("h03".U, "h23".U) {
      val store = opcode === "h23".U
      legal := funct3 <= 2.U || (!store && (funct3 === 4.U || funct3 === 5.U))
      d.fu := DecodeFu.MEMORY
      d.usesRs1 := true.B
      d.usesRs2 := store
      d.writesRd := !store
      d.isStore := store
      d.immediate := Mux(store, immS, immI)
      d.accessSize := funct3(1, 0)
      d.loadUnsigned := !store && funct3(2)
    }
  }
  // Keep raw register slices for tracing, but never advertise effects on errors.
  d.decodeError := !legal
  when(!legal) {
    d.usesRs1 := false.B
    d.usesRs2 := false.B
    d.writesRd := false.B
    d.isStore := false.B
  }
  when(d.rd === 0.U) { d.writesRd := false.B }
  io.decoded := d
}
