/// The pretty printer: a parsed block written back out as DOIR source, one declaration per line and nested blocks indented by a tab. It inverts `doir.syntax.parser`'s build, so the text parses back into an equivalent store: the same declarations, names, types, values, flags and source annotations (`AT-Source`). Comments, `language` blocks (`I-Language`) and literal spellings are not kept: a character or hexadecimal literal prints as its decimal value, a raw string as an escaped one, and a float as the shortest decimal that reads back to the same `double`.
///
/// It reads the components the parser writes, the `Lookup*` names among them, so it prints a store before name resolution.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import fp.string;
/// static import doir.query;
/// static import doir.source;
/// static import doir.strings;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.query.create(store);
/// scope(exit) doir.query.free(engine);
/// doir.strings.Strings strings;
/// scope(exit) doir.strings.free(strings);
/// immutable file = doir.source.addFile(engine, strings, "a.doir");
/// assert(doir.source.commit(engine, strings, file, "x:std.u8=0x5 // five") == 0);
/// auto text = print(store, strings, doir.source.rootOf(engine, file)).get;
/// scope(exit) fp.string.free(text);
/// assert(fp.string.slice(text) == "x : std.u8 = 5\n");
/// ---
module doir.printer;

static import core.stdc.stdio;
static import core.stdc.stdlib;
static import std.typecons;

static import fp.dynarray;
version(unittest) static import fp.testing;
static import fp.string;

static import ecrs.context;

static import doir.components.ast;
static import doir.components.source;
static import doir.strings;
static import doir.engine.locations;
static import doir.syntax.lexer;
static import doir.syntax.tables;

public import ecrs.registry : EntityId, invalidEntity;

@nogc nothrow:


// --- spelling ----------------------------------------------------------------

// The code point at `s[i]`, advancing `i`, or null if it is not well-formed UTF-8 (the lax `fp.string.decodeUtf8` accepts overlong and truncated forms).
private std.typecons.Nullable!uint decodeStrict(const(char)[] s, ref size_t i) @trusted {
	immutable start = i;
	bool valid;
	immutable c = fp.string.decodeUtf8(s, i, valid);
	if (!valid) return typeof(return).init;
	char[4] encoded = void;
	fp.string.Utf8Error error;
	immutable n = fp.string.encodeUtf8(c, encoded.ptr, error);
	if (error != fp.string.Utf8Error.none || n != i - start || encoded[0 .. n] != s[start .. i]) return typeof(return).init;
	return typeof(return)(c);
}

// Whether `name` lexes as a plain `Identifier` that `doir.syntax.parser.nameOf` reads back as itself, so it needs no `%"..."`.
private bool isPlain(const(char)[] name) {
	if (name.length == 0) return false;
	foreach (keyword; doir.syntax.tables.keywords) {
		if (name.length < keyword.length || name[0 .. keyword.length] != keyword) continue;
		size_t after = keyword.length;
		if (after == name.length) return false;
		immutable next = decodeStrict(name, after);
		if (next.isNull || !doir.syntax.lexer.isIdentifierContinue(next.get)) return false;
	}
	size_t i = 0;
	immutable first = decodeStrict(name, i);
	if (first.isNull || (first.get != '%' && !doir.syntax.lexer.isIdentifierStart(first.get))) return false;
	while (i < name.length) {
		immutable c = decodeStrict(name, i);
		if (c.isNull || (c.get != '.' && !doir.syntax.lexer.isIdentifierContinue(c.get))) return false;
	}
	return true;
}

// Appends `text` as `StringChar`s that decode back to exactly its bytes: well-formed printable UTF-8 as is, everything else escaped.
private bool appendEscaped(ref char* out_, const(char)[] text) {
	static immutable hex = "0123456789abcdef";
	bool afterByte = false; // a `\x` escape is greedy, so a hex digit after one is escaped too
	size_t i = 0;
	while (i < text.length) {
		immutable start = i;
		immutable decoded = decodeStrict(text, i);
		if (decoded.isNull) {
			immutable b = cast(ubyte) text[start];
			i = start + 1;
			if (fp.string.concatenateMultiple(out_, "\\x", hex[b >> 4 .. (b >> 4) + 1], hex[b & 15 .. (b & 15) + 1]) is null) return false;
			afterByte = true;
			continue;
		}
		immutable c = decoded.get;
		const(char)[] named = null;
		switch (c) {
			case '"': named = `\"`; break;
			case '\\': named = `\\`; break;
			case '\n': named = `\n`; break;
			case '\t': named = `\t`; break;
			case '\r': named = `\r`; break;
			case '\a': named = `\a`; break;
			case '\b': named = `\b`; break;
			case '\f': named = `\f`; break;
			case '\v': named = `\v`; break;
			default: break;
		}
		bool ok;
		if (named !is null) ok = fp.string.concatenate(out_, named) !is null;
		else if (c < 0x20 || c == 0x7F || (afterByte && c < 0x80 && fp.string.isHexDigit(cast(char) c)))
			ok = fp.string.concatenateMultiple(out_, "\\u00", hex[c >> 4 .. (c >> 4) + 1], hex[c & 15 .. (c & 15) + 1]) !is null;
		else ok = fp.string.concatenate(out_, text[start .. i]) !is null;
		if (!ok) return false;
		afterByte = false;
	}
	return true;
}

