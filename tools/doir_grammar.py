"""Loads `doir.peg`, and grammars that extend it such as `doir_plus.peg`, into pe (https://github.com/goodmami/pe) parsers whose match value is a tree of `Node`s, one per rule match.

pe has no back-references, so `RawString` (a run of three or more quotes, closed by the same run) is matched by a regex in place of its grammar rule.
"""

import bisect
import functools
import pathlib
import re

import pe
import pe.actions
import pe.operators

ROOT = pathlib.Path(__file__).resolve().parent.parent
GRAMMAR = ROOT / "doir.peg"

# Possessive repetition keeps PEG semantics: the opening run takes every quote, and the content stops at the first closing run not followed by a quote.
RAW_STRING = pe.operators.Regex(r'(?P<delim>"""(?:")*+)(?:(?!(?P=delim)(?!")).)*+(?P=delim)', re.DOTALL)


class Node:
	"""An AST node: one per rule match, spanning `src[pos:end]`."""

	__slots__ = ("name", "pos", "end", "nodes")

	def __init__(self, name, pos, end, nodes):
		self.name, self.pos, self.end, self.nodes = name, pos, end, nodes

	def child(self, name):
		"""The first child named `name`, or None."""
		return next((n for n in self.nodes if n.name == name), None)

	def children(self, name):
		"""Every child named `name`, in order."""
		return [n for n in self.nodes if n.name == name]


class BuildNode(pe.actions.Action):
	"""The pe action that makes each match of rule `name` a `Node` over its children's values."""

	__slots__ = ()

	def __init__(self, name):
		self.arg = name

	def __call__(self, s, pos, end, args, kwargs):
		return (Node(self.arg, pos, end, list(args)),), None


def rule_names(text):
	"""The names of the rules a grammar's text defines, in order."""
	return re.findall(r"^([A-Za-z_][A-Za-z0-9_]*)\s*<-", text, re.MULTILINE)


def load(*paths):
	"""Compiles the grammars at `paths` into one parser whose start rule is the first rule of the first path. A later grammar may only add rules. Raises `pe.Error` if they do not compile."""
	texts = [pathlib.Path(p).read_text() for p in paths]
	seen = set()
	for path, text in zip(paths, texts):
		redefined = seen.intersection(rule_names(text))
		if redefined:
			raise pe.GrammarError(f"{path} redefines {', '.join(sorted(redefined))}; an extending grammar may only add rules, so rename them there")
		seen.update(rule_names(text))
	compiled = pe.compile("\n".join(texts), ignore=None, flags=pe.NONE).grammar
	definitions = dict(compiled.definitions)
	if "RawString" in definitions:
		definitions["RawString"] = RAW_STRING
	grammar = pe.Grammar(definitions, actions={name: BuildNode(name) for name in definitions}, start=compiled.start)
	return pe.compile(grammar, ignore=None, flags=pe.NONE)


def grammar_error(exc):
	"""Describes a `pe.Error` from `load`, with the grammar line it failed on when pe reports one."""
	where = exc.__cause__ if isinstance(exc.__cause__, pe.ParseError) else None
	at = f" at line {where.lineno + 1}:{where.offset + 1}: {where.text}" if where and where.lineno is not None else f": {exc}"
	return f"grammar did not compile{at}; fix the grammar there, or pass another with -g"


# ---------------------------------------------------------------------------
# Source positions
# ---------------------------------------------------------------------------

@functools.lru_cache(maxsize=8)
def line_starts(src):
	"""The offset each line of `src` starts at, the first line's at index 0."""
	return [0] + [m.end() for m in re.finditer("\n", src)]


def line_at(src, pos):
	"""The 1-based line holding `pos`."""
	return bisect.bisect_right(line_starts(src), pos)


def column_at(src, pos):
	"""The 1-based column of `pos`."""
	return pos - line_starts(src)[line_at(src, pos) - 1] + 1


def line_of(src, line):
	"""The text of the 1-based `line`, without its newline, or the empty string if `src` has no such line."""
	starts = line_starts(src)
	if line < 1 or line > len(starts):
		return ""
	end = src.find("\n", starts[line - 1])
	return src[starts[line - 1]:end if end >= 0 else len(src)]


def text_of(src, node):
	"""The text of `src` that `node` matched."""
	return src[node.pos:node.end]


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

def expected_terminals(message):
	"""The terminals pe's furthest-failure message lists, which it renders as backquoted regexes: literals and one-character classes quoted, short classes as written, longer ones left out."""
	out = []
	for pattern in re.findall(r"`((?:[^`\\]|\\.)*)`", message, re.DOTALL):
		single = re.fullmatch(r"\[(\\?.)\]", pattern, re.DOTALL)
		if single:
			pattern = single.group(1)
		text = re.sub(r"\\(.)", r"\1", pattern, flags=re.DOTALL)
		if re.escape(text) == pattern or single:
			text = repr(text)
		elif pattern.startswith("[") and len(pattern) <= 12:
			text = pattern
		else:
			continue
		if text not in out:
			out.append(text)
	return out


def syntax_error(src, exc):
	"""Formats a `pe.ParseError` as `line L:C: syntax error, unexpected X; insert one of Y before it | near: <line>`, or with `remove it or rewrite the line` as the hint when pe names no terminal."""
	pos = line_starts(src)[exc.lineno] + exc.offset if exc.lineno is not None else len(src)
	ln = line_at(src, pos)
	token = re.compile(r"\w+|.", re.DOTALL).match(src, pos)
	unexpected = repr(token.group()) if token else "end of input"
	expected = expected_terminals(exc.message or "")
	hint = f"insert one of {', '.join(expected)} before it" if expected else "remove it or rewrite the line"
	return f"line {ln}:{column_at(src, pos)}: syntax error, unexpected {unexpected}; {hint} | near: {line_of(src, ln)}"


def parse(parser, src):
	"""The root `Node` of `src`. Raises `pe.ParseError` on a syntax error; format it with `syntax_error`."""
	return parser.match(src, flags=pe.MEMOIZE | pe.STRICT).value()
