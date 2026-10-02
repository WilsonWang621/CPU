#!/usr/bin/env python3
"""Identify loaded nets and their RTL aliases in a course synthesis result."""
import argparse
from collections import defaultdict
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--limit', type=int, default=20)
    args = parser.parse_args()
    top = json.loads((args.directory / 'design.json').read_text())['modules']['student_top']
    aliases, drivers, loads = defaultdict(list), {}, defaultdict(list)
    for name, net in top['netnames'].items():
        if not net.get('hide_name'):
            for index, bit in enumerate(net['bits']):
                aliases[bit].append(f'{name}[{index}]')
    for name, cell in top['cells'].items():
        for port, bits in cell['connections'].items():
            for bit in bits:
                if not isinstance(bit, int):
                    continue
                if cell['port_directions'][port] == 'output':
                    drivers[bit] = f'{name}/{port} ({cell["type"]})'
                elif port != 'CLK':
                    loads[bit].append(f'{name}/{port}')
    for bit in sorted(loads, key=lambda bit: len(loads[bit]), reverse=True)[:args.limit]:
        print(f'{len(loads[bit]):6d} loads: {drivers.get(bit, "input")} bit={bit}')
        print('  aliases:', ', '.join(aliases[bit]) or '(internal mapping net)')
        print('  sample loads:', ', '.join(loads[bit][:5]))


if __name__ == '__main__':
    main()
