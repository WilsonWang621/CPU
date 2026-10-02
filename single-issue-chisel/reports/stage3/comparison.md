参数、正确性和默认综合对照。未运行项目用 `—` / `not_run` 标记；原始报告在对应实验目录。

| experiment | status | debug | rob | iq | line_bytes | ic_bytes | dc_bytes | banks | btb | history_bits | l0_entries | l0_fill_stages | l0_replacement | l0_store_stages | ram_read_ahead | banked_load_payload | cache_hierarchy | prefetch_train_stages | trusted_load_credit | ras_write_stages | registered_squash_mask | cache_return_stages | store_entries_per_bank | store_slots | load_entries | checkpoints | fast_redirect | prefetch | ipc | frequency_mhz | area_um2 | correctness | tier2_pass |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| baseline-v71 | measured | 0 | 32 | 8 | 64 | 4096 | 4096 | 4 | 64 | 1 | 32 | 1 | 1 | 1 | 0 | 1 | 0 | 1 | 1 | 0 | 0 | 0 | 4 | 8 | 8 | 4 | 1 | 1 | 0.84602 | 307.69231 | 17653.37012 | passed | True |
| v74-debug-recovery-credit-invariants | measured | 1 | 32 | 8 | 64 | 4096 | 4096 | 4 | 64 | 1 | 32 | 1 | 1 | 1 | 0 | 1 | 0 | 1 | 1 | 0 | 1 | 0 | 4 | 8 | 8 | 4 | 1 | 1 | 0.84602 | — | — | passed | False |
| v74-registered-recovery-mask | measured | 0 | 32 | 8 | 64 | 4096 | 4096 | 4 | 64 | 1 | 32 | 1 | 1 | 1 | 0 | 1 | 0 | 1 | 1 | 0 | 1 | 0 | 4 | 8 | 8 | 4 | 1 | 1 | 0.84602 | 304.67123 | 17725.52654 | passed | True |
| v75-recovery-mask-ras-stage | measured | 0 | 32 | 8 | 64 | 4096 | 4096 | 4 | 64 | 1 | 32 | 1 | 1 | 1 | 0 | 1 | 0 | 1 | 1 | 1 | 1 | 0 | 4 | 8 | 8 | 4 | 1 | 1 | 0.84602 | 308.71269 | 17754.13250 | passed | True |
| v76-small-rob-larger-l0 | measured | 0 | 16 | 8 | 64 | 4096 | 4096 | 4 | 64 | 1 | 64 | 1 | 1 | 1 | 0 | 1 | 0 | 1 | 1 | 0 | 1 | 0 | 4 | 8 | 8 | 4 | 1 | 1 | 0.83811 | 233.57664 | 18592.22006 | passed | False |
| v77-registered-cache-return | measured | 0 | 32 | 8 | 64 | 4096 | 4096 | 4 | 64 | 1 | 32 | 1 | 1 | 1 | 0 | 1 | 0 | 1 | 1 | 1 | 1 | 1 | 4 | 8 | 8 | 4 | 1 | 1 | 0.83600 | 322.82472 | 17761.61204 | passed | False |
| v78-cache-return-ras-direct | measured | 0 | 32 | 8 | 64 | 4096 | 4096 | 4 | 64 | 1 | 32 | 1 | 1 | 1 | 0 | 1 | 0 | 1 | 1 | 0 | 1 | 1 | 4 | 8 | 8 | 4 | 1 | 1 | 0.83600 | 285.79403 | 17721.95444 | passed | False |

六项 IPC 明细见 [comparison.csv](comparison.csv)。
