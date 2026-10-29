#!/usr/bin/env python3
"""Writes the scale benchmark for `bin/doir --bench` (`roadmap.md` Phases 2-3): copies of `standard.doir`, each in a namespace of its own, until the file reaches the requested number of lines.

    python3 tools/gen_scale.py [lines] [output]    # defaults: 1000000 lines, bin/scale.doir
"""

import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def main():
	"""Writes the benchmark file; returns 0."""
	lines = int(sys.argv[1]) if len(sys.argv) > 1 else 1_000_000
	output = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "bin" / "scale.doir"
	source = (ROOT / "standard.doir").read_text(encoding="utf-8")
	per_copy = source.count("\n") + 2
	copies = -(-lines // per_copy)
	output.parent.mkdir(parents=True, exist_ok=True)
	output.write_text("".join(f"copy{i} : namespace = {{\n{source}}}\n" for i in range(copies)), encoding="utf-8")
	print(f"{output}: {copies * per_copy} lines in {copies} copies")
	return 0


if __name__ == "__main__":
	sys.exit(main())
