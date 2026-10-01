package cpu2026

import java.nio.charset.StandardCharsets
import java.nio.file.{Files, Path, Paths, StandardCopyOption}

/** Export the checked-in, regression-tested integration RTL.
  *
  * Leaf modules remain authored in Chisel and are emitted by
  * [[GenerateDatapath]].  Keeping the functional top checked in makes the
  * course build independent of a generator run while the pipelined Chisel top
  * is still under development.
  */
object Generate {
  def main(args: Array[String]): Unit = {
    require(args.length <= 1, "Usage: mill chisel.run [verilog-output-directory]")
    val root = Paths.get(System.getProperty("chisel.project.root", ".")).toAbsolutePath.normalize
    val source = root.resolve("verilog/student_top.sv")
    require(Files.isRegularFile(source), s"Missing integration RTL: $source")
    val output = Paths.get(args.headOption.getOrElse("verilog")).toAbsolutePath.normalize
    Files.createDirectories(output)
    val target = output.resolve("student_top.sv")
    if (source != target) Files.copy(source, target, StandardCopyOption.REPLACE_EXISTING)
    val filelist = output.resolve("filelist.f")
    val old = if (Files.isRegularFile(filelist)) Files.readString(filelist) else ""
    val listed = old.linesIterator.map(_.takeWhile(_ != '#').trim).contains("student_top.sv")
    if (!listed) {
      val separator = if (old.isEmpty || old.endsWith("\n")) "" else "\n"
      Files.writeString(filelist, old + separator + "student_top.sv\n", StandardCharsets.UTF_8)
    }
    println(s"Exported $target and updated $filelist")
  }
}
