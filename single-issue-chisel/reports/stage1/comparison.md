参数、正确性和默认综合对照。未运行项目用 `—` / `not_run` 标记；原始报告在对应实验目录。

| experiment | rob | iq | line_bytes | banks | btb | history_bits | l0_entries | store_entries_per_bank | checkpoints | fast_redirect | prefetch | ipc | frequency_mhz | area_um2 | correctness | tier2_pass |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| base-v1 | 16 | 8 | 32 | 1 | 64 | 0 | 0 | 0 | 0 | 0 | 0 | 0.55568 | 48.47108 | 13669.66387 | 19 | False |
| v10-rob64-iq16 | 64 | 16 | 64 | 4 | 64 | 0 | 0 | 0 | 0 | 0 | 1 | 0.79362 | — | — | not_run | False |
| v11-local-history | 32 | 8 | 64 | 4 | 128 | 1 | 0 | 0 | 0 | 0 | 1 | 0.79189 | — | — | not_run | False |
| v12-registered-ages | 32 | 8 | 64 | 4 | 128 | 1 | 0 | 0 | 0 | 0 | 1 | 0.79183 | 99.37888 | 19019.41581 | passed | False |
| v13-l0-16 | 32 | 8 | 64 | 4 | 128 | 1 | 16 | 0 | 0 | 0 | 1 | 0.80010 | — | — | passed | False |
| v14-history2-l0-32 | 32 | 8 | 64 | 4 | 256 | 2 | 32 | 0 | 0 | 0 | 1 | 0.80034 | — | — | not_run | False |
| v15-retired-store-buffer | 32 | 8 | 64 | 4 | 128 | 1 | 16 | 4 | 0 | 0 | 1 | 0.81546 | — | — | not_run | False |
| v16-checkpoint-onehot | 32 | 8 | 64 | 4 | 64 | 1 | 16 | 4 | 4 | 0 | 1 | 0.81520 | 134.41848 | 17293.43541 | not_run | False |
| v17-local-payload | 32 | 8 | 64 | 4 | 64 | 1 | 16 | 4 | 4 | 0 | 1 | 0.81518 | 147.44420 | 17493.00645 | not_run | False |
| v18-l0-refill-forward | 32 | 8 | 64 | 4 | 64 | 1 | 32 | 4 | 4 | 0 | 1 | 0.82420 | — | — | not_run | False |
| v19-execution-training | 32 | 8 | 64 | 4 | 64 | 1 | 32 | 4 | 4 | 0 | 1 | 0.82438 | — | — | not_run | False |
| v20-fast-frontend-recovery | 32 | 8 | 64 | 4 | 64 | 1 | 32 | 4 | 4 | 1 | 1 | 0.84465 | — | — | not_run | False |
| v21-l0-64-ic2k | 32 | 8 | 64 | 4 | 64 | 1 | 64 | 4 | 4 | 1 | 1 | 0.82749 | — | — | not_run | False |
| v22-line128-l0-64 | 32 | 8 | 128 | 4 | 64 | 1 | 64 | 4 | 4 | 1 | 1 | 0.82077 | — | — | not_run | False |
| v23-execution-prepare | 32 | 8 | 64 | 4 | 64 | 1 | 32 | 4 | 4 | 1 | 1 | 0.84465 | 110.27353 | 18300.70929 | not_run | False |
| v24-flow-store-buffer | 32 | 8 | 64 | 4 | 64 | 1 | 32 | 4 | 4 | 1 | 1 | 0.84634 | 115.14674 | 18258.86469 | passed | False |
| v25-scoped-read-write | — | — | — | 1 | 64 | 0 | 0 | 0 | 0 | 0 | 0 | — | — | — | not_run | False |
| v25b-scoped-read-write | — | — | — | 1 | 64 | 0 | 0 | 0 | 0 | 0 | 0 | — | — | — | not_run | False |
| v25c-scoped-read-write | 32 | 8 | 64 | 4 | 64 | 1 | 32 | 4 | 4 | 1 | 1 | 0.84634 | 98.23484 | 18887.84589 | not_run | False |
| v26-load-bank-selection | 32 | 8 | 64 | 4 | 64 | 1 | 32 | 4 | 4 | 1 | 1 | — | — | — | not_run | False |
| v27-registered-wrap | 32 | 8 | 64 | 4 | 64 | 1 | 32 | 4 | 4 | 1 | 1 | — | — | — | not_run | False |
| v27b-registered-wrap | 32 | 8 | 64 | 4 | 64 | 1 | 32 | 4 | 4 | 1 | 1 | 0.84962 | 105.83979 | 19386.70059 | not_run | False |
| v28-rob16-bank-selection | 16 | 8 | 64 | 4 | 64 | 1 | 32 | 4 | 4 | 1 | 1 | 0.84405 | — | — | not_run | False |
| v29-two-cache-banks | 32 | 8 | 64 | 2 | 64 | 1 | 32 | 4 | 4 | 1 | 1 | 0.82472 | — | — | not_run | False |
| v3-sram-tags | 16 | 8 | 32 | 1 | 64 | 0 | 0 | 0 | 0 | 0 | 0 | 0.60491 | 107.75545 | 12316.24971 | passed | False |
| v4-sram-sectors | 16 | 8 | 32 | 1 | 64 | 0 | 0 | 0 | 0 | 0 | 0 | 0.60491 | 121.01158 | 11953.76525 | not_run | False |
| v5-banked-cache | — | — | — | 1 | 64 | 0 | 0 | 0 | 0 | 0 | 0 | — | — | — | not_run | False |
| v5b-banked-cache | 16 | 8 | 32 | 4 | 64 | 0 | 0 | 0 | 0 | 0 | 0 | 0.62487 | 98.94676 | 12991.20925 | not_run | False |
| v6-early-recovery | 16 | 8 | 32 | 4 | 64 | 0 | 0 | 0 | 0 | 0 | 0 | 0.67052 | — | — | passed | False |
| v7-rob32-line64 | 32 | 8 | 64 | 4 | 64 | 0 | 0 | 0 | 0 | 0 | 0 | 0.70916 | — | — | not_run | False |
| v8-load-bypass | 32 | 8 | 64 | 4 | 64 | 0 | 0 | 0 | 0 | 0 | 0 | 0.75831 | — | — | not_run | False |
| v9-stream-prefetch | 32 | 8 | 64 | 4 | 64 | 0 | 0 | 0 | 0 | 0 | 1 | 0.78599 | 118.79350 | 15827.15397 | passed | False |

六项 IPC 明细见 [comparison.csv](comparison.csv)。
