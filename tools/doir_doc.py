#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pe>=0.6"]
# ///
"""Generates Markdown documentation from DOIR sources, and checks their comments against AGENTS.md.

A `//` or `#` comment directly above a declaration outside every function body and block documents it, and one at the top of a file documents the file. Namespaces and type bodies with declarations become sections, each listing its declarations in source order before its subsections; a declaration is shown with its signature, and a `_` declaration only when it is documented. A declaration's trailing comment is appended to its documentation.

With `--check`, nothing is written; instead each comment that breaks AGENTS.md is reported: a paragraph hard-wrapped over several lines, a free-standing comment over 25 words (rule tags not counted), or a file without a comment at its top.

    uv run tools/doir_doc.py [-o DIR] [file.doir...]    # write DIR/<name>.md for each file (default: bin/docs)
    uv run tools/doir_doc.py --check [file.doir...]

With no files it reads `standard.doir` and `reference/*.doir`.
"""

import argparse
import dataclasses
import pathlib
import re
import sys

import pe

import doir_grammar

TAG = re.compile(r"\b[A-Z]{1,3}-[A-Z][A-Za-z]+\b")
WORD_CAP = 25
SECTION_TYPES = ("namespace", "type")


@dataclasses.dataclass(slots=True)
class Comment:
	"""A run of comment lines with no blank line or code between them: `lines` without their markers, and the 1-based `first` and `last` lines it spans."""

	first: int
	last: int
	lines: list[str]
	documents: bool = False

	def paragraphs(self) -> list[list[str]]:
		"""The comment's paragraphs, split at its empty lines; a list item or indented line keeps a line of its own."""
		out: list[list[str]] = [[]]
		for line in self.lines:
			if line.strip():
				out[-1].append(line)
			elif out[-1]:
				out.append([])
		return [p for p in out if p]


@dataclasses.dataclass(slots=True)
class Declaration:
	"""A named declaration at documentation scope: its dotted `path`, `signature` text (with `export` when it has one), documentation, and the declarations of its body when it is a section."""

	path: str
	signature: str
	doc: list[str]
	section: bool
	children: list["Declaration"]


def is_continuation(line: str) -> bool:
	"""Whether a comment line continues its paragraph as written apart: a list item, or an indented line such as code."""
	return line.startswith((" ", "\t")) or bool(re.match(r"\s*([-*]|\d+[.)])\s", line))


def paragraph_text(paragraph: list[str]) -> str:
	"""A paragraph's lines joined into one, or kept as lines when some are list items or code."""
	if any(is_continuation(line) for line in paragraph[1:]):
		return "\n".join(paragraph)
	return " ".join(line.strip() for line in paragraph)


class Source:
	"""One parsed DOIR file and the comments in it."""

	def __init__(self, path: pathlib.Path, src: str, root: doir_grammar.Node):
		self.path, self.src, self.root = path, src, root
		self.lines = src.split("\n")
		self.comments = self.collect_comments()

	def text(self, node: doir_grammar.Node) -> str:
		"""The text `node` matched, up to the first comment inside it, without trailing whitespace."""
		end = min((c.pos for c in self.descendants(node, "LineComment")), default=node.end)
		return self.src[node.pos:end].rstrip()

	def line(self, pos: int) -> int:
		"""The 1-based line holding offset `pos`."""
		return doir_grammar.line_at(self.src, pos)

	def descendants(self, node: doir_grammar.Node, name: str) -> list[doir_grammar.Node]:
		"""Every node named `name` below `node`, in source order."""
		out = []
		for child in node.nodes:
			if child.name == name:
				out.append(child)
			out += self.descendants(child, name)
		return out

	def collect_comments(self) -> list[Comment]:
		"""Groups the file's whole-line comments into runs, and marks which document a declaration or the file."""
		runs: list[Comment] = []
		for node in self.descendants(self.root, "LineComment"):
			ln = self.line(node.pos)
			if self.lines[ln - 1][:node.pos - doir_grammar.line_starts(self.src)[ln - 1]].strip():
				continue
			body = self.src[node.pos:node.end]
			body = body[2:] if body.startswith("//") else body[1:]
			body = body[1:] if body.startswith(" ") else body
			if runs and runs[-1].last == ln - 1:
				runs[-1].last = ln
				runs[-1].lines.append(body)
			else:
				runs.append(Comment(ln, ln, [body]))
		if runs and runs[0].first == 1:
			runs[0].documents = True
		return runs

	def doc_above(self, line: int) -> Comment | None:
		"""The comment run ending on the line before `line`, if there is one; the file's own comment documents no declaration."""
		return next((c for c in self.comments if c.last == line - 1 and c.first != 1), None)

	def trailing(self, assignment: doir_grammar.Node) -> doir_grammar.Node | None:
		"""The comment on the line where `assignment`'s code ends, or None."""
		last = self.line(assignment.pos + len(self.text(assignment)) - 1)
		return next((c for c in self.descendants(assignment, "LineComment") if self.line(c.pos) == last), None)

	def declarations(self, block: doir_grammar.Node, prefix: str) -> list[Declaration]:
		"""The declarations of a namespace or type body, marking the comments that document them."""
		out = []
		for assignment in block.children("assignment"):
			ident, type_node, value = assignment.child("Identifier"), assignment.child("Type"), assignment.child("assignment_value")
			if not (ident and type_node):
				continue
			name, type_name = self.text(ident), self.text(type_node)
			comment = self.doc_above(self.line(assignment.pos))
			if comment:
				comment.documents = True
			doc = [paragraph_text(p) for p in comment.paragraphs()] if comment else []
			if trailing := self.trailing(assignment):
				doc.append(self.src[trailing.pos:trailing.end].lstrip("/#").strip())
			body = value.child("Block") if value else None
			section = body is not None and type_name in SECTION_TYPES and bool(body.children("assignment"))
			signature = self.text(assignment)[:type_node.end - assignment.pos].rstrip()
			if value and body is None:
				signature += " = " + self.text(value)
			elif body is not None and not section and type_name in SECTION_TYPES:
				signature += " = {}"
			children = self.declarations(body, f"{prefix}{name}.") if section else []
			if name != "_" or doc:
				out.append(Declaration(prefix + name, signature, doc, section, children))
		return out


