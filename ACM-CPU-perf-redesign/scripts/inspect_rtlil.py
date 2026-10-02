#!/usr/bin/env python3
"""Summarize RTLIL cell widths and source locations as JSON (not mapped area)."""
import argparse
import collections
import json
import re
from pathlib import Path


def inspect(path):
    cells = []
    source = ''
    cell = None
    for line in path.open():
        match = re.match(r'  attribute \\src "(.*)"', line)
        if match:
            source = match[1]
        match = re.match(r'  cell (\S+) (\S+)', line)
        if match:
            cell = {'type': match[1], 'name': match[2], 'source': source, 'parameters': {}}
            source = ''
        if cell is None:
            if line.startswith(('  wire ', '  memory ', '  connect ')):
                source = ''
            continue
        match = re.match(r'    parameter \\(\w+) ([-0-9]+)$', line.rstrip('\n'))
        if match:
            cell['parameters'][match[1]] = int(match[2])
        if line != '  end\n':
            continue
        parameters = cell['parameters']
        width = parameters.get('WIDTH', parameters.get('Y_WIDTH', parameters.get('Q_WIDTH', 0)))
        output_bits = width
        input_bits = parameters.get('A_WIDTH', 0) + parameters.get('B_WIDTH', 0)
        if cell['type'] == '$bmux':
            input_bits = width * (1 << parameters['S_WIDTH']) + parameters['S_WIDTH']
        elif cell['type'] == '$demux':
            output_bits = width * (1 << parameters['S_WIDTH'])
            input_bits = width + parameters['S_WIDTH']
        elif cell['type'] == '$mux':
            input_bits = width * 2 + 1
        cell.update(output_bits=output_bits, input_bits=input_bits)
        cells.append(cell)
        cell = None

    summary, sources = {}, {}
    for cell in cells:
        filename = Path(cell['source'].split(':')[0]).name or '<generated>'
        group = summary.setdefault(filename, {'cells': 0, 'output_bits': 0, 'input_bits': 0,
                                               'types': collections.Counter()})
        group['types'][cell['type']] += 1
        location = sources.setdefault(cell['source'], {'cells': 0, 'output_bits': 0, 'input_bits': 0})
        for count in (group, location):
            count['cells'] += 1
            count['output_bits'] += cell['output_bits']
            count['input_bits'] += cell['input_bits']
    return {
        'input': str(path),
        'scope': 'Intermediate cell port-width estimates; not distinct gates, storage bits, or mapped area',
        'summary': summary,
        'largest_output': sorted(cells, key=lambda cell: cell['output_bits'], reverse=True)[:20],
        'largest_input': sorted(cells, key=lambda cell: cell['input_bits'], reverse=True)[:20],
        'source_output_bits': sorted(sources.items(), key=lambda item: item[1]['output_bits'], reverse=True)[:30],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('rtlil', type=Path)
    args = parser.parse_args()
    print(json.dumps(inspect(args.rtlil), indent=2))


if __name__ == '__main__':
    main()
