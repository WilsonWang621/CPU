# 大型产物审计

范围：当前工作树中 Git 已跟踪文件。Git 历史对象仅在使用 `--history` 时扫描本地 refs；不代表远端完整历史。

总计：5766 个文件，596.53 MiB

## 按类别

| 类别 | 文件数 | 大小 |
| --- | ---: | ---: |
| `complete_logs_outputs` | 1376 | 209.72 MiB |
| `course_inputs` | 27 | 76.63 KiB |
| `experiment_summaries` | 905 | 80.76 MiB |
| `frozen_inputs` | 2732 | 245.71 MiB |
| `other_tracked` | 487 | 15.80 MiB |
| `required_generated_rtl` | 6 | 7.30 MiB |
| `source_and_config` | 229 | 1.69 MiB |
| `toolkit` | 4 | 35.47 MiB |

## 按顶层目录

| 目录 | 文件数 | 大小 |
| --- | ---: | ---: |
| `.github/scripts` | 1 | 6.38 KiB |
| `.github/tests` | 1 | 4.87 KiB |
| `.github/workflows` | 2 | 10.26 KiB |
| `.gitignore` | 1 | 295.00 B |
| `.gitmodules` | 1 | 114.00 B |
| `AGENTS.md` | 1 | 10.79 KiB |
| `Dockerfile` | 1 | 4.12 KiB |
| `Makefile` | 1 | 3.47 KiB |
| `README-EN.md` | 1 | 18.18 KiB |
| `README-ZH.md` | 1 | 17.78 KiB |
| `README.md` | 1 | 10.93 KiB |
| `archive/README.md` | 1 | 912.00 B |
| `archive/chisel-prototype` | 7 | 11.70 KiB |
| `archive/planning` | 1 | 10.91 KiB |
| `archive/rtl` | 7 | 41.55 KiB |
| `config.mk` | 1 | 1.62 KiB |
| `cpu2026-tools-x86_64.AppImage` | 1 | 35.46 MiB |
| `docs/README.md` | 1 | 2.30 KiB |
| `docs/architecture` | 49 | 9.02 MiB |
| `docs/architecture.md` | 1 | 2.55 KiB |
| `docs/artifacts.md` | 1 | 3.88 KiB |
| `docs/axi4-lite.md` | 1 | 1.77 KiB |
| `docs/ci.md` | 1 | 7.25 KiB |
| `docs/pages.md` | 1 | 1.35 KiB |
| `docs/parameters.md` | 1 | 2.64 KiB |
| `docs/site` | 1 | 6.99 KiB |
| `docs/sram.md` | 1 | 896.00 B |
| `dual-issue-chisel/.gitattributes` | 1 | 99.00 B |
| `dual-issue-chisel/.gitignore` | 1 | 52.00 B |
| `dual-issue-chisel/Makefile` | 1 | 1.19 KiB |
| `dual-issue-chisel/README.md` | 1 | 5.47 KiB |
| `dual-issue-chisel/build.sbt` | 1 | 443.00 B |
| `dual-issue-chisel/project` | 1 | 19.00 B |
| `dual-issue-chisel/reports` | 550 | 13.63 MiB |
| `dual-issue-chisel/rtl` | 3 | 5.07 MiB |
| `dual-issue-chisel/scripts` | 14 | 81.03 KiB |
| `dual-issue-chisel/src` | 15 | 133.29 KiB |
| `packaging/appimage` | 3 | 9.08 KiB |
| `reports/README.md` | 1 | 5.76 KiB |
| `reports/data` | 1640 | 221.59 MiB |
| `reports/dual-issue` | 10 | 59.94 KiB |
| `reports/experiments` | 3 | 19.07 KiB |
| `reports/framework` | 1 | 3.94 KiB |
| `scripts/archive_experiment.py` | 1 | 3.63 KiB |
| `scripts/area_v2` | 8 | 38.95 KiB |
| `scripts/audit_artifacts.py` | 1 | 5.68 KiB |
| `scripts/build.py` | 1 | 3.93 KiB |
| `scripts/build_experiment_index.py` | 1 | 7.85 KiB |
| `scripts/fakeram.py` | 1 | 9.81 KiB |
| `scripts/oj_io.py` | 1 | 3.02 KiB |
| `scripts/ram` | 1 | 2.81 KiB |
| `scripts/run.py` | 1 | 2.09 KiB |
| `scripts/sim.cpp` | 1 | 8.95 KiB |
| `scripts/synth.py` | 1 | 8.86 KiB |
| `scripts/synth_report.py` | 1 | 5.70 KiB |
| `scripts/testcase.py` | 1 | 3.92 KiB |
| `scripts/timing.py` | 1 | 2.93 KiB |
| `scripts/timing.tcl` | 1 | 3.36 KiB |
| `scripts/toolchain.py` | 1 | 1.25 KiB |
| `single-issue-chisel/.gitignore` | 1 | 59.00 B |
| `single-issue-chisel/Makefile` | 1 | 622.00 B |
| `single-issue-chisel/README.md` | 1 | 8.20 KiB |
| `single-issue-chisel/baseline.json` | 1 | 2.06 KiB |
| `single-issue-chisel/build.sbt` | 1 | 472.00 B |
| `single-issue-chisel/latest-measurement.json` | 1 | 9.70 KiB |
| `single-issue-chisel/project` | 1 | 19.00 B |
| `single-issue-chisel/reports` | 3303 | 308.52 MiB |
| `single-issue-chisel/rtl` | 2 | 1.97 MiB |
| `single-issue-chisel/scripts` | 9 | 53.12 KiB |
| `single-issue-chisel/src` | 22 | 116.52 KiB |
| `single-issue-chisel/tests` | 1 | 4.57 KiB |
| `tests/rtl` | 27 | 76.63 KiB |
| `verilog/area_v2` | 31 | 142.67 KiB |
| `verilog/area_v2_core.json` | 1 | 3.41 KiB |
| `verilog/area_v2_core.v` | 1 | 269.60 KiB |
| `verilog/filelist-source.f` | 1 | 804.00 B |
| `verilog/filelist.f` | 1 | 119.00 B |
| `verilog/pararisc_axi_adapter.sv` | 1 | 2.68 KiB |
| `verilog/reference_filelist.f` | 1 | 54.00 B |
| `verilog/student_top.sv` | 1 | 3.34 KiB |

