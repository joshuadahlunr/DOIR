/// The pretty printer: a parsed block written back out as DOIR source, one declaration per line, laid out by `doir.format` as the language server formats a file.
/// It inverts `doir.syntax.parser`'s build, so the text parses back into an equivalent store: the same declarations, names, types, values, flags and source annotations (`AT-Source`).
/// Comments, `language` blocks (`I-Language`) and literal spellings are not kept: a character or hexadecimal literal prints as its decimal value, a raw string as an escaped one, and a float as the shortest decimal that reads back to the same `double`.
/// No literal is a NaN or reads back as positive infinity's own spelling, so a declaration's NaN or positive infinity prints as the `N-Limits` call on its written type, `std.numbers.not_a_number(T)` or `std.numbers.infinity(T)`, which reads back as that call rather than as a constant.
/// A parameter default cannot be a call, so an infinite one prints as the literal `1e999` and a NaN one as the call, which does not parse.
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

static import std.typecons;

static import fp.dynarray;
static import fp.pointer;
static import fp.testing;

version(unittest) static import fp.testing;
static import fp.string;
static import fp.string.ascii;
static import fp.string.numbers;
static import fp.string.utf;

static import ecrs.context;

static import doir.components.ast;
static import doir.components.source;
static import doir.format;
static import doir.strings;
static import doir.engine.locations;
static import doir.syntax.lexer;
static import doir.syntax.parser;
static import doir.syntax.tables;

public import ecrs.registry : EntityId, invalidEntity;

@nogc nothrow:


// --- spelling ----------------------------------------------------------------

// Whether all of `text` lexes as one token of `kind`: what the printer's spellings promise the parser.
private bool lexesAs(const(char)[] text, doir.syntax.lexer.TokenKind kind) {
	if (text.length == 0) return false;
	auto cursor = doir.syntax.lexer.Cursor(text);
	immutable t = doir.syntax.lexer.next(cursor);
	return t.kind == kind && t.length == text.length;
}

// Whether `escaped` decodes back to exactly `text`, or the check itself could not allocate.
private bool decodesTo(const(char)[] escaped, const(char)[] text) {
	char* decoded = null;
	scope(exit) fp.string.free(decoded);
	bool refused;
	return doir.syntax.parser.decodeString(escaped, &decoded, refused) is null && (refused || fp.string.slice(decoded) == text);
}

// Whether `name` lexes as a plain `Identifier` that `doir.syntax.parser.nameOf` reads back as itself, so it needs no `%"..."`.
private bool isPlain(const(char)[] name) {
	if (name.length == 0) return false;
	foreach (keyword; doir.syntax.tables.keywords) {
		if (name.length < keyword.length || name[0 .. keyword.length] != keyword) continue;
		size_t after = keyword.length;
		if (after == name.length) return false;
		bool valid;
		immutable next = fp.string.utf.decode(name, after, valid);
		if (!valid || !doir.syntax.lexer.isIdentifierContinue(next)) return false;
	}
	size_t i = 0;
	bool valid;
	immutable first = fp.string.utf.decode(name, i, valid);
	if (!valid || (first != '%' && !doir.syntax.lexer.isIdentifierStart(first))) return false;
	while (i < name.length) {
		immutable c = fp.string.utf.decode(name, i, valid);
		if (!valid || (c != '.' && !doir.syntax.lexer.isIdentifierContinue(c))) return false;
	}
	assert(lexesAs(name, doir.syntax.lexer.TokenKind.identifier), "doir.printer.isPlain: a plain name the lexer does not read as one identifier");
	return true;
}

