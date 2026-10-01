package cpu2026

import chisel3._
import chisel3.util._

object AluOp {
  val ADD = 0.U(4.W); val SUB = 1.U(4.W)
  val SLT = 2.U(4.W); val SLTU = 3.U(4.W)
  val XOR = 4.U(4.W); val OR = 5.U(4.W); val AND = 6.U(4.W)
  val SLL = 7.U(4.W); val SRL = 8.U(4.W); val SRA = 9.U(4.W)
  val COPY_B = 10.U(4.W)
}

object BranchOp {
  val NONE = 0.U(4.W); val BEQ = 1.U(4.W); val BNE = 2.U(4.W)
  val BLT = 3.U(4.W); val BGE = 4.U(4.W)
  val BLTU = 5.U(4.W); val BGEU = 6.U(4.W)
  val JAL = 7.U(4.W); val JALR = 8.U(4.W)
}

object AccessSize {
  val BYTE = 0.U(2.W); val HALF = 1.U(2.W); val WORD = 2.U(2.W)
}

class IntegerAlu extends Module {
  val io = IO(new Bundle {
    val a = Input(UInt(32.W)); val b = Input(UInt(32.W)); val op = Input(UInt(4.W))
    val result = Output(UInt(32.W)); val equal = Output(Bool())
    val lessSigned = Output(Bool()); val lessUnsigned = Output(Bool())
  })
  io.equal := io.a === io.b
  io.lessSigned := io.a.asSInt < io.b.asSInt
  io.lessUnsigned := io.a < io.b
  io.result := 0.U
  switch(io.op) {
    is(AluOp.ADD) { io.result := io.a + io.b }
    is(AluOp.SUB) { io.result := io.a - io.b }
    is(AluOp.SLT) { io.result := io.lessSigned }
    is(AluOp.SLTU) { io.result := io.lessUnsigned }
    is(AluOp.XOR) { io.result := io.a ^ io.b }
    is(AluOp.OR) { io.result := io.a | io.b }
    is(AluOp.AND) { io.result := io.a & io.b }
    is(AluOp.SLL) { io.result := io.a << io.b(4, 0) }
    is(AluOp.SRL) { io.result := io.a >> io.b(4, 0) }
    is(AluOp.SRA) { io.result := (io.a.asSInt >> io.b(4, 0)).asUInt }
    is(AluOp.COPY_B) { io.result := io.b }
  }
}

class BranchUnit extends Module {
  val io = IO(new Bundle {
    val pc = Input(UInt(32.W)); val a = Input(UInt(32.W)); val b = Input(UInt(32.W))
    val offset = Input(UInt(32.W)); val op = Input(UInt(4.W))
    val taken = Output(Bool()); val nextPc = Output(UInt(32.W))
    val link = Output(UInt(32.W)); val targetMisaligned = Output(Bool())
  })
  io.link := io.pc + 4.U
  io.taken := false.B
  switch(io.op) {
    is(BranchOp.BEQ) { io.taken := io.a === io.b }
    is(BranchOp.BNE) { io.taken := io.a =/= io.b }
    is(BranchOp.BLT) { io.taken := io.a.asSInt < io.b.asSInt }
    is(BranchOp.BGE) { io.taken := io.a.asSInt >= io.b.asSInt }
    is(BranchOp.BLTU) { io.taken := io.a < io.b }
    is(BranchOp.BGEU) { io.taken := io.a >= io.b }
    is(BranchOp.JAL, BranchOp.JALR) { io.taken := true.B }
  }
  val rawTarget = Mux(io.op === BranchOp.JALR, io.a + io.offset, io.pc + io.offset)
  val target = Mux(io.op === BranchOp.JALR, rawTarget & "hfffffffe".U, rawTarget)
  io.nextPc := Mux(io.taken, target, io.link)
  io.targetMisaligned := io.taken && target(1, 0) =/= 0.U
}

class AddressGenerator extends Module {
  val io = IO(new Bundle {
    val base = Input(UInt(32.W)); val offset = Input(UInt(32.W))
    val storeData = Input(UInt(32.W)); val size = Input(UInt(2.W))
    val address = Output(UInt(32.W)); val wordAddress = Output(UInt(32.W))
    val byteLane = Output(UInt(2.W)); val writeMask = Output(UInt(4.W))
    val shiftedStoreData = Output(UInt(32.W)); val misaligned = Output(Bool())
    val sizeSupported = Output(Bool())
  })
  io.address := io.base + io.offset
  io.wordAddress := io.address & "hfffffffc".U
  io.byteLane := io.address(1, 0)
  io.shiftedStoreData := io.storeData << Cat(io.byteLane, 0.U(3.W))
  io.writeMask := 0.U; io.misaligned := false.B; io.sizeSupported := io.size =/= 3.U
  switch(io.size) {
    is(AccessSize.BYTE) { io.writeMask := (1.U(4.W) << io.byteLane)(3, 0) }
    is(AccessSize.HALF) {
      io.writeMask := (3.U(4.W) << io.byteLane)(3, 0); io.misaligned := io.byteLane(0)
    }
    is(AccessSize.WORD) { io.writeMask := 15.U; io.misaligned := io.byteLane =/= 0.U }
  }
}