// Appends the shortest decimal that `strtod` reads back as `value`, with a point or exponent so it lexes as a `FloatConstant`.
private bool appendFloat(ref char* out_, double value) @trusted {
	char[48] buffer = void;
	int n = 0;
	foreach (precision; 1 .. 18) {
		n = core.stdc.stdio.snprintf(buffer.ptr, buffer.length, "%.*g", precision, value);
		if (core.stdc.stdlib.strtod(buffer.ptr, null) == value) break;
	}
	bool isFloat = false;
	foreach (c; buffer[0 .. n]) isFloat |= c == '.' || c == 'e';
	return fp.string.concatenateMultiple(out_, buffer[0 .. n], isFloat ? "" : ".0") !is null;
}


// --- printing ----------------------------------------------------------------

private struct Printer {
	const(ecrs.context.Context)* store;
	const(doir.strings.Strings)* strings;
	char* out_;
}

private bool append(ref Printer p, const(char)[] text) {
	return text.length == 0 || fp.string.concatenate(p.out_, text) !is null;
}

// `quote` forces `%"..."` where the plain spelling would make the parser build another form, as `type` before a block does.
private bool appendName(ref Printer p, doir.strings.StringId name, bool quote = false) {
	const text = doir.strings.text(*p.strings, name);
	if (!quote && isPlain(text)) return append(p, text);
	return append(p, `%"`) && appendEscaped(p.out_, text) && append(p, `"`);
}

// A declaration's or parameter's own name, where a bare `_` spells none.
private bool appendOwnName(ref Printer p, EntityId e) {
	auto name = ecrs.context.findComponent!(doir.components.ast.Name)(*p.store, e);
	return name is null ? append(p, "_") : appendName(p, name.value, doir.strings.text(*p.strings, name.value) == "_");
}

private bool appendConstant(ref Printer p, ref const doir.components.ast.ConstantVal value) {
	final switch (value.kind) {
		case doir.components.ast.ConstantVal.Kind.integer:
			return fp.string.concatenateMultiple(p.out_, value.integerValue) !is null;
		case doir.components.ast.ConstantVal.Kind.float_:
			return appendFloat(p.out_, value.floatValue);
		case doir.components.ast.ConstantVal.Kind.bytes:
			return append(p, `"`) && appendEscaped(p.out_, doir.strings.text(*p.strings, value.bytesValue)) && append(p, `"`);
	}
}

// A parameter's `deduced type` is the interned `deducedTypeName`, which only a parameter may spell bare (`D-Deduce`).
private bool appendType(ref Printer p, EntityId e, bool parameter, bool quote = false) {
	if (auto lookup = ecrs.context.findComponent!(doir.components.ast.LookupTypeOf)(*p.store, e)) {
		if (parameter && doir.strings.text(*p.strings, lookup.name) == doir.components.ast.deducedTypeName) return append(p, "deduced type");
		return appendName(p, lookup.name, quote);
	}
	auto typeOf = ecrs.context.findComponent!(doir.components.ast.TypeOf)(*p.store, e);
	assert(typeOf !is null, "doir.printer: a typed declaration has neither LookupTypeOf nor an in-place TypeOf");
	return appendFunctionType(p, typeOf.type);
}

