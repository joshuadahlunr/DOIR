#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pe>=0.6"]
# ///
"""The differential test of the parser against `doir.peg` (`roadmap.md` Phase 2): runs `bin/doir --syntax` and pe over each file, and checks that both accept or both reject it, and that they report the first syntax error on the same line.
A file named `*.accept.doir` must also be accepted.
A `*.reject.doir` file in `tests/syntax`, or in `tests/conformance` with a case starting `syntax` (`<Rule-Tag>.syntax….reject.doir`), must be rejected; any other conformance reject case must parse, as its rule waits for the compiler.

    uv run tests/parse_diff.py [file.doir...]

With no files it checks the corpus (`standard.doir`, `test.doir`, `test_call.doir`), `tests/conformance` and `tests/syntax`.
Build `bin/doir` first (`dub build --compiler=ldc2`).
"""

import pathlib
import re
import subprocess
import sys

import pe

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))  # doir_grammar is a tool, shared with doir_doc and doirp

import doir_grammar  # noqa: E402
DOIR = ROOT / "bin" / "doir"


def grammar_line(parser, path):
	"""The line of pe's first syntax error in `path`, or None if it parses."""
	with open(path, encoding="utf-8", newline="") as file:  # keep a lone `\r`, which universal newlines would turn into `\n`
		src = file.read()
	try:
		doir_grammar.parse(parser, src)
	except pe.ParseError as exc:
		return doir_grammar.line_at(src, doir_grammar.error_position(src, exc))
	return None


def parser_line(path):
	"""The line of the parser's first syntax error in `path`, or None if it parses."""
	out = subprocess.run([DOIR, "--syntax", path], capture_output=True, text=True, check=True).stdout.strip()
	match = re.search(r": line (\d+):\d+: ", out)
	return int(match.group(1)) if match else None


def syntax_reject(path):
	"""Whether `path` is a reject case the grammar decides: any file in `tests/syntax`, or a conformance case named `<Rule-Tag>.syntax….reject.doir`."""
	parts = path.name.split(".")
	return "syntax" in path.parts or ("conformance" in path.parts and len(parts) == 4 and parts[1].startswith("syntax"))


def main():
	"""Compares the parser with `doir.peg` over the files named, or the corpus; returns 1 if any file disagrees or `bin/doir` is missing."""
	if not DOIR.exists():
		print("bin/doir is missing; run dub build --compiler=ldc2", file=sys.stderr)
		return 1
	files = [pathlib.Path(a) for a in sys.argv[1:]] or (
		[ROOT / "standard.doir", ROOT / "test.doir", ROOT / "test_call.doir"]
		+ sorted((ROOT / "tests" / "conformance").rglob("*.doir"))
		+ sorted((ROOT / "tests" / "syntax").glob("*.doir")))
	parser = doir_grammar.load(doir_grammar.GRAMMAR)
	sys.setrecursionlimit(100000)
	failures = 0
	for path in files:
		expected, actual = grammar_line(parser, path), parser_line(path)
		name = path.relative_to(ROOT) if path.is_relative_to(ROOT) else path
		problem = None
		if (expected is None) != (actual is None):
			problem = f"doir.peg {'accepts' if expected is None else f'rejects at line {expected}'}, the parser {'accepts' if actual is None else f'rejects at line {actual}'}"
		elif expected != actual:
			problem = f"first error at line {expected} in doir.peg, line {actual} in the parser"
		elif path.name.endswith(".accept.doir") and actual is not None:
			problem = "should be accepted"
		elif path.name.endswith(".reject.doir") and syntax_reject(path) and actual is None:
			problem = "should be rejected"
		elif path.name.endswith(".reject.doir") and "conformance" in path.parts and not syntax_reject(path) and actual is not None:
			problem = "should parse; only a `syntax` case is a syntax reject"
		if problem:
			failures += 1
			print(f"{name}: {problem}")
	print(f"parse_diff: {len(files) - failures} of {len(files)} files agree")
	return 1 if failures else 0


if __name__ == "__main__":
	sys.exit(main())
