#!/usr/bin/env python3
"""Compare every CPU retirement with the independent RV32IM interpreter."""
import argparse
import csv
import json
import sys
from pathlib import Path
from reference import ExecutionError, load_image, run

FIELDS = ("pc", "inst", "rd", "value", "store", "addr", "wdata", "wstrb")


def compare(image, trace, instruction_limit=100_000_000):
    count = 0
    with Path(trace).open() as stream:
        reader = csv.DictReader(stream)
        if tuple(reader.fieldnames or ()) != FIELDS:
            raise ExecutionError(f"invalid trace columns: {reader.fieldnames}")

        def check(expected):
            nonlocal count
            count += 1
            row = next(reader, None)
            if row is None:
                raise ExecutionError(f"trace ended before retirement {count} at PC 0x{expected[0]:08x}")
            try:
                actual = tuple(int(row[field], 16) for field in FIELDS)
            except (ValueError, TypeError) as error:
                raise ExecutionError(f"invalid trace at retirement {count}: {row}") from error
            # Value is architecturally meaningful only for a nonzero destination;
            # memory columns describe stores only. All other fields must match.
            meaningful = [0, 1, 2, 4]
            if expected[2]:
                meaningful.append(3)
            if expected[4]:
                meaningful += [5, 7]
            for index in meaningful:
                if actual[index] != expected[index]:
                    raise ExecutionError(
                        f"retirement {count}, PC 0x{expected[0]:08x}: {FIELDS[index]} "
                        f"actual=0x{actual[index]:08x}, expected=0x{expected[index]:08x}")

            if expected[4]:
                mask = sum(0xff << (8 * lane) for lane in range(4) if (expected[7] >> lane) & 1)
                if (actual[6] & mask) != (expected[6] & mask):
                    raise ExecutionError(
                        f"retirement {count}, PC 0x{expected[0]:08x}: store bytes "
                        f"actual=0x{actual[6] & mask:08x}, expected=0x{expected[6] & mask:08x}")

        result, retired, _ = run(load_image(Path(image)), instruction_limit, check)
        if next(reader, None) is not None:
            raise ExecutionError("trace contains extra retirements after exit")
    return {"status": "pass", "instructions": retired, "exit_value": result}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True, type=Path)
    parser.add_argument("--trace", required=True, type=Path)
    parser.add_argument("--instruction-limit", type=int, default=100_000_000)
    args = parser.parse_args()
    try:
        print(json.dumps(compare(args.image, args.trace, args.instruction_limit)))
        return 0
    except (OSError, ValueError, ExecutionError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