// `(a: T, b: U = 5) -> V`, from function type `ft`'s parameters and return type (`R-Param`, `F-Default`).
private bool appendFunctionType(ref Printer p, EntityId ft) {
	if (!append(p, "(")) return false;
	foreach (i, parameter; fp.dynarray.slice(ecrs.context.getComponent!(doir.components.ast.FunctionInputs)(*p.store, ft).related)) {
		if (i && !append(p, ", ")) return false;
		if (!appendOwnName(p, parameter) || !append(p, ": ") || !appendType(p, parameter, true)) return false;
		if (auto constant = ecrs.context.findComponent!(doir.components.ast.ConstantVal)(*p.store, parameter)) {
			if (!append(p, " = ") || !appendConstant(p, *constant)) return false;
		} else if (auto value = ecrs.context.findComponent!(doir.components.ast.LookupValue)(*p.store, parameter))
			if (!append(p, " = ") || !appendName(p, value.name)) return false;
	}
	if (!append(p, ")")) return false;
	if (auto lookup = ecrs.context.findComponent!(doir.components.ast.LookupFunctionReturn)(*p.store, ft)) return append(p, " -> ") && appendName(p, lookup.name);
	if (auto returned = ecrs.context.findComponent!(doir.components.ast.FunctionReturn)(*p.store, ft)) return append(p, " -> ") && appendFunctionType(p, returned.type);
	return true;
}

private bool appendIndent(ref Printer p, size_t depth) {
	foreach (_; 0 .. depth)
		if (fp.string.append(p.out_, '\t') is null) return false;
	return true;
}

// The source annotation `<"file":3-4:5>`: lines, then columns, each a range only where start and end differ (`AT-Source`).
private bool appendAnnotation(ref Printer p, ref const doir.components.source.SourceAnnotation annotation) {
	const at = annotation.location;
	// A quote in the name would end the quoted form early; the bare form ends at the first `:`.
	immutable quoted = fp.string.find(at.file, `"`, 0) == size_t.max;
	if (!append(p, quoted ? ` <"` : " <") || !append(p, at.file) || !append(p, quoted ? `":` : ":")) return false;
	if (fp.string.concatenateMultiple(p.out_, at.start.line) is null) return false;
	if (at.end.line != at.start.line && fp.string.concatenateMultiple(p.out_, "-", at.end.line) is null) return false;
	if (fp.string.concatenateMultiple(p.out_, ":", at.start.column) is null) return false;
	if (at.end.column != at.start.column && fp.string.concatenateMultiple(p.out_, "-", at.end.column) is null) return false;
	return append(p, ">");
}

private bool appendBlock(ref Printer p, EntityId block, size_t depth) {
	foreach (e; fp.dynarray.slice(ecrs.context.getComponent!(doir.components.ast.Block)(*p.store, block).related))
		if (!appendDeclaration(p, e, depth)) return false;
	return true;
}

// One `assignment` of `doir.peg`, the forms `doir.builders` documents, ended by a newline.
private bool appendDeclaration(ref Printer p, EntityId e, size_t depth) {
	auto store = p.store;
	auto flags = ecrs.context.findComponent!(doir.components.ast.Flags)(*store, e);
	immutable set = flags is null ? doir.components.ast.Flags.None : flags.flags;
	if (!appendIndent(p, depth) || !append(p, set & doir.components.ast.Flags.Export ? "export " : "")) return false;
	if (!appendOwnName(p, e) || !append(p, " : ")) return false;

	auto block = ecrs.context.findComponent!(doir.components.ast.Block)(*store, e);
	auto alias_ = ecrs.context.findComponent!(doir.components.ast.LookupAlias)(*store, e);
	auto reference = ecrs.context.findComponent!(doir.components.ast.LookupValue)(*store, e);
	bool ok;
	if (set & doir.components.ast.Flags.Namespace) ok = append(p, "namespace");
	else if (alias_ !is null) ok = append(p, "alias = ") && appendName(p, alias_.name);
	else {
		// The parser reads `type` and `namespace` before a block, and `alias` before a name, as other forms (`WF-Kind`).
		bool quote = false;
		if (auto lookup = ecrs.context.findComponent!(doir.components.ast.LookupTypeOf)(*store, e)) {
			const typeName = doir.strings.text(*p.strings, lookup.name);
			immutable aggregate = ecrs.context.hasComponent!(doir.components.ast.TypeDefinition)(*store, e);
			quote = (block !is null && !aggregate && (typeName == "type" || typeName == "namespace")) || (reference !is null && typeName == "alias");
		}
		ok = appendType(p, e, false, quote);
	}
	if (!ok) return false;

	if (block !is null) {
		if (!append(p, " = {\n") || !appendBlock(p, e, depth + 1) || !appendIndent(p, depth) || !append(p, "}")) return false;
	} else if (auto constant = ecrs.context.findComponent!(doir.components.ast.ConstantVal)(*store, e)) {
		if (!append(p, " = ") || !appendConstant(p, *constant)) return false;
	} else if (auto callee = ecrs.context.findComponent!(doir.components.ast.LookupCall)(*store, e)) {
		immutable prefix = set & doir.components.ast.Flags.Inline ? "inline " : set & doir.components.ast.Flags.Flatten ? "flatten " : set & doir.components.ast.Flags.Tail ? "tail " : "";
		if (!append(p, " = ") || !append(p, prefix) || !appendName(p, callee.name) || !append(p, "(")) return false;
		foreach (i, argument; fp.dynarray.slice(ecrs.context.getComponent!(doir.components.ast.LookupFunctionInputs)(*store, e).names))
			if ((i && !append(p, ", ")) || !appendName(p, argument)) return false;
		if (!append(p, ")")) return false;
	} else if (reference !is null) {
		if (!append(p, " = ") || !appendName(p, reference.name)) return false;
	} else if (ecrs.context.hasComponent!(doir.components.ast.FunctionInputs)(*store, e)) {
		if (!append(p, " = ") || !appendFunctionType(p, e)) return false;
	}

	if (auto annotation = ecrs.context.findComponent!(doir.components.source.SourceAnnotation)(*store, e))
		if (!appendAnnotation(p, *annotation)) return false;
	return append(p, "\n");
}