// Appends `text` as `StringChar`s that decode back to exactly its bytes: well-formed printable UTF-8 as is, everything else escaped.
private bool appendEscaped(ref char* out_, const(char)[] text) {
	static immutable hex = "0123456789abcdef";
	bool afterByte = false; // a `\x` escape is greedy, so a hex digit after one is escaped too
	immutable begin = fp.string.length(out_);
	size_t i = 0;
	while (i < text.length) {
		immutable start = i;
		bool valid;
		immutable c = fp.string.utf.decode(text, i, valid);
		assert(i > start && i <= text.length, "doir.printer.appendEscaped: decoding did not advance within the text");
		if (!valid) { // `decode` consumed the one byte, which is escaped
			immutable b = cast(ubyte) text[start];
			if (!fp.string.append(out_, "\\x", hex[b >> 4 .. (b >> 4) + 1], hex[b & 15 .. (b & 15) + 1])) return false;
			afterByte = true;
			continue;
		}
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
		if (named !is null) ok = fp.string.concatenate(out_, named);
		else if (c < 0x20 || c == 0x7F || (afterByte && c < 0x80 && fp.string.ascii.isHexDigit(cast(char) c)))
			ok = fp.string.append(out_, "\\u00", hex[c >> 4 .. (c >> 4) + 1], hex[c & 15 .. (c & 15) + 1]);
		else ok = fp.string.concatenate(out_, text[start .. i]);
		if (!ok) return false;
		afterByte = false;
	}
	assert(decodesTo(fp.string.slice(out_)[begin .. $], text), "doir.printer.appendEscaped: the escaped text decodes to other bytes");
	return true;
}

// Too large for any float type, so the literal rounds to infinity (spec: a float literal rounds to the nearest representable value).
private enum string infinityLiteral = "1e999";

// Appends `value`, not a NaN, as a `FloatConstant`: shortest decimal, a point added so it does not lex as an integer, `infinityLiteral` for infinity.
private bool appendFloat(ref char* out_, double value) {
	assert(value == value, "doir.printer.appendFloat: a NaN has no literal");
	if (value == double.infinity || value == -double.infinity) return fp.string.append(out_, value < 0 ? "-" : "", infinityLiteral);
	immutable start = fp.string.length(out_);
	if (!fp.string.numbers.appendFloat(out_, value)) return false;
	bool point = false;
	foreach (c; fp.string.slice(out_)[start .. $]) point = point || c == '.' || c == 'e';
	if (!point && !fp.string.concatenate(out_, ".0")) return false;
	assert(lexesAs(fp.string.slice(out_)[start .. $], doir.syntax.lexer.TokenKind.float_), "doir.printer.appendFloat: the spelling does not lex as a float");
	return true;
}


// --- printing ----------------------------------------------------------------

// The printer chooses tokens and where lines end; `doir.format` lays them out, so the two agree on spacing and indentation.
private struct Printer {
	const(ecrs.context.Context)* store;
	const(doir.strings.Strings)* strings;
	char* out_;
	bool attached; // the next token follows the last with no space, as a call's `(` follows its callee
}

// Starts a token: a space after the last one on its line, unless it is attached.
private bool space(ref Printer printer) {
	immutable n = fp.string.length(printer.out_);
	immutable separate = n && printer.out_[n - 1] != '\n' && !printer.attached;
	printer.attached = false;
	return !separate || fp.string.append(printer.out_, ' ');
}

// Appends the tokens of `text`, separated by spaces.
private bool tokens(ref Printer printer, const(char)[] text) {
	return space(printer) && fp.string.concatenate(printer.out_, text);
}

// `quote` forces `%"..."` where the plain spelling would make the parser build another form, as `type` before a block does.
private bool appendName(ref Printer printer, doir.strings.StringId name, bool quote = false) {
	const text = doir.strings.text(*printer.strings, name);
	if (!space(printer)) return false;
	if (!quote && isPlain(text)) return fp.string.concatenate(printer.out_, text);
	return fp.string.concatenate(printer.out_, `%"`) && appendEscaped(printer.out_, text) && fp.string.concatenate(printer.out_, `"`);
}

// A declaration's or parameter's own name, where a bare `_` spells none.
private bool appendOwnName(ref Printer printer, EntityId e) {
	auto name = ecrs.context.findComponent!(doir.components.ast.Name)(*printer.store, e);
	return name is null ? tokens(printer, "_") : appendName(printer, name.value, doir.strings.text(*printer.strings, name.value) == "_");
}

