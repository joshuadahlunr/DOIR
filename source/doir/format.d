/// Formatting from the lexer's token stream (`roadmap.md` Phase 3) for the language server and `doir.printer`, so comments survive and a file with parse errors still formats: each line is indented with a tab per bracket open around it, its trailing whitespace dropped, and the spaces around punctuation made the corpus's (`x : T = v`, `(a: T, b: U) -> R`, `a ; b`). Only the whitespace between tokens changes, never a token or a newline, except that a blank line after another is removed and `Options` may move a line break; space between two words, or before a call's `(`, is kept as written, since removing it could change what the line lexes as. A multi-line token, such as a raw string, is copied as it is, and lines it spans are not reindented.
///
/// Examples:
/// ---
/// Formatted f;
/// scope(exit) free(f);
/// assert(format("x:T=f( a ,b )\n", 0, f));
/// assert(f.edits[0].start == 0 && f.edits[0].end == 13);
/// assert(f.text[f.edits[0].from .. f.edits[0].from + f.edits[0].length] == "x : T = f(a, b)");
/// ---
module doir.format;

static import fp.dynarray;
static import fp.io;
static import fp.pointer;

version(unittest) static import fp.io;
static import fp.string;

static import doir.syntax.lexer;

@nogc nothrow:


// --- types and layout --------------------------------------------------------

/// A replacement: bytes `start` to `end` of the formatted source become `length` bytes of `Formatted.text` from `from`.
struct Edit {
	size_t start; /// The first byte replaced.
	size_t end; /// Past the last byte replaced.
	size_t from; /// Where the replacement starts in `Formatted.text`.
	size_t length; /// The replacement's length.
}

/// What `format` produces: the edits in source order, none overlapping, and the text they insert.
struct Formatted {
	char* text; /// An fp dynarray holding every edit's replacement.
	Edit* edits; /// An fp dynarray.
	size_t unlexed = fp.pointer.notFound; /// Where the token the lexer could not finish, or does not know, starts, when `format` made no edits because of it; `fp.pointer.notFound` otherwise.
}

/// Frees `f`'s text and edits, leaving it empty.
///
/// Examples:
/// ---
/// Formatted f;
/// assert(format("x  : T\n", 0, f));
/// free(f);
/// assert(f.edits is null);
/// ---
void free(ref Formatted f) {
	fp.dynarray.free(f.text);
	fp.dynarray.free(f.edits);
}


/// What `format` does with a `;` that ends a statement.
enum Semicolons : ubyte {
	kept, /// Leaves it.
	newlines, /// Ends the line there instead, or drops it where the line ends anyway.
	newlinesAfterBraces, /// As `newlines`, and ends the line after a `{` that has a statement after it on its line.
}

/// Whether `format` puts a space before a `:`, as `Options.definitionColons` and `Options.parameterColons` choose for definitions and parameters.
enum Colons : ubyte {
	spaced, /// `x : T = v`, `(a : T)`.
	attached, /// `x: T = v`, `(a: T)`.
}

/// Where `format` puts the `{` of a block an `=` opens, when the block spans lines.
enum Braces : ubyte {
	kept, /// Where it is written.
	sameLine, /// After the `=`, joining a `{` that starts the next line.
	nextLine, /// On a line of its own, below the `=`.
}

/// How `format` lays a file out.
struct Options {
	bool minify; /// Writes the file on one line: comments, indentation and blank lines go, a newline that ends a statement becomes `;`, and a space stays only between two words. `depth` and the other options are then ignored.
	Semicolons semicolons; /// What to do with a `;` that ends a statement.
	Colons definitionColons; /// Whether a definition's `:` has a space before it.
	Colons parameterColons = Colons.attached; /// Whether a parameter's `:` has a space before it.
	Braces braces; /// Where a block's `{` goes.
}


// --- spacing -----------------------------------------------------------------

private enum Space : ubyte { none, one, kept }

