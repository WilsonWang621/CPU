参数、正确性和默认综合对照。未运行项目用 `—` / `not_run` 标记；原始报告在对应实验目录。

| experiment | status | debug | rob | iq | line_bytes | ic_bytes | dc_bytes | banks | btb | history_bits | l0_entries | l0_fill_stages | l0_replacement | l0_store_stages | ram_read_ahead | banked_load_payload | cache_hierarchy | prefetch_train_stages | trusted_load_credit | ras_write_stages | registered_squash_mask | cache_return_stages | store_entries_per_bank | store_slots | load_entries | checkpoints | fast_redirect | prefetch | ipc | frequency_mhz | area_um2 | correctness | tier2_pass |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| baseline-v66 | measured | 0 | 32 | 8 | 64 | 4096 | 4096 | 4 | 64 | 1 | 32 | 1 | 1 | 1 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 4 | 8 | 8 | 4 | 1 | 1 | 0.84776 | 304.21866 | 17605.83932 | passed | True |
| v69-registered-prefetch-training | generation_failed | 0 | 32 | 8 | 64 | 4096 | 4096 | 4 | 64 | 1 | 32 | 1 | 1 | 1 | 0 | 1 | 0 | 1 | 0 | 0 | 0 | 0 | 4 | 8 | 8 | 4 | 1 | 1 | — | — | — | not_run | False |
| v69b-registered-prefetch-training | measured | 0 | 32 | 8 | 64 | 4096 | 4096 | 4 | 64 | 1 | 32 | 1 | 1 | 1 | 0 | 1 | 0 | 1 | 0 | 0 | 0 | 0 | 4 | 8 | 8 | 4 | 1 | 1 | 0.84602 | 271.04288 | 17656.79642 | passed | False |
| v70-prefetch-training-local-cache | generation_failed | 0 | 32 | 8 | 64 | 4096 | 4096 | 4 | 64 | 1 | 32 | 1 | 1 | 1 | 0 | 1 | 1 | 1 | 0 | 0 | 0 | 0 | 4 | 8 | 8 | 4 | 1 | 1 | — | — | — | not_run | False |
| v70b-prefetch-training-local-cache | measured | 0 | 32 | 8 | 64 | 4096 | 4096 | 4 | 64 | 1 | 32 | 1 | 1 | 1 | 0 | 1 | 1 | 1 | 0 | 0 | 0 | 0 | 4 | 8 | 8 | 4 | 1 | 1 | 0.84602 | 237.47681 | 17692.02170 | passed | False |
| v71-qualified-load-admission | measured | 0 | 32 | 8 | 64 | 4096 | 4096 | 4 | 64 | 1 | 32 | 1 | 1 | 1 | 0 | 1 | 0 | 1 | 1 | 0 | 0 | 0 | 4 | 8 | 8 | 4 | 1 | 1 | 0.84602 | 307.69231 | 17653.37012 | passed | True |
| v72-ras-write-stage-bypass | measured | 0 | 32 | 8 | 64 | 4096 | 4096 | 4 | 64 | 1 | 32 | 1 | 1 | 1 | 0 | 1 | 0 | 0 | 0 | 1 | 0 | 0 | 4 | 8 | 8 | 4 | 1 | 1 | 0.84776 | 296.89765 | 17622.70838 | passed | False |
| v73-ras-prefetch-qualified-credit | measured | 0 | 32 | 8 | 64 | 4096 | 4096 | 4 | 64 | 1 | 32 | 1 | 1 | 1 | 0 | 1 | 0 | 1 | 1 | 1 | 0 | 0 | 4 | 8 | 8 | 4 | 1 | 1 | 0.84602 | 300.46948 | 17682.45722 | passed | True |

六项 IPC 明细见 [comparison.csv](comparison.csv)。