// The value of `typed`, a declaration or, if `parameter`, a parameter default, whose written type a NaN or an infinity's `N-Limits` call names.
private bool appendConstant(ref Printer printer, EntityId typed, bool parameter, ref const doir.components.ast.ConstantVal value) {
	if (!space(printer)) return false;
	final switch (value.kind) {
		case doir.components.ast.ConstantVal.Kind.integer:
			return fp.string.append(printer.out_, value.integerValue);
		case doir.components.ast.ConstantVal.Kind.negativeInteger:
			return fp.string.append(printer.out_, "-") && fp.string.append(printer.out_, 0 - value.integerValue);
		case doir.components.ast.ConstantVal.Kind.float_:
			immutable notANumber = value.floatValue != value.floatValue;
			if (!notANumber && (parameter || value.floatValue != double.infinity)) return appendFloat(printer.out_, value.floatValue);
			if (!fp.string.concatenate(printer.out_, notANumber ? "std.numbers.not_a_number" : "std.numbers.infinity")) return false;
			printer.attached = true;
			return tokens(printer, "(") && appendType(printer, typed, parameter) && tokens(printer, ")");
		case doir.components.ast.ConstantVal.Kind.bytes:
			return fp.string.concatenate(printer.out_, `"`) && appendEscaped(printer.out_, doir.strings.text(*printer.strings, value.bytesValue)) && fp.string.concatenate(printer.out_, `"`);
	}
}

// A parameter's `deduced type` is the interned `deducedTypeName`, which only a parameter may spell bare (`D-Deduce`).
private bool appendType(ref Printer printer, EntityId e, bool parameter, bool quote = false) {
	if (auto lookup = ecrs.context.findComponent!(doir.components.ast.LookupTypeOf)(*printer.store, e)) {
		if (parameter && doir.strings.text(*printer.strings, lookup.name) == doir.components.ast.deducedTypeName) return tokens(printer, "deduced type");
		return appendName(printer, lookup.name, quote);
	}
	auto typeOf = ecrs.context.findComponent!(doir.components.ast.TypeOf)(*printer.store, e);
	assert(typeOf !is null, "doir.printer: a typed declaration has neither LookupTypeOf nor an in-place TypeOf");
	return appendFunctionType(printer, typeOf.type);
}

// bounded: doir.syntax.parser.maxNesting, the deepest function types a commit builds
// `(a: T, b: U = 5) -> V`, from function type `functionType`'s parameters and return type (`R-Param`, `F-Default`).
private bool appendFunctionType(ref Printer printer, EntityId functionType) {
	if (!tokens(printer, "(")) return false;
	foreach (i, parameter; fp.dynarray.slice(ecrs.context.getComponent!(doir.components.ast.FunctionInputs)(*printer.store, functionType).related)) {
		if (i && !tokens(printer, ",")) return false;
		if (!appendOwnName(printer, parameter) || !tokens(printer, ":") || !appendType(printer, parameter, true)) return false;
		if (auto constant = ecrs.context.findComponent!(doir.components.ast.ConstantVal)(*printer.store, parameter)) {
			if (!tokens(printer, "=") || !appendConstant(printer, parameter, true, *constant)) return false;
		} else if (auto value = ecrs.context.findComponent!(doir.components.ast.LookupValue)(*printer.store, parameter))
			if (!tokens(printer, "=") || !appendName(printer, value.name)) return false;
	}
	if (!tokens(printer, ")")) return false;
	if (auto lookup = ecrs.context.findComponent!(doir.components.ast.LookupFunctionReturn)(*printer.store, functionType)) return tokens(printer, "->") && appendName(printer, lookup.name);
	if (auto returned = ecrs.context.findComponent!(doir.components.ast.FunctionReturn)(*printer.store, functionType)) return tokens(printer, "->") && appendFunctionType(printer, returned.type);
	return true;
}