// The space between tokens `p` and `t` on one line; `inParentheses` whether the innermost open bracket is a parenthesis, so a `:` is a parameter's.
private Space between(doir.syntax.lexer.TokenKind p, doir.syntax.lexer.TokenKind t, bool inParentheses, ref const Options options) {
	with (doir.syntax.lexer.TokenKind) {
		if (t == lineComment || t == longComment || t == sourceInfo) return Space.one;
		if (t == comma || t == rightParen || p == leftParen) return Space.none;
		if (t == colon) return (inParentheses ? options.parameterColons : options.definitionColons) == Colons.attached ? Space.none : Space.one;
		if (p == comma || p == colon || p == semicolon || t == semicolon || p == equals || t == equals || p == arrow || t == arrow) return Space.one;
		if (p == leftBrace && t == rightBrace) return Space.kept;
		if (t == leftBrace || t == rightBrace || p == leftBrace) return Space.one;
		return Space.kept;
	}
}


// --- statements --------------------------------------------------------------

// The kind of the first token from `cursor` that is not whitespace, nor, with `lines`, a newline or comment; `end` at the text's end.
private doir.syntax.lexer.TokenKind peek(doir.syntax.lexer.Cursor cursor, bool lines) {
	while (cursor.at < cursor.source.length) {
		immutable t = doir.syntax.lexer.next(cursor);
		with (doir.syntax.lexer.TokenKind)
			if (t.kind == whitespace || (lines && (t.kind == newline || t.kind == lineComment || t.kind == longComment))) continue;
		return t.kind;
	}
	return doir.syntax.lexer.TokenKind.end;
}

// Whether a statement may end with a token of kind `k`, so a newline after it, outside parentheses, is its `Terminator`.
private bool endsStatement(doir.syntax.lexer.TokenKind k) {
	with (doir.syntax.lexer.TokenKind) return k == identifier || k == rightParen || k == rightBrace || k == integer || k == float_ || k == string_ || k == rawString || k == character || k == sourceInfo;
}

// Whether a token of kind `k` follows a `Terminator` rather than continuing the statement before it, as `=`, `->`, `(` and `:` do after a newline (`_` in `doir.peg`).
private bool startsStatement(doir.syntax.lexer.TokenKind k) {
	with (doir.syntax.lexer.TokenKind) return k == identifier || k == keyword || k == rightBrace || k == end;
}

// Whether a `{` followed on its line by a token of kind `after` ends its line once `semicolons` has broken lines, so its block spans lines.
private bool endsLineAfterBrace(doir.syntax.lexer.TokenKind after, Semicolons semicolons) {
	with (doir.syntax.lexer.TokenKind) return after == newline || after == end || after == lineComment || (semicolons == Semicolons.newlinesAfterBraces && after != rightBrace);
}

/// Whether `c` may be part of a word or a dotted name, so two tokens meeting at it and another such byte need a space between them.
///
/// Examples:
/// ---
/// assert(wordByte('%') && wordByte('.') && !wordByte('('));
/// ---
package(doir) bool wordByte(char c) {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '.' || c == '%' || c >= 0x80;
}

// Writes `source` on one line into `out_`, as one edit, for `Options.minify`. False on refusal, leaving `out_` empty.
private bool minify(const(char)[] source, ref Formatted out_) {
	char* text = null;
	scope(exit) fp.dynarray.free(text);
	auto cursor = doir.syntax.lexer.Cursor(source);
	doir.syntax.lexer.TokenKind last = doir.syntax.lexer.TokenKind.end;
	size_t parentheses = 0;
	bool kept = true;
	while (kept && cursor.at < source.length) {
		immutable t = doir.syntax.lexer.next(cursor);
		with (doir.syntax.lexer.TokenKind) switch (t.kind) {
			case invalid, unterminated:
				out_.unlexed = t.start;
				return true;
			case whitespace, lineComment, longComment: continue;
			case newline:
				if (parentheses == 0 && endsStatement(last) && startsStatement(peek(cursor, true))) {
					kept = fp.dynarray.pushBack(text, ';');
					last = semicolon;
				}
				continue;
			default: break;
		}
		const token = doir.syntax.lexer.text(t, source);
		immutable n = fp.dynarray.length(text);
		if (n && wordByte(text[n - 1]) && wordByte(token[0])) kept = fp.dynarray.pushBack(text, ' ');
		kept = kept && fp.dynarray.concatenate(text, token);
		if (t.kind == doir.syntax.lexer.TokenKind.leftParen) ++parentheses;
		else if (t.kind == doir.syntax.lexer.TokenKind.rightParen && parentheses) --parentheses;
		last = t.kind;
	}
	immutable n = fp.dynarray.length(text);
	const written = text is null ? "" : text[0 .. n];
	if (kept && source != written) kept = (n == 0 || fp.dynarray.concatenate(out_.text, written)) && fp.dynarray.pushBack(out_.edits, Edit(0, source.length, 0, n));
	if (!kept) free(out_);
	return kept;
}


