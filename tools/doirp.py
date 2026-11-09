#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pe>=0.6"]
# ///
"""DOIR+ Preprocessor: translates ergonomic DOIR+ syntax into conforming DOIR Core.

The DOIR+ grammar is `doir_plus.peg`, which extends `doir.peg`; both are loaded by `doir_grammar.py`. Each nested call, typed constant, inline block and inline function is hoisted into a temporary declared just before the statement that uses it, and every declaration carries a `SourceInfo` pointing back at the DOIR+ source.

    # Preprocess a DOIR+ file to stdout:
    uv run tools/doirp.py input.doirp

    # Preprocess a DOIR+ file to a specified DOIR Core output:
    uv run tools/doirp.py input.doirp -o output.doir

    # Check generated output:
    uv run tools/doir_check.py output.doir
"""

import argparse
import re
import sys

import pe

import doir_grammar

PLUS_GRAMMAR = doir_grammar.ROOT / "doir_plus.peg"

TERMINATORS = {"std.block_result", "std.return", "std.halt", "compiler.return", "compiler.block_result"}


class Value:
	"""Lowered DOIR text for an expression, the source span `(start, last)` it came from, and whether it is a name or a constant."""

	__slots__ = ("text", "span", "is_name", "is_constant")

	def __init__(self, text, span, is_name=False, is_constant=False):
		self.text, self.span, self.is_name, self.is_constant = text, span, is_name, is_constant


class Statement:
	"""A lowered statement: hoisted declarations `(code, span)`, its own code and source tag, and for an expression statement its value."""

	__slots__ = ("hoists", "code", "tag", "value")

	def __init__(self, hoists, code, tag, value=None):
		self.hoists, self.code, self.tag, self.value = hoists, code, tag, value


def parts(node):
	"""A node's children without the whitespace and comment rules between them."""
	return [n for n in node.nodes if n.name not in ("_", "wsc")]


def span_of(node):
	"""The source span `(start, last)` of `node`, its last character included."""
	return (node.pos, node.end - 1)


def merge(a, b):
	"""The smallest span covering spans `a` and `b`."""
	return (min(a[0], b[0]), max(a[1], b[1]))


def identifiers(node):
	"""Every `Identifier` node under `node`, in source order."""
	for n in node.nodes:
		if n.name == "Identifier":
			yield n
		else:
			yield from identifiers(n)


class LoweringError(Exception):
	"""A DOIR+ construct with no DOIR lowering; its message names the file, line, rule tag and a hint."""


def callee(text):
	"""The name lowered call text `text` calls, or None if it is not a call."""
	m = re.match(r"([^\s(]+)\(", text)
	return m.group(1) if m else None