/// Prints the declarations of `block`, a file's root block (`doir.source.rootOf`) or a block or namespace in one, returning a new fp string the caller releases with `fp.string.free`; an empty block gives a null `char*`, the empty fp string. Parsing the text back builds an equivalent store; see the module documentation for what it leaves out.
///
/// Returns null if an allocation was refused.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import fp.string;
/// static import doir.builders;
/// static import doir.strings;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// doir.strings.Strings strings;
/// scope(exit) doir.strings.free(strings);
/// auto root = doir.builders.createRoot(store);
/// auto math = doir.builders.pushNamespace(root, doir.strings.intern(strings, "math"));
/// cast(void) doir.builders.pushValueless(math, doir.strings.intern(strings, "pi"), doir.strings.intern(strings, "std.f64"));
/// auto text = print(store, strings, root.block).get;
/// scope(exit) fp.string.free(text);
/// assert(fp.string.slice(text) == "math : namespace = {\n\tpi : std.f64\n}\n");
/// ---
std.typecons.Nullable!(char*) print(ref const ecrs.context.Context store, ref const doir.strings.Strings strings, EntityId block) {
	auto p = Printer(&store, &strings, null);
	if (!appendBlock(p, block, 0)) {
		fp.string.free(p.out_);
		return typeof(return).init;
	}
	return typeof(return)(p.out_);
}


version(unittest) {
	static import fp.pointer;
	static import doir.query;
	static import doir.source;
	static import doir.testing;

	// Commits `text` as a new file and prints its root, which it sets `root` to.
	private char* reprint(ref doir.query.QueryEngine engine, ref doir.strings.Strings strings, const(char)[] path, const(char)[] text, out EntityId root) {
		immutable file = doir.source.addFile(engine, strings, path);
		assert(file != invalidEntity && doir.source.commit(engine, strings, file, text) == 0);
		root = doir.source.rootOf(engine, file);
		return print(*engine.store, strings, root).get;
	}
}

unittest { // spelling: plain names, escapes, floats
	assert(isPlain("std.u8") && isPlain("%x") && isPlain("α") && isPlain("exported") && isPlain("_x") && isPlain("_"));
	assert(!isPlain("") && !isPlain("a b") && !isPlain("1x") && !isPlain("export") && !isPlain("export.x") && !isPlain(".x") && !isPlain("\xC3"));

	char* s = null;
	scope(exit) fp.string.free(s);
	assert(appendEscaped(s, "a\"\\\n\x01é\x80A\x80g\t\r\a\b\f\v"));
	assert(fp.string.slice(s) == `a\"\\\n\u0001é\x80\u0041\x80g\t\r\a\b\f\v`);

	char* f = null;
	scope(exit) fp.string.free(f);
	assert(appendFloat(f, 2.5) && appendFloat(f, 3) && appendFloat(f, 0.1) && appendFloat(f, 1e-300));
	assert(fp.string.slice(f) == "2.53.00.11e-300");
}

