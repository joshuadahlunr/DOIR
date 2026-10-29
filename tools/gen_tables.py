#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pe>=0.6"]
# ///
"""Generates `source/doir/syntax/tables.d` from `doir.peg`: the code point ranges of `UnicodeIdentifierStart`, `UnicodeIdentifierContinue` and the non-newline whitespace of `wsc`, and the words of `Keywords`, so the lexer matches the grammar exactly (`roadmap.md` Phase 2).

    uv run tools/gen_tables.py            # rewrite the module
    uv run tools/gen_tables.py --check    # exit 1 if the module is out of date
"""

import pathlib
import sys

import pe
import pe.operators

ROOT = pathlib.Path(__file__).resolve().parent.parent
GRAMMAR = ROOT / "doir.peg"
OUTPUT = ROOT / "source" / "doir" / "syntax" / "tables.d"


def classes(op, out):
	"""Collects the (first, last) code point ranges of every character class under `op`."""
	if op.op == pe.operators.Operator.CLS:
		for first, last in op.args[0]:
			out.append((ord(first), ord(last if last is not None else first)))
		return
	for arg in op.args:
		if isinstance(arg, list):
			for a in arg:
				if hasattr(a, "op"):
					classes(a, out)
		elif hasattr(arg, "op"):
			classes(arg, out)


def literals(op, out):
	"""Collects the string of every literal under `op`."""
	if op.op == pe.operators.Operator.LIT:
		out.append(op.args[0])
		return
	for arg in op.args:
		if isinstance(arg, list):
			for a in arg:
				if hasattr(a, "op"):
					literals(a, out)
		elif hasattr(arg, "op"):
			literals(arg, out)


def merged(ranges):
	"""`ranges` sorted, with overlapping and adjacent ranges joined."""
	out = []
	for first, last in sorted(ranges):
		if out and first <= out[-1][1] + 1:
			out[-1] = (out[-1][0], max(out[-1][1], last))
		else:
			out.append((first, last))
	return out


def table(name, doc, ranges):
	"""The D declaration of the range table `name`, documented by `doc`."""
	rows = "".join(f"\t[0x{a:X}, 0x{b:X}],\n" for a, b in ranges)
	return f"/// {doc}\nimmutable uint[2][{len(ranges)}] {name} = [\n{rows}];\n"


def generate():
	"""The text of `tables.d` for the current `doir.peg`. Raises `pe.Error` if the grammar does not compile."""
	definitions = pe.compile(GRAMMAR.read_text(encoding="utf-8"), ignore=None, flags=pe.NONE).grammar.definitions
	start, cont, space, words = [], [], [], []
	classes(definitions["UnicodeIdentifierStart"], start)
	classes(definitions["UnicodeIdentifierContinue"], cont)
	classes(definitions["wsc"], space)
	literals(definitions["Keywords"], words)
	# `wsc` also matches comments, which are not classes; newlines are `Terminator`s, never in `wsc`.
	assert all(c not in (0x0A, 0x0D) for r in space for c in r)
	keywords = "".join(f'\t"{w}",\n' for w in words)
	return (
		"/// Character tables generated from `doir.peg` by `tools/gen_tables.py`; do not edit. Each table is sorted, non-overlapping inclusive code point ranges, searched by `doir.syntax.lexer`.\n"
		"module doir.syntax.tables;\n\n"
		+ table("identifierStart", "`UnicodeIdentifierStart`.", merged(start)) + "\n"
		+ table("identifierContinue", "`UnicodeIdentifierContinue`.", merged(cont)) + "\n"
		+ table("whitespace", "The whitespace of `wsc`, which `_` extends with the newlines.", merged(space)) + "\n"
		+ f"/// The words of `Keywords`, none of which is an `Identifier`.\nimmutable string[{len(words)}] keywords = [\n{keywords}];\n"
	)


def main():
	"""Rewrites `tables.d`, or with `--check` compares it; returns 1 if the check finds it out of date."""
	text = generate()
	if "--check" in sys.argv[1:]:
		current = OUTPUT.read_text(encoding="utf-8") if OUTPUT.exists() else ""
		if current != text:
			print(f"{OUTPUT.relative_to(ROOT)} is out of date with doir.peg; run `uv run tools/gen_tables.py` to regenerate it", file=sys.stderr)
			return 1
		return 0
	OUTPUT.parent.mkdir(parents=True, exist_ok=True)
	OUTPUT.write_text(text, encoding="utf-8")
	return 0


if __name__ == "__main__":
	sys.exit(main())