class Lowering:
	"""Lowers one parsed DOIR+ file to DOIR Core, numbering the temporaries it hoists."""

	def __init__(self, src, filename):
		self.src = src
		self.filename = filename.replace("\\", "/") if filename else "input.doirp"
		self.count = 0

	def fresh(self, prefix):
		"""A temporary name starting `prefix` that no other call has returned."""
		name = f"{prefix}{self.count}"
		self.count += 1
		return name

	def tag(self, span):
		"""The `SourceInfo` pointing `span` back at the DOIR+ source."""
		src = self.src
		l1, c1 = doir_grammar.line_at(src, span[0]), doir_grammar.column_at(src, span[0])
		l2, c2 = doir_grammar.line_at(src, span[1]), doir_grammar.column_at(src, span[1])
		if l1 == l2:
			return f'<"{self.filename}":{l1}:{c1}>' if c1 == c2 else f'<"{self.filename}":{l1}:{c1}-{c2}>'
		return f'<"{self.filename}":{l1}-{l2}:{c1}-{c2}>'

	def render(self, hoists, indent=""):
		"""The lines of `hoists`, each tagged with its source and indented by `indent`."""
		return [indent + f"{code} {self.tag(span)}".replace("\n", "\n" + indent) for code, span in hoists]

	def text(self, node):
		"""The DOIR+ text `node` matched."""
		return doir_grammar.text_of(self.src, node)

	def ensure_name(self, value, hoists):
		"""A name for `value`, hoisting it into a temporary unless it already is one."""
		if value.is_name:
			return value.text
		tmp = self.fresh("_t")
		hoists.append((f"{tmp} : _ = {value.text}", value.span))
		return tmp

	# -----------------------------------------------------------------------
	# Statements
	# -----------------------------------------------------------------------

	def program(self, root):
		"""The DOIR Core text of the whole file `root`."""
		lines = []
		for node in root.children("statement"):
			s = self.statement(node)
			lines += self.render(s.hoists)
			lines.append(s.code if s.tag is None else f"{s.code} {s.tag}")
		return "\n".join(lines) + "\n"

	def statement(self, node):
		"""Lowers a statement to a `Statement`, keeping its own `SourceInfo` when it has one."""
		inner = parts(node)[0]
		if inner.name == "change_language":
			return Statement([], self.text(inner).rstrip(), None)
		end = inner.child("statement_end")
		source = end.child("SourceInfo")
		if inner.name == "expression_statement":
			hoists, value = self.expr(inner.child("expr"))
			tag = self.text(source) if source else self.tag(value.span)
			return Statement(hoists, f"_ : _ = {value.text}", tag, value)
		name = inner.child("Identifier")
		export = "export " if inner.child("exported") else ""
		form = inner.child("inferred") or inner.child("declared")
		if form.name == "inferred":
			hoists, final_type, text, span = self.value(form.child("value"), None)
			code = f"{export}{self.text(name)} : {final_type} = {text}"
		else:
			type_inner = parts(form.child("plus_type"))[0]
			body = form.child("value") and parts(form.child("value"))[0]
			if type_inner.name == "function_type" and body and body.name == "plus_block":
				# A block bound to a function type is the function's body, so it returns rather than yields.
				hoists, type_str, type_span, prologue = self.function_type(type_inner)
				text, span = self.block(body, "std.return", prologue)
				code = f"{export}{self.text(name)} : {type_str} = {text}"
				return Statement(hoists, code, self.text(source) if source else self.tag(merge(span_of(name), merge(type_span, span))))
			hoists, type_str, span = self.type(form.child("plus_type"))
			if form.child("value"):
				value_hoists, final_type, text, span = self.value(form.child("value"), type_str)
				hoists += value_hoists
				code = f"{export}{self.text(name)} : {final_type} = {text}"
			else:
				code = f"{export}{self.text(name)} : {type_str}"
		span = merge(span_of(name), span)
		return Statement(hoists, code, self.text(source) if source else self.tag(span))

	def value(self, node, declared):
		"""Lowers a declaration's value to `(hoists, type, text, span)`; `declared` is the declared type, or None for `:=`."""
		inner = parts(node)[0]
		if inner.name == "plus_block":
			text, span = self.block(inner, "std.block_result")
			return [], declared or "_", text, span
		if inner.name == "function_value":
			hoists, fn_type, fn_span, prologue = self.function_type(inner.child("function_type"))
			if len(parts(inner)) == 1:
				self.bodiless(prologue)
				return hoists, declared or "type", fn_type, fn_span
			text, span = self.function_body(parts(inner)[1], prologue)
			return hoists, declared or fn_type, text, merge(fn_span, span)
		constant = inner.child("Constant")
		if inner.name == "typed_constant":
			hoists, type_str, type_span = self.type(inner.child("plus_type"))
			return hoists, declared or type_str, self.text(constant), merge(span_of(constant), type_span)
		if inner.name == "bare_constant":
			if declared is None:
				span = span_of(constant)
				line, column = doir_grammar.line_at(self.src, span[0]), doir_grammar.column_at(self.src, span[0])
				raise LoweringError(f"{self.filename}:{line}:{column}: V-Literal: a constant's type cannot be inferred; write it, as in `x : std.i64 = {self.text(constant)}`")
			return [], declared, self.text(constant), span_of(constant)
		hoists, value = self.expr(inner)
		# V-NoImplicitCopy: naming a binding is not copying it, so the declaration is an alias.
		return hoists, "alias" if value.is_name else declared or "_", value.text, value.span

	def function_body(self, node, prologue):
		"""Lowers a function body, a block or an expression, to `(text, span)`, opening it with the `prologue` lines (D-Assert)."""
		if node.name == "plus_block":
			return self.block(node, "std.return", prologue)
		hoists, value = self.expr(node)
		name = self.ensure_name(value, hoists)
		lines = self.render(prologue + hoists, "\t") + [f"\t_ : _ = std.return({name}) {self.tag(value.span)}"]
		return "{\n" + "\n".join(lines) + "\n}", value.span

	def block(self, node, terminator, prologue=()):
		"""Lowers a block to `(text, span)`, opening it with the `prologue` lines. A trailing expression becomes the block's `terminator` call, and a block not ending in a terminator gets `terminator(std.nothing)` (WF-Term)."""
		lines = self.render(prologue, "\t")
		statements = node.children("statement")
		last_code = None
		for i, child in enumerate(statements):
			s = self.statement(child)
			lines += self.render(s.hoists, "\t")
			code = s.code
			if i == len(statements) - 1 and s.value is not None and callee(s.value.text) not in TERMINATORS:
				hoists = []
				name = self.ensure_name(s.value, hoists)
				lines += self.render(hoists, "\t")
				code = f"_ : _ = {terminator}({name})"
			lines.append("\t" + (code if s.tag is None else f"{code} {s.tag}").replace("\n", "\n\t"))
			last_code = code if s.value is not None or code.startswith("_ : _ = ") else None
		if last_code is None or callee(last_code[len("_ : _ = "):]) not in TERMINATORS:
			lines.append(f"\t_ : _ = {terminator}(std.nothing) {self.tag((node.end - 1, node.end - 1))}")
		return "{\n" + "\n".join(lines) + "\n}", span_of(node)

	# -----------------------------------------------------------------------
	# Types
	# -----------------------------------------------------------------------

	def type(self, node):
		"""Lowers a type to `(hoists, text, span)`; a constructed type call is hoisted into a `type` temporary."""
		inner = parts(node)[0]
		if inner.name == "function_type":
			hoists, text, span, prologue = self.function_type(inner)
			self.bodiless(prologue)
			return hoists, text, span
		if inner.name == "type_call":
			hoists, args = self.arguments(inner.child("arguments"))
			tmp = self.fresh("_t_type")
			hoists.append((f"{tmp} : type = {self.text(inner.child('Identifier'))}({', '.join(args)})", span_of(inner)))
			return hoists, tmp, span_of(inner)
		return [], self.text(inner), span_of(inner)

	def bodiless(self, prologue):
		"""Raises `LoweringError` if a function type with no body has a `prologue` to assert."""
		if prologue:
			span = prologue[-1][1]
			line, column = doir_grammar.line_at(self.src, span[0]), doir_grammar.column_at(self.src, span[0])
			raise LoweringError(f"{self.filename}:{line}:{column}: D-Assert: this type is built from a parameter, and a function type without a body has nowhere to assert it; give the function a body, or take the parameter as a `deduced type` and assert its type where the function is defined")

	def dependent_type(self, node, owner, prologue):
		"""Lowers constructed type `node`, built from a parameter in `scope`, to a fresh deduced parameter, appending to `prologue` the assertion that solves it (D-Assert)."""
		hoists, args = self.arguments(node.child("arguments"))
		param, built, condition, message = self.fresh("_t_type"), self.fresh("_t_type"), self.fresh("_c"), self.fresh("_c")
		span, former = span_of(node), self.text(node.child("Identifier"))
		prologue += hoists + [
			(f"{built} : type = {former}({', '.join(args)})", span),
			(f"{condition} : std.u1 = std.types.is_same_type({param}, {built})", span),
			(f'{message} : std.c_string = "D-Assert: {owner} has a type {former} did not build; give it one that {former} built"', span),
			(f"_ : void = std.diagnostics.assert({condition}, {message})", span),
		]
		return param

	def function_type(self, node, scope=frozenset()):
		"""Lowers a function type to `(hoists, text, span, prologue)`, hoisting each parameter's constructed type.

		A constructed type built from a parameter, its own or one of an enclosing function type's in `scope`, cannot be hoisted out of the function: it becomes a deduced parameter, and `prologue` the lines that open the body to solve and check it (D-Assert)."""
		hoists, params, prologue, leading = [], [], [], []
		names = set(scope)

		def dependent(type_node):
			inner = parts(type_node)[0]
			return inner if inner.name == "type_call" and any(self.text(i).split(".")[0] in names for i in identifiers(inner)) else None

		for p in node.children("plus_parameter"):
			name = self.text(p.child("Identifier"))
			if p.child("deduced"):
				params.append(f"{name} : deduced type")
				names.add(name)
				continue
			type_node = p.child("plus_type")
			call = dependent(type_node)
			if call:
				param = self.dependent_type(call, f"`{name}`", prologue)
				params.append(f"{param} : deduced type")
				type_str = param
			elif parts(type_node)[0].name == "function_type":
				type_hoists, type_str, _, inner_prologue = self.function_type(parts(type_node)[0], names)
				self.bodiless(inner_prologue)
				hoists += type_hoists
			else:
				type_hoists, type_str, _ = self.type(type_node)
				hoists += type_hoists
			default = p.child("Constant") or (p.children("Identifier")[1:] or [None])[0]
			params.append(f"{name} : {type_str}" + (f" = {self.text(default)}" if default else ""))
			names.add(name)
		ret = node.child("plus_type")
		ret_str = None
		if ret:
			call = dependent(ret)
			if call:
				# D-Return: the return type is a leading deduced parameter, solved from the destination.
				ret_str = self.dependent_type(call, "the return value", prologue)
				leading.append(f"{ret_str} : deduced type")
			elif parts(ret)[0].name == "function_type":
				ret_hoists, ret_str, _, inner_prologue = self.function_type(parts(ret)[0], names)
				self.bodiless(inner_prologue)
				hoists += ret_hoists
			else:
				ret_hoists, ret_str, _ = self.type(ret)
				hoists += ret_hoists
		text = f"({', '.join(leading + params)})" + (f" -> {ret_str}" if ret_str else "")
		return hoists, text, span_of(node), prologue

	# -----------------------------------------------------------------------
	# Expressions
	# -----------------------------------------------------------------------

	def expr(self, node):
		"""Lowers an expression to `(hoists, Value)`; a typed one is hoisted into a temporary of that type."""
		hoists, value = self.pipe_expr(node.child("pipe_expr"))
		type_node = node.child("plus_type")
		if type_node:
			type_hoists, type_str, type_span = self.type(type_node)
			hoists += type_hoists
			span = merge(value.span, type_span)
			tmp = self.fresh("_c" if value.is_constant else "_t")
			hoists.append((f"{tmp} : {type_str} = {value.text}", span))
			value = Value(tmp, span, is_name=True)
		return hoists, value

	def pipe_expr(self, node):
		"""Lowers `x |> f(y)` to `(hoists, Value)` as the call `f(x, y)`."""
		hoists, lhs = self.infix_expr(node.child("infix_expr"))
		for pipe in node.children("pipe"):
			args = [self.ensure_name(lhs, hoists)]
			fn = pipe.child("Identifier")
			end = span_of(fn)
			call = pipe.child("call_suffix")
			if call:
				arg_hoists, more = self.arguments(call.child("arguments"))
				hoists += arg_hoists
				args += more
				end = span_of(call)
			lhs = Value(f"{self.text(fn)}({', '.join(args)})", merge(lhs.span, end))
		return hoists, lhs

	def infix_expr(self, node):
		"""Lowers `a op b` to `(hoists, Value)` as the call `op(a, b)`, left to right."""
		hoists, lhs = self.postfix_expr(node.child("postfix_expr"))
		for infix in node.children("infix"):
			rhs_hoists, rhs = self.postfix_expr(infix.child("postfix_expr"))
			hoists += rhs_hoists
			lhs_name = self.ensure_name(lhs, hoists)
			rhs_name = self.ensure_name(rhs, hoists)
			lhs = Value(f"{self.text(infix.child('Identifier'))}({lhs_name}, {rhs_name})", merge(lhs.span, rhs.span))
		return hoists, lhs

	def postfix_expr(self, node):
		"""Lowers a chain of calls `f(a)(b)` to `(hoists, Value)`, naming each callee."""
		hoists, value = self.primary(node.child("primary"))
		for call in node.children("call_suffix"):
			arg_hoists, args = self.arguments(call.child("arguments"))
			hoists += arg_hoists
			fn = self.ensure_name(value, hoists)
			value = Value(f"{fn}({', '.join(args)})", merge(value.span, span_of(call)))
		return hoists, value

	def arguments(self, node):
		"""Lowers call arguments to `(hoists, names)`: every argument is passed by name (WF-Arg)."""
		hoists, names = [], []
		for arg in node.children("argument") if node else []:
			inner = parts(arg)[0]
			if inner.name == "inline_function":
				names.append(self.inline_function(inner, hoists).text)
			elif inner.name in ("constant_argument", "block_argument"):
				type_node = inner.child("plus_type")
				if inner.name == "constant_argument":
					text, span, prefix, default = self.text(inner.child("Constant")), span_of(inner.child("Constant")), "_c", "_"
				else:
					(text, span), prefix, default = self.block(inner.child("plus_block"), "std.block_result"), "_blk", "block"
				type_str = default
				if type_node:
					type_hoists, type_str, type_span = self.type(type_node)
					hoists += type_hoists
					span = merge(span, type_span)
				tmp = self.fresh(prefix)
				hoists.append((f"{tmp} : {type_str} = {text}", span))
				names.append(tmp)
			else:
				expr_hoists, value = self.expr(inner)
				hoists += expr_hoists
				names.append(self.ensure_name(value, hoists))
		return hoists, names

	def inline_function(self, node, hoists):
		"""Hoists an inline function into a `_fn` temporary, returning its name."""
		type_hoists, fn_type, fn_span, prologue = self.function_type(node.child("function_type"))
		hoists += type_hoists
		body = parts(node)[1]
		if body.name == "plus_block":
			text, span = self.block(body, "std.return", prologue)
			tmp = self.fresh("_fn")
		else:
			body_hoists, value = self.expr(body)
			tmp = self.fresh("_fn")
			name = self.ensure_name(value, body_hoists)
			lines = self.render(prologue + body_hoists, "\t") + [f"\t_ : _ = std.return({name}) {self.tag(value.span)}"]
			text, span = "{\n" + "\n".join(lines) + "\n}", value.span
		span = merge(fn_span, span)
		hoists.append((f"{tmp} : {fn_type} = {text}", span))
		return Value(tmp, span, is_name=True)

	def primary(self, node):
		"""Lowers a primary expression to `(hoists, Value)`."""
		inner = parts(node)[0]
		if inner.name == "paren_constant":
			hoists, type_str, _ = self.type(inner.child("plus_type"))
			tmp = self.fresh("_c")
			hoists.append((f"{tmp} : {type_str} = {self.text(inner.child('Constant'))}", span_of(inner)))
			return hoists, Value(tmp, span_of(inner), is_name=True)
		if inner.name == "inline_function":
			hoists = []
			return hoists, self.inline_function(inner, hoists)
		if inner.name == "function_type":
			hoists, text, span, prologue = self.function_type(inner)
			self.bodiless(prologue)
			return hoists, Value(text, span)
		if inner.name == "paren_expr":
			hoists, value = self.expr(inner.child("expr"))
			return hoists, Value(value.text, span_of(inner), value.is_name, value.is_constant)
		if inner.name == "plus_block":
			text, span = self.block(inner, "std.block_result")
			return [], Value(text, span)
		return [], Value(self.text(inner), span_of(inner), is_name=inner.name == "Identifier", is_constant=inner.name == "Constant")