## 本地 refs 中的大型历史 blob（≥1 MiB）

| 大小 | 对象 | 路径 |
| ---: | --- | --- |
| 35.46 MiB | `54f6e2f5566441f5ebc377658d5f3811d97c1949` | `cpu2026-tools-x86_64.AppImage` |
| 5.17 MiB | `f50f29068723bf793d8567d35c7b6fc8aa00b12b` | `reports/data/2026-10-15/timing-stage8/split-load-address/report.json` |
| 5.07 MiB | `bce33541baf6ebaf920dc2726bca4c7da104fd2b` | `dual-issue-chisel/rtl/student_top.sv` |
| 5.07 MiB | `a11f6e742f6f37487f2f0b51c19d8c0b63692c36` | `dual-issue-chisel/rtl/student_top.sv` |
| 5.07 MiB | `1bd9c436fda6dee4a6407d762b9b4f0a67fe5f00` | `dual-issue-chisel/rtl/student_top.sv` |
| 5.07 MiB | `97ee3a4ac2e38040e5f317d80b18f7e3cbab4b1b` | `dual-issue-chisel/rtl/student_top.sv` |
| 4.82 MiB | `dd46b14b107725ceac3c7b82fb6524908ce4bd4f` | `reports/data/2026-10-15/timing-stage8/store-grants/report.json` |
| 4.82 MiB | `2bbe8feb5946b3eedf9a6aef2b0c6d848e4fcbdb` | `reports/data/2026-10-15/timing-stage8/local-address/report.json` |
| 4.82 MiB | `89d5dc96318fdeba83c1bfea83ca4c41ae8e11a4` | `reports/data/2026-10-16/timing-stage10/clean-default/frozen-input/report.json` |
| 4.82 MiB | `79963ff3870fdc39b5338f395108ed73e6a45313` | `reports/data/2026-10-16/timing-stage10/clean-default/report.json` |
| 4.79 MiB | `a29f8dff4361e3f73685b77a51d771682c7595d8` | `reports/data/2026-10-15/timing-stage8/split-address/report.json` |
| 4.79 MiB | `b8383bf55e9a36a5da72a0bd8c95427f42eee151` | `reports/data/2026-10-15/timing-stage8/lookahead-tree/report.json` |
| 4.79 MiB | `40ec6655d7b9ebec882ad74678ab9e2c906d7ec5` | `reports/data/2026-10-15/timing-stage8/cache-1k-load/report.json` |
| 4.76 MiB | `b8ec66be95d50cb8024fc3a1379487be2c702a2d` | `reports/data/2026-10-15/timing-stage8/parallel-return/report.json` |
| 4.76 MiB | `28d78561908b935b0af47c9092716f7f8e0e71a7` | `reports/data/2026-10-15/timing-stage8/return-lookahead/report.json` |
| 4.76 MiB | `43f26db0305e91a877a516af550ca08d03190d87` | `reports/data/2026-10-15/timing-stage8/load-value-tree/report.json` |
| 4.76 MiB | `15c6aa4f105678678abe4f6df24b84525e6143fd` | `reports/data/2026-10-15/timing-stage8/split-dispatch/report.json` |
| 4.75 MiB | `c18a0d92e5e198c997ddd034241fbb7e705306d9` | `reports/data/2026-10-15/timing-stage9/clean-default/report.json` |
| 4.74 MiB | `fe633486eef2904978cbd67522a1a4a24a483c4a` | `reports/data/2026-10-15/timing-stage8/store-priority/report.json` |
| 4.74 MiB | `da1e4d2e45645d4bcc559b8de3e06a0b5f047ef9` | `reports/data/2026-10-15/timing-stage8/parallel-complete/report.json` |
| 4.67 MiB | `717b5b40e429d88764fab6bdc063efc8265c1914` | `reports/data/2026-10-15/timing-stage8/forward-div/report.json` |
| 4.56 MiB | `373aa8f1701333d20a295fd9c919975d977cd34d` | `reports/data/2026-10-15/timing-stage8/cache-lookup-v2/report.json` |
| 4.51 MiB | `6b1ccc62c1d72ce49a2224d6588ccdea10efc778` | `reports/data/2026-10-15/timing-stage8/memory-grants/report.json` |
| 4.49 MiB | `5b1e1dc5c81c0f8525790052eb7a35bec6d50d45` | `reports/data/2026-10-15/timing-stage8/memory-grants-mask/report.json` |
| 4.48 MiB | `bcd0bd04f87cac57c3493087e35d84fee047165c` | `reports/data/2026-10-15/timing-stage8/parallel-issue/report.json` |
| 4.48 MiB | `1bdacca460f269482bd445d74d824655d3295439` | `reports/data/2026-10-15/timing-stage8/parallel-forward/report.json` |
| 4.46 MiB | `17d960ac1a53579dc3d294814e122e655cca5246` | `reports/data/2026-10-15/timing-stage8/local-address-rob16/report.json` |
| 4.45 MiB | `c42f97facd75e661894266e535cfab3ab483e33a` | `reports/data/2026-10-15/timing-stage8/forward-wake/report.json` |
| 4.44 MiB | `bcb67dcc85ddda92e04db9d8a240c8491676c9d2` | `reports/data/2026-10-15/timing-stage8/wb-parallel/report.json` |
| 4.43 MiB | `cdd0869a2e6481993eb585f2c2ee329feef980f4` | `reports/data/2026-10-15/timing-stage8/wake-local/report.json` |
| 4.43 MiB | `5a7c0bab750d5ecc0812110f8ea646b760b6fbee` | `reports/data/2026-10-15/timing-stage8/forward-bypass/report.json` |
| 4.41 MiB | `9be23d6d2875a49d7ea6eac40ed2dc4f2b8e1791` | `reports/data/2026-10-15/timing-stage8/clean-default/report.json` |
| 4.38 MiB | `5f495263caf53d148669ecbac82750bc1e4c754c` | `reports/data/2026-10-15/timing-stage8/rob16/report.json` |
| 4.37 MiB | `c2c1202038f3c88521cff3cfd87def8fcd29d43e` | `reports/data/2026-10-15/timing-stage8/cache-1k/report.json` |
| 4.22 MiB | `a300280b529eae7dded53f75f6f161071a90dfd6` | `reports/data/2026-10-15/timing-stage7/address-mul2-prefix-v3/report.json` |
| 3.30 MiB | `0372af0f464a79077d33124020a5269d0f512892` | `dual-issue-chisel/reports/requirements-2026-10-16/verified/synthesis/mapped.v.gz` |
| 3.25 MiB | `9609b3fd035167a984e815e2e5ec07466693c18a` | `single-issue-chisel/reports/stage1/v10-rob64-iq16/rtl/student_top.sv` |
| 3.23 MiB | `09b41057afaaaf8e43ce8e1f57406b98cd88f478` | `reports/data/2026-10-15/timing-stage7/address-mul2/report.json` |
| 3.14 MiB | `4ced6d62212a2417bc352c7f1781f5f3009d166a` | `reports/data/2026-10-15/timing-stage7/all-trees-redirect/report.json` |
| 3.13 MiB | `edf381a031230870d3f8598c4bdcc819381bf4b9` | `reports/data/2026-10-15/timing-stage7/address-radix4/report.json` |
| 2.99 MiB | `5e43533c434e6c419dc7ca86a56a925a324b32c1` | `docs/architecture/dual-issue-overview.gif` |
| 2.85 MiB | `00be446d99ff2c53c8f1e3ec79de951f19e6f2db` | `reports/data/2026-10-15/timing-stage7/structural-mul2-8-v2/report.json.gz` |
| 2.82 MiB | `c91e84950dea9af4816002b4beb32dbe53b0422a` | `reports/data/2026-10-15/timing-stage7/all-trees/report.json` |
| 2.79 MiB | `030f7f11f7c7c9f47f39cb30d829c03cd1a83049` | `reports/data/2026-10-15/timing-stage7/structural-probe/report.json.gz` |
| 2.42 MiB | `3a678812d00a6f129e58c2912ebce8d415c4e924` | `docs/architecture/single-issue-overview.gif` |
| 2.41 MiB | `43517f5e48c69f8e980a6b914224ab761ebd93da` | `single-issue-chisel/reports/stage1/v14-history2-l0-32/rtl/student_top.sv` |
| 2.36 MiB | `b68f812ee52daec88e63a9f69320fd3fb5eff67a` | `reports/data/2026-10-15/timing-stage7/structural-mul2-12-flatff/report.json.gz` |
| 2.34 MiB | `f12665873b59c9e517a50e99fd908e9132b93adf` | `reports/data/2026-10-15/timing-stage7/recovery-mdu-rob-cache/report.json` |
| 2.20 MiB | `4487de21810af9366f8eb0e122b94a299fed4afe` | `single-issue-chisel/reports/stage5/v107-combined-debug/rtl/student_top.sv` |
| 2.17 MiB | `17d8961fbab99781f62b37b64c1cebc58e5cce49` | `single-issue-chisel/reports/stage1/v15-retired-store-buffer/rtl/student_top.sv` |