unittest { // every declaration form prints as written and reparses to the same text
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	auto engine = doir.query.create(store);
	scope(exit) doir.query.free(engine);
	doir.strings.Strings strings;
	scope(exit) doir.strings.free(strings);

	immutable source = "// a comment the printer drops\n"
		~ "export six : std.u8 = 0x6 <\"gen.doir\":3-4:5>\n"
		~ "w : f64 = 2.50; whole : f64 = 3.; tiny : f64 = 1e-300\n"
		~ "s : p = \"a\\tb\\x80\\x41\\u00e9\\\"\" ; r : p = \"\"\"raw \"quoted\"\"\"\" ; c : u32 = 'é'\n"
		~ "_ : T\n"
		~ "blk : block = {\n\tinner : T = tail f(x, %\"y z\")\n\t_ : _ = std.block_result(std.nothing) <g.doir:1:2-9>\n}\n"
		~ "vec : type = { x : f32 ; y : f32 ; }\n"
		~ "add_t : type = (a: T, b: deduced type, c: T = 5, d: T = y) -> T\n"
		~ "f : (g: (x: T) -> U, _: V) -> (c: U) -> V\n"
		~ "color : alias = vec\n"
		~ "math : namespace = { pi : f64 = 3.14159 ; }\nmath : namespace = {}\n"
		~ "%\"a b\" : %\"type\" = {}\n%\"_\" : %\"alias\" = q\n%\"export.x\" : %\"deduced type\" = %\"namespace\"\n"
		~ "empty : () = flatten g()\n";
	immutable expected = "export six : std.u8 = 6 <\"gen.doir\":3-4:5>\n"
		~ "w : f64 = 2.5\nwhole : f64 = 3.0\ntiny : f64 = 1e-300\n"
		~ "s : p = \"a\\tb\\x80\\u0041é\\\"\"\nr : p = \"raw \\\"quoted\\\"\"\nc : u32 = 233\n"
		~ "_ : T\n"
		~ "blk : block = {\n\tinner : T = tail f(x, %\"y z\")\n\t_ : _ = std.block_result(std.nothing) <\"g.doir\":1:2-9>\n}\n"
		~ "vec : type = {\n\tx : f32\n\ty : f32\n}\n"
		~ "add_t : type = (a: T, b: deduced type, c: T = 5, d: T = y) -> T\n"
		~ "f : (g: (x: T) -> U, _: V) -> (c: U) -> V\n"
		~ "color : alias = vec\n"
		~ "math : namespace = {\n\tpi : f64 = 3.14159\n}\nmath : namespace = {\n}\n"
		~ "%\"a b\" : %\"type\" = {\n}\n%\"_\" : %\"alias\" = q\n%\"export.x\" : %\"deduced type\" = namespace\n"
		~ "empty : () = flatten g()\n";

	EntityId a, b;
	auto first = reprint(engine, strings, "a.doir", source, a);
	scope(exit) fp.string.free(first);
	assert(fp.string.slice(first) == expected);
	auto second = reprint(engine, strings, "b.doir", fp.string.slice(first), b);
	scope(exit) fp.string.free(second);
	assert(fp.string.slice(second) == expected);

	// The reparse built the same entities, not only the same text: `%"type"` stayed a block, `%"alias"` a reference, and the bytes and floats kept their values.
	const reparsed = fp.dynarray.slice(ecrs.context.getComponent!(doir.components.ast.Block)(store, b).related);
	assert(reparsed.length == 19);
	assert(ecrs.context.getComponent!(doir.components.ast.ConstantVal)(store, reparsed[3]).floatValue == 1e-300);
	assert(doir.strings.text(strings, ecrs.context.getComponent!(doir.components.ast.ConstantVal)(store, reparsed[4]).bytesValue) == "a\tb\x80Aé\"");
	assert(ecrs.context.getComponent!(doir.components.ast.Flags)(store, reparsed[0]).flags == (doir.components.ast.Flags.Comptime | doir.components.ast.Flags.Export));
	assert(ecrs.context.hasComponent!(doir.components.ast.Block)(store, reparsed[15]) && !ecrs.context.hasComponent!(doir.components.ast.TypeDefinition)(store, reparsed[15]));
	assert(ecrs.context.hasComponent!(doir.components.ast.LookupValue)(store, reparsed[16]) && !ecrs.context.hasComponent!(doir.components.ast.LookupAlias)(store, reparsed[16]));
	assert(doir.strings.text(strings, ecrs.context.getComponent!(doir.components.ast.Name)(store, reparsed[16]).value) == "_");

	// A refused allocation returns null and leaves no text.
	for (size_t n = 0;; ++n) {
		assert(n < 1000);
		auto previous = fp.testing.beginRationedAllocator(n);
		auto printed = print(store, strings, a);
		fp.testing.endRationedAllocator(previous);
		if (printed.isNull) continue;
		scope(exit) fp.string.free(printed.get);
		assert(fp.string.slice(printed.get) == expected);
		break;
	}
}