// --- formatting --------------------------------------------------------------

private struct State {
	Formatted* out_;
	const(char)[] source;
	char* line; // the current line as formatted
	bool* brackets; // the open brackets, true for a parenthesis
	size_t lineStart;
	uint blank; // blank lines in a row before the current one
	bool any; // whether the current line has a token
	bool atStart; // whether nothing is written since the current line, or a break `Semicolons` made, began
}

// Records that bytes `start` to `end` become `replacement`, unless they are it already. False on refusal.
private bool replace(ref State s, size_t start, size_t end, const(char)[] replacement) {
	if (s.source[start .. end] == replacement) return true;
	immutable from = fp.dynarray.length(s.out_.text);
	if (replacement.length && !fp.dynarray.concatenate(s.out_.text, replacement)) return false;
	return fp.dynarray.pushBack(s.out_.edits, Edit(start, end, from, replacement.length));
}

// Ends the current line at the newline from `newline` to `next`, the start of the next line. False on refusal.
private bool endLine(ref State s, size_t newline, size_t next) {
	bool kept = true;
	if (s.any) {
		s.blank = 0;
		kept = replace(s, s.lineStart, newline, s.line is null ? "" : s.line[0 .. fp.dynarray.length(s.line)]);
	} else kept = s.blank++ ? replace(s, s.lineStart, next, "") : replace(s, s.lineStart, newline, "");
	if (s.line !is null) fp.dynarray.clear(s.line);
	s.lineStart = next;
	s.any = false;
	s.atStart = true;
	return kept;
}

