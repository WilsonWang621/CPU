package tier3

import chisel3._
import chisel3.util._
import tier3.Bits._
import ISA._

/** The Verilog MDU's 16x16 partial products, carry-save reduction, three
  * pending slots, radix-4/16 restoring divide and quotient/remainder cache.
  */
class MulDiv(divStepBits: Int = 2) extends ClockedLogic {
  override def desiredName = "muldiv"
  require(divStepBits == 2 || divStepBits == 4)
  val divSteps = 32 / divStepBits; val stepW = log2Ceil(divSteps)
  val kill = inBool(); val kill_mask = in(256)
  val req_valid = inBool(); val req_ready = outBool(); val mul_ready = outBool(); val div_ready = outBool()
  val req_op = in(6); val req_a = in(32); val req_b = in(32); val req_tag = in(8)
  val rsp_valid = outBool(); val rsp_ready = inBool(); val rsp_result = out(32); val rsp_tag = out(8)
  val mul_valid_q = flags(3); val mul_tag_q = regs(3, 8)
  val div_busy_q = flag(); val div_done_q = flag(); val div_tag_q = reg(8)
  val step_q = reg(stepW); val quotient_negative_q = flag(); val remainder_negative_q = flag()
  val remainder_operation_q = flag(); val div_signed_q = flag()
  val cache_valid_q = flag(); val cache_signed_q = flag()
  val out_valid_q = flag(); val prefer_div_q = flag(); val out_tag_q = reg(8)
  val pipeline_valid_q = flag(); val pipeline_low_q = flag(); val pipeline_tag_q = reg(8)
  val mulReady0 = Wire(Bool()); val mulReady1 = Wire(Bool()); val mulReady2 = Wire(Bool())
  val pipelineLive = pipeline_valid_q && !kill_mask(pipeline_tag_q)
  val pipelineReady = !pipelineLive || mulReady0
  val pipelineConsume = pipelineLive && mulReady0
  val requestMul = req_op >= MUL && req_op <= MULHU
  val requestDiv = req_op >= DIV && req_op <= REMU
  val signedDivide = req_op === DIV || req_op === REM
  val aNegative = signedDivide && req_a(31); val bNegative = signedDivide && req_b(31)
  val aMagnitude = Mux(aNegative, PrefixAdder(~req_a, 0.U(32.W), true.B)._1, req_a)
  val bMagnitude = Mux(bNegative, PrefixAdder(~req_b, 0.U(32.W), true.B)._1, req_b)
  val divLive = div_busy_q && !kill_mask(div_tag_q)
  val divResultLive = div_done_q && !kill_mask(div_tag_q)
  rsp_valid := out_valid_q && !kill_mask(out_tag_q) && !kill && !rst
  rsp_tag := out_tag_q
  val outSpace = !out_valid_q || kill_mask(out_tag_q) || rsp_ready
  val mulLive = VecInit((0 until 3).map(s => mul_valid_q(s) && !kill_mask(mul_tag_q(s))))
  val mulHead = Mux(mulLive(2), 2.U(2.W), Mux(mulLive(1), 1.U(2.W), 0.U(2.W)))
  val grantDiv = outSpace && divResultLive && (!mulLive.asUInt.orR || prefer_div_q)
  val grantMul = outSpace && mulLive.asUInt.orR && (!divResultLive || !prefer_div_q)
  val mulRemaining = VecInit((0 until 3).map(s => mulLive(s) && !(grantMul && mulHead === s.U(2.W))))
  mulReady2 := !mulRemaining(2); mulReady1 := !mulRemaining(1) || mulReady2
  mulReady0 := !mulRemaining(0) || mulReady1
  mul_ready := !rst && !kill && pipelineReady
  div_ready := !rst && !kill && !divLive && (!divResultLive || grantDiv)
  req_ready := !kill_mask(req_tag) && ((requestMul && mul_ready) || (requestDiv && div_ready))
  val grantNewMul = outSpace && !grantMul && !grantDiv && pipelineConsume
  val pipelineAccept = req_valid && req_ready && requestMul
  val dataClear = rst || kill
  def dataReg(width: Int, writes: Seq[(Bool, UInt)]): UInt = {
    val m = Module(new PriorityRegister(width, writes.size)); m.clk := clk; m.clear := dataClear
    m.enable := VecInit(writes.map(_._1)).asUInt
    m.data := pack(writes.map { case (_, d) => val w = Wire(UInt(width.W)); w := d; w })
    m.value
  }
  val pp00_q = dataReg(32, Seq(pipelineAccept -> (req_a(15, 0) * req_b(15, 0))))
  val pp01_q = dataReg(32, Seq(pipelineAccept -> (req_a(15, 0) * req_b(31, 16))))
  val pp10_q = dataReg(32, Seq(pipelineAccept -> (req_a(31, 16) * req_b(15, 0))))
  val pp11_q = dataReg(32, Seq(pipelineAccept -> (req_a(31, 16) * req_b(31, 16))))
  val correctionA = Mux(req_a(31) && (req_op === MULH || req_op === MULHSU), req_b, 0.U(32.W))
  val correctionB = Mux(req_b(31) && req_op === MULH, req_a, 0.U(32.W))
  val pcorr_a_q = dataReg(32, Seq(pipelineAccept -> correctionA))
  val pcorr_b_q = dataReg(32, Seq(pipelineAccept -> correctionB))
  val productMiddle = Cat(0.U(2.W), pp00_q(31, 16)) + Cat(0.U(2.W), pp01_q(15, 0)) + Cat(0.U(2.W), pp10_q(15, 0))
  val term0 = pp11_q; val term1 = Cat(0.U(16.W), pp01_q(31, 16)); val term2 = Cat(0.U(16.W), pp10_q(31, 16))
  val term3 = Cat(0.U(30.W), productMiddle(17, 16)) + 2.U(32.W)
  val term4 = ~pcorr_a_q; val term5 = ~pcorr_b_q
  def csa(a: UInt, b: UInt, c: UInt): (UInt, UInt) =
    (a ^ b ^ c, (((a & b) | (a & c) | (b & c)) << 1)(31, 0))
  val (sum0, carry0) = csa(term0, term1, term2)
  val (sum1, carry1) = csa(term3, term4, term5)
  val (sum2, carry2) = csa(sum0, carry0, sum1)
  val (sum3, carry3) = csa(sum2, carry2, carry1)
  val productHigh = PrefixAdder(sum3, carry3)._1
  val mulComputed = Mux(pipeline_low_q, Cat(productMiddle(15, 0), pp00_q(15, 0)), productHigh)

