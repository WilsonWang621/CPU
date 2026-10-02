package tier2
import chisel3._
import chisel3.util._

class Decoded extends Bundle {
  val rd = UInt(5.W); val rs1 = UInt(5.W); val rs2 = UInt(5.W)
  val use1 = Bool(); val use2 = Bool(); val writes = Bool()
  val imm = UInt(32.W); val fn = UInt(3.W); val sub = Bool()
  val pcA = Bool(); val immB = Bool(); val lui = Bool()
  val branch = Bool(); val jal = Bool(); val jalr = Bool()
  val load = Bool(); val store = Bool(); val muldiv = Bool(); val illegal = Bool()
}
class Decoder extends Module {
  val io = IO(new Bundle { val inst = Input(UInt(32.W)); val d = Output(new Decoded) })
  val x = io.inst; val op = x(6,0); val d = io.d
  d := 0.U.asTypeOf(d)
  d.rd := x(11,7); d.rs1 := x(19,15); d.rs2 := x(24,20); d.fn := x(14,12)
  d.imm := Util.sext(x(31,20)); d.illegal := true.B
  switch(op) {
    is("h37".U) { d.lui := true.B; d.imm := Cat(x(31,12), 0.U(12.W)); d.writes := true.B; d.illegal := false.B }
    is("h17".U) { d.pcA := true.B; d.immB := true.B; d.fn := 0.U; d.imm := Cat(x(31,12), 0.U(12.W)); d.writes := true.B; d.illegal := false.B }
    is("h6f".U) { d.jal := true.B; d.imm := Util.sext(Cat(x(31),x(19,12),x(20),x(30,21),0.U(1.W))); d.writes := true.B; d.illegal := false.B }
    is("h67".U) { d.jalr := true.B; d.use1 := true.B; d.writes := true.B; d.illegal := x(14,12) =/= 0.U }
    is("h63".U) { d.branch := true.B; d.use1 := true.B; d.use2 := true.B; d.imm := Util.sext(Cat(x(31),x(7),x(30,25),x(11,8),0.U(1.W))); d.illegal := x(14,13) === 1.U }
    is("h03".U) { d.load := true.B; d.use1 := true.B; d.writes := true.B; d.illegal := x(14,12) === 3.U || x(14,12) >= 6.U }
    is("h23".U) { d.store := true.B; d.use1 := true.B; d.use2 := true.B; d.imm := Util.sext(Cat(x(31,25),x(11,7))); d.illegal := x(14,12) > 2.U }
    is("h13".U) { d.use1 := true.B; d.immB := true.B; d.writes := true.B; d.sub := x(30) && x(14,12) === 5.U; d.illegal := false.B }
    is("h33".U) { d.use1 := true.B; d.use2 := true.B; d.writes := true.B; d.sub := x(30); d.muldiv := x(31,25) === 1.U; d.illegal := false.B }
    is("h0f".U) { d.illegal := false.B }
  }
}

class Execute extends Module {
  val io = IO(new Bundle {
    val d = Input(new Decoded); val pc = Input(UInt(32.W)); val a = Input(UInt(32.W)); val b = Input(UInt(32.W))
    val result = Output(UInt(32.W)); val next = Output(UInt(32.W)); val taken = Output(Bool()); val addr = Output(UInt(32.W))
  })
  val d = io.d; val a = Mux(d.pcA,io.pc,io.a); val b = Mux(d.immB,d.imm,io.b)
  val add = Util.addCarry(a,Mux(d.sub,~b,b),d.sub)
  val signedLess = io.a.asSInt < io.b.asSInt
  val unsignedLess = io.a < io.b
  val right = (Cat(d.sub && a(31),a).asSInt >> b(4,0)).asUInt
  val alu = MuxLookup(d.fn, add)(Seq(
    1.U -> (a << b(4,0))(31,0), 2.U -> (a.asSInt < b.asSInt).asUInt,
    3.U -> (a < b).asUInt, 4.U -> (a ^ b), 5.U -> right(31,0), 6.U -> (a | b), 7.U -> (a & b)))
  io.result := Mux(d.jal || d.jalr,io.pc + 4.U,Mux(d.lui,d.imm,alu))
  val cond = MuxLookup(d.fn, false.B)(Seq(0.U -> (io.a === io.b),1.U -> (io.a =/= io.b),
    4.U -> signedLess,5.U -> !signedLess,6.U -> unsignedLess,7.U -> !unsignedLess))
  io.taken := d.jal || d.jalr || (d.branch && cond)
  io.addr := Util.add(io.a,d.imm)
  io.next := Mux(io.taken, Mux(d.jalr,Cat(io.addr(31,1),0.U(1.W)),Util.add(io.pc,d.imm)),io.pc + 4.U)
}
