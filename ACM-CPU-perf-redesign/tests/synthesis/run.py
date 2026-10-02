#!/usr/bin/env python3
"""Reproduce dynamic-array expansion, prove the decoded rewrite, and time strict checks."""
import argparse
import hashlib
import json
import os
import signal
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def quote(path):
    return '"' + str(path).replace('\\', '\\\\').replace('"', '\\"') + '"'


def run(yosys, directory, stage, commands, timeout):
    script = directory / f'{stage}.ys'
    script.write_text('\n'.join(commands) + '\n')
    start = time.monotonic()
    with (directory / f'{stage}.log').open('w') as log:
        process = subprocess.Popen([str(yosys), '-Q', '-T', '-s', str(script)],
                                   stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
                                   cwd=directory)
        try:
            status = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait()
            status = 124
    return {'status': status, 'wall_seconds': time.monotonic() - start}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/tests-synthesis')
    parser.add_argument('--tools-dir', type=Path, default=ROOT / 'build/tools')
    parser.add_argument('--words', type=int, nargs='+', default=[128, 1024])
    parser.add_argument('--timeout', type=int, default=45)
    args = parser.parse_args()
    if args.timeout < 1 or any(n < 2 or n & (n-1) for n in args.words):
        parser.error('Timeout must be positive and word counts powers of two >=2')
    output, tools = args.output.resolve(), args.tools_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    yosys = tools / 'oss-cad-suite/bin/yosys'
    sources = {kind: ROOT / f'tests/synthesis/byte_write_{kind}.sv' for kind in ('dynamic', 'decoded')}
    report = {
        'toolchain': json.loads((ROOT / 'scripts/modern_synthesis.lock.json').read_text()),
        'sources_sha256': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources.values()},
        'timeout_seconds': args.timeout, 'runs': [],
        'scope': 'Intermediate RTLIL size and strict-check runtime; not mapped area or frequency',
    }
    okay = True
    for words in sorted(set([8] + args.words)):
        for kind, source in sources.items():
            directory = output / f'{kind}-{words}'
            directory.mkdir(exist_ok=True)
            (directory / 'sources.f').write_text(quote(source) + '\n')
            result = {'kind': kind, 'words': words}
            result['elaborate'] = run(yosys, directory, 'elaborate', [
                f'read_slang --top byte_write_probe --no-implicit-memories -G N={words} -f sources.f',
                'opt_clean', f'tee -o {quote(directory / "stat.json")} stat -json',
                f'write_rtlil {quote(directory / "design.il")}'], args.timeout)
            if result['elaborate']['status'] == 0:
                result['statistics'] = json.loads((directory / 'stat.json').read_text())['design']
                result['check'] = run(yosys, directory, 'check', [
                    f'read_rtlil {quote(directory / "design.il")}', 'check -assert -nolatches'], args.timeout)
                # A timed-out dynamic model is an observed audit result. A
                # decoded model must finish with every strict check enabled.
                okay &= result['check']['status'] == 0 or (kind == 'dynamic' and result['check']['status'] == 124)
            else:
                okay = False
            report['runs'].append(result)
            (output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
            print(f'{kind} {words} words: {result.get("check", result["elaborate"])}', flush=True)
    report['equivalence'] = run(yosys, output, 'equivalence', [
        f'read_rtlil {quote(output / "dynamic-8/design.il")}', 'rename byte_write_probe gold',
        f'read_rtlil {quote(output / "decoded-8/design.il")}', 'rename byte_write_probe gate',
        'equiv_make gold gate equiv', 'hierarchy -top equiv', 'equiv_simple',
        'equiv_induct -seq 2', 'equiv_status -assert'], args.timeout)
    okay &= report['equivalence']['status'] == 0
    report['status'] = 'pass' if okay else 'failed'
    (output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f'Audit {report["status"]}: {output / "results.json"}')
    return 0 if okay else 1


if __name__ == '__main__':
    raise SystemExit(main())