  val leadingSteps = WireDefault(0.U(stepW.W))
  for (groups <- 1 until divSteps) {
    when((aMagnitude >> (32 - divStepBits * groups)) === 0.U) { leadingSteps := groups.U }
  }
  val shortcut = WireDefault(true.B); val shortcutQuotient = WireDefault(0.U(32.W)); val shortcutRemainder = WireDefault(0.U(32.W))
  when(req_b === 0.U) { shortcutQuotient := "hffffffff".U; shortcutRemainder := req_a }
    .elsewhen(signedDivide && req_a === "h80000000".U && req_b === "hffffffff".U) { shortcutQuotient := "h80000000".U }
    .elsewhen(aMagnitude < bMagnitude || aMagnitude === 0.U) { shortcutRemainder := req_a }
    .elsewhen(bMagnitude === 1.U) { shortcutQuotient := Mux(aNegative ^ bNegative, ~aMagnitude + 1.U, aMagnitude) }
    .otherwise { shortcut := false.B }
  val quotient_q = Wire(UInt(32.W)); val remainder_q = Wire(UInt(33.W)); val divisor_q = Wire(UInt(32.W))
  val div_result_q = Wire(UInt(32.W)); val div_a_q = Wire(UInt(32.W)); val div_b_q = Wire(UInt(32.W))
  val cache_a_q = Wire(UInt(32.W)); val cache_b_q = Wire(UInt(32.W))
  val cache_quotient_q = Wire(UInt(32.W)); val cache_remainder_q = Wire(UInt(32.W))
  val divideSteps = (0 until divStepBits).foldLeft((quotient_q, remainder_q)) { case ((q, r), _) =>
    val shifted = Cat(r(31, 0), q(31)); val nextQ = Cat(q(30, 0), 0.U(1.W))
    val subtract = shifted >= Cat(0.U(1.W), divisor_q)
    (nextQ | subtract.asUInt, Mux(subtract, shifted - Cat(0.U(1.W), divisor_q), shifted))
  }
  val quotientNext = Mux(divLive, divideSteps._1, quotient_q)
  val remainderNext = Mux(divLive, divideSteps._2, remainder_q)
  val completedQuotient = Mux(quotient_negative_q, ~quotientNext + 1.U, quotientNext)
  val completedRemainder = Mux(remainder_negative_q, ~remainderNext(31, 0) + 1.U, remainderNext(31, 0))
  val cacheHit = cache_valid_q && cache_a_q === req_a && cache_b_q === req_b && cache_signed_q === signedDivide
  val acceptDiv = req_valid && req_ready && requestDiv
  val finishDiv = divLive && step_q === (divSteps - 1).U(stepW.W)
  val startDiv = acceptDiv && !cacheHit && !shortcut
  val saveShortcut = acceptDiv && !cacheHit && shortcut
  val acceptMul = pipelineConsume && !grantNewMul
  val remainderOp = req_op === REM || req_op === REMU
  val freshDivResult = Mux(cacheHit, Mux(remainderOp, cache_remainder_q, cache_quotient_q), Mux(remainderOp, shortcutRemainder, shortcutQuotient))
  val mul_result_q = Wire(Vec(3, UInt(32.W)))
  val out_result_q = dataReg(32, Seq(grantNewMul -> mulComputed, grantMul -> mul_result_q(mulHead), grantDiv -> div_result_q))
  div_result_q := dataReg(32, Seq(finishDiv -> Mux(remainder_operation_q, completedRemainder, completedQuotient),
    (acceptDiv && (cacheHit || shortcut)) -> freshDivResult))
  quotient_q := dataReg(32, Seq(divLive -> quotientNext, startDiv -> (aMagnitude << (leadingSteps * divStepBits.U))))
  remainder_q := dataReg(33, Seq(divLive -> remainderNext, startDiv -> 0.U(33.W)))
  divisor_q := dataReg(32, Seq(startDiv -> bMagnitude))
  div_a_q := dataReg(32, Seq(acceptDiv -> req_a)); div_b_q := dataReg(32, Seq(acceptDiv -> req_b))
  cache_a_q := dataReg(32, Seq(finishDiv -> div_a_q, saveShortcut -> req_a))
  cache_b_q := dataReg(32, Seq(finishDiv -> div_b_q, saveShortcut -> req_b))
  cache_quotient_q := dataReg(32, Seq(finishDiv -> completedQuotient, saveShortcut -> shortcutQuotient))
  cache_remainder_q := dataReg(32, Seq(finishDiv -> completedRemainder, saveShortcut -> shortcutRemainder))
  mul_result_q(0) := dataReg(32, Seq((mulReady0 && acceptMul) -> mulComputed))
  mul_result_q(1) := dataReg(32, Seq((mulReady1 && mulRemaining(0)) -> mul_result_q(0)))
  mul_result_q(2) := dataReg(32, Seq((mulReady2 && mulRemaining(1)) -> mul_result_q(1)))
  rsp_result := out_result_q

