package tier3

import chisel3._
import chisel3.util._
import chisel3.experimental.{annotate, ChiselAnnotation}

/** Parameters of the final ROB32 Verilog implementation (d134aa1).
  * The Scala implementation retains synchronous reset, register enables and
  * the original edge of each preparation, execution and recovery operation.
  */
case class Config(
  robEntries: Int = 32, iqEntries: Int = 4, loadSlots: Int = 8, storeSlots: Int = 16,
  checkpoints: Int = 3, renameWidth: Int = 2, commitWidth: Int = 2, integerPorts: Int = 2,
  issueWidth: Int = 3, prfEntries: Int = 32, icacheWays: Int = 1, dcacheWays: Int = 2,
  icacheBytes: Int = 1024, dcacheBytes: Int = 2048, dcacheLineBytes: Int = 64,
  dMshrs: Int = 4, fetchQueueEntries: Int = 8, bhtEntries: Int = 256,
  btbEntries: Int = 32, localHistoryBits: Int = 1, historyEntries: Int = 64,
  maxMemOutstanding: Int = 16, ramBytes: Int = 268435456,
  controlTree: Boolean = true, robWriteTree: Boolean = true, cacheTree: Boolean = true,
  commitTree: Boolean = true, registerRedirect: Boolean = true
) {
  require(robEntries >= 4 && robEntries <= 256 && isPow2(robEntries), "ROB must be a power of two in 4..256 (MDU tags are 8 bits)")
  require(prfEntries >= 4 && prfEntries <= 256 && isPow2(prfEntries), "Speculative PRF must be a power of two in 4..256")
  require(iqEntries >= 2 && isPow2(iqEntries))
  require(loadSlots >= 2 && isPow2(loadSlots))
  require(storeSlots >= 2 && isPow2(storeSlots))
  require(checkpoints >= 2 && checkpoints <= robEntries)
  require(Set(1, 2)(renameWidth) && Set(1, 2)(commitWidth) && Set(1, 2)(integerPorts))
  require(issueWidth >= 1 && issueWidth <= integerPorts + 1, "Issue width counts both integer ports and the LSU")
  require(Set(1, 2, 4)(icacheWays) && Set(1, 2, 4)(dcacheWays))
  require(isPow2(icacheBytes) && icacheBytes >= 64 * icacheWays)
  require(isPow2(dcacheLineBytes) && dcacheLineBytes >= 16)
  require(isPow2(dcacheBytes) && dcacheBytes >= (4 max (2 * dcacheWays)) * dcacheLineBytes)
  require(isPow2(dMshrs) && dMshrs >= 2 && isPow2(maxMemOutstanding) && maxMemOutstanding >= 2)
  require(isPow2(fetchQueueEntries) && fetchQueueEntries >= 2)
  require(isPow2(bhtEntries) && bhtEntries >= 2 && isPow2(btbEntries) && btbEntries >= 2)
  require(isPow2(historyEntries) && historyEntries >= 2 && localHistoryBits >= 0 && localHistoryBits < log2Ceil(bhtEntries))
  require(ramBytes == 268435456, "The course top-level memory map is 256 MiB")
  val rw = log2Ceil(robEntries); val qw = log2Ceil(iqEntries)
  val lt = log2Ceil(loadSlots); val st = log2Ceil(storeSlots)
  val cpw = log2Ceil(checkpoints); val hb = localHistoryBits max 1
}

abstract class Logic extends RawModule {
  protected def in(n: Int): UInt = IO(Input(UInt(n.W)))
  protected def out(n: Int): UInt = IO(Output(UInt(n.W)))
  protected def inBool(): Bool = IO(Input(Bool()))
  protected def outBool(): Bool = IO(Output(Bool()))
  protected def keepHierarchy(keepInstances: Boolean = false): Unit = {
    val owner = this
    annotate(new ChiselAnnotation {
      override def toFirrtl: firrtl.annotations.Annotation =
        firrtl.AttributeAnnotation(owner.toTarget,
          if (keepInstances) "keep_hierarchy = 1, keep = 1" else "keep_hierarchy = 1")
    })
  }
}

abstract class ClockedLogic extends Logic {
  val clk = IO(Input(Clock()))
  val rst = inBool()
  protected def reg(n: Int): UInt = withClock(clk) { Reg(UInt(n.W)) }
  protected def flag(): Bool = withClock(clk) { Reg(Bool()) }
  protected def regs(n: Int, width: Int): Vec[UInt] = withClock(clk) { Reg(Vec(n, UInt(width.W))) }
  protected def flags(n: Int): Vec[Bool] = withClock(clk) { Reg(Vec(n, Bool())) }
  protected def connectClock(m: ClockedLogic): Unit = { m.clk := clk; m.rst := rst }
}