// The source annotation `<"file":3-4:5>`: lines, then columns, each a range only where start and end differ (`AT-Source`).
private bool appendAnnotation(ref Printer printer, ref const doir.components.source.SourceAnnotation annotation) {
	const at = annotation.location;
	// A quote in the name would end the quoted form early; the bare form ends at the first `:`.
	immutable quoted = fp.string.find(at.file, `"`, 0) == fp.pointer.notFound;
	if (!tokens(printer, quoted ? `<"` : "<") || !fp.string.concatenate(printer.out_, at.file) || !fp.string.concatenate(printer.out_, quoted ? `":` : ":")) return false;
	if (!fp.string.append(printer.out_, at.start.line)) return false;
	if (at.end.line != at.start.line && !fp.string.append(printer.out_, "-", at.end.line)) return false;
	if (!fp.string.append(printer.out_, ":", at.start.column)) return false;
	if (at.end.column != at.start.column && !fp.string.append(printer.out_, "-", at.end.column)) return false;
	return fp.string.concatenate(printer.out_, ">");
}

private bool appendBlock(ref Printer printer, EntityId block) {
	foreach (e; fp.dynarray.slice(ecrs.context.getComponent!(doir.components.ast.Block)(*printer.store, block).related))
		if (!appendDeclaration(printer, e)) return false;
	return true;
}

// One `assignment` of `doir.peg`, the forms `doir.builders` documents, ended by a newline.
private bool appendDeclaration(ref Printer printer, EntityId e) {
	auto store = printer.store;
	auto flags = ecrs.context.findComponent!(doir.components.ast.Flags)(*store, e);
	immutable set = flags is null ? doir.components.ast.Flags.None : flags.flags;
	if ((set & doir.components.ast.Flags.Export) && !tokens(printer, "export")) return false;
	if (!appendOwnName(printer, e) || !tokens(printer, ":")) return false;

	auto block = ecrs.context.findComponent!(doir.components.ast.Block)(*store, e);
	auto alias_ = ecrs.context.findComponent!(doir.components.ast.LookupAlias)(*store, e);
	auto reference = ecrs.context.findComponent!(doir.components.ast.LookupValue)(*store, e);
	bool ok;
	if (set & doir.components.ast.Flags.Namespace) ok = tokens(printer, "namespace");
	else if (alias_ !is null) ok = tokens(printer, "alias =") && appendName(printer, alias_.name);
	else {
		// The parser reads `type` and `namespace` before a block, and `alias` before a name, as other forms (`WF-Kind`).
		bool quote = false;
		if (auto lookup = ecrs.context.findComponent!(doir.components.ast.LookupTypeOf)(*store, e)) {
			const typeName = doir.strings.text(*printer.strings, lookup.name);
			immutable aggregate = ecrs.context.hasComponent!(doir.components.ast.TypeDefinition)(*store, e);
			quote = (block !is null && !aggregate && (typeName == "type" || typeName == "namespace")) || (reference !is null && typeName == "alias");
		}
		ok = appendType(printer, e, false, quote);
	}
	if (!ok) return false;

	if (block !is null) {
		if (!tokens(printer, "= {\n") || !appendBlock(printer, e) || !fp.string.concatenate(printer.out_, "}")) return false;
	} else if (auto constant = ecrs.context.findComponent!(doir.components.ast.ConstantVal)(*store, e)) {
		if (!tokens(printer, "=") || !appendConstant(printer, e, false, *constant)) return false;
	} else if (auto callee = ecrs.context.findComponent!(doir.components.ast.LookupCall)(*store, e)) {
		immutable prefix = set & doir.components.ast.Flags.Inline ? "inline" : set & doir.components.ast.Flags.Flatten ? "flatten" : set & doir.components.ast.Flags.Tail ? "tail" : "";
		if (!tokens(printer, "=") || (prefix.length && !tokens(printer, prefix)) || !appendName(printer, callee.name)) return false;
		printer.attached = true;
		if (!tokens(printer, "(")) return false;
		foreach (i, argument; fp.dynarray.slice(ecrs.context.getComponent!(doir.components.ast.LookupFunctionInputs)(*store, e).names.p))
			if ((i && !tokens(printer, ",")) || !appendName(printer, argument)) return false;
		if (!tokens(printer, ")")) return false;
	} else if (reference !is null) {
		if (!tokens(printer, "=") || !appendName(printer, reference.name)) return false;
	} else if (ecrs.context.hasComponent!(doir.components.ast.FunctionInputs)(*store, e)) {
		if (!tokens(printer, "=") || !appendFunctionType(printer, e)) return false;
	}

	if (auto annotation = ecrs.context.findComponent!(doir.components.source.SourceAnnotation)(*store, e))
		if (!appendAnnotation(printer, *annotation)) return false;
	return fp.string.concatenate(printer.out_, "\n");
}

