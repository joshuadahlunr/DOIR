#!/usr/bin/env python3
"""Run the conformance corpus (`roadmap.md` Phase 10) through `doir_check`.

Each file in `tests/conformance` is named `<Rule-Tag>.<case>.accept.doir` or `<Rule-Tag>.<case>.reject.doir`, and its first line is a comment saying what it tests.
The `<case>` prefix gives the file's place in its build:

- `program...`: the program, the last file of the chain, checked with `doir_check -p`.
- `backends...`: the build's backends file, in place of `reference/backends.doir`.
- `syntax...`: a reject case the grammar decides, which must fail with a syntax error.
- anything else: a library file between `std` and the program.

A case's build is the files `reference/compiler.doir`, `reference/backends.doir`, `standard.doir` and the case, whose tower the compiler reads from them (`L-Tower`, `L-Scan`); a `// backends: <path>` comment replaces the backends file, relative to the corpus.
`standard.doir` pastes `standard.os.doir`, and `reference/backends.doir` pairs the Mizu machine with the freestanding operating system (`OS-Target`), so an `OS-` case gets `std.os` with no file of its own; a `backends…` case pairs another.
Files under `support/` are what cases import or build on; they must parse.

`doir_check` parses and checks the few rules its diagnostics name.
A reject case for one of those rules must fail naming its tag; for a rule it checks only in part (`PARTIAL`), a case it passes is pending instead.
A reject case for any other rule must parse cleanly and is counted as pending: it waits for the compiler, and a syntax error or another rule's diagnostic means the case is broken.
Runs `tests/doir_check.py` through `uv`, unless `--checker` names another command, split as a shell would (`--checker "bin/doir --check"`).

    python3 tests/conformance.py [--checker "bin/doir --check"] [--pending]
"""

import argparse
import pathlib
import re
import shlex
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CORPUS = ROOT / "tests/conformance"


# Tags `doir_check` checks only in part: a reject case for one that it passes is pending, not failed.
PARTIAL = {"B-Tail", "L-Scan", "L-Sema", "L-Bind"}  # B-Tail's return-type match needs types; L-Scan's, L-Sema's and L-Bind's name resolution need the whole build


def checked_tags():
	"""The rule tags `doir_check` reports in full, read from its diagnostic strings."""
	return set(re.findall(r'["\']([A-Z][A-Za-z0-9]*-[A-Za-z]+):', (ROOT / "tests/doir_check.py").read_text())) - PARTIAL


def results(output):
	"""Maps each path in `doir_check` output to (passed, its report lines)."""
	out, current = {}, None
	for line in output.splitlines():
		if line.startswith("  ") and current:
			out[current][1].append(line)
		else:
			current, _, status = line.rpartition(": ")
			out[current] = (status == "ok", [line])
	return out


def build_problems(case):
	"""A `// backends:` path that does not exist, or a first line that is not a comment."""
	lines = case.read_text().splitlines()
	problems = [] if lines and lines[0].startswith("//") else ["first line is not a comment saying what the case tests; add one"]
	for line in lines:
		if line.startswith("// backends:") and not (CORPUS / line.split(":", 1)[1].strip()).exists():
			problems.append(f"backends file not found: {line}; fix the path, which is relative to tests/conformance")
	return problems


def main():
	"""Runs the corpus and prints each failing case; returns 1 if any fails."""
	parser = argparse.ArgumentParser()
	parser.add_argument("--checker", help="the command to check with, split as a shell would, as in \"bin/doir --check\"")
	parser.add_argument("--pending", action="store_true", help="list the pending reject cases")
	args = parser.parse_args()
	checker = shlex.split(args.checker) if args.checker else ["uv", "run", "-q", str(ROOT / "tests/doir_check.py")]
	cases = sorted(CORPUS.glob("*.doir"))
	support = sorted(CORPUS.glob("support/*.doir"))
	parsed = {case: case.name.split(".") for case in cases}
	programs = [str(c) for c in cases if parsed[c][1].startswith("program")]
	files = [str(c) for c in cases if str(c) not in programs] + [str(s) for s in support]
	run = subprocess.run(checker + ["-g", str(ROOT / "doir.peg")] + files + ["-p"] + programs, capture_output=True, text=True)
	reports = results(run.stdout)
	if not reports:
		print(f"{checker[0]}: reported no results (exit {run.returncode}); check that --checker names a command taking doir_check's arguments, as \"bin/doir --check\" does\n{run.stderr}", file=sys.stderr)
		return 1
	checked = checked_tags()
	failures, pending = [], []
	for case in cases + support:
		passed, lines = reports.get(str(case), (False, [f"{case}: no result"]))
		text = "\n".join(lines)
		if case in support:
			if not passed:
				failures.append(f"FAIL support/{case.name}\n{text}")
			continue
		tag, name, expectation, _ = parsed[case]
		problems = build_problems(case)
		syntax_error = "syntax error" in text
		if expectation == "accept":
			ok = passed
		elif name.startswith("syntax"):
			ok = syntax_error
		elif tag in checked or (tag in PARTIAL and not passed):
			ok = not passed and tag in text
		else:
			ok = passed
			if ok:
				pending.append(case.name)
		if not ok or problems:
			failures.append("\n".join([f"FAIL {case.name}", text] + [f"  {p}" for p in problems]))
	for failure in failures:
		print(failure)
	if args.pending:
		for name in pending:
			print(f"pending {name}")
	decided = len(cases) - len(pending)
	print(f"{decided - sum(f.startswith('FAIL') for f in failures)}/{decided} conformance cases pass, {len(pending)} reject cases pending the compiler (rules doir_check does not check)")
	return 1 if failures else 0


if __name__ == "__main__":
	sys.exit(main())