object Bits {
  def pack(xs: Iterable[UInt]): UInt = Cat(xs.toSeq.reverse)
  def word(x: UInt, index: Int, width: Int): UInt = x((index + 1) * width - 1, index * width)
  def mask(x: UInt, enable: Bool): UInt = x & Fill(x.getWidth, enable)
  def orTree(xs: Seq[UInt]): UInt = {
    require(xs.nonEmpty)
    if (xs.size == 1) xs.head else {
      val (a, b) = xs.splitAt(xs.size / 2)
      orTree(a) | orTree(b)
    }
  }
  def sext(x: UInt, width: Int = 32): UInt = Cat(Fill(width - x.getWidth, x(x.getWidth - 1)), x)
}

object ISA {
  val ADD = 0.U(6.W)
  val SUB = 1.U(6.W)
  val SLL = 2.U(6.W)
  val SLT = 3.U(6.W)
  val SLTU = 4.U(6.W)
  val XOR = 5.U(6.W)
  val SRL = 6.U(6.W)
  val SRA = 7.U(6.W)
  val OR = 8.U(6.W)
  val AND = 9.U(6.W)
  val LUI = 10.U(6.W)
  val AUIPC = 11.U(6.W)
  val JAL = 12.U(6.W)
  val JALR = 13.U(6.W)
  val BEQ = 14.U(6.W)
  val BNE = 15.U(6.W)
  val BLT = 16.U(6.W)
  val BGE = 17.U(6.W)
  val BLTU = 18.U(6.W)
  val BGEU = 19.U(6.W)
  val LOAD = 20.U(6.W)
  val STORE = 21.U(6.W)
  val MUL = 22.U(6.W)
  val MULH = 23.U(6.W)
  val MULHSU = 24.U(6.W)
  val MULHU = 25.U(6.W)
  val DIV = 26.U(6.W)
  val DIVU = 27.U(6.W)
  val REM = 28.U(6.W)
  val REMU = 29.U(6.W)
  val NONE = 0.U(4.W); val ILLEGAL = 1.U(4.W)
  val FETCH_ALIGN = 2.U(4.W); val FETCH_RANGE = 3.U(4.W); val FETCH_BUS = 4.U(4.W)
  val TARGET_ALIGN = 5.U(4.W); val LOAD_ALIGN = 6.U(4.W); val LOAD_RANGE = 7.U(4.W)
  val STORE_ALIGN = 8.U(4.W); val STORE_RANGE = 9.U(4.W)
  val LOAD_BUS = 10.U(4.W); val STORE_BUS = 11.U(4.W)
  def isBranch(op: UInt): Bool = op >= JAL && op <= BGEU
  def isMdu(op: UInt): Bool = op >= MUL && op <= REMU
  def isAlu(op: UInt): Bool = op <= AUIPC
}

// Field declaration order matches the packed records in cpu_pkg.sv/cpu_top.sv.
class Decoded extends Bundle {
  val op = UInt(6.W); val rs1 = UInt(5.W); val rs2 = UInt(5.W); val rd = UInt(5.W)
  val uses_rs1 = Bool(); val uses_rs2 = Bool(); val writes_rd = Bool(); val use_imm = Bool()
  val imm = UInt(32.W); val mem_size = UInt(2.W); val load_signed = Bool(); val illegal = Bool()
}
class RobEntry(p: Config) extends Bundle {
  val valid = Bool(); val done = Bool(); val iv = Bool(); val store = Bool(); val exiting = Bool()
  val rd = UInt(5.W); val fault = UInt(4.W); val store_slot = UInt(p.st.W); val mask = UInt(4.W)
  val pc = UInt(32.W); val inst = UInt(32.W); val fault_address = Vec(4, UInt(8.W))
  val address = Vec(4, UInt(8.W)); val wdata = Vec(4, UInt(8.W))
}
class RetireMeta(p: Config) extends Bundle {
  val done = Bool(); val exiting = Bool(); val store = Bool(); val fault = UInt(4.W)
  val rd = UInt(5.W); val store_slot = UInt(p.st.W)
}
class IssueEntry(p: Config) extends Bundle {
  val valid = Bool(); val ready_a = Bool(); val ready_b = Bool(); val use_imm = Bool()
  val sign_extend = Bool(); val generation = Bool()
  val rid = UInt(p.rw.W); val source_a = UInt(p.rw.W); val source_b = UInt(p.rw.W)
  val op = UInt(6.W); val pc = UInt(30.W); val prediction = UInt(30.W)
  val history = UInt(p.hb.W); val size = UInt(2.W); val checkpoint = UInt(p.cpw.W)
  val a = UInt(32.W); val b = UInt(32.W); val imm = UInt(32.W)
}
class StoreEntry(p: Config) extends Bundle {
  val valid = Bool(); val committed = Bool(); val issued = Bool(); val done = Bool()
  val rid = UInt(p.rw.W); val mask = UInt(4.W)
  val address = UInt(32.W); val data = UInt(32.W); val pc = UInt(32.W); val inst = UInt(32.W)
}
class LoadEntry(p: Config) extends Bundle {
  val valid = Bool(); val canceled = Bool(); val sign_extend = Bool()
  val rid = UInt(p.rw.W); val size = UInt(2.W); val address = UInt(32.W)
}
