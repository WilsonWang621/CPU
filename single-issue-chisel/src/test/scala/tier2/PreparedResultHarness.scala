package tier2
import chisel3._
import chisel3.util._

/** Exercise actual result words and sticky cache owners. The software driver
  * checks the published words independently; pending words are unpublished.
  */
class PreparedResultHarness(sliceBits: Int) extends Module {
  val p = Config(debug=true,bankedReturnMatch=true,preparedLoadResult=true,resultSliceBits=sliceBits)
  val legacyP = p.copy(preparedLoadResult=false)
  val allocate = IO(Input(UInt(p.rob.W)))
  val exe_valid = IO(Input(Bool())); val exe_tag = IO(Input(UInt(p.tagBits.W))); val exe_data = IO(Input(UInt(32.W)))
  val md_valid = IO(Input(Bool())); val md_tag = IO(Input(UInt(p.tagBits.W))); val md_data = IO(Input(UInt(32.W)))
  val load_data = IO(Input(UInt(32.W)))
  val offer = IO(Input(UInt(p.banks.W))); val offer_tags = IO(Input(UInt((p.banks*p.tagBits).W)))
  val offer_prefetch = IO(Input(UInt(p.banks.W)))
  val respond = IO(Input(UInt(p.banks.W))); val consume = IO(Input(UInt(p.banks.W)))
  val squash = IO(Input(Bool())); val squash_mask = IO(Input(UInt(p.rob.W)))
  val owner_valid = IO(Output(UInt(p.banks.W))); val owner_dead = IO(Output(UInt(p.banks.W)))
  val owner_pending = IO(Output(UInt(p.banks.W)))
  val completed = IO(Output(UInt(p.rob.W))); val finalized = IO(Output(UInt(p.rob.W)))
  val values = IO(Output(UInt((p.rob*32).W)))

  val owners = Seq.fill(p.banks)(Module(new CacheOwner(p)))
  val returned = Wire(new BankedLoadReturn(p))
  for(i <- 0 until p.banks) {
    val owner = owners(i)
    owner.io.offer.valid := offer(i)
    owner.io.offer.bits := 0.U.asTypeOf(new LoadInfo(p))
    owner.io.offer.bits.tag := offer_tags((i+1)*p.tagBits-1,i*p.tagBits)
    owner.io.offer.bits.prefetch := offer_prefetch(i)
    owner.io.consume := consume(i) || (respond(i) && owner.io.valid)
    owner.io.squash := squash; owner.io.squashMask := squash_mask
    owner.io.boundary := 0.U; owner.io.wrapped := 0.U
    returned.tags(i) := owner.io.info.tag
    returned.pending.get(i) := owner.io.valid && !owner.io.info.prefetch && !owner.io.dead
    returned.selected(i) := respond(i) && returned.pending.get(i)
  }
  owner_valid := VecInit(owners.map(_.io.valid)).asUInt
  owner_dead := VecInit(owners.map(_.io.dead)).asUInt
  owner_pending := returned.pending.get.asUInt
  val selectedTag = Mux1H(returned.selected,returned.tags)
  val done = RegInit(VecInit(Seq.fill(p.rob)(false.B)))
  val prepared = Seq.tabulate(p.rob)(i => Module(new LocalResultWord(p,i)))
  val legacy = Seq.tabulate(p.rob)(i => Module(new LocalResultWord(legacyP,i)))
  for(i <- 0 until p.rob) {
    val survives = !squash || !squash_mask(i)
    val valid = VecInit(Seq(exe_valid && survives,survives,md_valid && survives)).asUInt
    for(word <- Seq(prepared(i),legacy(i))) {
      word.io.valid := valid
      word.io.tags := VecInit(Seq(exe_tag,selectedTag,md_tag))
      word.io.data := VecInit(Seq(exe_data,load_data,md_data))
      word.io.loadReturn.get.tags := returned.tags
      word.io.loadReturn.get.selected := returned.selected
      word.io.loadReturn.get.pending.foreach(_ := returned.pending.get)
      word.io.finalized.foreach(_ := done(i))
    }
    when(prepared(i).io.completed) { done(i) := true.B }
    when(allocate(i) || (squash && squash_mask(i))) { done(i) := false.B }
    when(!reset.asBool) {
      assert(prepared(i).io.completed === legacy(i).io.completed,"Result preparation changed completion timing")
      when(done(i)) { assert(prepared(i).io.value === legacy(i).io.value,"Published prepared result differs from legacy result") }
      assert(PopCount(VecInit((0 until p.banks).map(b =>
        returned.pending.get(b) && returned.tags(b) === i.U))) <= 1.U,"Multiple live cache owners share one ROB tag")
    }
  }
  when(!reset.asBool) {
    assert(PopCount(respond) <= 1.U,"Driver supplied multiple selected bank responses")
    assert((allocate & VecInit(prepared.map(_.io.completed)).asUInt) === 0.U,"Driver reused a tag during its completion")
  }
  completed := VecInit(prepared.map(_.io.completed)).asUInt
  finalized := done.asUInt
  values := Cat(prepared.reverse.map(_.io.value))
}

object GeneratePreparedResultHarness extends App {
  for(bits <- Seq(8,16,32)) {
    _root_.circt.stage.ChiselStage.emitSystemVerilogFile(new PreparedResultHarness(bits),
      Array("--target-dir",s"${args(0)}/slice${bits}"),Array("--disable-all-randomization"))
  }
}