def load(parser, path: pathlib.Path) -> Source:
	"""Parses the file at `path`. Raises `OSError` if it cannot be read, and `pe.ParseError` if it does not parse."""
	src = path.read_text(encoding="utf-8")
	return Source(path, src, doir_grammar.parse(parser, src))


def render(source: Source, decls: list[Declaration]) -> str:
	"""The Markdown page for one file: its own documentation, then in each section its declarations in source order, followed by its subsections."""
	out = [f"# `{source.path.name}`", ""]
	top = source.comments[0] if source.comments and source.comments[0].first == 1 else None
	file_doc = [paragraph_text(p) for p in top.paragraphs()] if top else []

	def emit_doc(paragraphs: list[str]) -> None:
		for paragraph in paragraphs:
			out.extend([paragraph if "\n" not in paragraph else f"```\n{paragraph}\n```", ""])

	# Markdown cannot close a section, so a section's own declarations come before its subsections.
	def emit(items: list[Declaration], depth: int) -> None:
		for d in (d for d in items if not d.section):
			out.extend(["```doir", d.signature, "```"] if "\n" in d.signature else [f"`{d.signature}`"])
			out.append("")
			emit_doc(d.doc)
		for d in (d for d in items if d.section):
			out.extend([f"{'#' * min(depth, 6)} `{d.path}`", "", f"`{d.signature}`", ""])
			emit_doc(d.doc)
			emit(d.children, depth + 1)

	emit_doc(file_doc)

	emit(decls, 2)
	return "\n".join(out).rstrip() + "\n"


def problems(source: Source) -> list[str]:
	"""Every comment in `source` that breaks AGENTS.md, as `path:line: problem; hint`."""
	out = []
	if not source.comments or source.comments[0].first != 1:
		out.append(f"{source.path}:1: no comment at the top of the file; add one saying what the file is")
	for comment in source.comments:
		if any(len(p) > 1 and not all(is_continuation(l) for l in p[1:]) for p in comment.paragraphs()):
			out.append(f"{source.path}:{comment.first}: comment hard-wrapped over lines {comment.first}-{comment.last}; join each paragraph onto one line, since editors here soft-wrap")
		words = len(TAG.sub("", " ".join(comment.lines)).split())
		if not comment.documents and words > WORD_CAP:
			out.append(f"{source.path}:{comment.first}: free-standing comment of {words} words, over the cap of {WORD_CAP}; shorten it, or move it directly above the declaration it documents")
	for node in source.descendants(source.root, "LineComment"):
		ln = source.line(node.pos)
		words = len(TAG.sub("", source.src[node.pos:node.end].lstrip("/#")).split())
		if not any(c.first <= ln <= c.last for c in source.comments) and words > WORD_CAP:
			out.append(f"{source.path}:{ln}: trailing comment of {words} words, over the cap of {WORD_CAP}; shorten it, or move it above the declaration as its documentation")
	return out


def main() -> int:
	"""Writes the documentation for the files named, or checks their comments; returns 1 if a file cannot be read or parsed, or `--check` finds a problem."""
	args = argparse.ArgumentParser(description="Generate Markdown documentation from DOIR sources, or check their comments.")
	args.add_argument("-o", dest="output", default=str(doir_grammar.ROOT / "bin" / "docs"), help="the directory to write <name>.md into")
	args.add_argument("--check", action="store_true", help="report comments that break AGENTS.md instead of writing documentation")
	args.add_argument("files", nargs="*", type=pathlib.Path, help="DOIR files (default: standard.doir and reference/*.doir)")
	opts = args.parse_args()
	files = opts.files or [doir_grammar.ROOT / "standard.doir"] + sorted((doir_grammar.ROOT / "reference").glob("*.doir"))
	try:
		parser = doir_grammar.load(doir_grammar.GRAMMAR)
	except pe.Error as exc:
		print(doir_grammar.grammar_error(exc), file=sys.stderr)
		return 1
	sys.setrecursionlimit(100000)
	failed = False
	output = pathlib.Path(opts.output)
	for path in files:
		try:
			source = load(parser, path)
		except OSError as exc:
			print(f"{path}: cannot read: {exc.strerror}; check that the path names a readable file", file=sys.stderr)
			failed = True
			continue
		except pe.ParseError as exc:
			print(f"{path}: {doir_grammar.syntax_error(path.read_text(encoding='utf-8'), exc)}", file=sys.stderr)
			failed = True
			continue
		decls = source.declarations(source.root, "")
		if opts.check:
			for problem in problems(source):
				print(problem)
				failed = True
			continue
		output.mkdir(parents=True, exist_ok=True)
		(output / f"{path.stem}.md").write_text(render(source, decls), encoding="utf-8")
	return 1 if failed else 0


if __name__ == "__main__":
	sys.exit(main())