/// Prints the declarations of `block`, a file's root block (`doir.source.rootOf`) or a block or namespace in one, returning a new fp string the caller releases with `fp.string.free`; an empty block gives a null `char*`, the empty fp string.
/// Parsing the text back builds an equivalent store; see the module documentation for what it leaves out.
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
	auto printer = Printer(&store, &strings, null);
	scope(exit) fp.string.free(printer.out_);
	doir.format.Formatted layout;
	scope(exit) doir.format.free(layout);
	char* out_ = null;
	if (!appendBlock(printer, block) || !doir.format.format(fp.string.slice(printer.out_), 0, layout) || !doir.format.apply(fp.string.slice(printer.out_), layout, out_)) {
		fp.string.free(out_);
		return typeof(return).init;
	}
	return typeof(return)(out_);
}


version(unittest) {
	static import fp.pointer;
	static import doir.builders;
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
	// An infinity prints as a literal, not as `inf`, which lexes as a name, and reads back as itself.
	fp.string.free(f);
	f = null;
	assert(appendFloat(f, double.infinity) && fp.string.slice(f) == infinityLiteral);
	assert(fp.string.numbers.parseFloat(fp.string.slice(f)).get.value == double.infinity);
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
		~ "w : f64 = 2.50; whole : f64 = 3.; tiny : f64 = 1e-300; huge : f64 = 2e400\n"
		~ "neg : i32 = -42; negf : f64 = -2.5\n"
		~ "s : p = \"a\\tb\\x80\\x41\\u00e9\\\"\" ; r : p = \"\"\"raw \"quoted\"\"\"\" ; c : u32 = 'é'\n"
		~ "_ : T\n"
		~ "blk : block = {\n\tinner : T = tail f(x, %\"y z\")\n\t_ : _ = std.block_result(std.nothing) <g.doir:1:2-9>\n}\n"
		~ "vec : type = { x : f32 ; y : f32 ; }\n"
		~ "add_t : type = (a: T, b: deduced type, c: T = 5, d: T = y, e: f64 = 1e999, n: f64 = -1e999) -> T\n"
		~ "f : (g: (x: T) -> U, _: V) -> (c: U) -> V\n"
		~ "color : alias = vec\n"
		~ "math : namespace = { pi : f64 = 3.14159 ; }\nmath : namespace = {}\n"
		~ "%\"a b\" : %\"type\" = {}\n%\"_\" : %\"alias\" = q\n%\"export.x\" : %\"deduced type\" = %\"namespace\"\n"
		~ "empty : () = flatten g()\n";
	immutable expected = "export six : std.u8 = 6 <\"gen.doir\":3-4:5>\n"
		~ "w : f64 = 2.5\nwhole : f64 = 3.0\ntiny : f64 = 1e-300\nhuge : f64 = std.numbers.infinity(f64)\n"
		~ "neg : i32 = -42\nnegf : f64 = -2.5\n"
		~ "s : p = \"a\\tb\\x80\\u0041é\\\"\"\nr : p = \"raw \\\"quoted\\\"\"\nc : u32 = 233\n"
		~ "_ : T\n"
		~ "blk : block = {\n\tinner : T = tail f(x, %\"y z\")\n\t_ : _ = std.block_result(std.nothing) <\"g.doir\":1:2-9>\n}\n"
		~ "vec : type = {\n\tx : f32\n\ty : f32\n}\n"
		~ "add_t : type = (a: T, b: deduced type, c: T = 5, d: T = y, e: f64 = 1e999, n: f64 = -1e999) -> T\n"
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

	// The reparse built the same entities, not just the same text: `%"type"` stayed a block, `%"alias"` a reference, bytes and floats kept their values.
	const reparsed = fp.dynarray.slice(ecrs.context.getComponent!(doir.components.ast.Block)(store, b).related);
	assert(reparsed.length == 22);
	assert(ecrs.context.getComponent!(doir.components.ast.ConstantVal)(store, reparsed[3]).floatValue == 1e-300);
	assert(!ecrs.context.hasComponent!(doir.components.ast.ConstantVal)(store, reparsed[4]) && ecrs.context.hasComponent!(doir.components.ast.LookupCall)(store, reparsed[4]));
	assert(ecrs.context.getComponent!(doir.components.ast.ConstantVal)(store, reparsed[5]).kind == doir.components.ast.ConstantVal.Kind.negativeInteger);
	assert(ecrs.context.getComponent!(doir.components.ast.ConstantVal)(store, reparsed[6]).floatValue == -2.5);
	assert(doir.strings.text(strings, ecrs.context.getComponent!(doir.components.ast.ConstantVal)(store, reparsed[7]).bytesValue) == "a\tb\x80Aé\"");
	assert(ecrs.context.getComponent!(doir.components.ast.Flags)(store, reparsed[0]).flags == (doir.components.ast.Flags.Comptime | doir.components.ast.Flags.Export));
	assert(ecrs.context.hasComponent!(doir.components.ast.Block)(store, reparsed[18]) && !ecrs.context.hasComponent!(doir.components.ast.TypeDefinition)(store, reparsed[18]));
	assert(ecrs.context.hasComponent!(doir.components.ast.LookupValue)(store, reparsed[19]) && !ecrs.context.hasComponent!(doir.components.ast.LookupAlias)(store, reparsed[19]));
	assert(doir.strings.text(strings, ecrs.context.getComponent!(doir.components.ast.Name)(store, reparsed[19]).value) == "_");

	// A refused allocation returns null and leaves no text.
	for (size_t n = 0;; ++n) {
		assert(n < 1000);
		auto previous = fp.testing.limitAllocations(n);
		auto printed = print(store, strings, a);
		fp.testing.restoreAllocator(previous);
		if (printed.isNull) continue;
		scope(exit) fp.string.free(printed.get);
		assert(fp.string.slice(printed.get) == expected);
		break;
	}
}

