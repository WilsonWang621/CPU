package tier3

import chisel3._
import chisel3.util._
import tier3.Bits._

/** Native Chisel equivalents of the preserved local Verilog modules.
  * No external RTL, BlackBox, SRAM substitution, or extra register is used.
  */
class DistributionInverter(width: Int) extends Logic {
  override def desiredName = "v2_distribution_inverter"
  // Yosys treats a module's keep attribute as keep on each of its instances.
  // This preserves the same four inverter banks per fork as the reference.
  keepHierarchy(keepInstances = true)
  val data_in = in(width); val data_out = out(width)
  data_out := ~data_in
}
class Distribution(width: Int, leaves: Int) extends Logic {
  override def desiredName = "v2_distribution"
  require(width > 0 && leaves > 0)
  val data_in = in(width); val data_out = out(width * leaves)
  if (leaves == 1) data_out := data_in else {
    def fork(count: Int): UInt = {
      val first = Module(new DistributionInverter(width))
      val second = Module(new DistributionInverter(width))
      first.data_in := data_in; second.data_in := first.data_out
      val tree = Module(new Distribution(width, count)); tree.data_in := second.data_out
      tree.data_out
    }
    val left = fork(leaves / 2); val right = fork(leaves - leaves / 2)
    data_out := Cat(right, left)
  }
}
object Distribution {
  def apply(data: UInt, leaves: Int): Seq[UInt] = {
    val m = Module(new Distribution(data.getWidth, leaves)); m.data_in := data
    (0 until leaves).map(i => word(m.data_out, i, data.getWidth))
  }
}
class PrefixNode extends Logic {
  override def desiredName = "v2_prefix_node"
  keepHierarchy()
  val high_g = inBool(); val high_p = inBool(); val low_g = inBool(); val low_p = inBool()
  val group_g = outBool(); val group_p = outBool()
  group_g := high_g | (high_p & low_g); group_p := high_p & low_p
}
class PrefixAdder(width: Int = 32) extends Logic {
  override def desiredName = "v2_prefix_adder"
  require(width >= 1)
  keepHierarchy()
  val a = in(width); val b = in(width); val carry_in = inBool()
  val sum = out(width); val carry_out = outBool()
  val bitPropagates = a ^ b
  val initialG = VecInit((0 until width).map(i =>
    if (i == 0) (a(i) & b(i)) | (bitPropagates(i) & carry_in) else a(i) & b(i))).asUInt
  val stages = (0 until log2Ceil(width)).foldLeft((initialG, bitPropagates)) {
    case ((g, p), level) =>
      val nodes = (0 until width).map { i =>
        if (i < (1 << level)) (g(i), p(i)) else {
          val node = Module(new PrefixNode)
          node.high_g := g(i); node.high_p := p(i)
          node.low_g := g(i - (1 << level)); node.low_p := p(i - (1 << level))
          (node.group_g, node.group_p)
        }
      }
      (VecInit(nodes.map(_._1)).asUInt, VecInit(nodes.map(_._2)).asUInt)
  }
  sum := VecInit((0 until width).map(i => bitPropagates(i) ^ (if (i == 0) carry_in else stages._1(i - 1)))).asUInt
  carry_out := stages._1(width - 1)
}
object PrefixAdder {
  def apply(a: UInt, b: UInt, carry: Bool = false.B): (UInt, Bool) = {
    require(a.getWidth == b.getWidth)
    val m = Module(new PrefixAdder(a.getWidth)); m.a := a; m.b := b; m.carry_in := carry
    (m.sum, m.carry_out)
  }
}
class IncrementJoin extends Logic {
  override def desiredName = "v2_inc_join"
  keepHierarchy()
  val a = inBool(); val b = inBool(); val value = outBool()
  value := a & b
}
class Increment(bits: Int = 30) extends Logic {
  override def desiredName = "v2_increment"
  val value = in(bits); val result = out(bits)
  val prefix = (0 until log2Ceil(bits)).foldLeft(value) { (prior, level) =>
    VecInit((0 until bits).map { i =>
      if (i < (1 << level)) prior(i) else {
        val m = Module(new IncrementJoin); m.a := prior(i); m.b := prior(i - (1 << level)); m.value
      }
    }).asUInt
  }
  result := VecInit((0 until bits).map(i => if (i == 0) !value(0) else value(i) ^ prefix(i - 1))).asUInt
}
class ReadMask(wordBits: Int = 32) extends Logic {
  override def desiredName = "v2_read_mask"
  keepHierarchy()
  val selected = inBool(); val word = in(wordBits); val value = out(wordBits)
  value := mask(word, selected)
}
object ReadMask {
  def apply(data: UInt, selected: Bool): UInt = {
    val m = Module(new ReadMask(data.getWidth)); m.word := data; m.selected := selected; m.value
  }
}
class Read(entries: Int, wordBits: Int = 32, indexBits: Int = 0, indexGroup: Int = 0) extends Logic {
  override def desiredName = "v2_read"
  val iw = if (indexBits > 0) indexBits else log2Ceil(entries)
  val index = in(iw); val words = in(entries * wordBits); val value = out(wordBits)
  val groupSize = if (indexGroup > 0) indexGroup else entries
  val localIndices = Distribution(index, (entries + groupSize - 1) / groupSize)
  val leaves = 1 << log2Ceil(entries)
  value := orTree((0 until leaves).map { i =>
    if (i < entries) ReadMask(word(words, i, wordBits), localIndices(i / groupSize) === i.U(iw.W))
    else 0.U(wordBits.W)
  })
}
object Read {
  def apply(words: Seq[UInt], index: UInt, indexGroup: Int = 0): UInt = {
    val m = Module(new Read(words.size, words.head.getWidth, index.getWidth, indexGroup))
    m.index := index; m.words := pack(words); m.value
  }
}
class IQRead(entries: Int, wordBits: Int = 32, indexBits: Int = 0) extends Logic {
  override def desiredName = "v2_iq_read"
  keepHierarchy()
  val iw = if (indexBits > 0) indexBits else log2Ceil(entries)
  val index = in(iw); val words = in(entries * wordBits); val value = out(wordBits)
  val m = Module(new Read(entries, wordBits, iw)); m.index := index; m.words := words; value := m.value
}
class CacheRead(entries: Int, wordBits: Int = 32, indexBits: Int = 0, indexGroup: Int = 0) extends Logic {
  override def desiredName = "v2_cache_read"
  keepHierarchy()
  val iw = if (indexBits > 0) indexBits else log2Ceil(entries)
  val index = in(iw); val words = in(entries * wordBits); val value = out(wordBits)
  val m = Module(new Read(entries, wordBits, iw, indexGroup))
  m.index := index; m.words := words; value := m.value
}
class GrantRead(entries: Int, wordBits: Int = 32) extends Logic {
  override def desiredName = "v2_grant_read"
  keepHierarchy()
  val grant = in(entries); val words = in(entries * wordBits); val value = out(wordBits)
  val leaves = 1 << log2Ceil(entries)
  value := orTree((0 until leaves).map(i =>
    if (i < entries) ReadMask(word(words, i, wordBits), grant(i)) else 0.U(wordBits.W)))
}
class PriorityMux(wordBits: Int = 32, ports: Int = 3, groupBits: Int = 8) extends Logic {
  override def desiredName = "v2_priority_mux"
  keepHierarchy()
  val enable = in(ports); val old_value = in(wordBits); val data = in(ports * wordBits); val value = out(wordBits)
  val chosen = VecInit((0 until ports).map(p =>
    if (p == ports - 1) enable(p) else enable(p) && !enable(ports - 1, p + 1).orR)).asUInt
  val controls = Distribution(Cat(!enable.orR, chosen), (wordBits + groupBits - 1) / groupBits)
  value := VecInit((0 until wordBits).map { bit =>
    val c = controls(bit / groupBits)
    (old_value(bit) && c(ports)) | (0 until ports).map(p => data(p * wordBits + bit) && c(p)).reduce(_ | _)
  }).asUInt
}
class PriorityRegister(wordBits: Int = 32, ports: Int = 2, groupBits: Int = 8) extends Logic {
  override def desiredName = "v2_priority_register"
  keepHierarchy()
  val clk = IO(Input(Clock())); val clear = inBool()
  val enable = in(ports); val data = in(ports * wordBits); val value = out(wordBits)
  val controls = Distribution(Cat(clear, enable), (wordBits + groupBits - 1) / groupBits)
  val stored = withClock(clk) { Reg(Vec(wordBits, Bool())) }
  for (bit <- 0 until wordBits) {
    val c = controls(bit / groupBits)
    when(c(ports)) { stored(bit) := false.B }.otherwise {
      for (p <- 0 until ports) { when(c(p)) { stored(bit) := data(p * wordBits + bit) } }
    }
  }
  value := stored.asUInt
}
class ArchWord(register: Int, controlTree: Boolean = true) extends ClockedLogic {
  override def desiredName = "v2_arch_word"
  keepHierarchy()
  val commit_valid = in(2); val commit_rd = in(10); val commit_values = in(64); val value = out(32)
  val enables = VecInit((0 until 2).map(c => commit_valid(c) && word(commit_rd, c, 5) === register.U(5.W))).asUInt
  if (controlTree) {
    val m = Module(new PriorityRegister(32, 2)); m.clk := clk; m.clear := rst || (register == 0).B
    m.enable := enables; m.data := commit_values; value := m.value
  } else {
    val stored = reg(32)
    when(rst || (register == 0).B) { stored := 0.U }.otherwise {
      for (c <- 0 until 2) { when(enables(c)) { stored := word(commit_values, c, 32) } }
    }
    value := stored
  }
}
class RetireRead(entries: Int = 32, wordBits: Int = 32, lane: Int = 0, controlTree: Boolean = true) extends ClockedLogic {
  override def desiredName = "v2_retire_read"
  keepHierarchy()
  require(isPow2(entries) && entries >= 4)
  val advance = in(2); val words = in(entries * wordBits); val value = out(wordBits)
  val selected = flags(entries)
  val advances = if (controlTree) Distribution(advance, (entries + 7) / 8) else Seq.fill((entries + 7) / 8)(advance)
  for (r <- 0 until entries) {
    when(rst) { selected(r) := (r == lane).B }.otherwise {
      when(advances(r / 8) === 1.U) { selected(r) := selected((r + entries - 1) % entries) }
      when(advances(r / 8) === 2.U) { selected(r) := selected((r + entries - 2) % entries) }
    }
  }
  value := orTree((0 until entries).map(i => ReadMask(word(words, i, wordBits), selected(i))))
}
class RegisteredGrant(entries: Int, indexBits: Int = 0) extends ClockedLogic {
  override def desiredName = "v2_registered_grant"
  keepHierarchy()
  val iw = if (indexBits > 0) indexBits else log2Ceil(entries)
  val valid = inBool(); val index = in(iw); val grant = out(entries)
  val stored = flags(entries)
  for (i <- 0 until entries) {
    when(rst) { stored(i) := false.B }.otherwise { stored(i) := valid && index === i.U(iw.W) }
  }
  grant := stored.asUInt
}
class Operand(slotBits: Int = 5) extends Logic {
  override def desiredName = "v2_operand"
  keepHierarchy()
  val live = inBool(); val prepare = inBool(); val old_ready = inBool(); val initial_ready = inBool()
  val source = in(slotBits); val old_value = in(32); val initial_value = in(32)
  val wb_good = in(3); val wb_slots = in(3 * slotBits); val wb_values = in(96)
  val next_ready = outBool(); val next_value = out(32)
  val hit = VecInit((0 until 3).map(w => live && !old_ready && wb_good(w) && source === word(wb_slots, w, slotBits))).asUInt
  val chosen = Seq(hit(0) && !hit(2, 1).orR, hit(1) && !hit(2), hit(2))
  val initializing = !live && prepare
  val holding = !(initializing || chosen.reduce(_ || _))
  next_ready := Mux(live, old_ready || hit.orR, Mux(prepare, initial_ready, old_ready))
  next_value := mask(old_value, holding) | mask(initial_value, initializing) |
    chosen.zipWithIndex.map { case (e, w) => mask(word(wb_values, w, 32), e) }.reduce(_ | _)
}
class CacheTagMatch(tagBits: Int = 18, words: Int = 16) extends Logic {
  override def desiredName = "v2_cache_tag_match"
  keepHierarchy()
  val selected = inBool(); val valid = inBool(); val tag = in(tagBits); val request_tag = in(tagBits)
  val word_valid = in(words); val word_index = in(log2Ceil(words)); val match_bits = outBool(); val hit = outBool()
  match_bits := selected && valid && tag === request_tag
  hit := match_bits && word_valid(word_index)
}
class CacheLookup(sets: Int = 16, tagBits: Int = 18, words: Int = 16) extends Logic {
  override def desiredName = "v2_cache_lookup"
  keepHierarchy()
  val sb = log2Ceil(sets); val ww = log2Ceil(words)
  val address = in(tagBits + sb + ww)
  val tags = in(2 * sets * tagBits); val valid = in(2 * sets); val word_valid = in(2 * sets * words)
  val match_bits = out(2); val hit = outBool()
  val addresses = Distribution(address, (2 * sets + 3) / 4)
  val matches = (0 until 2 * sets).map { line =>
    val localAddress = addresses(line / 4)
    val m = Module(new CacheTagMatch(tagBits, words))
    m.selected := localAddress(ww + sb - 1, ww) === (line / 2).U(sb.W)
    m.valid := valid(line); m.tag := word(tags, line, tagBits)
    m.request_tag := localAddress(tagBits + sb + ww - 1, sb + ww)
    m.word_valid := word(word_valid, line, words); m.word_index := localAddress(ww - 1, 0)
    m
  }
  match_bits := VecInit((0 until 2).map(way => (0 until sets).map(s => matches(2 * s + way).match_bits).reduce(_ | _))).asUInt
  val wayHits = (0 until 2).map(way => (0 until sets).map(s => matches(2 * s + way).hit).reduce(_ | _))
  hit := Mux(match_bits(0), wayHits(0), wayHits(1))
}
