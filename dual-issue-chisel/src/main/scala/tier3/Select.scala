package tier3

import chisel3._
import chisel3.util._
import tier3.Bits._

class OrderCompare(bits: Int = 6) extends Logic {
  override def desiredName = "v2_order_compare"
  keepHierarchy()
  val a = in(bits); val b = in(bits); val first = outBool()
  val difference = a - b
  first := difference(bits - 1) || a === b
}
class Select(entries: Int = 8, slotBits: Int = 5, youngest: Boolean = false, extendedOrder: Boolean = false) extends Logic {
  override def desiredName = "v2_select"
  val iw = log2Ceil(entries); val leaves = 1 << log2Ceil(entries)
  val ready = in(entries); val owner = in(entries * slotBits); val rob_head = in(slotBits)
  val valid = outBool(); val index = out(iw)
  case class Node(position: UInt, wrapped: Bool, selected: UInt, winner: Bool)
  def node(n: Int): Node = {
    if (n >= leaves) {
      val i = n - leaves
      val pos = if (i < entries) word(owner, i, slotBits) else 0.U(slotBits.W)
      Node(pos, if (extendedOrder || i >= entries) false.B else pos < rob_head,
        (i % (1 << iw)).U(iw.W), if (i < entries) ready(i) else false.B)
    } else {
      val left = node(2 * n); val right = node(2 * n + 1)
      val sameSide = left.wrapped === right.wrapped
      val difference = left.position - right.position
      val leftFirst = if (extendedOrder) {
        if (youngest) !difference(slotBits - 1) else difference(slotBits - 1) || difference === 0.U
      } else if (youngest) Mux(sameSide, left.position >= right.position, left.wrapped)
      else Mux(sameSide, left.position <= right.position, !left.wrapped)
      val leftWins = left.winner && (!right.winner || leftFirst)
      Node(Mux(leftWins, left.position, right.position), Mux(leftWins, left.wrapped, right.wrapped),
        Mux(leftWins, left.selected, right.selected), left.winner || right.winner)
    }
  }
  val root = node(1); valid := root.winner; index := root.selected
}
class ParallelSelect(entries: Int = 4, slotBits: Int = 6) extends Logic {
  override def desiredName = "v2_parallel_select"
  val iw = log2Ceil(entries)
  val ready = in(entries); val owner = in(entries * slotBits); val rob_head = in(slotBits)
  val valid = outBool(); val index = out(iw); val grant = out(entries)
  val comparisons = (for (a <- 0 until entries; b <- a + 1 until entries) yield {
    val m = Module(new OrderCompare(slotBits)); m.a := word(owner, a, slotBits); m.b := word(owner, b, slotBits)
    (a, b) -> m.first
  }).toMap
  val grants = (0 until entries).map { r =>
    val blocked = (0 until entries).map { o =>
      val first = if (r == o) true.B else if (r < o) comparisons((r, o)) else !comparisons((o, r))
      ready(o) && !first
    }
    ready(r) && !blocked.reduce(_ || _)
  }
  grant := VecInit(grants).asUInt; valid := ready.orR
  index := grants.zipWithIndex.map { case (e, i) => mask(i.U(iw.W), e) }.reduce(_ | _)
}
class CircularGrant(entries: Int = 16) extends Logic {
  override def desiredName = "v2_circular_grant"
  val iw = log2Ceil(entries)
  val ready = in(entries); val head = in(iw); val valid = outBool(); val index = out(iw); val grant = out(entries)
  val wrapped = VecInit((0 until entries).map(q => ready(q) && q.U(iw.W) < head)).asUInt
  val anyWrapped = wrapped.orR
  val grants = (0 until entries).map { q =>
    val highestWrapped = if (q == entries - 1) wrapped(q) else wrapped(q) && !wrapped(entries - 1, q + 1).orR
    val highestAny = if (q == entries - 1) ready(q) else ready(q) && !ready(entries - 1, q + 1).orR
    highestWrapped || (!anyWrapped && highestAny)
  }
  grant := VecInit(grants).asUInt; valid := ready.orR
  index := grants.zipWithIndex.map { case (e, i) => mask(i.U(iw.W), e) }.reduce(_ | _)
}