/// Formats `source`, whose first byte starts a line `depth` brackets deep, into `out_`, which must be empty, laid out as `options` says. On a token the lexer cannot finish or does not know, it makes no edits, since the file's brackets cannot be trusted, and sets `out_.unlexed` to where the token starts.
///
/// Returns false on a refused allocation, leaving `out_` empty.
///
/// Examples:
/// ---
/// Formatted f;
/// scope(exit) free(f);
/// assert(format("{\nx : T\n}\n", 1, f));
/// assert(f.text[0 .. f.edits[0].length] == "\t{");
/// Formatted g;
/// scope(exit) free(g);
/// assert(format("x : T = 1 ; y : T\n", 0, g, Options(false, Semicolons.newlines)));
/// assert(g.text[0 .. g.edits[0].length] == "x : T = 1\ny : T");
/// ---
bool format(const(char)[] source, uint depth, ref Formatted out_, Options options = Options.init) {
	if (options.minify) return minify(source, out_);
	State s = State(&out_, source);
	s.atStart = true;
	scope(exit) {
		fp.dynarray.free(s.line);
		fp.dynarray.free(s.brackets);
	}
	auto cursor = doir.syntax.lexer.Cursor(source);
	doir.syntax.lexer.TokenKind previous;
	bool spaced = false, kept = true;
	while (kept && cursor.at < source.length) {
		immutable t = doir.syntax.lexer.next(cursor);
		auto text = doir.syntax.lexer.text(t, source);
		with (doir.syntax.lexer.TokenKind) switch (t.kind) {
			case invalid, unterminated:
				free(out_);
				out_.unlexed = t.start;
				return true;
			case whitespace:
				spaced = true;
				continue;
			case newline:
				// The grammar's `_` after `=` takes a newline, so joining the `{` below changes only the layout.
				if (options.braces == Braces.sameLine && s.any && previous == equals && peek(cursor, false) == leftBrace) {
					spaced = true;
					continue;
				}
				kept = endLine(s, t.start, t.start + t.length);
				spaced = false;
				continue;
			default: break;
		}
		immutable open = fp.dynarray.length(s.brackets);
		if (t.kind == doir.syntax.lexer.TokenKind.semicolon && options.semicolons != Semicolons.kept && (open == 0 || !s.brackets[open - 1]) && startsStatement(peek(cursor, true))) {
			// Where the line ends anyway, or only a comment follows, its newline already ends the statement.
			immutable after = peek(cursor, false);
			with (doir.syntax.lexer.TokenKind) if (after != newline && after != end && after != lineComment) {
				kept = fp.dynarray.pushBack(s.line, '\n');
				s.atStart = true;
			}
			previous = t.kind;
			spaced = false;
			continue;
		}
		immutable closes = t.kind == doir.syntax.lexer.TokenKind.rightBrace || t.kind == doir.syntax.lexer.TokenKind.rightParen;
		with (doir.syntax.lexer.TokenKind) if (t.kind == leftBrace && options.braces == Braces.nextLine && !s.atStart && previous == equals && endsLineAfterBrace(peek(cursor, false), options.semicolons)) {
			kept = kept && fp.dynarray.pushBack(s.line, '\n');
			s.atStart = true;
		}
		if (s.atStart) {
			immutable levels = depth + open;
			foreach (_; 0 .. closes && levels ? levels - 1 : levels) kept = kept && fp.dynarray.pushBack(s.line, '\t');
		} else {
			immutable space = between(previous, t.kind, open && s.brackets[open - 1], options);
			if (space == Space.one || (space == Space.kept && spaced)) kept = kept && fp.dynarray.pushBack(s.line, ' ');
		}
		if (t.kind == doir.syntax.lexer.TokenKind.lineComment)
			text = fp.string.trimEnd(text, " \t");
		s.any = true;
		s.atStart = false;
		immutable newline = fp.string.find(text, '\n');
		immutable first = newline == fp.pointer.notFound ? text.length : newline;
		if (first < text.length) {
			// A multi-line token: its first line ends this one, and its last line starts the next, which is not reindented.
			size_t last = text.length;
			while (text[last - 1] != '\n') --last;
			kept = kept && (first == 0 || fp.dynarray.concatenate(s.line, text[0 .. first])) && endLine(s, t.start + first, t.start + last);
			s.any = true;
			s.atStart = false;
			text = text[last .. $];
		}
		kept = kept && (text.length == 0 || fp.dynarray.concatenate(s.line, text));
		with (doir.syntax.lexer.TokenKind) {
			if (t.kind == leftBrace || t.kind == leftParen) kept = kept && fp.dynarray.pushBack(s.brackets, t.kind == leftParen);
			else if (closes && open) cast(void) fp.dynarray.removeLast(s.brackets);
			if (t.kind == leftBrace && options.semicolons == Semicolons.newlinesAfterBraces) {
				immutable after = peek(cursor, false);
				if (after != newline && after != end && after != lineComment && endsLineAfterBrace(after, options.semicolons)) {
					kept = kept && fp.dynarray.pushBack(s.line, '\n');
					s.atStart = true;
				}
			}
		}
		previous = t.kind;
		spaced = false;
	}
	kept = kept && endLine(s, source.length, source.length);
	if (!kept) free(out_);
	return kept;
}


/// Appends `source` with every edit of `f`, which `format` made of it, applied to the fp string `out_`.
///
/// Returns false on a refused allocation, `out_` then holding part of the text.
///
/// Examples:
/// ---
/// static import fp.string;
/// Formatted f;
/// scope(exit) free(f);
/// assert(format("x:T\n", 0, f));
/// char* text = null;
/// scope(exit) fp.string.free(text);
/// assert(apply("x:T\n", f, text) && fp.string.slice(text) == "x : T\n");
/// ---
bool apply(const(char)[] source, ref const Formatted f, ref char* out_) {
	// Concatenating nothing gives the empty fp string, null, which is not a refusal.
	size_t at = 0;
	foreach (ref e; fp.dynarray.slice(f.edits)) {
		if ((e.start > at && !fp.string.concatenate(out_, source[at .. e.start])) || (e.length && !fp.string.concatenate(out_, f.text[e.from .. e.from + e.length]))) return false;
		at = e.end;
	}
	return at == source.length || fp.string.concatenate(out_, source[at .. $]);
}


