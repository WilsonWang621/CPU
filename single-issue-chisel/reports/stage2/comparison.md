参数、正确性和默认综合对照。未运行项目用 `—` / `not_run` 标记；原始报告在对应实验目录。

| experiment | status | debug | rob | iq | line_bytes | ic_bytes | dc_bytes | banks | btb | history_bits | l0_entries | l0_fill_stages | l0_replacement | l0_store_stages | ram_read_ahead | banked_load_payload | cache_hierarchy | prefetch_train_stages | store_entries_per_bank | store_slots | load_entries | checkpoints | fast_redirect | prefetch | ipc | frequency_mhz | area_um2 | correctness | tier2_pass |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| baseline-v66 | measured | 0 | 32 | 8 | 64 | 4096 | 4096 | 4 | 64 | 1 | 32 | 1 | 1 | 1 | 0 | 1 | 0 | 0 | 4 | 8 | 8 | 4 | 1 | 1 | 0.84776 | 304.21866 | 17605.83932 | passed | True |
| v69-registered-prefetch-training | generation_failed | 0 | 32 | 8 | 64 | 4096 | 4096 | 4 | 64 | 1 | 32 | 1 | 1 | 1 | 0 | 1 | 0 | 1 | 4 | 8 | 8 | 4 | 1 | 1 | — | — | — | not_run | False |
| v70-prefetch-training-local-cache | generation_failed | 0 | 32 | 8 | 64 | 4096 | 4096 | 4 | 64 | 1 | 32 | 1 | 1 | 1 | 0 | 1 | 1 | 1 | 4 | 8 | 8 | 4 | 1 | 1 | — | — | — | not_run | False |

六项 IPC 明细见 [comparison.csv](comparison.csv)。