unittest { // a NaN, which no literal spells, prints as the N-Limits call on its declaration's type and reparses as that call
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	auto engine = doir.query.create(store);
	scope(exit) doir.query.free(engine);
	doir.strings.Strings strings;
	scope(exit) doir.strings.free(strings);

	auto root = doir.builders.createRoot(store);
	immutable f64 = doir.strings.intern(strings, "f64");
	assert(doir.builders.pushConstant(root, doir.strings.intern(strings, "nan"), f64, doir.components.ast.ConstantVal.float_(double.nan)) != invalidEntity);
	immutable function_ = doir.builders.pushFunctionType(root, doir.strings.intern(strings, "g"), doir.strings.intern(strings, "type"));
	immutable parameter = doir.builders.pushParameter(store, function_, doir.strings.intern(strings, "x"), f64);
	assert(function_ != invalidEntity && parameter != invalidEntity && doir.builders.setDefault(store, parameter, doir.components.ast.ConstantVal.float_(double.nan)));
	auto text = print(store, strings, root.block).get;
	scope(exit) fp.string.free(text);
	// A parameter default cannot be a call, so that NaN has no spelling that parses.
	assert(fp.string.slice(text) == "nan : f64 = std.numbers.not_a_number(f64)\ng : type = (x: f64 = std.numbers.not_a_number(f64))\n");

	EntityId reparsedRoot;
	auto again = reprint(engine, strings, "nan.doir", "nan : f64 = std.numbers.not_a_number(f64)\n", reparsedRoot);
	scope(exit) fp.string.free(again);
	assert(fp.string.slice(again) == "nan : f64 = std.numbers.not_a_number(f64)\n");
	immutable call = ecrs.context.getComponent!(doir.components.ast.Block)(store, reparsedRoot).related[0];
	assert(doir.strings.text(strings, ecrs.context.getComponent!(doir.components.ast.LookupCall)(store, call).name) == "std.numbers.not_a_number");
}
