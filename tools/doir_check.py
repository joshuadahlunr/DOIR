#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pe>=0.6"]
# ///
"""Parse DOIR sources against doir.peg and report syntax errors plus the rules that need a tree walk: WF-Term (terminators), WF-Order (a binding read before it is bound), D-Return (a `_` destination receiving a `_` return), B-Tail (a tail call ends its block), L-Scan and L-Sema (tower and check calls at level scope), and I-Language (no frontend is registered, so every `language` block is an error). WF-Arg is enforced by the grammar itself: `function_call` accepts only `Identifier _` arguments.

doir.peg is a pe (https://github.com/goodmami/pe) grammar, loaded by `doir_grammar.py`; each rule match becomes a `Node`.

    uv run tools/doir_check.py [-a] [-g doir.peg] file.doir... [-p program.doir...]

Files after -p are programs, whose root must also end with a terminator (L-Entry).
"""

import argparse
import collections.abc
import dataclasses
import pathlib
import sys

import pe

import doir_grammar

SCANNED_CALLS = frozenset({"compiler.levels.make", "compiler.levels.this_file", "compiler.levels.lower_to", "compiler.levels.bundle"})

# Not read by the scan, but found without running anything, so also written at level scope (L-Sema).
CHECK_CALL = "compiler.levels.check"
BIND_PASS_CALL = "compiler.levels.bind_pass"

TERMINATORS = frozenset({"std.return", "std.block_result", "std.halt", "return", "block_result", "halt", "compiler.return", "compiler.block_result"})

# Types whose names are not values, so they may be read above their declaration; a label may be named before it is placed (B-Label).
NON_VALUE_TYPES = frozenset({"type", "namespace", "alias", "std.label"})


def is_tail_call(call: str) -> bool:
	"""Whether the call text `call` is a tail call (`tail f(...)`, B-Tail)."""
	return len(call) > 4 and call.startswith("tail") and call[4] in " \t"


def is_terminator_call(call: str) -> bool:
	"""A tail call returns its callee's result, so it ends a block like std.return (B-Tail)."""
	return is_tail_call(call) or call.partition("(")[0] in TERMINATORS


def call_arguments(call: doir_grammar.Node) -> list[doir_grammar.Node]:
	"""The argument nodes of a call: every `Identifier` child but the callee. WF-Arg makes identifiers the only argument form, so arguments are direct children of the call."""
	return call.children("Identifier")[1:]


def function_type_of(node: doir_grammar.Node) -> doir_grammar.Node | None:
	"""The `FunctionType` a declaration or type position declares, or None if it declares none."""
	for child in node.nodes:
		if child.name == "FunctionType":
			return child
		if child.name in ("Type", "assignment_value") and (found := function_type_of(child)):
			return found
	return None


def resolve(sigs: dict[str, doir_grammar.Node], name: str, prefix: str) -> doir_grammar.Node | None:
	"""R-Unqual, approximated over namespace prefixes: try `name` in each enclosing namespace, innermost first."""
	while prefix and prefix + name not in sigs:
		dot = prefix.rfind(".", 0, len(prefix) - 1)
		prefix = prefix[:dot + 1]
	return sigs.get(prefix + name)


@dataclasses.dataclass(slots=True)
class Decl:
	"""A name bound to a value (not a function, type, or namespace) cannot be read before its declaration line: SSA binds it once, and C-Order runs effects lexically."""

	name: str
	type_name: str
	value: doir_grammar.Node
	is_value: bool
	is_function: bool
	line: int