def preprocess(source, filename=""):
	"""Translates DOIR+ `source` to DOIR Core text. Raises `pe.ParseError` on a syntax error, which `doir_grammar.syntax_error` formats, and `LoweringError` on a construct DOIR cannot express."""
	parser = doir_grammar.load(PLUS_GRAMMAR, doir_grammar.GRAMMAR)
	return Lowering(source, filename).program(doir_grammar.parse(parser, source))


def main():
	"""Preprocesses the file named on the command line; returns 0 on success, 1 if it cannot be read, does not parse or cannot be lowered."""
	parser = argparse.ArgumentParser(description="DOIR+ Preprocessor to standard DOIR Core")
	parser.add_argument("input", help="Input .doirp file")
	parser.add_argument("-o", "--output", help="Output .doir file (default: stdout)")
	args = parser.parse_args()

	try:
		with open(args.input, "r", encoding="utf-8") as f:
			source = f.read()
	except OSError as exc:
		print(f"{args.input}: cannot read: {exc.strerror}; check that the path names a readable file", file=sys.stderr)
		return 1
	try:
		out_code = preprocess(source, filename=args.input)
	except pe.ParseError as exc:
		print(f"{args.input}: {doir_grammar.syntax_error(source, exc)}", file=sys.stderr)
		return 1
	except pe.Error as exc:
		print(doir_grammar.grammar_error(exc), file=sys.stderr)
		return 1
	except LoweringError as exc:
		print(exc, file=sys.stderr)
		return 1

	if args.output:
		with open(args.output, "w", encoding="utf-8") as f:
			f.write(out_code)
	else:
		sys.stdout.write(out_code)
	return 0


if __name__ == "__main__":
	sys.exit(main())
