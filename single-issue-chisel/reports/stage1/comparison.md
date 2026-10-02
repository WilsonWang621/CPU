参数、正确性和默认综合对照。未运行项目用 `—` / `not_run` 标记；原始报告在对应实验目录。

| experiment | rob | iq | line_bytes | banks | btb | history_bits | prefetch | ipc | frequency_mhz | area_um2 | correctness | tier2_pass |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| base-v1 | 16 | 8 | 32 | 1 | 64 | 0 | 0 | 0.55568 | 48.47108 | 13669.66387 | 19 | False |
| v10-rob64-iq16 | 64 | 16 | 64 | 4 | 64 | 0 | 1 | 0.79362 | — | — | not_run | False |
| v11-local-history | 32 | 8 | 64 | 4 | 128 | 1 | 1 | 0.79189 | — | — | not_run | False |
| v3-sram-tags | 16 | 8 | 32 | 1 | 64 | 0 | 0 | 0.60491 | 107.75545 | 12316.24971 | passed | False |
| v4-sram-sectors | 16 | 8 | 32 | 1 | 64 | 0 | 0 | 0.60491 | 121.01158 | 11953.76525 | not_run | False |
| v5-banked-cache | — | — | — | 1 | 64 | 0 | 0 | — | — | — | not_run | False |
| v5b-banked-cache | 16 | 8 | 32 | 4 | 64 | 0 | 0 | 0.62487 | 98.94676 | 12991.20925 | not_run | False |
| v6-early-recovery | 16 | 8 | 32 | 4 | 64 | 0 | 0 | 0.67052 | — | — | passed | False |
| v7-rob32-line64 | 32 | 8 | 64 | 4 | 64 | 0 | 0 | 0.70916 | — | — | not_run | False |
| v8-load-bypass | 32 | 8 | 64 | 4 | 64 | 0 | 0 | 0.75831 | — | — | not_run | False |
| v9-stream-prefetch | 32 | 8 | 64 | 4 | 64 | 0 | 1 | 0.78599 | 118.79350 | 15827.15397 | passed | False |

六项 IPC 明细见 [comparison.csv](comparison.csv)。
