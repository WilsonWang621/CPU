#!/usr/bin/env python3
"""Combine the pinned ASAP7 cell groups, giving each timing template a unique name."""
import argparse
import re
from pathlib import Path


def group_end(text, opening):
    # Liberty braces in quoted strings do not terminate groups.
    depth, quote, escaped = 0, False, False
    for n in range(opening, len(text)):
        c = text[n]
        if quote:
            if escaped:
                escaped = False
            elif c == "\\":
                escaped = True
            elif c == '"':
                quote = False
        elif c == '"':
            quote = True
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return n + 1
    raise ValueError("Unbalanced Liberty group")


def merge(directory):
    paths = sorted(directory.glob("asap7*RVT_TT*.lib"))
    if len(paths) != 5:
        raise ValueError(f"Expected five pinned ASAP7 cell groups, found {len(paths)}")
    template_headers, cell_blocks = [], []
    header = None
    cells_seen = set()
    for number, path in enumerate(paths):
        text = path.read_text()
        for attribute, value in [("time_unit", '"1ps"'), ("voltage_unit", '"1V"')]:
            if not re.search(rf"\b{attribute}\s*:\s*{re.escape(value)}\s*;", text):
                raise ValueError(f"Unexpected units in {path}")
        first_cell = re.search(r"\n\s*cell\s*\(", text)
        if not first_cell:
            raise ValueError(f"No cells in {path}")
        # Templates differ between combinational and sequential groups. Rename
        # definitions and uses together, preserving every table and cell area.
        template_names = re.findall(r"(?:lu_table_template|power_lut_template)\s*\(\s*(\w+)\s*\)",
                                    text[:first_cell.start()])
        for name in set(template_names):
            text = re.sub(rf"\b{re.escape(name)}\b", f"group{number}_{name}", text)
        first_cell = re.search(r"\n\s*cell\s*\(", text)
        if number == 0:
            header = re.sub(r"library\s*\([^)]*\)", "library (asap7_rvt_tt)", text[:first_cell.start()], count=1)
        else:
            for match in re.finditer(r"\n\s*(?:lu_table_template|power_lut_template)\s*\([^)]*\)\s*\{",
                                     text[:first_cell.start()]):
                start = text.index("{", match.start())
                template_headers.append(text[match.start():group_end(text, start)])
        block = text[first_cell.start():text.rfind("}")]
        for name in re.findall(r"\bcell\s*\(\s*(\w+)\s*\)", block):
            if name in cells_seen:
                raise ValueError(f"Duplicate cell {name}")
            cells_seen.add(name)
        cell_blocks.append(block)
    result = directory / "asap7_rvt_tt.lib"
    result.write_text(header + "\n".join(template_headers + cell_blocks) + "\n}\n")
    print(f"Merged {len(cells_seen)} ASAP7 cells into {result}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    merge(parser.parse_args().directory)
