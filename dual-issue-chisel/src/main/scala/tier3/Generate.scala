package tier3

import chisel3.RawModule

/** Module emission is also used by the original-vs-Chisel formal checks. */
object Generate extends App {
  require(args.length % 2 == 0, "Options are --name value pairs")
  val supported = Set("--module", "--out", "--rob", "--iq", "--control-tree", "--rob-write-tree", "--cache-tree",
    "--commit-tree", "--register-redirect", "--width", "--entries", "--leaves", "--index-group", "--ports", "--register",
    "--tree", "--lane", "--slot-bits", "--tag-bits", "--words", "--sets", "--youngest", "--extended-order",
    "--checkpoints", "--credits", "--div-step-bits", "--cache-bytes", "--queue-entries", "--bht-entries", "--btb-entries",
    "--history-entries", "--ram-bytes", "--history-bits", "--line-bytes", "--mshrs", "--load-slots", "--store-slots", "--firtool-opt")
  val options = args.grouped(2).map(a => a(0) -> a(1)).toMap
  require(options.keySet.subsetOf(supported), "Unknown options: " + (options.keySet -- supported).mkString(", "))
  def n(key: String, default: Int): Int = options.get(key).map(_.toInt).getOrElse(default)
  val width = n("--width", 32); val entries = n("--entries", 4)
  val module = options.getOrElse("--module", "top")
  val p = Config(robEntries = n("--rob", 32), iqEntries = n("--iq", 4),
    controlTree = n("--control-tree", 1) != 0, robWriteTree = n("--rob-write-tree", 1) != 0,
    cacheTree = n("--cache-tree", 1) != 0, commitTree = n("--commit-tree", 1) != 0,
    registerRedirect = n("--register-redirect", 1) != 0)
  def design(): RawModule = module match {
    case "top" => new StudentTop(p)
    case "core" => new Core(p)
    case "decoder" => new Decoder
    case "decode-class-proof" => new DecodeClassProof
    case "rename-input-proof" => new RenameInputProof
    case "alu" => new Alu
    case "branch-unit" => new BranchUnit
    case "rename" => new Rename(n("--slot-bits", 5), n("--checkpoints", 3), n("--tree", 1) != 0)
    case "memory-controller" => new MemoryController(n("--credits", 16))
    case "axi-adapter" => new AxiAdapter(n("--entries", 16))
    case "muldiv" => new MulDiv(n("--div-step-bits", 2))
    case "frontend" => new Frontend(cacheBytes = n("--cache-bytes", 1024), queueEntries = n("--queue-entries", 8),
      bhtEntries = n("--bht-entries", 256), btbEntries = n("--btb-entries", 32), historyEntries = n("--history-entries", 64),
      ramBytes = n("--ram-bytes", 268435456), localHistoryBits = n("--history-bits", 1), cacheTree = n("--tree", 1) != 0)
    case "dcache" => new DCache(cacheBytes = n("--cache-bytes", 2048), lineBytes = n("--line-bytes", 64),
      mshrs = n("--mshrs", 4), loadSlots = n("--load-slots", 8), storeSlots = n("--store-slots", 16),
      credits = n("--credits", 16), ramBytes = n("--ram-bytes", 268435456), cacheTree = n("--tree", 1) != 0)
    case "prefix-adder" => new PrefixAdder(width)
    case "increment" => new Increment(width)
    case "distribution" => new Distribution(width, n("--leaves", 6))
    case "read" => new Read(entries, width, indexGroup = n("--index-group", 0))
    case "iq-read" => new IQRead(entries, width)
    case "cache-read" => new CacheRead(entries, width, indexGroup = n("--index-group", 0))
    case "grant-read" => new GrantRead(entries, width)
    case "priority-mux" => new PriorityMux(width, n("--ports", 3))
    case "priority-register" => new PriorityRegister(width, n("--ports", 2))
    case "arch-word" => new ArchWord(n("--register", 1), n("--tree", 1) != 0)
    case "retire-read" => new RetireRead(entries, width, n("--lane", 0), n("--tree", 1) != 0)
    case "registered-grant" => new RegisteredGrant(entries)
    case "operand" => new Operand(n("--slot-bits", 5))
    case "cache-tag-match" => new CacheTagMatch(n("--tag-bits", 18), n("--words", 16))
    case "cache-lookup" => new CacheLookup(n("--sets", 16), n("--tag-bits", 18), n("--words", 16))
    case "order-compare" => new OrderCompare(width)
    case "select" => new Select(entries, n("--slot-bits", 5), n("--youngest", 0) != 0, n("--extended-order", 0) != 0)
    case "parallel-select" => new ParallelSelect(entries, n("--slot-bits", 6))
    case "circular-grant" => new CircularGrant(entries)
    case other => throw new IllegalArgumentException(s"Unknown module: $other")
  }
  _root_.circt.stage.ChiselStage.emitSystemVerilogFile(design(),
    Array("--target-dir", options.getOrElse("--out", "rtl")),
    Array("--disable-all-randomization", "--lowering-options=disallowLocalVariables,disallowPackedArrays") ++
      (if (n("--firtool-opt", 1) == 0) Array("--disable-opt") else Array.empty[String]))
}
