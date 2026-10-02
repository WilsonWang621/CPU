# CPU 2026：四路 RV32IM 乱序处理器

**新架构路线已改为 [Area-v2](../../design.md)**：以 40,000 面积为硬约束，重新设计小窗口乱序核心和固定端口缓存。已完成方案、关键结构映射和性能模型筛选，见 [新工作区](../../designs/area_v2/README.md)。尚无完整 v2 CPU；以下构建命令和实测 IPC 属于旧四路实现。

采用流水统一内存、四路取指/重命名/执行/写回/提交、一周期重命名映射重建、推测多 Load 与内存违例重放、字节前递、非阻塞 sector cache、单周期乘法和独立高基数除法。

历史四路中心配置（测量源码见报告）在 20 周期延迟、冷缓存、包含退出排空与清脏的六项性能回归中测得总 IPC **1.489920**，六项算术平均 **1.550394**。这两种汇总口径均超过 1.0140；面积与 300 MHz 是独立验收项，进度和候选配置见 [报告](../../reports/architecture.md)。不能用 IPC 通过宣称完整性能评分通过。

较新的精简四路配置实测总 IPC **1.092137**，并通过 3/20 周期各 25 项完整差分与 29 项随机系统测试；源码及参数见 [整合验证记录](../../reports/data/lean_integrated_validation.json)。一个后续冻结版本已完成严格全核映射，但面积超标、STA 超时，`pi` 运行时间也超过 30 秒；准确版本与结果见 [综合诊断](../../reports/synthesis.md)。后续优化仍在继续。

用户确认课程输入只有本仓库固定版本的三个子模块，并明确授权流水内存。外存接口每周期可接受一笔 32 位请求，每笔读写仍在 20 周期后响应，最多 64 笔在途。接口详见 [docs/interfaces.md](../../docs/interfaces.md)，旧四路架构详见 [归档](../../docs/archive/fourwide-v1.md)。旧串行版本仅保留在 Git 标签 `baseline-correct-serial`。

## 构建与回归

需要 Linux x86-64、Python 3、Make、G++；Verilator 来自随附工具链。克隆后执行 `git submodule update --init --recursive`。

```sh
make build JOBS=4
make test LATENCY=3 TEST_ARGS=--differential
make test LATENCY=20 TEST_ARGS=--differential
make test-system LATENCY=20 TEST_ARGS='--random-wait 9 --request-wait 3'
make test-isa
make test-cache
make test-frontend
make test-core
make test-lsu
```

全程序回归比较 25 个镜像的退出值、精确退休数及完整 256 KiB 最终 RAM。`--differential` 逐条比较退休 PC、指令、寄存器写值和 Store 字节记录。核心/LSU 测试还要求实际触发四路退休、checkpoint 恢复、Load 重放、迟到结果取消及资源重用，不能只凭最终结果推测机制被覆盖。

```sh
build/cpu_sim --image RISC-V-CPU-2026-Testcases/perf_vvadd/program.data \
  --expected RISC-V-CPU-2026-Testcases/perf_vvadd/expected.txt \
  --memory RISC-V-CPU-2026-Testcases/perf_vvadd/expected.memory \
  --instructions 4524 --latency 20 --max-outstanding 64
```

成功输出 JSON，错误返回非零。默认无波形及逐周期日志。JSON 含退休 0–4 条周期分布、分支恢复、Load 重放、缓存缺失、内存并发、耗时及 RSS。退休跟踪仅在明确传入 `--trace` 时生成。

## 参数和实验

```sh
make build BUILD_DIR=build/dual PARAMS='-GFETCH_WIDTH=2 -GRENAME_WIDTH=2 -GISSUE_WIDTH=2 -GWB_WIDTH=2 -GCOMMIT_WIDTH=2'
python3 scripts/parameter_sweep.py default width2 issue2 phys96 rob32 iq16 --jobs 4
python3 scripts/parameter_sweep.py compact dcache4096 dcache8192 --jobs 4
```

五个宽度独立支持 1/2/4，队列和寄存器容量可独立调整。中心配置为 PRF128/ROB64/IQ32，I-cache4KiB/2路/4MSHR，D-cache16KiB/4路/8MSHR；完整默认值与合法条件在 `rtl/cpu_top.sv`。大配置不是面积合格的保证，较小候选必须同时保留正确性和实测 IPC。

`BUILD_DIR` 隔离配置；扫描保存源码与镜像 SHA-256、Git 版本、构建参数及逐程序结果。性能统计固定为 20 周期、II=1、冷缓存，包含所有退出工作。没有删掉清脏周期，也没有预装程序数据进缓存。

## 综合

```sh
python3 scripts/bootstrap_synth.py
make export-verilog
make synth-check
make synth
```

工具和 ASAP7 Liberty 下载来源及 SHA 固定在 `scripts/synthesis.lock.json`，安装到 `build/tools`，不修改系统环境。sv2v 导出可交给 Yosys/Verilator 的 Verilog；综合包装层只移除未连接的调试观测，cache、PRF、队列仍计入真实片上面积。具体工具约束、已完成检查和结果限制见 [docs/synthesis.md](../../docs/synthesis.md)。ABC 延迟约束不是完成的布局布线时序证明。

实现 ISA 为题目 RV32IM 子集及 LB/LBU/LH/LHU；不含特权态、CSR、ECALL/EBREAK、FENCE/FENCE.I、压缩、原子或自修改代码。非法、非对齐和越界访问在正确路径 ROB 头报告精确调试 fault。