version(unittest) {
	// `text` parsed and printed back by `doir.printer`, as an fp string: what the store holds, without comments or spelling.
	private char* printed(const(char)[] text) {
		static import ecrs.context;
		static import doir.printer;
		static import doir.query;
		static import doir.source;
		static import doir.strings;
		auto store = ecrs.context.create();
		scope(exit) ecrs.context.free(store);
		auto engine = doir.query.create(store);
		scope(exit) doir.query.free(engine);
		doir.strings.Strings strings;
		scope(exit) doir.strings.free(strings);
		immutable file = doir.source.addFile(engine, strings, "f.doir");
		assert(doir.source.commit(engine, strings, file, text) == 0);
		return doir.printer.print(store, strings, doir.source.rootOf(engine, file)).get;
	}

	// Checks that formatting `text` as `options` says changes only its layout, that formatting the result again changes nothing, and, with the default options, that the printer's output is already formatted. Returns the formatted text.
	private char* checkFormat(const(char)[] text, Options options = Options.init) {
		Formatted f;
		scope(exit) free(f);
		assert(format(text, 0, f, options));
		char* once = null;
		assert(apply(text, f, once));
		auto formatted = fp.string.slice(once);
		Formatted again;
		scope(exit) free(again);
		assert(format(formatted, 0, again, options) && fp.dynarray.length(again.edits) == 0);
		char* before = printed(text), after = printed(formatted);
		scope(exit) fp.string.free(before);
		scope(exit) fp.string.free(after);
		assert(fp.string.slice(before) == fp.string.slice(after));
		Formatted ofPrinted;
		scope(exit) free(ofPrinted);
		assert(format(fp.string.slice(before), 0, ofPrinted) && (options != Options.init || fp.dynarray.length(ofPrinted.edits) == 0));
		return once;
	}
}