class Checker:
	"""The tree-walk checks over one parsed file, collecting their diagnostics in `errors`."""

	def __init__(self, src: str):
		self.src = src
		self.sigs: dict[str, doir_grammar.Node] = {}
		self.errors: list[str] = []

	def text(self, node: doir_grammar.Node) -> str:
		"""The source text `node` matched."""
		return doir_grammar.text_of(self.src, node)

	def line(self, node: doir_grammar.Node) -> int:
		"""The line `node` starts on."""
		return doir_grammar.line_at(self.src, node.pos)

	def callee(self, call: doir_grammar.Node) -> str:
		"""The name a call calls, or the empty string if it has none."""
		ident = call.child("Identifier")
		return self.text(ident) if ident else ""

	def type_name(self, type_node: doir_grammar.Node) -> str:
		"""The name a type position resolves to: an identifier, or `function` for a function type."""
		for child in type_node.nodes:
			if child.name == "Identifier":
				return self.text(child)
			if child.name == "FunctionType":
				return "function"
		return ""

	def assignment_parts(self, assignment: doir_grammar.Node) -> tuple[str, doir_grammar.Node | None, doir_grammar.Node | None]:
		"""The name, `Type` node, and `assignment_value` node of an assignment; absent parts are empty or None."""
		ident = assignment.child("Identifier")
		return (self.text(ident) if ident else ""), assignment.child("Type"), assignment.child("assignment_value")

	def ends_with_terminator(self, block: doir_grammar.Node) -> bool:
		"""Whether the last statement of `block` is a terminator call (WF-Term)."""
		assignments = block.children("assignment")
		return bool(assignments) and any(inner.name == "function_call" and is_terminator_call(self.text(inner)) for value in assignments[-1].children("assignment_value") for inner in value.nodes)

	def return_is_deduced(self, ft: doir_grammar.Node) -> bool:
		"""D-Return: `_` in the return position is a leading deduced parameter that no argument binds, so only the destination at the call site can solve it (D-Deduce)."""
		return any(self.text(ident) == "_" for t in ft.children("Type") for ident in t.children("Identifier"))

	# Signatures

	def signatures(self, block: doir_grammar.Node, prefix: str) -> collections.abc.Iterator[tuple[str, str, doir_grammar.Node | None, str]]:
		"""Yields (prefix, name, declared `FunctionType` or None, type name) for each named declaration, descending into namespaces."""
		for child in block.children("assignment"):
			name, type_node, value = self.assignment_parts(child)
			if not name or name == "_":
				continue
			type_name = self.type_name(type_node) if type_node else ""
			if type_name == "namespace" and value:
				for part in value.children("Block"):
					yield from self.signatures(part, f"{prefix}{name}.")
				continue
			yield prefix, name, function_type_of(child), type_name

	def collect_signatures(self, root: doir_grammar.Node) -> None:
		"""Fills `sigs` (qualified name -> declared `FunctionType`), resolving declarations typed by a named function type once every type is known."""
		named = []
		for prefix, name, ft, type_name in self.signatures(root, ""):
			if ft:
				self.sigs[prefix + name] = ft
			elif type_name:
				named.append((prefix, name, type_name))
		for prefix, name, type_name in named:
			if ft := resolve(self.sigs, type_name, prefix):
				self.sigs[prefix + name] = ft

	# Reads

	def reads(self, node: doir_grammar.Node) -> collections.abc.Iterator[str]:
		"""Every binding identifier a value reads: callees and plain arguments."""
		for child in node.nodes:
			yield from self.reads_of(child)

	def reads_of(self, node: doir_grammar.Node) -> collections.abc.Iterator[str]:
		"""Every binding identifier `node` itself reads, without descending into blocks."""
		match node.name:
			case "function_call":
				if (callee := self.callee(node)) and callee != "_":
					yield callee
				for arg in call_arguments(node):
					yield from self.reads_of(arg)
			case "Identifier":
				if (name := self.text(node)) != "_":
					yield name
			case "parameter":
				# A parameter's name declares; only its type and default read (R-Param).
				for child in node.nodes[1:]:
					yield from self.reads_of(child)
			case "Block":
				pass
			case _:
				yield from self.reads(node)

	def arg_names(self, node: doir_grammar.Node) -> collections.abc.Iterator[str]:
		"""Names a value passes as a call argument: where a block binding is executed."""
		for child in node.nodes:
			match child.name:
				case "function_call":
					args = call_arguments(child)
				case "Identifier":
					args = [child]
				case "Block":
					continue
				case _:
					yield from self.arg_names(child)
					continue
			yield from (name for name in map(self.text, args) if name != "_")

	# Blocks

	def declarations(self, block: doir_grammar.Node) -> collections.abc.Iterator[Decl]:
		"""The complete assignments of `block`, in order; one missing its name, type or value is skipped."""
		for child in block.children("assignment"):
			name, type_node, value = self.assignment_parts(child)
			if not (name and type_node and value):
				continue
			type_name = self.type_name(type_node)
			# A Block value is a function body unless the declared type is `block` itself.
			is_function = function_type_of(child) is not None or (value.child("Block") is not None and type_name not in ("block", "namespace", "type"))
			is_value = not is_function and type_name not in NON_VALUE_TYPES
			yield Decl(name, type_name, value, is_value, is_function, self.line(child))

	def check_block(self, block: doir_grammar.Node, *, executed: bool = True, ordered: bool = True, outer: dict[str, tuple[int, Decl]] | None = None, deadline: int = 0, prefix: str = "", in_function: bool = False, level_scope: bool = True) -> None:
		"""`outer` maps the enclosing block's names to (declaration index, declaration); `deadline` is the index at which this block is spliced into the enclosing one, and a spliced block cannot read a value the enclosing block binds after it. `in_function` says whether a function body encloses the block, `level_scope` whether it is a file root or namespace (L-Freeze), and `prefix` names the enclosing namespace."""
		outer = outer or {}
		decls = list(self.declarations(block))
		index: dict[str, int] = {}
		for i, d in enumerate(decls):
			# `_ : _ = ...` is a statement: it reads, but it binds no name.
			if d.name != "_":
				index.setdefault(d.name, i)
		scope = {name: (i, decls[i]) for name, i in index.items()}

		# Where each block binding is first passed to a control-flow primitive: that is where it runs.
		use: dict[str, int] = {}
		for i, d in enumerate(decls):
			for name in self.arg_names(d.value):
				use.setdefault(name, i)

		for i, d in enumerate(decls):
			value = d.value
			is_namespace = d.type_name == "namespace"
			is_type = d.type_name == "type"
			runs = executed and not is_namespace and not is_type

			for call in value.children("function_call"):
				# L-Scan: the tower is read before ascent, so the calls that shape it sit at level scope.
				if not level_scope and (callee := self.callee(call)) in SCANNED_CALLS:
					self.errors.append(f"L-Scan: '{callee}' at line {d.line} is not at level scope, so the scan cannot read the tower from it; move the call to the file root or a namespace")
				if not level_scope and self.callee(call) == CHECK_CALL:
					self.errors.append(f"L-Sema: '{CHECK_CALL}' at line {d.line} is not at level scope, so the level's checks cannot be found without running it; move the call to the file root or a namespace")
				if not level_scope and self.callee(call) == BIND_PASS_CALL:
					self.errors.append(f"L-Bind: '{BIND_PASS_CALL}' at line {d.line} is not at level scope, so the names it binds cannot be found without running it; move the call to the file root or a namespace")
				if not is_tail_call(self.text(call)):
					continue
				if not in_function:
					self.errors.append(f"B-Tail: the tail call at line {d.line} is outside a function body, so it has nothing to return from; move it into a function, or drop `tail` to make it a plain call")
				elif i + 1 < len(decls):
					self.errors.append(f"B-Tail: the tail call at line {d.line} is a terminator but does not end its block; make it the block's last statement, or drop `tail`")

			if ordered:
				for name in self.reads(value):
					if name in index:
						bound = decls[index[name]]
						if index[name] > i and bound.is_value:
							self.errors.append(f"WF-Order: '{name}' read at line {d.line} before it is bound at line {bound.line}; move its declaration above line {d.line}")
					elif name in outer:
						at, bound = outer[name]
						if bound.is_value and at > deadline:
							self.errors.append(f"WF-Order: '{name}' read in a spliced block at line {d.line} before the enclosing block binds it at line {bound.line}; bind it above the statement that runs the block")

			direct_block = bool(value.nodes) and value.nodes[0].name == "Block"
			for part in value.nodes:
				if part.name == "Block":
					# WF-Term is syntactic: a body or block binding ends properly wherever it is declared.
					if not is_namespace and not is_type and not self.ends_with_terminator(part):
						self.errors.append(f"WF-Term: block at line {self.line(part)} does not end with a terminator call; end it with std.return, std.block_result, std.halt or a tail call")
					# A function body sees the enclosing scope as at the call, and a namespace binds lexically.
					# A named block runs where it is first passed to a primitive.
					if d.is_function:
						self.check_block(part, prefix=prefix, in_function=True, level_scope=False)
					elif is_namespace:
						self.check_block(part, executed=False, outer=scope, deadline=i, prefix=f"{prefix}{d.name}.", in_function=in_function, level_scope=level_scope)
					else:
						if not direct_block:
							inner_outer, inner_deadline = scope, i
						elif d.name in use:
							inner_outer, inner_deadline = scope, use[d.name]
						else:
							inner_outer, inner_deadline = {}, 0
						self.check_block(part, executed=runs, ordered=runs, outer=inner_outer, deadline=inner_deadline, prefix=prefix, in_function=in_function, level_scope=False)
				elif part.name == "function_call":
					callee = self.callee(part)
					# D-Return: a `_` destination receiving a `_` return leaves the return type unsolved, control flow included (`_ : void = std.if(...)`, B-If).
					ft = resolve(self.sigs, callee, prefix)
					if ft and d.type_name == "_" and self.return_is_deduced(ft):
						self.errors.append(f"D-Return: '{callee}' at line {self.line(part)} has an unresolved '_' return type")

	def check_languages(self, node: doir_grammar.Node) -> None:
		"""I-Language: this prototype registers no foreign frontends, so every `language` block is an error."""
		if node.name == "change_language":
			language = self.text(node).split('"', 2)[1]
			self.errors.append(f'I-Language: no frontend is registered for language "{language}" at line {self.line(node)}; rewrite the block in DOIR, since this compiler registers no frontend')
			return
		for child in node.nodes:
			self.check_languages(child)


