"""Guard the delivery check's failure boundaries without running another CPU."""
import contextlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("check_generated_rtl", Path(__file__).parents[1] / "scripts/check_generated_rtl.py")
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


class DeliveryCheckTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.delivery = self.root / "dual-issue-chisel/rtl"
        self.generated = self.root / "generated"
        self.report = self.root / "report"
        for path in [self.delivery, self.generated, self.report, self.root / "verilog", self.root / "dual-issue-chisel/project"]:
            path.mkdir(parents=True, exist_ok=True)
        (self.root / "verilog/filelist.f").write_text("../dual-issue-chisel/rtl/student_top.sv\n")
        (self.delivery / "filelist.f").write_text("student_top.sv\n")
        rtl = CHECK.FIRTOOL_HEADER + '\nmodule student_top; wire value = 1; initial $display("/tmp/example"); endmodule\n'
        for directory in [self.delivery, self.generated]:
            (directory / "student_top.sv").write_text(rtl)
            (directory / "elaboration.json").write_text('{"module":"top","config":{"robEntries":32}}\n')
        (self.root / "dual-issue-chisel/build.sbt").write_text('ThisBuild / scalaVersion := "2.13.12"\nval chiselVersion = "6.5.0"\n')
        (self.root / "dual-issue-chisel/project/build.properties").write_text("sbt.version=1.10.2\n")

    def compare(self):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return CHECK.compare_delivery(self.root, self.generated, self.report)

    def change_rtl(self, before, after):
        path = self.generated / "student_top.sv"
        path.write_text(path.read_text().replace(before, after))

    def test_matching_delivery_passes(self):
        self.assertTrue(all(row["equal"] for row in self.compare()))
        self.assertFalse(list(self.report.glob("*.diff")))

    def test_real_rtl_change_fails_with_named_diff(self):
        self.change_rtl("value = 1", "value = 0")
        rows = self.compare()
        self.assertFalse(rows[0]["equal"])
        diff = (self.report / "student_top.sv.diff").read_text()
        self.assertIn("value = 1", diff)
        self.assertIn("value = 0", diff)

    def test_source_location_comment_is_not_filtered(self):
        self.change_rtl("endmodule", "endmodule // Core.scala:42:7")
        self.assertFalse(self.compare()[0]["equal"])

    def test_whitespace_is_not_filtered(self):
        self.change_rtl("value = 1", "value  = 1")
        self.assertFalse(self.compare()[0]["equal"])

    def test_path_in_string_literal_is_not_filtered(self):
        self.change_rtl("/tmp/example", "/home/other")
        self.assertFalse(self.compare()[0]["equal"])

    def test_configuration_drift_fails(self):
        (self.generated / "elaboration.json").write_text('{"module":"top","config":{"robEntries":16}}\n')
        self.assertFalse(self.compare()[1]["equal"])
        self.assertTrue((self.report / "elaboration.json.diff").is_file())

    def test_missing_generated_file_fails(self):
        (self.generated / "student_top.sv").unlink()
        with self.assertRaisesRegex(ValueError, "did not emit course artifact"):
            self.compare()

    def test_wrong_firtool_fails(self):
        self.change_rtl("firtool-1.62.0", "firtool-1.139.0")
        with self.assertRaisesRegex(ValueError, "expected.*firtool-1.62.0"):
            self.compare()

    def test_empty_generated_file_fails(self):
        (self.generated / "student_top.sv").write_text("")
        with self.assertRaisesRegex(ValueError, "empty course artifact"):
            self.compare()

    def test_course_entry_switch_fails(self):
        (self.root / "verilog/reference.sv").write_text("module student_top; endmodule\n")
        (self.root / "verilog/filelist.f").write_text("reference.sv\n")
        with self.assertRaisesRegex(ValueError, "filelist.*disagree"):
            self.compare()

    def test_native_filelist_drift_fails(self):
        (self.delivery / "extra.sv").write_text("module extra; endmodule\n")
        (self.delivery / "filelist.f").write_text("student_top.sv\nextra.sv\n")
        with self.assertRaisesRegex(ValueError, "filelist.*disagree"):
            self.compare()

    def test_tool_version_drift_fails(self):
        self.assertEqual(CHECK.project_versions(self.root), CHECK.VERSIONS)
        (self.root / "dual-issue-chisel/project/build.properties").write_text("sbt.version=1.11.0\n")
        with self.assertRaisesRegex(ValueError, "sbt: project specifies 1.11.0, CI pins 1.10.2"):
            CHECK.project_versions(self.root)


if __name__ == "__main__":
    unittest.main()