unittest { // indentation, spacing, blank lines, comments and multi-line tokens, semicolon, colon and brace modes and minifying; formatting keeps what the text parses to, twice changes nothing, and the printer's output is already formatted
	static immutable string[2][] cases = [
		["n:namespace={\nf:(a:T,b:U)->V={\n  x : T = g( a ,b );y:T=1   \n}\n}\n", "n : namespace = {\n\tf : (a: T, b: U) -> V = {\n\t\tx : T = g(a, b) ; y : T = 1\n\t}\n}\n"],
		["a : T = 1\n\n\n\nb : T = 2\n   \n", "a : T = 1\n\nb : T = 2\n\n"],
		["n : namespace = {\n// above   \n    x : T = 1    // after\n}", "n : namespace = {\n\t// above\n\tx : T = 1 // after\n}"],
		["n : namespace = {\n  s : T = \"\"\"\n   kept  \n  as is\"\"\"  ; t : T = 1\n}\n", "n : namespace = {\n\ts : T = \"\"\"\n   kept  \n  as is\"\"\" ; t : T = 1\n}\n"],
		["f : (x: deduced  type) -> T = g (y)\nb : block = {}\n", "f : (x: deduced type) -> T = g (y)\nb : block = {}\n"],
		["x : T = f(\na,\nb\n)\n", "x : T = f(\n\ta,\n\tb\n)\n"],
	];
	foreach (c; cases) {
		char* once = checkFormat(c[0]);
		scope(exit) fp.string.free(once);
		assert(fp.string.slice(once) == c[1]);
	}
	// Semicolons become line breaks, where a newline does not already end the statement; minifying turns the newlines that end one into `;`.
	static immutable source = "vec : type = { x : f32 ; y : f32 ; }\na : T = 1 ; // c\nb : T = 2 ; c : T = 3\nn : namespace = {\n\t// c\n\tx : T = 1\n\ty : T = f(x)\n}\nexport z : T\n= 2\n";
	static immutable string[1][] modes = [
		["vec : type = { x : f32\n\ty : f32\n}\na : T = 1 // c\nb : T = 2\nc : T = 3\nn : namespace = {\n\t// c\n\tx : T = 1\n\ty : T = f(x)\n}\nexport z : T\n= 2\n"],
		["vec : type = {\n\tx : f32\n\ty : f32\n}\na : T = 1 // c\nb : T = 2\nc : T = 3\nn : namespace = {\n\t// c\n\tx : T = 1\n\ty : T = f(x)\n}\nexport z : T\n= 2\n"],
		["vec:type={x:f32;y:f32;};a:T=1;b:T=2;c:T=3;n:namespace={x:T=1;y:T=f(x);};export z:T=2;"],
	];
	foreach (i, options; [Options(false, Semicolons.newlines), Options(false, Semicolons.newlinesAfterBraces), Options(true)]) {
		char* once = checkFormat(source, options);
		scope(exit) fp.string.free(once);
		assert(fp.string.slice(once) == modes[i][0]);
	}
	// A block's `{` moves to the `=` or below it only where an `=` opens a block spanning lines; definition and parameter colons are spaced or attached apart.
	static immutable blocks = "n : namespace =\n{\n\tf : (a: T) -> T = { // c\n\t\tx : T = a\n\t}\n\tb : block = {}\n\tv : type = { x : f32 ; }\n\tw : type = { x : f32 ; y : f32 ; }\n}\n";
	static immutable Options[4] layouts = [Options(false, Semicolons.kept, Colons.spaced, Colons.attached, Braces.sameLine), Options(false, Semicolons.kept, Colons.attached, Colons.attached, Braces.nextLine), Options(false, Semicolons.newlinesAfterBraces, Colons.spaced, Colons.attached, Braces.nextLine), Options(false, Semicolons.kept, Colons.attached, Colons.spaced)];
	static immutable string[4] laidOut = [
		"n : namespace = {\n\tf : (a: T) -> T = { // c\n\t\tx : T = a\n\t}\n\tb : block = {}\n\tv : type = { x : f32 ; }\n\tw : type = { x : f32 ; y : f32 ; }\n}\n",
		"n: namespace =\n{\n\tf: (a: T) -> T =\n\t{ // c\n\t\tx: T = a\n\t}\n\tb: block = {}\n\tv: type = { x: f32 ; }\n\tw: type = { x: f32 ; y: f32 ; }\n}\n",
		"n : namespace =\n{\n\tf : (a: T) -> T =\n\t{ // c\n\t\tx : T = a\n\t}\n\tb : block = {}\n\tv : type =\n\t{\n\t\tx : f32\n\t}\n\tw : type =\n\t{\n\t\tx : f32\n\t\ty : f32\n\t}\n}\n",
		"n: namespace =\n{\n\tf: (a : T) -> T = { // c\n\t\tx: T = a\n\t}\n\tb: block = {}\n\tv: type = { x: f32 ; }\n\tw: type = { x: f32 ; y: f32 ; }\n}\n",
	];
	foreach (i, options; layouts) {
		char* once = checkFormat(blocks, options);
		scope(exit) fp.string.free(once);
		assert(fp.string.slice(once) == laidOut[i]);
	}
	// A `{` the `=` is not right before, here after a comment, stays where it is.
	char* commented = checkFormat("n : namespace = // c\n{\n}\n", layouts[0]);
	scope(exit) fp.string.free(commented);
	assert(fp.string.slice(commented) == "n : namespace = // c\n{\n}\n");
	// The corpus formats without changing what it parses to (only its layout), and the printer agrees with the formatter on layout.
	static immutable string[12] corpus = ["standard.doir", "standard.os.doir", "os.linux.doir", "os.windows.doir", "os.freestanding.doir", "format.flat.doir", "reference/compiler.doir", "reference/format.doir", "reference/machine.doir", "reference/operating_system.doir", "reference/host.doir", "reference/backends.doir"];
	foreach (path; corpus) {
		static import doir.source;
		char* text = fp.io.readFile(path).get;
		scope(exit) fp.string.free(text);
		foreach (options; [Options.init, Options(false, Semicolons.newlines), Options(false, Semicolons.newlinesAfterBraces), Options(true), Options(false, Semicolons.kept, Colons.attached, Colons.spaced, Braces.sameLine), Options(false, Semicolons.newlinesAfterBraces, Colons.attached, Colons.attached, Braces.nextLine)])
			fp.string.free(checkFormat(fp.string.slice(text), options));
	}
	// A token the lexer cannot finish leaves the file as it is.
	Formatted broken;
	assert(format("x:T = \"open\n", 0, broken) && broken.edits is null && broken.unlexed == 6);
	Formatted brokenMinified;
	assert(format("x:T = \"open\n", 0, brokenMinified, Options(true)) && brokenMinified.edits is null && brokenMinified.unlexed == 6);
}