def check(ast: doir_grammar.Node, src: str, is_program: bool) -> list[str]:
	"""Every tree-walk diagnostic for the parsed file `ast`."""
	checker = Checker(src)
	checker.collect_signatures(ast)
	checker.check_block(ast)
	checker.check_languages(ast)
	if is_program and not checker.ends_with_terminator(ast):
		checker.errors.append("WF-Term: the program's root does not end with a terminator call (L-Entry); end it with std.return, std.block_result, std.halt or a tail call")
	return checker.errors


def dump(node: doir_grammar.Node, src: str, depth: int = 0) -> None:
	"""Prints the tree below `node`, one node per line indented by `depth`, with each leaf's text."""
	print("  " * depth + node.name + ("" if node.nodes else f" {doir_grammar.text_of(src, node)!r}"))
	for child in node.nodes:
		dump(child, src, depth + 1)


def check_file(parser, path: str, *, is_program: bool, dump_ast: bool) -> bool:
	"""Checks the file at `path` and prints its report; returns whether it passed."""
	src, ast = "", None
	try:
		src = pathlib.Path(path).read_text()
		ast = doir_grammar.parse(parser, src)
	except OSError as exc:
		errors = [f"cannot read: {exc.strerror}; check that the path names a readable file"]
	except pe.ParseError as exc:
		errors = [doir_grammar.syntax_error(src, exc)]
	else:
		errors = check(ast, src, is_program)
	print(f"{path}: {'FAIL' if errors else 'ok'}")
	for error in errors:
		print(f"  {error}")
	if dump_ast and ast is not None:
		dump(ast, src)
	return not errors


def main() -> int:
	"""Checks the files named on the command line; returns 0 if all pass, 1 if any fails or the grammar does not compile."""
	args = argparse.ArgumentParser(description="Check DOIR sources against doir.peg and the tree-walk rules.")
	args.add_argument("-a", dest="dump_ast", action="store_true", help="print each file's AST")
	args.add_argument("-g", dest="grammar", default=doir_grammar.GRAMMAR, help="the grammar to parse with")
	args.add_argument("files", nargs="*", help="library files")
	args.add_argument("-p", dest="programs", nargs="*", default=[], help="program files, whose root must end with a terminator (L-Entry)")
	opts = args.parse_args()
	try:
		parser = doir_grammar.load(opts.grammar)
	except pe.Error as exc:
		print(doir_grammar.grammar_error(exc), file=sys.stderr)
		return 1
	sys.setrecursionlimit(100000)
	files = [(path, False) for path in opts.files] + [(path, True) for path in opts.programs]
	results = [check_file(parser, path, is_program=is_program, dump_ast=opts.dump_ast) for path, is_program in files]
	return 0 if all(results) else 1


if __name__ == "__main__":
	sys.exit(main())