  when(dataClear) {
    pipeline_valid_q := false.B; pipeline_low_q := false.B; pipeline_tag_q := 0.U
    for (s <- 0 until 3) { mul_valid_q(s) := false.B; mul_tag_q(s) := 0.U }
    div_busy_q := false.B; div_done_q := false.B; div_tag_q := 0.U; step_q := 0.U
    quotient_negative_q := false.B; remainder_negative_q := false.B; remainder_operation_q := false.B
    div_signed_q := false.B; cache_valid_q := false.B; cache_signed_q := false.B
    out_valid_q := false.B; out_tag_q := 0.U; prefer_div_q := true.B
  }.otherwise {
    when(pipelineReady) {
      pipeline_valid_q := pipelineAccept
      when(pipelineAccept) { pipeline_low_q := req_op === MUL; pipeline_tag_q := req_tag }
    }
    when(outSpace) {
      out_valid_q := grantDiv || grantMul || grantNewMul
      when(grantDiv) { out_tag_q := div_tag_q; prefer_div_q := false.B }
        .elsewhen(grantMul) { out_tag_q := mul_tag_q(mulHead); prefer_div_q := true.B }
        .elsewhen(grantNewMul) { out_tag_q := pipeline_tag_q; prefer_div_q := true.B }
    }
    when(mulReady2) { mul_valid_q(2) := mulRemaining(1); when(mulRemaining(1)) { mul_tag_q(2) := mul_tag_q(1) } }
    when(mulReady1) { mul_valid_q(1) := mulRemaining(0); when(mulRemaining(0)) { mul_tag_q(1) := mul_tag_q(0) } }
    when(mulReady0) { mul_valid_q(0) := acceptMul; when(acceptMul) { mul_tag_q(0) := pipeline_tag_q } }
    when(kill_mask(div_tag_q)) { div_busy_q := false.B; div_done_q := false.B }
    when(grantDiv) { div_done_q := false.B }
    when(divLive) {
      step_q := step_q + 1.U
      when(finishDiv) {
        div_busy_q := false.B; div_done_q := true.B; cache_valid_q := true.B; cache_signed_q := div_signed_q
      }
    }
    when(acceptDiv) {
      div_tag_q := req_tag; div_signed_q := signedDivide
      quotient_negative_q := aNegative ^ bNegative; remainder_negative_q := aNegative
      remainder_operation_q := remainderOp; div_busy_q := false.B; div_done_q := true.B
      when(!cacheHit) {
        when(shortcut) { cache_valid_q := true.B; cache_signed_q := signedDivide }
          .otherwise { div_busy_q := true.B; div_done_q := false.B; step_q := leadingSteps }
      }
    }
  }
}
