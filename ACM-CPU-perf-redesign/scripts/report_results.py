#!/usr/bin/env python3
"""Render performance tables and charts solely from frozen measured inputs."""
import argparse
import csv
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TARGET = 1.0140


def summary(rows):
    return (sum(r['instructions'] for r in rows) / sum(r['cycles'] for r in rows),
            sum(r['ipc'] for r in rows) / len(rows))


def read(path):
    return json.loads(path.read_text())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--center', type=Path, required=True, help='six-program summary.json')
    parser.add_argument('--center-metadata', type=Path, required=True, help='frozen build source/binary metadata')
    parser.add_argument('--sweeps', type=Path, nargs='*', default=[])
    parser.add_argument('--validation', type=Path, nargs='*', default=[])
    parser.add_argument('--output', type=Path, default=ROOT / 'reports')
    parser.add_argument('--plots', action='store_true', help='requires matplotlib')
    args = parser.parse_args()
    center = read(args.center)
    center_metadata = read(args.center_metadata)
    source_hashes = center_metadata.get('sources_sha256', center_metadata.get('source_sha256'))
    if not source_hashes or not center_metadata.get('binary_sha256'):
        raise SystemExit('Center metadata must identify actual measured sources and binary')
    if center['passed'] != 6 or center['failed'] or center['latency'] != 20:
        raise SystemExit('Center must pass all six programs at latency20')
    rows = center['results']
    if any(row.get('max_outstanding') != 64 for row in rows):
        raise SystemExit('Center measurements must use the documented 64-credit model')
    aggregate, mean = summary(rows)
    records = {'default': {'configuration': 'default', 'parameters': center_metadata.get('parameters', {}),
                            'status': 'pass', 'measurements': center}}
    batches = []
    for path in args.sweeps:
        batch = read(path)
        if batch['latency'] != 20 or batch.get('memory_initiation_interval') != 1:
            raise SystemExit(f'Incompatible memory contract: {path}')
        batches.append({key: value for key, value in batch.items() if key != 'results'})
        for record in batch['results']:
            if record['status'] != 'pass' or record['measurements']['failed']:
                raise SystemExit(f"Unsuccessful measured point: {record['configuration']}")
            records[record['configuration']] = record
    validations = [{'source': str(path), 'measurements': read(path)} for path in args.validation]
    output = args.output
    (output / 'data').mkdir(parents=True, exist_ok=True)
    archive = {'target_ipc': TARGET, 'memory': {'latency': 20, 'initiation_interval': 1,
               'bits': 32, 'max_outstanding': 64, 'ordered_responses': True,
               'cold_caches': True, 'includes_startup_and_flush': True},
               'measurement_scope': 'Frozen source snapshots; not necessarily current working-tree RTL',
               'center_sources_sha256': source_hashes,
               'center_metadata': center_metadata,
               'batches': batches, 'configurations': list(records.values()), 'validation': validations}
    (output / 'data/measurements.json').write_text(json.dumps(archive, indent=2) + '\n')
    columns = ['instructions', 'cycles', 'ipc', 'memory_requests', 'memory_writes',
               'memory_pending_cycles', 'memory_transaction_cycles', 'memory_peak_outstanding',
               'branch_misses', 'icache_misses', 'dcache_misses', 'load_replay_count'] + [
               f'retire_cycles_{i}' for i in range(5)]
    with (output / 'data/performance.csv').open('w', newline='') as stream:
        writer = csv.writer(stream)
        writer.writerow(['configuration', 'parameters', 'program'] + columns)
        for name, record in records.items():
            for row in record['measurements']['results']:
                writer.writerow([name, json.dumps(record['parameters'], sort_keys=True), row['case']] +
                                [row[key] for key in columns])
    totals = {name: summary(record['measurements']['results']) for name, record in records.items()}
    text = ['# 参数敏感度报告', '',
        f'中心配置在 20 周期内存延迟下，总 IPC **{aggregate:.6f}**，六项 IPC 算术平均 **{mean:.6f}**。'
        f'目标为 {TARGET:.4f}；两种汇总方式分别为目标的 {aggregate/TARGET:.3f} 和 {mean/TARGET:.3f} 倍。', '',
        '数据来自实际 Verilator RTL 仿真。外存统一为 32 位、II=1、64 在途、有序响应；'
        '每笔读写等待 20 周期，冷复位，包含启动、恢复、Store 排空和清脏。'
        '原始版本/源码哈希、参数和逐程序数据保存在 [data/measurements.json](data/measurements.json)，'
        '表格数据见 [data/performance.csv](data/performance.csv)。', '',
        '每个扫描点都检查六项程序的退出值、精确退休数、完整最终 RAM。'
        '完整正确性回归仅以存档 validation 数据中列出的测试为准。'
        '未写出的参数沿用该批次源码的 cpu_top 默认值，不能拿其他版本默认值解释历史数据。', '',
        '| 配置 | 参数变化 | 总 IPC | 算术平均 | 相对中心总 IPC |',
        '| --- | --- | ---: | ---: | ---: |']
    for name, record in records.items():
        ipc, avg = totals[name]
        parameters = ', '.join(f'{key}={value}' for key, value in record['parameters'].items()) or '默认中心配置'
        text.append(f'| {name} | {parameters} | {ipc:.6f} | {avg:.6f} | {(ipc/aggregate-1)*100:+.2f}% |')
    text += ['', '## 逐程序结果', '',
        '| 程序 | 退休数 | 周期 | IPC | 分支恢复 | D-cache 缺失分配 | 峰值在途 |',
        '| --- | ---: | ---: | ---: | ---: | ---: | ---: |']
    for row in rows:
        text.append(f"| {row['case']} | {row['instructions']} | {row['cycles']} | {row['ipc']:.6f} | "
                    f"{row['branch_misses']} | {row['dcache_misses']} | {row['memory_peak_outstanding']} |")
    text += ['', '逐程序 IPC 与汇总 IPC 是不同要求。本报告的达标结论针对上面明确列出的两种汇总公式，'
        '不声称每一个程序都分别超过 1.0140。缓存缺失计数包含 sector 补齐所分配的 MSHR，不能直接当成不同缓存行数。', '',
        '## 指标解释', '',
        '`width2` 同时改变全链路宽度，`issue2` 只改变执行发射宽度；二者区分执行资源与前后端带宽。'
        '`phys96`、`rob32` 和 `iq16` 各自只改变一类容量。缓存点保持 core 参数不变；'
        '`compact` 是明确列出参数的联合面积探索点，不能称为单因素结果。', '',
        'bimodal/gshare/tournament 使用相同缓存、流水和内存。chooser 只根据实际取指时保存的两个分量预测训练；'
        '不会使用基准程序名称、已知答案或离线轨迹作为硬件预测输入。', '',
        '面积/频率须按同一配置独立测量，当前 IPC 达标不等于完整评分达标。'
        '综合的实际阶段、工具版本和限制见 [synthesis.md](synthesis.md)。'
        '不把未知面积填成 0，也不绘制虚构的 IPC–面积 Pareto 图。']
    if args.plots:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
        fig, ax = plt.subplots(figsize=(10, max(4, len(totals)*.35)))
        names = list(totals)
        ax.barh(names, [totals[n][0] for n in names], color=['#205989' if n=='default' else '#73a9c6' for n in names])
        ax.axvline(TARGET, color='#be4d30', linestyle='--', label='Target 1.0140')
        ax.set_xlabel('Total retired instructions / total cycles (20-cycle RAM)')
        ax.invert_yaxis();ax.grid(axis='x', alpha=.2);ax.legend();fig.tight_layout()
        fig.savefig(output/'parameter_ipc.svg');plt.close(fig)
        fig, ax = plt.subplots(figsize=(9,4))
        names = [r['case'].removeprefix('perf_') for r in rows]
        bottom = [0.0]*len(rows)
        for i, color in enumerate(['#e1e7ec','#b5ccdb','#80aac4','#487faa','#205989']):
            values = [r[f'retire_cycles_{i}']/r['cycles'] for r in rows]
            ax.bar(names, values, bottom=bottom, label=str(i), color=color)
            bottom = [a+b for a,b in zip(bottom,values)]
        ax.set_ylabel('Fraction of cycles');ax.legend(title='Retirements / cycle', ncol=5);fig.tight_layout()
        fig.savefig(output/'retirement_utilization.svg');plt.close(fig)
        text += ['', '![Measured parameter IPC](parameter_ipc.svg)', '', '![Retirement utilization](retirement_utilization.svg)']
    (output/'parameter_sensitivity.md').write_text('\n'.join(text)+'\n')
    print(f'Rendered {len(records)} configurations; aggregate={aggregate:.6f}, mean={mean:.6f}')


if __name__=='__main__':
    main()
