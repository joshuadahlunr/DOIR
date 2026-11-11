/// The recursive-descent parser over the lexer's tokens (`roadmap.md` Phase 2), its rules named as `doir.peg`'s so the two can be diffed: `_` skips newlines and trivia, `wsc` trivia only, and each rule restores the token position when it fails, as PEG does.
///
/// It runs in two modes.
/// `skim` parses a whole file into one `Record` per declaration, in preorder, with the declaration's tokens and its hash, and the syntax errors it recovered from; it reads only the tokens, so files can be skimmed in parallel.
/// `describe` parses one record's tokens again into the writes that make its components, skipping its nested block, whose declarations have records of their own; it touches no store, so workers can run it, and `apply` replays the writes through `doir.builders`.
/// `build` is the two together.
/// The input commit (`doir.source`) matches records against the previous parse and builds only the ones that are new or changed.
///
/// Examples:
/// ---
/// static import fp.dynarray;
/// Syntax syntax;
/// scope(exit) free(syntax);
/// assert(skim("x : std.u8 = 5\nns : namespace = {\n\ty : T\n}\n", syntax));
/// assert(fp.dynarray.length(syntax.records) == 3 && syntax.records[1].end == 3);
/// assert(fp.dynarray.length(syntax.errors) == 0);
/// ---
module doir.syntax.parser;

static import core.atomic;
static import std.typecons;

static import fp.dynarray;
static import fp.algorithms;
static import fp.pointer;
static import fp.string;
static import fp.string.ascii;
static import fp.string.numbers;
static import fp.string.utf;
version(unittest) static import fp.testing;
version(unittest) static import bc.platform;

static import diagnose;
static import ecrs.context;

static import doir.strings;
static import doir.builders;
static import doir.components.ast;
static import doir.components.source;
static import doir.engine.locations;
static import doir.syntax.lexer;

public import ecrs.registry : EntityId, invalidEntity;
public import doir.syntax.lexer : Token, TokenKind;

@nogc nothrow:


// --- types and layout --------------------------------------------------------

/// The token index that names no token, where a token is absent: no source annotation, no default, no nested record.
enum uint noToken = uint.max;

/// `Record.name` for a `_` declaration, which has no name token.
enum uint unnamed = noToken;

/// `Record.blockOpen` and `Record.blockClose` for a declaration whose value is not a block.
enum uint noBlock = noToken;

/// `SyntaxError.declaration` for an error outside every declaration.
enum uint outsideDeclaration = noToken;

/// How deeply blocks and function types may nest before the parser reports it rather than recurse further: the minimum `IL-Nest` sets.
enum uint maxNesting = 256;

/// One parsed declaration: where its tokens are, the records of the declarations nested in its block, and its hash.
struct Record {
	uint first; /// The index of its first token.
	uint terminator; /// The index of its `Terminator` token (a newline, `;` or the `end`).
	uint end; /// The index of the record after its last nested one; its nested records are those between it and `end`.
	uint name = unnamed; /// The index of its name token, or `unnamed` for `_`.
	uint blockOpen = noBlock; /// The `{` of its block value, or `noBlock`.
	uint blockClose = noBlock; /// The `}` of its block value, or `noBlock`.
	uint spanStart; /// The byte offset of its first token.
	uint spanEnd; /// The byte offset after its last token before the terminator.
	ulong hash; /// Its non-trivia tokens, its nested declarations each replaced by a placeholder, and its terminator left out.
}

/// Which part of a declaration the parser was reading when a syntax error stopped it, so the error can say what belongs there.
enum Reading : ubyte {
	declaration, /// The start of a declaration: its name, or `export` or `language`.
	colon, /// After a declaration's name, where `:` goes.
	type, /// After `:`, where the declared type goes.
	afterType, /// After the declared type: `=` and a value, or the end of the declaration.
	value, /// After `=`, where the value goes.
	afterValue, /// After the value, where the declaration ends.
	parameter, /// Inside a function type's `(`, where a parameter or `)` goes.
	parameterColon, /// After a parameter's name, where `:` goes.
	parameterType, /// After a parameter's `:`, where its type goes.
	afterParameter, /// After a parameter: `,`, `)` or a default value.
	parameterDefault, /// After a parameter's `=`, where its default value goes.
	returnType, /// After `->`, where the return type goes.
	callArgument, /// Inside a call's `(`, where an argument or `)` goes.
	block, /// Inside a block, where a declaration or `}` goes.
	language, /// After `language`, where the language's name and braced body go.
}

/// A syntax error the parser recovered from.
struct SyntaxError {
	/// What went wrong.
	enum Kind : ubyte {
		syntax, /// No rule matched; `token` is where the parse got furthest.
		nesting, /// Blocks or function types nest deeper than `maxNesting`.
		language, /// A `language` block, which no frontend handles (`I-Language`); `token` is its name.
		literal, /// A constant the reference cannot represent; `message` says why.
	}
	Kind kind; /// What went wrong.
	uint at; /// The byte offset it is reported at.
	uint token; /// The token it is about.
	string message; /// For `literal`, why.
	string fix; /// For `literal`, how to fix it.
	uint expected; /// For `syntax`, a bit `1 << kind` for each `TokenKind` the parse tried at `at`.
	Reading where; /// For `syntax`, what the parse was reading at `at`.
	uint declaration = outsideDeclaration; /// For `syntax`, the first token of the declaration being read, or `outsideDeclaration`.
}

/// A skimmed file: its tokens, its records in preorder and its syntax errors.
/// Plain data, released by `free`.
struct Syntax {
	Token* tokens = null; /// Every token, trivia included, ending with `end`.
	Record* records = null; /// One per declaration, in preorder.
	SyntaxError* errors = null; /// In source order.
}

/// Releases `syntax`'s arrays, leaving it empty.
///
/// Examples:
/// ---
/// Syntax syntax;
/// cast(void) skim("x : T\n", syntax);
/// free(syntax);
/// assert(syntax.tokens is null);
/// ---
void free(ref Syntax syntax) {
	fp.dynarray.free(syntax.tokens);
	fp.dynarray.free(syntax.records);
	fp.dynarray.free(syntax.errors);
	syntax = Syntax.init;
}

// Where the `>` starts if `error` is at a `-` that only spaces part from it, an arrow written `- >`; otherwise `fp.pointer.notFound`.
private size_t splitArrowHead(ref const Syntax syntax, const(char)[] source, SyntaxError error) {
	if (error.kind != SyntaxError.Kind.syntax) return fp.pointer.notFound;
	immutable t = syntax.tokens[error.token];
	if (t.kind != TokenKind.invalid || doir.syntax.lexer.text(t, source) != "-") return fp.pointer.notFound;
	size_t i = error.token + 1;
	while (doir.syntax.lexer.isTrivia(syntax.tokens[i].kind)) ++i;
	immutable next = syntax.tokens[i];
	if (next.kind != TokenKind.invalid || doir.syntax.lexer.text(next, source) != ">" || next.start == t.start + 1) return fp.pointer.notFound;
	foreach (c; source[t.start + 1 .. next.start])
		if (c != ' ' && c != '\t') return fp.pointer.notFound;
	return next.start;
}

/// Writes the message of `error` in `syntax`, parsed from `source`, to `out_`, a new fp string, or null if allocation fails.
///
/// Examples:
/// ---
/// static import fp.string;
/// Syntax syntax;
/// scope(exit) free(syntax);
/// immutable source = "x : = 5\n";
/// cast(void) skim(source, syntax);
/// auto message = describe(syntax, source, syntax.errors[0]);
/// scope(exit) fp.string.free(message);
/// assert(fp.string.slice(message) == "syntax error, unexpected '=' where the declared type should be");
/// ---
char* describe(ref const Syntax syntax, const(char)[] source, SyntaxError error) {
	final switch (error.kind) {
		case SyntaxError.Kind.syntax:
			immutable t = syntax.tokens[error.token];
			const where = whereText[error.where];
			if (t.kind == TokenKind.end) return fp.string.joined("syntax error, the file ends ", where).get(null);
			if (t.kind == TokenKind.newline) return fp.string.joined("syntax error, the line ends ", where).get(null);
			if (t.kind == TokenKind.unterminated) return fp.string.clone(unclosed[t.attempted] ? unclosed[t.attempted] : "syntax error, this token is never finished").get(null);
			if (splitArrowHead(syntax, source, error) != fp.pointer.notFound) return fp.string.clone("syntax error, the arrow `->` is split by a space").get(null);
			if (t.kind == TokenKind.invalid) return fp.string.clone("syntax error, DOIR has no use for this character").get(null);
			auto spelled = doir.syntax.lexer.text(t, source);
			if (spelled.length > 32) spelled = spelled[0 .. 32];
			return fp.string.joined("syntax error, unexpected '", spelled, "' ", where).get(null);
		case SyntaxError.Kind.nesting:
			return fp.string.clone("IL-Nest: blocks and function types nest too deeply").get(null);
		case SyntaxError.Kind.language:
			return fp.string.joined("I-Language: no frontend is registered for language ", doir.syntax.lexer.text(syntax.tokens[error.token], source)).get(null);
		case SyntaxError.Kind.literal:
			return fp.string.clone(error.message).get(null);
	}
}

// The five constant kinds, which a hint names together.
private enum uint constantKinds = 1u << TokenKind.integer | 1u << TokenKind.float_ | 1u << TokenKind.string_ | 1u << TokenKind.rawString | 1u << TokenKind.character;

// Whether a token of `kind` could start a declaration's value.
private bool startsValue(TokenKind kind) {
	return (constantKinds & (1u << kind)) || kind == TokenKind.identifier || kind == TokenKind.leftBrace || kind == TokenKind.leftParen;
}

// A hint more pointed than the list of expected kinds, and the text it says to insert, if it names one.
private struct ContextHint {
	string text; // Null when the list of expected kinds is the hint.
	string inserted; // Null when the author has to choose what to write.
}

// A hint more pointed than the list of expected kinds, where what the parse was reading makes the fix plain; a null `text` otherwise.
private ContextHint contextHint(ref const Syntax syntax, SyntaxError error) {
	immutable unexpected = syntax.tokens[error.token].kind;
	// A name opening the next line more likely starts a declaration after a missing `)` than continues a list.
	size_t before = error.token;
	while (before > 0 && doir.syntax.lexer.isTrivia(syntax.tokens[before - 1].kind)) --before;
	immutable sameLine = before > 0 && syntax.tokens[before - 1].kind != TokenKind.newline;
	immutable ended = unexpected == TokenKind.newline || unexpected == TokenKind.end || unexpected == TokenKind.semicolon;
	switch (error.where) {
		case Reading.afterType:
			return startsValue(unexpected) && (error.expected & (1u << TokenKind.equals)) ? ContextHint("insert `=` here", "=") : ContextHint.init;
		case Reading.type, Reading.returnType:
			return error.expected & (1u << TokenKind.identifier) ? ContextHint("insert a type or `_` here", "_") : ContextHint.init;
		case Reading.parameterType:
			return error.expected & (1u << TokenKind.identifier) ? ContextHint("insert a type here") : ContextHint.init;
		case Reading.value:
			return ContextHint(ended ? "insert a value here, such as `0`, a name or a block in braces" : "replace this with a value: a constant, a name, a call, a block or a function type");
		case Reading.colon:
			return unexpected == TokenKind.equals ? ContextHint("insert `: _` here", ": _") : ContextHint.init;
		case Reading.afterParameter:
			return unexpected == TokenKind.identifier && sameLine ? ContextHint("insert `,` here", ",") : ContextHint.init;
		case Reading.callArgument:
			if (unexpected == TokenKind.identifier && sameLine) return ContextHint("insert `,` here", ",");
			return constantKinds & (1u << unexpected) ? ContextHint("replace this constant with the name of a declaration that holds it") : ContextHint.init;
		default:
			return ContextHint.init;
	}
}

/// The byte offset of the innermost `{` or `(` still open before `error`, if `error` is a syntax error whose parse tried that bracket's closer there and nothing likelier fits, as `,` does between two parameters; otherwise `fp.pointer.notFound`.
///
/// Examples:
/// ---
/// Syntax syntax;
/// scope(exit) free(syntax);
/// immutable source = "f : (x: T\n";
/// cast(void) skim(source, syntax);
/// assert(opening(syntax, syntax.errors[0]) == 4);
/// ---
size_t opening(ref const Syntax syntax, SyntaxError error) {
	if (error.kind != SyntaxError.Kind.syntax || contextHint(syntax, error).text !is null) return fp.pointer.notFound;
	// A closed brace pair counts whole, its parentheses ignored: they need not balance inside a block, and an edit there must not move this answer.
	size_t braces = 0, parens = 0;
	for (size_t i = error.token; i-- > 0;) {
		immutable t = syntax.tokens[i];
		if (t.kind == TokenKind.rightBrace) ++braces;
		else if (t.kind == TokenKind.rightParen) parens += braces == 0;
		else if (t.kind == TokenKind.leftBrace) {
			if (braces == 0) return error.expected & (1u << TokenKind.rightBrace) ? t.start : fp.pointer.notFound;
			--braces;
		} else if (t.kind == TokenKind.leftParen && braces == 0) {
			if (parens == 0) return error.expected & (1u << TokenKind.rightParen) ? t.start : fp.pointer.notFound;
			--parens;
		}
	}
	return fp.pointer.notFound;
}

// What a hint calls each token kind, or null if no rule expects it.
// Tables, not switches: the lexer and `note` never produce some kinds.
private immutable string[TokenKind.max + 1] spelling = [
	TokenKind.newline: "a line break",
	TokenKind.identifier: "a name",
	TokenKind.keyword: "a keyword",
	TokenKind.integer: "an integer",
	TokenKind.float_: "a float",
	TokenKind.string_: "a string",
	TokenKind.rawString: "a raw string",
	TokenKind.character: "a character",
	TokenKind.colon: "`:`",
	TokenKind.equals: "`=`",
	TokenKind.comma: "`,`",
	TokenKind.leftParen: "`(`",
	TokenKind.rightParen: "`)`",
	TokenKind.leftBrace: "`{`",
	TokenKind.rightBrace: "`}`",
	TokenKind.arrow: "`->`",
	TokenKind.semicolon: "`;`",
	TokenKind.sourceInfo: "a source annotation",
	TokenKind.languageBody: "a braced block",
];

// What closes a token that `unterminated` says started as each kind, or null for one that cannot be left open.
private immutable string[TokenKind.max + 1] closing = [
	TokenKind.string_: "close the string with `\"`, and check that its escapes are valid",
	TokenKind.character: "close the character with `'`; it holds exactly one character or escape",
	TokenKind.rawString: "close the raw string with the same run of quotes that opens it",
	TokenKind.longComment: "close the comment with `*/`",
	TokenKind.sourceInfo: "finish the source annotation, as in `<\"file.doir\":1:1>`",
	TokenKind.languageBody: "close the block with `}`",
];

// Where each `Reading` is, as a message ends: "unexpected '{' after the declared type".
private immutable string[Reading.max + 1] whereText = [
	Reading.declaration: "where a declaration should start",
	Reading.colon: "after the declaration's name",
	Reading.type: "where the declared type should be",
	Reading.afterType: "after the declared type",
	Reading.value: "where the value after `=` should be",
	Reading.afterValue: "after the declaration's value",
	Reading.parameter: "in a parameter list",
	Reading.parameterColon: "after a parameter's name",
	Reading.parameterType: "where a parameter's type should be",
	Reading.afterParameter: "after a parameter",
	Reading.parameterDefault: "where a parameter's default value should be",
	Reading.returnType: "where the return type after `->` should be",
	Reading.callArgument: "in a call's arguments",
	Reading.block: "inside a block",
	Reading.language: "in a `language` block",
];

// What a message calls a token that `unterminated` says started as each kind and never finished.
private immutable string[TokenKind.max + 1] unclosed = [
	TokenKind.string_: "syntax error, this string is never closed",
	TokenKind.character: "syntax error, this character constant is never closed",
	TokenKind.rawString: "syntax error, this raw string is never closed",
	TokenKind.longComment: "syntax error, this comment is never closed",
	TokenKind.sourceInfo: "syntax error, this source annotation is never finished",
	TokenKind.languageBody: "syntax error, this `language` block is never closed",
];

// What a hint calls each kind in `expected`, in order, the five constant kinds as one.
private struct ExpectedNames {
	string[TokenKind.max + 2] items;
	size_t length;
}

// The names a hint lists for `expected`, without the end of the file, which cannot be inserted.
private ExpectedNames expectedNames(uint expected) {
	// A keyword or source annotation is rarely what a beginner meant, so the hint names them only when nothing else fits.
	enum uint rare = 1u << TokenKind.keyword | 1u << TokenKind.sourceInfo;
	if (expected & ~rare & ~(1u << TokenKind.end)) expected &= ~rare;
	immutable allConstants = (expected & constantKinds) == constantKinds;
	ExpectedNames names;
	foreach (kind; 0 .. TokenKind.max + 1) {
		if (!(expected & (1u << kind)) || (allConstants && (constantKinds & (1u << kind)))) continue;
		if (auto name = spelling[kind]) names.items[names.length++] = name;
	}
	if (allConstants) names.items[names.length++] = "a constant";
	return names;
}

// "insert A, B or C here" for the kinds in `expected`; the end of the file cannot be inserted.
private char* expectedHint(uint expected) {
	const names = expectedNames(expected);
	immutable n = names.length;
	if (n == 0) return fp.string.clone(expected & (1u << TokenKind.end) ? "remove everything from here to the end of the file" : "remove this, or finish the declaration before it").get(null);
	char* out_ = fp.string.clone("insert ").get(null);
	bool ok = out_ !is null;
	foreach (i; 0 .. n)
		ok = ok && (i == 0 || fp.string.concatenate(out_, i + 1 == n ? " or " : ", ")) && fp.string.concatenate(out_, names.items[i]);
	if (ok && fp.string.concatenate(out_, " here")) return out_;
	fp.string.free(out_);
	return null;
}

/// Writes how to fix `error` in `syntax`, parsed from `source`, to `out_`, a new fp string, or null if allocation fails.
/// A diagnostic draws it at `error.at`.
///
/// Examples:
/// ---
/// static import fp.string;
/// Syntax syntax;
/// scope(exit) free(syntax);
/// immutable source = "x : = 5\n";
/// cast(void) skim(source, syntax);
/// auto fix = hint(syntax, source, syntax.errors[0]);
/// scope(exit) fp.string.free(fix);
/// assert(fp.string.slice(fix) == "insert a type or `_` here");
/// ---
char* hint(ref const Syntax syntax, const(char)[] source, SyntaxError error) {
	final switch (error.kind) {
		case SyntaxError.Kind.syntax:
			immutable t = syntax.tokens[error.token];
			if (t.kind == TokenKind.unterminated) return fp.string.clone(closing[t.attempted] ? closing[t.attempted] : "finish or remove this token").get(null);
			if (splitArrowHead(syntax, source, error) != fp.pointer.notFound) return fp.string.clone("remove the space between `-` and `>`").get(null);
			if (t.kind == TokenKind.invalid) return fp.string.clone("remove this character; no token starts with it").get(null);
			if (auto specific = contextHint(syntax, error).text) return fp.string.clone(specific).get(null);
			immutable open = opening(syntax, error);
			if (open != fp.pointer.notFound) return fp.string.joined("insert `", source[open] == '{' ? "}" : ")", "` here to close the `", source[open .. open + 1], "` left open").get(null);
			return expectedHint(error.expected);
		case SyntaxError.Kind.nesting:
			return fp.string.format("move some of these blocks or function types into declarations of their own; at most %u may nest", maxNesting).get(null);
		case SyntaxError.Kind.language:
			return fp.string.clone("remove this block, or rewrite it in DOIR").get(null);
		case SyntaxError.Kind.literal:
			return fp.string.clone(error.fix).get(null);
	}
}

// `text`, inserted at `at` in `source`, as a fix: `,` and `)` against the token before them, and a space on either side where DOIR is written with one, as `x : T = {`.
private doir.components.source.SyntaxFix insertion(const(char)[] source, size_t reported, size_t at, string text) {
	if (text == "," || text == ")")
		while (at > 0 && (source[at - 1] == ' ' || source[at - 1] == '\t')) --at;
	immutable before = at > 0 ? source[at - 1] : '\n', after = at < source.length ? source[at] : '\n';
	immutable bracket = text == "(" || text == ")" || text == "}";
	immutable separator = text == "," || text == ":" || text == ";";
	immutable offset = cast(int) (cast(ptrdiff_t) at - cast(ptrdiff_t) reported);
	return doir.components.source.SyntaxFix(offset, offset, text, !fp.string.ascii.isWhitespace(before) && !bracket && !separator, !fp.string.ascii.isWhitespace(after) && !bracket);
}

/// The edits that `hint` states exactly for `error` in `syntax`, parsed from `source`: each token in backquotes it offers to insert, and a split arrow written together.
/// A hint that needs the author to choose, such as "insert a type here", offers none.
///
/// Examples:
/// ---
/// Syntax syntax;
/// scope(exit) free(syntax);
/// immutable source = "f : (a: T\n";
/// cast(void) skim(source, syntax);
/// const offered = fixes(syntax, source, syntax.errors[0]);
/// assert(offered.length == 1 && offered.items[0].text == ")");
/// ---
doir.components.source.SyntaxFixes fixes(ref const Syntax syntax, const(char)[] source, SyntaxError error) {
	// Each token spelled as its text in backquotes, as `=`, is one a fix can insert; a hint lists at most all of them.
	static assert(() {
		size_t n = 0;
		foreach (name; spelling) if (name.length && name[0] == '`') ++n;
		return n;
	}() <= doir.components.source.maxSyntaxFixes);
	doir.components.source.SyntaxFixes out_;
	if (error.kind != SyntaxError.Kind.syntax) return out_;
	immutable t = syntax.tokens[error.token];
	if (t.kind == TokenKind.unterminated || t.kind == TokenKind.invalid) {
		immutable head = splitArrowHead(syntax, source, error);
		if (head != fp.pointer.notFound) out_.items[out_.length++] = doir.components.source.SyntaxFix(cast(int) (t.start - error.at), cast(int) (head + 1 - error.at), "->");
		return out_;
	}
	if (auto inserted = contextHint(syntax, error).inserted) {
		out_.items[out_.length++] = insertion(source, error.at, error.at, inserted);
		return out_;
	}
	if (contextHint(syntax, error).text !is null) return out_;
	immutable open = opening(syntax, error);
	if (open != fp.pointer.notFound) {
		out_.items[out_.length++] = insertion(source, error.at, error.at, source[open] == '{' ? "}" : ")");
		return out_;
	}
	const names = expectedNames(error.expected);
	foreach (name; names.items[0 .. names.length])
		if (name[0] == '`') out_.items[out_.length++] = insertion(source, error.at, error.at, name[1 .. $ - 1]);
	return out_;
}

// `source` from declaration `first` to `at`, the part an example rewrites, or null when it is too long or spans lines to quote.
private const(char)[] writtenSoFar(ref const Syntax syntax, const(char)[] source, uint first, uint at) {
	if (first == outsideDeclaration) return null;
	auto written = source[syntax.tokens[first].start .. at];
	written = fp.string.trimEnd(written, " \t");
	if (written.length == 0 || written.length > 48 || fp.string.contains(written, "\n", 0)) return null;
	return written;
}

/// Writes an explanation of `error` in `syntax`, parsed from `source`, for someone new to DOIR, to a new fp string: how DOIR writes what the parse was reading, with an example, quoting the declaration where that helps.
/// A diagnostic shows it as its closing note, after the hint.
/// Returns null if allocation fails.
///
/// Examples:
/// ---
/// static import fp.string;
/// Syntax syntax;
/// scope(exit) free(syntax);
/// immutable source = "stack : namespace {\n}\n";
/// cast(void) skim(source, syntax);
/// auto note = explain(syntax, source, syntax.errors[0]);
/// scope(exit) fp.string.free(note);
/// assert(fp.string.contains(fp.string.slice(note), "`stack : namespace = {`", 0));
/// ---
char* explain(ref const Syntax syntax, const(char)[] source, SyntaxError error) {
	final switch (error.kind) {
		case SyntaxError.Kind.syntax:
			break;
		case SyntaxError.Kind.nesting:
			return fp.string.clone("Each block or function type written inside another adds a level. Declaring the inner ones separately, under names of their own, keeps the nesting shallow.").get(null);
		case SyntaxError.Kind.language:
			return fp.string.clone("A `language` block holds code in another language for a frontend to translate into DOIR, and this compiler has no frontend for that language.").get(null);
		case SyntaxError.Kind.literal:
			return fp.string.clone("DOIR stores every constant exactly, so a constant it cannot store exactly is an error rather than being rounded or cut short.").get(null);
	}
	immutable t = syntax.tokens[error.token];
	if (t.kind == TokenKind.unterminated) return fp.string.clone("Everything from where it starts to the end of the file was read as part of it, so errors reported after it may go away once it is closed.").get(null);
	if (splitArrowHead(syntax, source, error) != fp.pointer.notFound) return fp.string.clone("An arrow is the two characters `->` written together, as in `(a: std.u8) -> std.u8`. With a space between them, DOIR reads `-` and `>` as two characters, and neither means anything alone.").get(null);
	if (t.kind == TokenKind.invalid) return fp.string.clone("DOIR code is made of names, constants, comments and the punctuation `:`, `=`, `,`, `(`, `)`, `{`, `}`, `->` and `;`. A stray character is often left over from another language or from pasted text.").get(null);
	final switch (error.where) {
		case Reading.declaration:
			return fp.string.clone("Each line of DOIR declares one name, written `name : type = value`, as in `count : std.u8 = 5`; the `= value` part is optional. A line starts with the name it declares.").get(null);
		case Reading.colon:
			if (t.kind == TokenKind.equals) return fp.string.clone("Every declaration names its type between its name and `=`, as in `count : std.u8 = 5`. Write `_` as the type to have the compiler work it out: `count : _ = 5`.").get(null);
			return fp.string.clone("A declaration's name is followed by `:` and its type, as in `count : std.u8`. A name cannot contain spaces; join words with `_`, as in `item_count`.").get(null);
		case Reading.type:
			if (t.kind == TokenKind.equals) return fp.string.clone("Every declaration names its type between `:` and `=`. Write `_` there to have the compiler work the type out, as in `count : _ = 5`.").get(null);
			return fp.string.clone("After `:` comes the declared type: a name such as `std.u8` or `namespace`, or a function type such as `(a: std.u8) -> std.u8`.").get(null);
		case Reading.afterType:
			if (startsValue(t.kind)) {
				const written = writtenSoFar(syntax, source, error.declaration, error.at);
				const what = t.kind == TokenKind.leftBrace ? "A block in braces is a value, and a declaration's value" : "A declaration's value";
				const next = t.kind == TokenKind.leftBrace ? "{" : doir.syntax.lexer.text(t, source);
				if (written is null || next.length > 32) return fp.string.joined(what, " comes after `=`, as in `count : std.u8 = 5`.").get(null);
				return fp.string.joined(what, " comes after `=`: write `", written, " = ", next, "`.").get(null);
			}
			return fp.string.clone("A declaration ends at the end of its line or at `;`. Between its type and its end there can only be `=` and a value, as in `count : std.u8 = 5`; anything else goes on a line of its own.").get(null);
		case Reading.value:
			return fp.string.clone("After `=` comes the declaration's value: a constant such as `5` or `\"text\"`, the name of another declaration, a call such as `add(a, b)`, a block in braces, or a function type. To declare a name without a value, leave out the `=`.").get(null);
		case Reading.afterValue:
			return fp.string.clone("A declaration holds one value and ends at the end of its line or at `;`. Put the next declaration on a line of its own, or separate the two with `;`.").get(null);
		case Reading.parameter:
			return fp.string.clone("A function type lists its parameters between `(` and `)`, each written `name : type` and separated by `,`, as in `(a: std.u8, b: std.u8) -> std.u8`; `()` takes none.").get(null);
		case Reading.parameterColon:
			return fp.string.clone("Each parameter is written `name : type`, as in `(count: std.u8)`, so its name needs `:` and a type after it.").get(null);
		case Reading.parameterType:
			return fp.string.clone("A parameter's type follows its `:`, as in `(count: std.u8)`.").get(null);
		case Reading.afterParameter:
			return fp.string.clone("Separate parameters with `,` and close the list with `)`, as in `(a: std.u8, b: std.u8)`. A default value follows `=`, as in `(a: std.u8 = 0)`.").get(null);
		case Reading.parameterDefault:
			return fp.string.clone("A parameter's default value is a constant or the name of a declaration, as in `(a: std.u8 = 0)`.").get(null);
		case Reading.returnType:
			return fp.string.clone("After `->` comes the type the function returns, as in `(a: std.u8) -> std.u8`, or `_` to have the compiler work it out.").get(null);
		case Reading.callArgument:
			return fp.string.clone("A call's arguments are names of declarations, separated by `,`, as in `add(a, b)`. To pass a constant, declare it first, as in `five : std.u8 = 5`, and pass `five`.").get(null);
		case Reading.block:
			return fp.string.clone("Every `{` needs a matching `}`. The declarations between them belong to the block, one per line or separated by `;`.").get(null);
		case Reading.language:
			return fp.string.clone("A `language` block is written `language \"name\" { ... }`: the language's name in quotes, then its code in braces.").get(null);
	}
}


// --- literals ----------------------------------------------------------------

// The `StringChar` at `s[i]`, which the lexer matched: its value, an escaped byte (`\x`, octal) flagged by `isByte`.
private uint stringChar(const(char)[] s, ref size_t i, out bool isByte, out bool overflow) {
	if (s[i] != '\\') {
		bool valid;
		return fp.string.utf.decode(s, i, valid);
	}
	assert(i + 1 < s.length, "doir.parser.stringChar: a lone backslash ends the content, which the lexer never matches");
	immutable e = s[i + 1];
	i += 2;
	switch (e) {
		case 'a': return 7;
		case 'b': return 8;
		case 'f': return 12;
		case 'n': return 10;
		case 'r': return 13;
		case 't': return 9;
		case 'v': return 11;
		case 'x':
		case '0': .. case '7':
			immutable base = e == 'x' ? 16 : 8;
			if (e != 'x') --i;
			ulong value = 0;
			while (i < s.length && (base == 16 ? fp.string.ascii.isHexDigit(s[i]) : (s[i] >= '0' && s[i] <= '7'))) {
				value = value * base + fp.string.numbers.hexDigitValue(s[i++]);
				if (value > 0x10FFFF) overflow = true;
			}
			isByte = true;
			return cast(uint) value;
		case 'u', 'U':
			immutable n = e == 'u' ? 4 : 8;
			uint value = 0;
			foreach (k; 0 .. n) value = value * 16 + fp.string.numbers.hexDigitValue(s[i++]);
			if (value > 0x10FFFF || (value >= 0xD800 && value <= 0xDFFF)) overflow = true;
			return value;
		default: return e; // ' " ? \ %
	}
}

/// Decodes `content`, the `StringChar`s between a string literal's quotes, appending the UTF-8 it spells to `*out_` unless `out_` is null; `doir.printer` asserts its escaping against it.
///
/// Returns the `V-Literal` error, or null; on a refused append sets `refused` and returns null, `*out_` holding what was decoded so far.
///
/// Examples:
/// ---
/// static import fp.string;
/// char* decoded = null;
/// scope(exit) fp.string.free(decoded);
/// bool refused;
/// assert(decodeString(`a\x41\n`, &decoded, refused) is null && !refused);
/// assert(fp.string.slice(decoded) == "aA\n");
/// assert(decodeString(`\xFF`, null, refused) is null && decodeString(`\xFFFF`, null, refused) !is null);
/// assert(decodeString(`\U00110000`, null, refused) !is null);
/// ---
package(doir) string decodeString(const(char)[] content, char** out_, ref bool refused) {
	size_t i = 0;
	while (i < content.length) {
		immutable start = i;
		bool isByte, overflow;
		immutable value = stringChar(content, i, isByte, overflow);
		if (overflow || (isByte && value > 0xFF)) return "V-Literal: an escape in a string must be a byte or a Unicode scalar value";
		if (out_ is null) continue;
		bool appended;
		if (content[start] != '\\') appended = fp.string.concatenate(*out_, content[start .. i]);
		else if (isByte || value < 0x80) appended = fp.string.append(*out_, cast(char) value);
		else appended = fp.string.utf.append(*out_, value) == fp.string.utf.EncodeError.none;
		if (!appended) {
			refused = true;
			return null;
		}
	}
	return null;
}

// An integer literal's magnitude, its leading `-` left out; `overflow` if it needs more than 64 bits, or a negative that needs more than 63.
private ulong integerValue(const(char)[] s, out bool overflow) {
	immutable negative = s.length > 0 && s[0] == '-';
	size_t i = negative ? 1 : 0;
	uint base = 10;
	if (s.length - i > 2 && s[i] == '0' && s[i + 1] == 'x') { base = 16; i += 2; }
	else if (s.length - i > 2 && s[i] == '0' && s[i + 1] == 'b') { base = 2; i += 2; }
	else if (s.length - i > 1 && s[i] == '0') { base = 8; i += 1; }
	ulong value = 0;
	for (; i < s.length; ++i) {
		immutable d = fp.string.numbers.hexDigitValue(s[i]);
		if (value > (ulong.max - d) / base) overflow = true;
		value = value * base + d;
	}
	if (negative && value > (ulong(1) << 63)) overflow = true;
	return value;
}

// The content of a raw string token, between its delimiters.
private const(char)[] rawContent(const(char)[] s) {
	size_t n = 0;
	while (s[n] == '"') ++n;
	return s[n .. $ - n];
}


/// The interned name an identifier spells: `%"text"` names `text`, its escapes decoded (spec Part I); any other spells itself.
///
/// Returns `refused` if allocation fails, leaving `strings` as it was.
///
/// Examples:
/// ---
/// static import doir.strings;
/// doir.strings.Strings strings;
/// scope(exit) doir.strings.free(strings);
/// assert(internSpelling(`%"a b"`, strings) == doir.strings.intern(strings, "a b"));
/// assert(doir.strings.text(strings, internSpelling("std.u8", strings)) == "std.u8");
/// ---
doir.strings.StringId internSpelling(const(char)[] spelled, ref doir.strings.Strings strings) {
	doir.strings.StringId id;
	if (spelled.length >= 3 && spelled[0] == '%' && spelled[1] == '"') {
		char* decoded = null;
		scope(exit) fp.string.free(decoded);
		bool refused = false;
		cast(void) decodeString(spelled[2 .. $ - 1], &decoded, refused);
		if (refused) return doir.strings.refused;
		id = doir.strings.intern(strings, fp.string.slice(decoded));
	} else id = doir.strings.intern(strings, spelled);
	return id;
}


// --- the parser --------------------------------------------------------------

/// What `build` writes into: the store, the declaration's entity, and the entities the parse made for it besides its nested declarations (its function types and parameters), reused in order so a rebuild keeps their ids.
struct Builder {
	ecrs.context.Context* store; /// The store.
	doir.strings.Strings* strings; /// Where names and string literals are interned.
	EntityId declaration = invalidEntity; /// The declaration's entity, with no parsed components.
	const(EntityId)[] reuse; /// Entities to build parts into before making new ones; each must have no parsed components.
	EntityId* parts = null; /// Out: every part built, in order, parents first; an fp dynarray the caller frees.
	diagnose.LineColumnRange annotation; /// Out: the declaration's `SourceAnnotation`, if `annotated`.
	bool annotated; /// Out: whether it has one.
}

/// How a `Write` names the declaration it describes; its parts are numbered from `firstPart`, in the order the parse made them.
enum EntityId declarationRef = 1;
/// How a `Write` names the declaration's first part.
enum EntityId firstPart = 2;

/// A recorded write's type: an interned name, or one of the declaration's parts, a function type written in place.
struct TypeRef {
	doir.strings.StringId name; /// The type's name, when `part` is `invalidEntity`.
	EntityId part = invalidEntity; /// The function type, as a `Write` names a part.
}

/// One store write `describe` records and `apply` replays: which `doir.builders` call it is, on which of the declaration's entities, and with what.
struct Write {
	/// The builder it replays.
	enum Kind : ubyte { span, inPlaceFunctionType, parameter, defaultValue, defaultName, returnType, functionType, valueless, constant, namespace, aggregate, block, call, alias_, reference, flags }
	Kind kind; /// Which.
	EntityId target; /// `declarationRef` or a part.
	EntityId other = invalidEntity; /// An in-place function type's owner, or a parameter's function type.
	TypeRef type; /// The type, for the writes that give one.
	doir.strings.StringId name; /// A parameter's name, a default's, alias's or reference's target, or a call's callee.
	doir.components.ast.ConstantVal value; /// A constant, or a parameter's default.
	uint flags; /// For `flags`.
	uint from, count; /// A span's start and length from its parent's start; a call's arguments in `Description.arguments`.
}

/// What `describe` records of one declaration: the writes `build` would make, in order, and how many part entities they need.
/// Plain data, released by `free`; it holds no entity, so any thread may make one.
struct Description {
	Write* writes = null; /// In order; an fp dynarray.
	doir.strings.StringId* arguments = null; /// Calls' arguments, which `Write.from` and `Write.count` slice; an fp dynarray.
	uint parts; /// The part entities the writes name, from `firstPart`.
	diagnose.LineColumnRange annotation; /// The declaration's `SourceAnnotation`, if `annotated`.
	bool annotated; /// Whether it has one.
}

/// Releases `d`'s arrays, leaving it empty.
///
/// Examples:
/// ---
/// Description d;
/// free(d);
/// assert(d.writes is null);
/// ---
void free(ref Description d) {
	fp.dynarray.free(d.writes);
	fp.dynarray.free(d.arguments);
	d = Description.init;
}

private struct Parser {
	const(char)[] source;
	const(Token)[] tokens;
	size_t pos;
	uint furthest; // byte offset of the furthest failure in the current statement
	uint furthestToken;
	bool failed; // whether any failure was noted in the current statement
	uint expected; // the kinds tried at `furthest`, as `SyntaxError.expected`
	Reading where; // what the rules are reading now
	Reading furthestWhere; // what they were reading at `furthest`
	uint declaration = outsideDeclaration; // the first token of the innermost declaration being read
	uint furthestDeclaration = outsideDeclaration; // `declaration` at `furthest`
	bool tooDeep;
	bool refused; // an allocation was refused; every rule stops and the entry point returns false
	uint depth;
	Syntax* syntax; // skimming
	Description* description; // describing a record to build; null while skimming or validating
	doir.strings.Strings* strings; // where a description's names are interned
	const(Record)* record; // the record being built
	uint record_; // the record being skimmed
}

private bool refuse(ref Parser parser) {
	parser.refused = true;
	return false;
}

private void note(ref Parser parser, TokenKind expected) {
	static assert(TokenKind.max < SyntaxError.expected.sizeof * 8, "SyntaxError.expected holds a bit per TokenKind");
	assert(parser.pos < parser.tokens.length, "doir.syntax.parser: a failure noted past the end token");
	immutable t = parser.tokens[parser.pos];
	// `_` and `wsc` try a comment between any two tokens, so an unclosed one fails at its end wherever it is.
	immutable reached = t.attempted == expected || t.attempted == TokenKind.longComment;
	immutable at = t.kind == TokenKind.unterminated && reached ? t.start + t.length : t.start;
	if (parser.failed && at == parser.furthest) parser.expected |= 1u << expected;
	else if (!parser.failed || at > parser.furthest) parser.expected = 1u << expected;
	if (!parser.failed || at >= parser.furthest) {
		parser.furthest = at;
		parser.furthestToken = cast(uint) parser.pos;
		parser.furthestWhere = parser.where;
		parser.furthestDeclaration = parser.declaration;
		parser.failed = true;
	}
	assert(parser.failed && (parser.expected & (1u << expected)) != 0 || at < parser.furthest, "doir.syntax.parser: a failure at the furthest point that forgot what was expected");
}

private bool currentIs(ref Parser parser, TokenKind kind) {
	assert(parser.pos < parser.tokens.length, "doir.syntax.parser: reading past the end token");
	if (parser.tokens[parser.pos].kind == kind) return true;
	note(parser, kind);
	return false;
}

private bool atWord(ref Parser parser, TokenKind kind, const(char)[] word) {
	assert(parser.pos < parser.tokens.length && word.length > 0, "doir.syntax.parser: reading past the end token, or for no word");
	immutable t = parser.tokens[parser.pos];
	if (t.kind == kind && doir.syntax.lexer.text(t, parser.source) == word) return true;
	note(parser, kind);
	return false;
}

// `wsc`
private void skipTrivia(ref Parser parser) {
	assert(parser.pos < parser.tokens.length, "doir.syntax.parser: skipping trivia past the end token");
	while (doir.syntax.lexer.isTrivia(parser.tokens[parser.pos].kind)) ++parser.pos;
	// The end token is no trivia, so the skip stops on it at the latest.
	assert(parser.pos < parser.tokens.length, "doir.syntax.parser: skipped past the end token");
}

// `_`
private void skipBlank(ref Parser parser) {
	assert(parser.pos < parser.tokens.length, "doir.syntax.parser: skipping blanks past the end token");
	while (doir.syntax.lexer.isTrivia(parser.tokens[parser.pos].kind) || parser.tokens[parser.pos].kind == TokenKind.newline) ++parser.pos;
	assert(parser.pos < parser.tokens.length, "doir.syntax.parser: skipped past the end token");
}

// The byte offset after the last non-trivia token before `parser.pos`.
private uint lastEnd(ref Parser parser, size_t from) {
	size_t i = parser.pos;
	while (i > from && (doir.syntax.lexer.isTrivia(parser.tokens[i - 1].kind) || parser.tokens[i - 1].kind == TokenKind.newline)) --i;
	assert(i > 0 && i <= parser.tokens.length, "doir.syntax.parser: the end of a statement before the first token");
	immutable t = parser.tokens[i - 1];
	assert(t.start + t.length <= parser.source.length, "doir.syntax.parser: a token past the source");
	return t.start + t.length;
}

private bool enter(ref Parser parser) {
	if (parser.depth >= maxNesting) {
		parser.tooDeep = true;
		return false;
	}
	++parser.depth;
	assert(parser.depth <= maxNesting, "doir.syntax.parser: nested past maxNesting (IL-Nest)");
	return true;
}

private void error(ref Parser parser, SyntaxError.Kind kind, uint at, uint token, string message = null, string fix = null, uint expected = 0) {
	if (parser.syntax is null) return;
	assert(at <= parser.source.length && token < parser.tokens.length, "doir.syntax.parser: an error past the source or its tokens");
	auto e = SyntaxError(kind, at, token, message, fix, expected);
	if (kind == SyntaxError.Kind.syntax) {
		e.where = parser.furthestWhere;
		e.declaration = parser.furthestDeclaration;
	}
	if (!fp.dynarray.pushBack(parser.syntax.errors, e)) parser.refused = true;
}

// The intern functions return `refused` and set `parser.refused` if allocation fails.
private doir.strings.StringId intern(ref Parser parser, size_t token) {
	assert(token < parser.tokens.length && parser.strings !is null, "doir.syntax.parser: interning a token past the end, or with no strings");
	immutable id = internSpelling(doir.syntax.lexer.text(parser.tokens[token], parser.source), *parser.strings);
	if (id == doir.strings.refused) parser.refused = true;
	return id;
}

private doir.strings.StringId intern(ref Parser parser, const(char)[] spelled) {
	immutable id = doir.strings.intern(*parser.strings, spelled);
	if (id == doir.strings.refused) parser.refused = true;
	return id;
}

private bool record(ref Parser parser, Write write) {
	assert(parser.description !is null, "doir.syntax.parser: recording a write while not describing");
	return fp.dynarray.pushBack(parser.description.writes, write) || refuse(parser);
}

private bool setSpan(ref Parser parser, EntityId e, uint parentStart, uint start, uint end) {
	assert(parentStart <= start && start <= end && end <= parser.source.length, "doir.syntax.parser: a span before its parent, ending before it starts, or past the source");
	auto write = Write(kind: Write.Kind.span, target: e);
	write.from = start - parentStart;
	write.count = end - start;
	return record(parser, write);
}

/// A parsed type position: a name, or a function type written in place.
private struct ParsedType {
	uint name = noToken; // the identifier, or noToken
	EntityId entity = invalidEntity; // while building, the function type
}

private bool isName(ref Parser parser, ParsedType type, const(char)[] word) {
	assert(type.name == unnamed || type.name < parser.tokens.length, "doir.syntax.parser: a type named by a token past the end");
	return type.name != unnamed && doir.syntax.lexer.text(parser.tokens[type.name], parser.source) == word;
}

// Calls `f` with the type as a `Write` holds it: the interned name or function type part.
// False on refused interning.
private bool withType(alias f)(ref Parser parser, ParsedType type) {
	if (type.entity != invalidEntity) return f(TypeRef(doir.strings.unnamed, type.entity));
	immutable name = intern(parser, type.name);
	return name != doir.strings.refused && f(TypeRef(name));
}

/// A parsed constant's payload.
private struct ParsedConstant {
	doir.components.ast.ConstantVal value;
}

// `Constant <- '-'? FloatConstant / '-'? IntegerConstant / RawString / '"' StringChar* '"' / '\'' StringChar '\''`
private std.typecons.Nullable!ParsedConstant constant(ref Parser parser) {
	immutable t = parser.tokens[parser.pos];
	const spelled = doir.syntax.lexer.text(t, parser.source);
	ParsedConstant out_;
	switch (t.kind) {
		case TokenKind.float_:
			// The lexer admits only spellings `parseFloat` reads, so null means copying a long literal was refused (V-Literal rounds the rest).
			immutable value = fp.string.numbers.parseFloat(spelled);
			if (value.isNull) {
				cast(void) refuse(parser);
				return typeof(return).init;
			}
			out_.value = doir.components.ast.ConstantVal.float_(value.get.value);
			break;
		case TokenKind.integer:
			bool overflow;
			immutable negative = spelled.length > 0 && spelled[0] == '-';
			immutable magnitude = integerValue(spelled, overflow);
			out_.value = negative ? doir.components.ast.ConstantVal.negativeInteger(magnitude) : doir.components.ast.ConstantVal.integer(magnitude);
			if (overflow) error(parser, SyntaxError.Kind.literal, t.start, cast(uint) parser.pos, "V-Literal: an integer literal must fit in 64 bits", negative ? "write a value at or above -2^63" : "write a value below 2^64");
			break;
		case TokenKind.rawString, TokenKind.string_:
			const content = t.kind == TokenKind.rawString ? rawContent(spelled) : spelled[1 .. $ - 1];
			if (parser.description is null) {
				if (t.kind == TokenKind.string_) {
					bool unused;
					immutable problem = decodeString(content, null, unused);
					if (problem !is null) error(parser, SyntaxError.Kind.literal, t.start, cast(uint) parser.pos, problem, "keep `\\x` and octal escapes at or below 0xFF, and `\\u` and `\\U` escapes to Unicode scalar values");
				}
				break;
			}
			doir.strings.StringId bytes;
			if (t.kind == TokenKind.rawString) bytes = intern(parser, content);
			else {
				char* decoded = null;
				scope(exit) fp.string.free(decoded);
				bool refused = false;
				cast(void) decodeString(content, &decoded, refused);
				if (refused) {
					cast(void) refuse(parser);
					return typeof(return).init;
				}
				bytes = intern(parser, fp.string.slice(decoded));
			}
			if (bytes == doir.strings.refused) return typeof(return).init;
			out_.value = doir.components.ast.ConstantVal.bytes(bytes);
			break;
		case TokenKind.character:
			size_t i = 1;
			bool isByte, overflow;
			out_.value = doir.components.ast.ConstantVal.integer(stringChar(spelled, i, isByte, overflow));
			if (overflow) error(parser, SyntaxError.Kind.literal, t.start, cast(uint) parser.pos, "V-Literal: a character literal must be a Unicode scalar value", "use a code point up to U+10FFFF, outside the surrogates U+D800 to U+DFFF");
			break;
		default:
			foreach (kind; [TokenKind.float_, TokenKind.integer, TokenKind.rawString, TokenKind.string_, TokenKind.character]) note(parser, kind);
			return typeof(return).init;
	}
	++parser.pos;
	return typeof(return)(out_);
}

// Parses in skimming mode and rewinds, so a build makes no part for a function type that does not parse whole.
private bool validates(alias rule)(ref Parser parser) {
	immutable save = parser.pos;
	auto build = parser.description;
	parser.description = null;
	immutable ok = rule(parser);
	parser.description = build;
	parser.pos = save;
	return ok;
}

// `Type <- FunctionType / Identifier`; a function type is built as a part owned by `owner`, whose span starts at `ownerStart`.
private std.typecons.Nullable!ParsedType type(ref Parser parser, EntityId owner, uint ownerStart) {
	if (parser.tokens[parser.pos].kind == TokenKind.leftParen) {
		if (parser.description is null) {
			if (functionType(parser, invalidEntity, 0)) return typeof(return)(ParsedType.init);
		} else if (validates!(q => functionType(q, invalidEntity, 0))(parser)) {
			immutable start = parser.tokens[parser.pos].start;
			// The next part, which `apply` makes or reuses.
			immutable e = cast(EntityId) (firstPart + parser.description.parts++);
			immutable typeName = intern(parser, "type");
			if (typeName == doir.strings.refused) return typeof(return).init;
			if (!record(parser, Write(kind: Write.Kind.inPlaceFunctionType, target: e, type: TypeRef(typeName), other: owner))) return typeof(return).init;
			if (!functionType(parser, e, start)) {
				assert(parser.refused, "doir.parser: a validated function type did not build");
				return typeof(return).init;
			}
			if (!setSpan(parser, e, ownerStart, start, lastEnd(parser, 0))) return typeof(return).init;
			return typeof(return)(ParsedType(noToken, e));
		}
		if (parser.refused) return typeof(return).init;
	}
	if (!currentIs(parser, TokenKind.identifier)) return typeof(return).init;
	return typeof(return)(ParsedType(cast(uint) parser.pos++));
}

// 'deduced' _ 'type' _, a parameter type deduced from its argument: whether it was there, consumed.
private bool consumeDeducedType(ref Parser parser) {
	if (!atWord(parser, TokenKind.keyword, "deduced")) return false;
	immutable save = parser.pos;
	++parser.pos;
	skipBlank(parser);
	if (!atWord(parser, TokenKind.identifier, "type")) {
		parser.pos = save;
		return false;
	}
	++parser.pos;
	skipBlank(parser);
	return true;
}

// `parameter <- Identifier _ ':'_ deducible_type`; `deducible_type <- ('deduced' _ 'type' _) / (Type _ ('='_ (Constant / Identifier) _)?)`
private bool parameter(ref Parser parser, EntityId functionType, uint ftStart) {
	immutable start = parser.pos;
	parser.where = Reading.parameter;
	if (!currentIs(parser, TokenKind.identifier)) return false;
	immutable name = cast(uint) parser.pos++;
	skipBlank(parser);
	parser.where = Reading.parameterColon;
	if (!currentIs(parser, TokenKind.colon)) { parser.pos = start; return false; }
	++parser.pos;
	skipBlank(parser);
	parser.where = Reading.parameterType;

	immutable deduced = consumeDeducedType(parser);

	ParsedType paramType;
	ParsedConstant defaultConstant;
	uint defaultName = noToken;
	bool hasDefault = false;
	// The parameter's entity is taken before its type's, so its parts stay parent-first; `apply` makes or reuses the next.
	immutable e = parser.description is null ? invalidEntity : cast(EntityId) (firstPart + parser.description.parts++);
	if (parser.refused) return false;
	if (!deduced) {
		auto parsedType = type(parser, functionType, ftStart);
		if (parsedType.isNull) {
			assert(parser.description is null || parser.refused);
			parser.pos = start;
			return false;
		}
		paramType = parsedType.get;
		skipBlank(parser);
		immutable save = parser.pos;
		parser.where = Reading.afterParameter;
		if (currentIs(parser, TokenKind.equals)) {
			++parser.pos;
			skipBlank(parser);
			parser.where = Reading.parameterDefault;
			auto parsedDefault = constant(parser);
			if (!parsedDefault.isNull) {
				defaultConstant = parsedDefault.get;
				hasDefault = true;
			} else if (parser.refused) return false;
			else if (currentIs(parser, TokenKind.identifier)) { defaultName = cast(uint) parser.pos++; hasDefault = true; }
			if (hasDefault) skipBlank(parser);
			else parser.pos = save;
		}
	}
	if (parser.description is null) return true;

	immutable unnamed = doir.syntax.lexer.text(parser.tokens[name], parser.source) == "_";
	immutable named = unnamed ? doir.strings.unnamed : intern(parser, name);
	if (parser.refused) return false;
	bool ok;
	if (deduced) {
		immutable deducedType = intern(parser, doir.components.ast.deducedTypeName);
		ok = deducedType != doir.strings.refused && record(parser, Write(kind: Write.Kind.parameter, target: e, type: TypeRef(deducedType), name: named, other: functionType));
	} else ok = withType!(t => record(parser, Write(kind: Write.Kind.parameter, target: e, type: t, name: named, other: functionType)))(parser, paramType);
	if (ok && hasDefault && defaultName != noToken) {
		immutable value = intern(parser, defaultName);
		ok = value != doir.strings.refused && record(parser, Write(kind: Write.Kind.defaultName, target: e, name: value));
	} else if (ok && hasDefault) {
		auto write = Write(kind: Write.Kind.defaultValue, target: e);
		write.value = defaultConstant.value;
		ok = record(parser, write);
	}
	if (!ok) return refuse(parser);
	return setSpan(parser, e, ftStart, parser.tokens[start].start, lastEnd(parser, start));
}

// `FunctionType <- '('_ (parameter (','_ parameter)*)? ')' (_ '->'_ Type)?`; while building, its parameters and return type go on `functionType`.
private bool functionType(ref Parser parser, EntityId functionType, uint ftStart) {
	if (!currentIs(parser, TokenKind.leftParen)) return false;
	if (!enter(parser)) return false;
	scope(exit) --parser.depth;
	immutable start = parser.pos;
	++parser.pos;
	skipBlank(parser);
	immutable any = parameter(parser, functionType, ftStart);
	if (any) {
		for (;;) {
			immutable save = parser.pos;
			parser.where = Reading.afterParameter;
			if (!currentIs(parser, TokenKind.comma)) break;
			++parser.pos;
			skipBlank(parser);
			if (!parameter(parser, functionType, ftStart)) {
				if (parser.refused) return false;
				parser.pos = save;
				break;
			}
		}
	} else if (parser.refused) return false;
	parser.where = any ? Reading.afterParameter : Reading.parameter;
	if (!currentIs(parser, TokenKind.rightParen)) {
		parser.pos = start;
		return false;
	}
	++parser.pos;
	immutable save = parser.pos;
	skipBlank(parser);
	if (currentIs(parser, TokenKind.arrow)) {
		++parser.pos;
		skipBlank(parser);
		parser.where = Reading.returnType;
		auto returned = type(parser, functionType, ftStart);
		if (!returned.isNull) {
			if (parser.description is null || withType!(t => record(parser, Write(kind: Write.Kind.returnType, target: functionType, type: t)))(parser, returned.get)) return true;
			return refuse(parser);
		}
		if (parser.refused) return false;
	}
	parser.pos = save;
	return true;
}

/// A parsed call.
private struct ParsedCall {
	uint flags;
	uint callee;
	uint* arguments; // token indices, an fp dynarray
}

// `function_call <- (('flatten' / 'inline' / 'tail') _)? Identifier _ '('_ (Identifier _ (','_ Identifier _)*)? ')' wsc`
private bool functionCall(ref Parser parser, ref ParsedCall out_) {
	immutable start = parser.pos;
	if (parser.tokens[parser.pos].kind == TokenKind.keyword) {
		const word = doir.syntax.lexer.text(parser.tokens[parser.pos], parser.source);
		if (word == "flatten") out_.flags = doir.components.ast.Flags.Flatten;
		else if (word == "inline") out_.flags = doir.components.ast.Flags.Inline;
		else if (word == "tail") out_.flags = doir.components.ast.Flags.Tail;
		if (out_.flags) {
			++parser.pos;
			skipBlank(parser);
		}
	} else note(parser, TokenKind.keyword);
	if (!currentIs(parser, TokenKind.identifier)) { parser.pos = start; return false; }
	out_.callee = cast(uint) parser.pos++;
	skipBlank(parser);
	if (!currentIs(parser, TokenKind.leftParen)) { parser.pos = start; return false; }
	++parser.pos;
	skipBlank(parser);
	parser.where = Reading.callArgument;
	if (currentIs(parser, TokenKind.identifier)) {
		if (!fp.dynarray.pushBack(out_.arguments, cast(uint) parser.pos++)) return refuse(parser);
		skipBlank(parser);
		for (;;) {
			immutable save = parser.pos;
			if (!currentIs(parser, TokenKind.comma)) break;
			++parser.pos;
			skipBlank(parser);
			if (!currentIs(parser, TokenKind.identifier)) {
				parser.pos = save;
				break;
			}
			if (!fp.dynarray.pushBack(out_.arguments, cast(uint) parser.pos++)) return refuse(parser);
			skipBlank(parser);
		}
	}
	if (!currentIs(parser, TokenKind.rightParen)) { parser.pos = start; return false; }
	++parser.pos;
	skipTrivia(parser);
	return true;
}

// `Block <- '{'_ assignment* '}'`; while skimming, each failed assignment is reported and skipped.
private bool block(ref Parser parser) {
	if (!currentIs(parser, TokenKind.leftBrace)) return false;
	if (parser.description !is null) {
		// A block the skim found unclosed, as in `n : e` followed by `= {`, fails here as it did there.
		if (parser.record.blockOpen == noBlock) return false;
		assert(parser.pos == parser.record.blockOpen, "doir.parser: describing a block the skim did not record");
		parser.pos = parser.record.blockClose + 1;
		return true;
	}
	if (!enter(parser)) return false;
	scope(exit) --parser.depth;
	immutable start = parser.pos;
	immutable owner = parser.record_;
	++parser.pos;
	skipBlank(parser);
	for (;;) {
		immutable t = parser.tokens[parser.pos].kind;
		if (t == TokenKind.rightBrace) break;
		if (t == TokenKind.end) {
			parser.where = Reading.block;
			note(parser, TokenKind.rightBrace);
			parser.pos = start;
			return false;
		}
		statement(parser);
		if (parser.refused) return false;
	}
	parser.syntax.records[owner].blockOpen = cast(uint) start;
	parser.syntax.records[owner].blockClose = cast(uint) parser.pos;
	++parser.pos;
	return true;
}

/// Which `assignment_value` alternative matched.
private enum Value : ubyte { none, constant, block, call, reference, functionType }

// `change_language <- 'language' _ '"' StringChar* '"'_ matching_braces _`
private bool changeLanguage(ref Parser parser) {
	immutable start = parser.pos;
	++parser.pos;
	skipBlank(parser);
	parser.where = Reading.language;
	if (!currentIs(parser, TokenKind.string_)) { parser.pos = start; return false; }
	immutable name = cast(uint) parser.pos++;
	skipBlank(parser);
	if (!currentIs(parser, TokenKind.languageBody)) { parser.pos = start; return false; }
	++parser.pos;
	skipBlank(parser);
	error(parser, SyntaxError.Kind.language, parser.tokens[start].start, name);
	return true;
}

/// Where a `Record.hash` starts, before `hashTokens` mixes in its tokens.
enum ulong hashStart = 0xcbf29ce484222325;

/// Mixes into `h` tokens `from` to `to` of `syntax`, skimmed from `source`, as a `Record.hash` covers them: each record from `child` on whose first token it reaches, and those after it at its level, is one placeholder, its terminator included; trivia, newlines and semicolons are left out.
/// A hash split across several skims, as a commit that chunks a block's contents makes it, carries `h` from one to the next.
/// It cannot fail.
///
/// Examples:
/// ---
/// Syntax syntax;
/// scope(exit) free(syntax);
/// assert(skim("ns : namespace = {\n\tx : T\n}\n", syntax));
/// immutable r = syntax.records[0];
/// assert(hashTokens(hashStart, syntax, "ns : namespace = {\n\tx : T\n}\n", r.first, r.terminator, 1) == r.hash);
/// ---
ulong hashTokens(ulong h, ref const Syntax syntax, const(char)[] source, size_t from, size_t to, size_t child = noToken) {
	auto records = fp.dynarray.slice(syntax.records);
	size_t t = from;
	while (t < to) {
		if (child < records.length && t == records[child].first) {
			h = fp.algorithms.combine(h, 0x9e3779b97f4a7c15);
			t = records[child].terminator + 1;
			child = records[child].end;
			continue;
		}
		immutable token = syntax.tokens[t++];
		if (doir.syntax.lexer.isTrivia(token.kind) || token.kind == TokenKind.newline || token.kind == TokenKind.semicolon) continue;
		h = fp.algorithms.combine(h, token.kind);
		h = fp.algorithms.combine(h, fp.algorithms.hashShortBytes(doir.syntax.lexer.text(token, source)));
	}
	return h;
}

// A SourceInfo token's parts: its file, first and last line and column, and whether a number needs more than 64 bits.
private struct AnnotationText {
	const(char)[] file;
	ulong[4] values;
	bool overflow;
}

// Reads SourceInfo token `s`, which the lexer has matched.
private AnnotationText readAnnotation(const(char)[] s) {
	AnnotationText read;
	size_t i = 1;
	// As the lexer decided: the quoted form only if the first quote after `<"` is followed by `:`.
	immutable quote = s[1] == '"' ? fp.string.find(s, "\"", 2) : fp.pointer.notFound;
	if (quote != fp.pointer.notFound && quote + 1 < s.length && s[quote + 1] == ':') {
		read.file = s[2 .. quote];
		i = quote + 2;
	} else {
		immutable colon = fp.string.find(s, ":", 1);
		read.file = s[1 .. colon];
		i = colon + 1;
	}
	foreach (part; 0 .. 2) {
		immutable first = doir.syntax.lexer.integerEnd(s, i);
		bool overflow; // `integerValue` clears it, so each number's is gathered into `read`
		read.values[part * 2] = integerValue(s[i .. first], overflow);
		read.overflow |= overflow;
		i = first;
		read.values[part * 2 + 1] = read.values[part * 2];
		if (s[i] == '-') {
			immutable second = doir.syntax.lexer.integerEnd(s, i + 1);
			if (second != fp.pointer.notFound) {
				read.values[part * 2 + 1] = integerValue(s[i + 1 .. second], overflow);
				read.overflow |= overflow;
				i = second;
			}
		}
		++i;
	}
	return read;
}

// SourceInfo's location, its file name interned.
// Null if interning is refused.
private std.typecons.Nullable!(diagnose.LineColumnRange) annotation(ref Parser parser, size_t token) {
	const read = readAnnotation(doir.syntax.lexer.text(parser.tokens[token], parser.source));
	immutable name = intern(parser, read.file);
	if (name == doir.strings.refused) return typeof(return).init;
	return typeof(return)(diagnose.LineColumnRange(doir.strings.text(*parser.strings, name),
		diagnose.LineColumn(cast(size_t) read.values[0], cast(size_t) read.values[2]), diagnose.LineColumn(cast(size_t) read.values[1], cast(size_t) read.values[3])));
}

// What an assignment's value parsed into, for `assignment` to describe.
private struct ParsedValue {
	ParsedConstant constant;
	ParsedCall call;
	uint reference = noToken;
}

// assignment_value after the declared type: `=` and a constant, block, call, reference or function type, into `out_`, or `Value.none` with the position back where it was.
// Refusal sets `parser.refused`.
private Value assignmentValue(ref Parser parser, EntityId e, ParsedType declared, uint declStart, ref ParsedValue out_) {
	immutable beforeValue = parser.pos;
	skipBlank(parser);
	parser.where = Reading.afterType;
	if (!currentIs(parser, TokenKind.equals)) {
		parser.pos = beforeValue;
		return Value.none;
	}
	Value value = Value.none;
	++parser.pos;
	skipBlank(parser);
	parser.where = Reading.value;
	auto parsedConstant = constant(parser);
	if (!parsedConstant.isNull) {
		out_.constant = parsedConstant.get;
		value = Value.constant;
	} else if (block(parser)) value = Value.block;
	else if (functionCall(parser, out_.call)) value = Value.call;
	else if (currentIs(parser, TokenKind.identifier)) {
		out_.reference = cast(uint) parser.pos++;
		value = Value.reference;
	} else if (parser.tokens[parser.pos].kind == TokenKind.leftParen) {
		if (parser.description is null) {
			if (functionType(parser, invalidEntity, 0)) value = Value.functionType;
		} else if (validates!(q => functionType(q, invalidEntity, 0))(parser)) {
			if (!withType!(t => record(parser, Write(kind: Write.Kind.functionType, target: e, type: t)))(parser, declared)) {
				cast(void) refuse(parser);
				return Value.none;
			}
			if (!functionType(parser, e, declStart)) {
				assert(parser.refused, "doir.parser: a validated function type did not build");
				return Value.none;
			}
			value = Value.functionType;
		}
	}
	if (parser.refused) return Value.none;
	if (value == Value.none) parser.pos = beforeValue;
	else if (value != Value.call) skipTrivia(parser);
	return value;
}

// Fills skimmed record `r`, the assignment from token `first` to `terminator`, named by token `name`, its source annotation token `info` checked (`AT-Source`).
private void fillRecord(ref Parser parser, uint r, uint first, uint terminator, uint name, uint info, size_t spanStart, size_t spanEnd) {
	if (info != noToken && readAnnotation(doir.syntax.lexer.text(parser.tokens[info], parser.source)).overflow)
		error(parser, SyntaxError.Kind.literal, parser.tokens[info].start, info, "AT-Source: a source annotation's lines and columns must fit in 64 bits", "write the line and column where the declaration is in its file");
	auto record = &parser.syntax.records[r];
	record.first = first;
	record.terminator = terminator;
	record.end = cast(uint) fp.dynarray.length(parser.syntax.records);
	record.name = doir.syntax.lexer.text(parser.tokens[name], parser.source) == "_" ? unnamed : name;
	record.spanStart = cast(uint) spanStart;
	record.spanEnd = cast(uint) spanEnd;
	record.hash = hashTokens(hashStart, *parser.syntax, parser.source, record.first, record.terminator, r + 1 < record.end ? r + 1 : noToken);
}

// Records what building the assignment `e` writes: its value as `value` parsed into `parsed`, its `export` flag and its source annotation `info`.
// False on refusal.
private bool describeAssignment(ref Parser parser, EntityId e, Value value, ParsedType declared, ref ParsedValue parsed, bool exported, uint info) {
	bool ok = true;
	final switch (value) {
		case Value.none:
			ok = withType!(t => record(parser, Write(kind: Write.Kind.valueless, target: e, type: t)))(parser, declared);
			break;
		case Value.constant:
			ok = withType!((t) {
				auto write = Write(kind: Write.Kind.constant, target: e, type: t);
				write.value = parsed.constant.value;
				return record(parser, write);
			})(parser, declared);
			break;
		case Value.block:
			if (isName(parser, declared, "namespace")) ok = record(parser, Write(kind: Write.Kind.namespace, target: e));
			else if (isName(parser, declared, "type")) ok = withType!(t => record(parser, Write(kind: Write.Kind.aggregate, target: e, type: t)))(parser, declared);
			else ok = withType!(t => record(parser, Write(kind: Write.Kind.block, target: e, type: t)))(parser, declared);
			break;
		case Value.call:
			immutable from = cast(uint) fp.dynarray.length(parser.description.arguments);
			foreach (a; fp.dynarray.slice(parsed.call.arguments)) {
				immutable argument = intern(parser, a);
				if (argument == doir.strings.refused || !fp.dynarray.pushBack(parser.description.arguments, argument)) return refuse(parser);
			}
			immutable callee = intern(parser, parsed.call.callee);
			if (callee == doir.strings.refused) return false;
			ok = withType!((t) {
				auto write = Write(kind: Write.Kind.call, target: e, type: t, name: callee);
				write.from = from;
				write.count = cast(uint) (fp.dynarray.length(parser.description.arguments) - from);
				return record(parser, write);
			})(parser, declared);
			if (ok && parsed.call.flags) {
				auto write = Write(kind: Write.Kind.flags, target: e);
				write.flags = parsed.call.flags;
				ok = record(parser, write);
			}
			break;
		case Value.reference:
			immutable target = intern(parser, parsed.reference);
			if (target == doir.strings.refused) return false;
			if (isName(parser, declared, "alias")) ok = record(parser, Write(kind: Write.Kind.alias_, target: e, name: target));
			else ok = withType!(t => record(parser, Write(kind: Write.Kind.reference, target: e, type: t, name: target)))(parser, declared);
			break;
		case Value.functionType:
			break;
	}
	if (ok && exported) {
		auto write = Write(kind: Write.Kind.flags, target: e);
		write.flags = doir.components.ast.Flags.Export;
		ok = record(parser, write);
	}
	if (!ok) return refuse(parser);
	if (info != noToken) {
		auto location = annotation(parser, info);
		if (location.isNull) return false;
		parser.description.annotation = location.get;
		parser.description.annotated = true;
	}
	return true;
}

// `assignment <- change_language / ('export' _)? Identifier _ ':'_ Type wsc (_ '='_ assignment_value)? (SourceInfo wsc)? Terminator _`
// `assignment_value <- Constant wsc / Block wsc / function_call / Identifier wsc / Type wsc`
private bool assignment(ref Parser parser) {
	immutable start = parser.pos;
	parser.where = Reading.declaration;
	if (atWord(parser, TokenKind.keyword, "language")) return changeLanguage(parser);
	immutable outerDeclaration = parser.declaration;
	parser.declaration = cast(uint) start;
	scope(exit) parser.declaration = outerDeclaration;

	// While skimming, the record is reserved first so it precedes its nested ones.
	immutable outer = parser.record_;
	immutable r = parser.syntax is null ? 0 : cast(uint) fp.dynarray.length(parser.syntax.records);
	if (parser.syntax !is null) {
		if (!fp.dynarray.pushBack(parser.syntax.records, Record.init)) return refuse(parser);
		parser.record_ = r;
	}
	scope(exit) parser.record_ = outer;
	bool fail() {
		parser.pos = start;
		if (parser.syntax !is null) cast(void) fp.dynarray.removeLast(parser.syntax.records, fp.dynarray.length(parser.syntax.records) - r);
		return false;
	}

	immutable e = parser.description is null ? invalidEntity : declarationRef;
	immutable declStart = parser.tokens[start].start;
	bool exported = false;
	if (atWord(parser, TokenKind.keyword, "export")) {
		++parser.pos;
		skipBlank(parser);
		exported = true;
	}
	if (!currentIs(parser, TokenKind.identifier)) return fail();
	immutable name = cast(uint) parser.pos++;
	skipBlank(parser);
	parser.where = Reading.colon;
	if (!currentIs(parser, TokenKind.colon)) return fail();
	++parser.pos;
	skipBlank(parser);
	parser.where = Reading.type;
	auto parsedType = type(parser, e, declStart);
	if (parsedType.isNull) return parser.refused ? false : fail();
	immutable declared = parsedType.get;
	skipTrivia(parser);

	ParsedValue parsed;
	scope(exit) fp.dynarray.free(parsed.call.arguments);
	immutable value = assignmentValue(parser, e, declared, declStart, parsed);
	if (parser.refused) return false;
	parser.where = value == Value.none ? Reading.afterType : Reading.afterValue;

	uint info = noToken;
	if (currentIs(parser, TokenKind.sourceInfo)) {
		info = cast(uint) parser.pos++;
		skipTrivia(parser);
	}
	immutable terminatorKind = parser.tokens[parser.pos].kind;
	if (terminatorKind != TokenKind.newline && terminatorKind != TokenKind.semicolon && terminatorKind != TokenKind.end) {
		note(parser, TokenKind.newline);
		return fail();
	}
	immutable terminator = cast(uint) parser.pos;
	immutable spanEnd = lastEnd(parser, start);
	if (terminatorKind != TokenKind.end) ++parser.pos;
	skipBlank(parser);

	if (parser.syntax !is null) fillRecord(parser, r, cast(uint) start, terminator, name, info, declStart, spanEnd);
	if (parser.description is null) return true;
	return describeAssignment(parser, e, value, declared, parsed, exported, info);
}

// One assignment; while skimming, a failed one is reported and skipped to the next terminator at its brace depth, or its block's end.
private void statement(ref Parser parser) {
	immutable start = parser.pos;
	parser.failed = false;
	parser.tooDeep = false;
	if (assignment(parser) || parser.refused) return;
	// A block that fails where a statement inside it already did adds what it expected there to that error rather than repeating it.
	auto last = parser.syntax is null || fp.dynarray.length(parser.syntax.errors) == 0 ? null : fp.dynarray.back(parser.syntax.errors);
	if (parser.tooDeep) error(parser, SyntaxError.Kind.nesting, parser.tokens[start].start, cast(uint) start);
	else if (last !is null && last.kind == SyntaxError.Kind.syntax && last.token == parser.furthestToken) last.expected |= parser.expected;
	else error(parser, SyntaxError.Kind.syntax, parser.furthest, parser.furthestToken, null, null, parser.expected);

	size_t depth = 0;
	for (;;) {
		immutable t = parser.tokens[parser.pos].kind;
		if (t == TokenKind.end) break;
		if (t == TokenKind.leftBrace) ++depth;
		else if (t == TokenKind.rightBrace) {
			if (depth == 0) break;
			--depth;
		} else if ((t == TokenKind.newline || t == TokenKind.semicolon) && depth == 0) {
			++parser.pos;
			break;
		}
		++parser.pos;
	}
	if (parser.pos == start && parser.tokens[parser.pos].kind != TokenKind.end) ++parser.pos;
	skipBlank(parser);
	assert(parser.pos > start || parser.tokens[parser.pos].kind == TokenKind.end, "doir.parser: a statement that consumed nothing");
}


// --- entry points ------------------------------------------------------------

/// Lexes and parses `source` into `out_`, which must be empty: a record for every declaration that parses, in preorder, and the syntax errors in the rest, each failed declaration skipped to the next terminator at its brace depth so its siblings still parse.
/// Reads nothing but `source`.
/// `depth` is how many blocks enclose `source`, when it is one declaration cut from a file, so `maxNesting` counts them.
///
/// Returns false if allocation fails, leaving `out_` empty.
///
/// Examples:
/// ---
/// static import fp.dynarray;
/// Syntax syntax;
/// scope(exit) free(syntax);
/// assert(skim("a : T = 1\nb : = 2\nc : T = 3\n", syntax));
/// assert(fp.dynarray.length(syntax.records) == 2 && fp.dynarray.length(syntax.errors) == 1);
/// ---
bool skim(const(char)[] source, ref Syntax out_, uint depth = 0) {
	assert(out_.tokens is null && out_.records is null && out_.errors is null);
	out_.tokens = doir.syntax.lexer.lex(source);
	if (out_.tokens is null) return false;
	Parser parser;
	parser.source = source;
	parser.tokens = fp.dynarray.slice(out_.tokens);
	parser.syntax = &out_;
	parser.record_ = uint.max;
	parser.depth = depth;
	skipBlank(parser);
	while (!parser.refused && parser.tokens[parser.pos].kind != TokenKind.end) statement(parser);
	if (!parser.refused) return true;
	free(out_);
	return false;
}

/// Records what `build` would write for record `r` of `syntax`, skimmed from `source`, into `out_`, which must be empty: its type, value, flags, parts and their spans, but not its `Name`, `Parent`, span or nested declarations, which the commit writes.
/// It reads no store and interns names in `strings`, which any thread may do at once, so workers can describe a commit's declarations while it writes the store.
///
/// Returns false if allocation fails, leaving `out_` partly recorded for the caller to free.
///
/// Examples:
/// ---
/// static import fp.dynarray;
/// static import doir.strings;
/// Syntax syntax;
/// scope(exit) free(syntax);
/// immutable source = "f : (a: T) -> U\n";
/// assert(skim(source, syntax));
/// doir.strings.Strings strings;
/// scope(exit) doir.strings.free(strings);
/// Description d;
/// scope(exit) free(d);
/// assert(describe(syntax, source, 0, strings, d));
/// assert(d.parts == 2 && d.writes[0].kind == Write.Kind.inPlaceFunctionType); // the function type and its parameter
/// ---
bool describe(ref const Syntax syntax, const(char)[] source, size_t r, ref doir.strings.Strings strings, ref Description out_) {
	version(unittest) core.atomic.atomicOp!"+="(bc.platform.asShared(builds), 1);
	Parser parser;
	parser.source = source;
	parser.tokens = fp.dynarray.slice(syntax.tokens);
	parser.description = &out_;
	parser.strings = &strings;
	parser.record = &syntax.records[r];
	parser.pos = syntax.records[r].first;
	if (assignment(parser)) return true;
	assert(parser.refused, "doir.parser: a skimmed record did not describe");
	return false;
}

// Calls `f` with `type` as the builders take it, a name or an entity, `parts` resolving a part.
private bool withRef(alias f)(TypeRef type, const(EntityId)[] parts) {
	return type.part == invalidEntity ? f(type.name) : f(parts[type.part - firstPart]);
}

/// Writes `d` into `builder.declaration` through `doir.builders`, making or reusing its parts as `build` does.
/// It must run where the store may be changed, and may not run on several threads at once.
///
/// Returns false if allocation fails, leaving the declaration and `builder.parts` partly built; the parts taken so far are still listed there.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import fp.dynarray;
/// static import doir.strings;
/// static import doir.components.ast;
/// Syntax syntax;
/// scope(exit) free(syntax);
/// immutable source = "x : T = 5\n";
/// assert(skim(source, syntax));
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// doir.strings.Strings strings;
/// scope(exit) doir.strings.free(strings);
/// Description d;
/// scope(exit) free(d);
/// assert(describe(syntax, source, 0, strings, d));
/// Builder b = Builder(&store, &strings, ecrs.context.addEntity(store));
/// scope(exit) fp.dynarray.free(b.parts);
/// assert(apply(d, b));
/// assert(ecrs.context.getComponent!(doir.components.ast.ConstantVal)(store, b.declaration).integerValue == 5);
/// ---
bool apply(ref const Description d, ref Builder builder) @trusted {
	auto store = builder.store;
	foreach (i; 0 .. d.parts) {
		immutable reused = i < builder.reuse.length;
		immutable e = reused ? builder.reuse[i] : ecrs.context.addEntity(*store);
		if (e == invalidEntity) return false;
		if (fp.dynarray.pushBack(builder.parts, e)) continue;
		if (!reused) cast(void) ecrs.context.removeEntity(*store, e); // if refused, an orphan nothing reaches
		return false;
	}
	auto parts = fp.dynarray.slice(builder.parts);
	EntityId entity(EntityId named) {
		return named == declarationRef ? builder.declaration : parts[named - firstPart];
	}
	foreach (write; fp.dynarray.slice(d.writes)) {
		immutable e = entity(write.target);
		bool ok;
		final switch (write.kind) with (Write.Kind) {
			case span:
				// Set rather than written in place: a reused part keeps its span, and the commit's transaction must be able to restore it.
				ok = ecrs.context.setComponent!(doir.components.source.SourceSpan)(*store, e, doir.components.source.SourceSpan(write.from, write.count));
				break;
			case inPlaceFunctionType: ok = withRef!(t => doir.builders.attachInPlaceFunctionType(*store, e, entity(write.other), t))(write.type, parts); break;
			case parameter: ok = withRef!(t => doir.builders.attachParameter(*store, e, entity(write.other), write.name, t))(write.type, parts); break;
			case defaultValue: ok = doir.builders.setDefault(*store, e, write.value); break;
			case defaultName: ok = doir.builders.setDefault(*store, e, write.name); break;
			case returnType: ok = withRef!(t => doir.builders.setReturnType(*store, e, t))(write.type, parts); break;
			case functionType: ok = withRef!(t => doir.builders.attachFunctionType(*store, e, t))(write.type, parts); break;
			case valueless: ok = withRef!(t => doir.builders.attachValueless(*store, e, t))(write.type, parts); break;
			case constant: ok = withRef!(t => doir.builders.attachConstant(*store, e, t, write.value))(write.type, parts); break;
			case namespace: ok = doir.builders.attachNamespace(*store, e).block != invalidEntity; break;
			case aggregate: ok = withRef!(t => doir.builders.attachAggregate(*store, e, t).block != invalidEntity)(write.type, parts); break;
			case block: ok = withRef!(t => doir.builders.attachBlock(*store, e, t).block != invalidEntity)(write.type, parts); break;
			case call: ok = withRef!(t => doir.builders.attachCall(*store, e, t, write.name, d.arguments[write.from .. write.from + write.count]))(write.type, parts); break;
			case alias_: ok = ecrs.context.setComponent!(doir.components.ast.LookupAlias)(*store, e, doir.components.ast.LookupAlias(write.name)); break;
			case reference: ok = withRef!(t => doir.builders.attachReference(*store, e, t, write.name))(write.type, parts); break;
			case flags: ok = doir.builders.addFlags(*store, e, write.flags); break;
		}
		if (!ok) return false;
	}
	builder.annotation = d.annotation;
	builder.annotated = d.annotated;
	return true;
}

/// Writes record `r` of `syntax`, skimmed from `source`, into `builder.declaration` through `doir.builders`: `describe`, then `apply`.
/// Parts reuse `builder.reuse` in order before new entities are made; each gets its `SourceSpan`.
///
/// Returns false if allocation fails, leaving the declaration and `builder.parts` partly built; the parts taken so far are still listed there.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import fp.dynarray;
/// static import doir.strings;
/// static import doir.components.ast;
/// Syntax syntax;
/// scope(exit) free(syntax);
/// immutable source = "f : (a: T) -> U\n";
/// assert(skim(source, syntax));
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// doir.strings.Strings strings;
/// scope(exit) doir.strings.free(strings);
/// Builder b = Builder(&store, &strings, ecrs.context.addEntity(store));
/// scope(exit) fp.dynarray.free(b.parts);
/// assert(build(syntax, source, 0, b));
/// assert(fp.dynarray.length(b.parts) == 2); // the function type and its parameter
/// assert(ecrs.context.getComponent!(doir.components.ast.TypeOf)(store, b.declaration).type == b.parts[0]);
/// ---
bool build(ref const Syntax syntax, const(char)[] source, size_t r, ref Builder builder) {
	Description d;
	scope(exit) free(d);
	return describe(syntax, source, r, *builder.strings, d) && apply(d, builder);
}

/// The components `build` writes, which a rebuild removes first.
/// `Name` and `Parent` are among them, written by the builders on parts and by the commit on declarations.
alias ParsedComponents = imported!"std.meta".AliasSeq!(doir.components.ast.Name, doir.components.ast.Parent, doir.components.ast.Block, doir.components.ast.TypeOf, doir.components.ast.TypeDefinition, doir.components.ast.FunctionInputs, doir.components.ast.FunctionReturn, doir.components.ast.ConstantVal, doir.components.ast.Flags, doir.components.ast.LookupTypeOf, doir.components.ast.LookupFunctionReturn, doir.components.ast.LookupCall, doir.components.ast.LookupFunctionInputs, doir.components.ast.LookupAlias, doir.components.ast.LookupValue, doir.components.source.SourceAnnotation);

/// Removes every component the parse wrote on `e`, leaving what queries produced on it.
///
/// Returns false only inside a store transaction whose journal cannot grow, having removed some of them; the transaction's rollback restores them.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.components.ast;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// immutable e = ecrs.context.addEntity(store);
/// ecrs.context.addComponent!(doir.components.ast.Flags)(store, e).flags = 1;
/// assert(removeParsed(store, e));
/// assert(!ecrs.context.hasComponent!(doir.components.ast.Flags)(store, e));
/// ---
bool removeParsed(ref ecrs.context.Context store, EntityId e) {
	static foreach (C; ParsedComponents)
		if (ecrs.context.hasComponent!C(store, e) && !ecrs.context.removeComponent!C(store, e)) return false;
	return true;
}


version(unittest) {

	/// How many times `build` has run, for tests that a commit builds only what changed.
	package(doir) __gshared size_t builds;

	private struct Built {
		ecrs.context.Context store;
		doir.strings.Strings strings;
		Syntax syntax;
		Builder builder;
	}

	// Skims `source`, which must hold one declaration, and builds it.
	private void buildOne(ref Built b, const(char)[] source) {
		b.store = ecrs.context.create();
		assert(skim(source, b.syntax) && fp.dynarray.length(b.syntax.errors) == 0);
		b.builder = Builder(&b.store, &b.strings, ecrs.context.addEntity(b.store));
		assert(build(b.syntax, source, 0, b.builder));
	}

	private void release(ref Built b) {
		fp.dynarray.free(b.builder.parts);
		free(b.syntax);
		doir.strings.free(b.strings);
		ecrs.context.free(b.store);
	}


	// Builds `source`'s one declaration under every allocation budget until one suffices; each smaller budget must fail cleanly.
	private void buildRationed(const(char)[] source) {
		Built whole;
		scope(exit) release(whole);
		buildOne(whole, source);
		for (size_t budget = 0;; ++budget) {
			Built b;
			scope(exit) release(b);
			b.store = ecrs.context.create();
			assert(skim(source, b.syntax));
			b.builder = Builder(&b.store, &b.strings, ecrs.context.addEntity(b.store));
			auto allocator = fp.testing.limitAllocations(budget);
			immutable built = build(b.syntax, source, 0, b.builder);
			fp.testing.restoreAllocator(allocator);
			if (!built) continue;
			assert(fp.dynarray.length(b.builder.parts) == fp.dynarray.length(whole.builder.parts));
			assert(b.builder.annotated == whole.builder.annotated);
			return;
		}
	}
}

unittest { // skimming: records in preorder, hashes that ignore trivia, and recovery
	static assert(maxNesting >= 256, "IL-Nest: an implementation accepts at least 256 nested blocks and function types");
	Syntax a, b;
	scope(exit) { free(a); free(b); }

	// Nested declarations follow their parent; a parent's hash ignores what is inside its block.
	assert(skim("ns : namespace = {\n\tx : T = 1\n\ty : T\n}\nz : T = 2\n", a));
	assert(skim("ns : namespace = {\n\tx : T = 7 // seven\n\ty : T\n}\nz : T=2;\n", b));
	assert(fp.dynarray.length(a.records) == 4 && a.records[0].end == 3 && a.records[3].end == 4);
	assert(a.records[0].hash == b.records[0].hash && a.records[1].hash != b.records[1].hash);
	assert(a.records[2].hash == b.records[2].hash && a.records[3].hash == b.records[3].hash);
	assert(a.records[2].name != unnamed && a.records[0].blockOpen != noBlock);

	// The span covers the declaration's text, and not its terminator.
	immutable source = "x : T = 5 ; # c\n_ : _ = std.return(x) <f:1:2>\n";
	Syntax c;
	scope(exit) free(c);
	assert(skim(source, c) && fp.dynarray.length(c.records) == 2);
	assert(source[c.records[0].spanStart .. c.records[0].spanEnd] == "x : T = 5");
	assert(source[c.records[1].spanStart .. c.records[1].spanEnd] == "_ : _ = std.return(x) <f:1:2>");
	assert(c.records[1].name == unnamed);

	// Newlines: one ends a declaration after its type or value, not before `=`, `->` or inside `(...)`.
	Syntax d;
	scope(exit) free(d);
	assert(skim("x : T\n= 5\nf : (a: T,\n\tb: U)\n\t-> V\ng : T = h\n(a)\n", d));
	assert(fp.dynarray.length(d.records) == 3 && fp.dynarray.length(d.errors) == 0);

	// A failed declaration is reported where the parse got furthest, and its siblings still parse.
	Syntax e;
	scope(exit) free(e);
	immutable broken = "a : T = 1\nblk : block = {\n\tb : = 2\n\tc : T = 3\n}\nd : T = (x: T\ne : T = 4\n";
	assert(skim(broken, e));
	assert(fp.dynarray.length(e.errors) == 2 && fp.dynarray.length(e.records) == 4);
	assert(e.errors[0].kind == SyntaxError.Kind.syntax && broken[e.errors[0].at] == '=');
	assert(e.records[1].end == 3); // blk keeps c

	// A block's last declaration needs its terminator before `}`.
	Syntax f;
	scope(exit) free(f);
	assert(skim("g : block = { _ : _ = std.return(x) }\nh : block = { _ : _ = std.block_result(x); }\n", f));
	assert(fp.dynarray.length(f.errors) == 1 && fp.dynarray.length(f.records) == 3); // g recovers inside its block; h keeps its inner declaration

	// `language` blocks are skipped and reported; literals the reference cannot hold are reported.
	Syntax g;
	scope(exit) free(g);
	immutable foreign = "language \"c\" { int f() { return 0; } }\nbig : T = 0x10000000000000000\ns : T = \"\\x100\"\nok : T = '\\u00e9'\n";
	assert(skim(foreign, g));
	assert(fp.dynarray.length(g.errors) == 3 && fp.dynarray.length(g.records) == 3);
	assert(g.errors[0].kind == SyntaxError.Kind.language && g.errors[1].kind == SyntaxError.Kind.literal);
	char* message = describe(g, foreign, g.errors[0]);
	scope(exit) fp.string.free(message);
	assert(fp.string.slice(message) == "I-Language: no frontend is registered for language \"c\"");
	char* literal = describe(g, foreign, g.errors[1]);
	scope(exit) fp.string.free(literal);
	char* literalFix = hint(g, foreign, g.errors[1]);
	scope(exit) fp.string.free(literalFix);
	assert(fp.string.slice(literal) == "V-Literal: an integer literal must fit in 64 bits" && fp.string.slice(literalFix) == "write a value below 2^64");

	// A negative integer has one bit fewer for its magnitude, and says so.
	Syntax low;
	scope(exit) free(low);
	immutable belowRange = "small : i64 = -9223372036854775809\n";
	assert(skim(belowRange, low) && fp.dynarray.length(low.errors) == 1 && low.errors[0].kind == SyntaxError.Kind.literal);
	char* lowFix = hint(low, belowRange, low.errors[0]);
	scope(exit) fp.string.free(lowFix);
	assert(fp.string.slice(lowFix) == "write a value at or above -2^63");

	// So are source annotations whose numbers do not fit, in a line or a column, at its start or its end (AT-Source).
	foreach (huge; ["x : T = 1 <a.doir:99999999999999999999:1>\n", "x : T = 1 <\"a\":1:2-99999999999999999999>\n"]) {
		Syntax annotated;
		scope(exit) free(annotated);
		assert(skim(huge, annotated) && fp.dynarray.length(annotated.errors) == 1 && annotated.errors[0].kind == SyntaxError.Kind.literal);
		char* why = describe(annotated, huge, annotated.errors[0]), fix = hint(annotated, huge, annotated.errors[0]);
		scope(exit) { fp.string.free(why); fp.string.free(fix); }
		assert(fp.string.startsWith(why, "AT-Source:") && fp.string.slice(fix) == "write the line and column where the declaration is in its file");
	}


	// Too deep a nesting is reported rather than overflowing the stack.
	char* deep = null;
	scope(exit) fp.string.free(deep);
	foreach (i; 0 .. maxNesting + 1) assert(fp.string.concatenate(deep, "x : T = {\n"));
	Syntax h;
	scope(exit) free(h);
	assert(skim(fp.string.slice(deep), h) && fp.dynarray.length(h.errors) >= 1 && h.errors[0].kind == SyntaxError.Kind.nesting);
	foreach (err; fp.dynarray.slice(h.errors)) assert(err.kind != SyntaxError.Kind.syntax || h.tokens[err.token].kind == TokenKind.end);
	char* nested = describe(h, fp.string.slice(deep), h.errors[0]);
	scope(exit) fp.string.free(nested);
	assert(fp.string.slice(nested) == "IL-Nest: blocks and function types nest too deeply");

	// Every error has a hint; a missing closer names the bracket it would close.
	static bool hinted(ref Syntax syntax, const(char)[] source, size_t i, string expected) {
		char* fix = hint(syntax, source, syntax.errors[i]);
		scope(exit) fp.string.free(fix);
		return fp.string.slice(fix) == expected;
	}
	assert(opening(e, e.errors[0]) == fp.pointer.notFound && hinted(e, broken, 0, "insert a type or `_` here"));
	assert(broken[opening(e, e.errors[1])] == '(' && hinted(e, broken, 1, "insert `)` here to close the `(` left open"));
	assert(hinted(g, foreign, 0, "remove this block, or rewrite it in DOIR") && hinted(g, foreign, 1, "write a value below 2^64"));
	assert(hinted(g, foreign, 2, "keep `\\x` and octal escapes at or below 0xFF, and `\\u` and `\\U` escapes to Unicode scalar values"));
	assert(hinted(h, fp.string.slice(deep), 0, "move some of these blocks or function types into declarations of their own; at most 256 may nest"));
	Syntax lexed;
	scope(exit) free(lexed);
	immutable lexical = "s : T = \"abc\nc : T = /* open";
	assert(skim(lexical, lexed) && fp.dynarray.length(lexed.errors) == 2);
	Syntax cut;
	scope(exit) free(cut);
	immutable unclosed = "ns : namespace = {\n\tf : (x: T\n";
	assert(skim(unclosed, cut) && fp.dynarray.length(cut.errors) == 1 && unclosed[opening(cut, cut.errors[0])] == '(');
	// A closed block counts whole: the `(` it leaves open is not what the file's end needs closed.
	Syntax inner;
	scope(exit) free(inner);
	immutable closedInside = "ns : namespace = {\n\tf : T = {\n\t\tx : T = g(\n\t}\n";
	assert(skim(closedInside, inner) && fp.dynarray.length(inner.errors) == 2);
	assert(opening(inner, inner.errors[1]) == 17);
	assert(hinted(lexed, lexical, 0, "close the string with `\"`, and check that its escapes are valid") && hinted(lexed, lexical, 1, "close the comment with `*/`"));
	static immutable string[2][3] unclosedTokens = [["c : T = 'ab'\n", "close the character with `'`; it holds exactly one character or escape"], ["x : T <\"f.doir\"\n", "finish the source annotation, as in `<\"file.doir\":1:1>`"], ["language \"c\" { x\n", "close the block with `}`"]];
	foreach (token; unclosedTokens) {
		Syntax open;
		scope(exit) free(open);
		assert(skim(token[0], open) && fp.dynarray.length(open.errors) >= 1 && hinted(open, token[0], 0, token[1]));
	}

	// A hint naming exact tokens fixes the error with them, spaced as DOIR is written; one asking the author to choose, or about a literal, offers none.
	static bool fixed(string source, string expected) {
		Syntax syntax;
		scope(exit) free(syntax);
		cast(void) skim(source, syntax);
		const offered = fixes(syntax, source, syntax.errors[0]);
		if (offered.length != 1) return false;
		const f = offered.items[0];
		immutable from = syntax.errors[0].at + f.from, to = syntax.errors[0].at + f.to;
		char* applied = fp.string.joined(source[0 .. from], f.spaceBefore ? " " : "", f.text, f.spaceAfter ? " " : "", source[to .. $]).get(null);
		scope(exit) fp.string.free(applied);
		return fp.string.slice(applied) == expected;
	}
	assert(fixed("stack : namespace {\n}\n", "stack : namespace = {\n}\n") && fixed("x = 5\n", "x : _ = 5\n") && fixed("x : = 5\n", "x : _ = 5\n"));
	assert(fixed("f : (a: T b: T)\n", "f : (a: T, b: T)\n") && fixed("f : (a: T\n", "f : (a: T\n)") && fixed("g : T = f(a b)\n", "g : T = f(a, b)\n"));
	assert(fixed("allocate_t : type = (T: type) - > T\n", "allocate_t : type = (T: type) -> T\n"));
	assert(fixes(lexed, lexical, lexed.errors[0]).length == 0 && fixes(g, foreign, g.errors[1]).length == 0 && fixes(h, fp.string.slice(deep), h.errors[0]).length == 0);
	static immutable string[4] choosings = ["f : (a: )\n", "x : T = \n", "x : T = 1 $\n", "g : T = f(1 2)\n"];
	foreach (choosing; choosings) {
		Syntax syntax;
		scope(exit) free(syntax);
		cast(void) skim(choosing, syntax);
		assert(fp.dynarray.length(syntax.errors) && fixes(syntax, choosing, syntax.errors[0]).length == 0);
	}
	// A list of expected tokens offers each it spells in backquotes, in order, and none of the kinds it names in words.
	Syntax start;
	scope(exit) free(start);
	immutable stray = "( x\n";
	cast(void) skim(stray, start);
	auto many = start.errors[0];
	many.expected = 1u << TokenKind.identifier | 1u << TokenKind.equals | 1u << TokenKind.comma;
	const offered = fixes(start, stray, many);
	assert(offered.length == 2 && offered.items[0].text == "=" && offered.items[1].text == "," && offered.items[0].from == 0 && !offered.items[0].spaceBefore && offered.items[0].spaceAfter);

	// The kinds a parse expected are listed in order, the five constant kinds as one, and every kind a rule expects has a name.
	static bool listed(uint expected, string listing) {
		char* fix = expectedHint(expected);
		scope(exit) fp.string.free(fix);
		return fp.string.slice(fix) == listing;
	}
	assert(listed(1u << TokenKind.string_, "insert a string here") && listed(constantKinds | 1u << TokenKind.identifier, "insert a name or a constant here"));
	assert(listed(1u << TokenKind.newline | 1u << TokenKind.keyword | 1u << TokenKind.colon | 1u << TokenKind.equals, "insert a line break, `:` or `=` here")); // a keyword only when nothing else fits
	assert(listed(1u << TokenKind.keyword, "insert a keyword here") && listed(1u << TokenKind.sourceInfo | 1u << TokenKind.end, "insert a source annotation here"));
	assert(listed(1u << TokenKind.comma | 1u << TokenKind.leftParen | 1u << TokenKind.rightParen | 1u << TokenKind.leftBrace | 1u << TokenKind.rightBrace, "insert `,`, `(`, `)`, `{` or `}` here"));
	assert(listed(1u << TokenKind.arrow | 1u << TokenKind.sourceInfo | 1u << TokenKind.languageBody, "insert `->` or a braced block here"));

	// What the parse was reading shapes the message, picks one fix where it is plain, and explains with the declaration's own text.
	static immutable string[4][8] contexts = [
		["stack : namespace {\n}\n", "syntax error, unexpected '{' after the declared type", "insert `=` here", "`stack : namespace = {`"],
		["x : T 5\n", "syntax error, unexpected '5' after the declared type", "insert `=` here", "`x : T = 5`"],
		["x = 5\n", "syntax error, unexpected '=' after the declaration's name", "insert `: _` here", "`count : _ = 5`"],
		["x : T =\n", "syntax error, the file ends where the value after `=` should be", "insert a value here, such as `0`, a name or a block in braces", "leave out the `=`"],
		["f : (a: T b: T)\n", "syntax error, unexpected 'b' after a parameter", "insert `,` here", "`(a: std.u8, b: std.u8)`"],
		["y : T = add(1, b)\n", "syntax error, unexpected '1' in a call's arguments", "replace this constant with the name of a declaration that holds it", "declare it first"],
		["ns : namespace = {\n", "syntax error, the file ends inside a block", "insert `}` here to close the `{` left open", "Every `{` needs a matching `}`"],
		["f : (T: type) - > T\n", "syntax error, the arrow `->` is split by a space", "remove the space between `-` and `>`", "`->` written together"],
	];
	foreach (context; contexts) {
		Syntax k;
		scope(exit) free(k);
		assert(skim(context[0], k) && fp.dynarray.length(k.errors) == 1);
		char* said = describe(k, context[0], k.errors[0]);
		char* note = explain(k, context[0], k.errors[0]);
		scope(exit) { fp.string.free(said); fp.string.free(note); }
		assert(fp.string.slice(said) == context[1] && hinted(k, context[0], 0, context[2]) && fp.string.contains(fp.string.slice(note), context[3], 0));
		assert((opening(k, k.errors[0]) == fp.pointer.notFound) == (context[2][$ - 9 .. $] != "left open")); // a pointed fix outranks closing the bracket
	}
	assert(listed(1u << TokenKind.end, "remove everything from here to the end of the file") && listed(1u << TokenKind.end | 1u << TokenKind.newline, "insert a line break here"));
	for (size_t budget = 0;; ++budget) {
		auto allocator = fp.testing.limitAllocations(budget);
		char* fix = expectedHint(1u << TokenKind.comma | 1u << TokenKind.rightParen);
		fp.testing.restoreAllocator(allocator);
		scope(exit) fp.string.free(fix);
		if (fix !is null) {
			assert(fp.string.slice(fix) == "insert `,` or `)` here");
			break;
		}
	}

	// Nesting, an inexact constant and a missing return type each explain themselves.
	static bool explained(const(char)[] source, string part) {
		Syntax x;
		scope(exit) free(x);
		assert(skim(source, x) && fp.dynarray.length(x.errors) >= 1);
		char* note = explain(x, source, x.errors[0]);
		scope(exit) fp.string.free(note);
		return fp.string.contains(fp.string.slice(note), part, 0);
	}
	assert(explained(fp.string.slice(deep), "keeps the nesting shallow") && explained("big : u64 = 99999999999999999999\n", "stores every constant exactly"));
	assert(explained("f : (a: T) ->\n", "After `->` comes the type the function returns"));

	// A stray `}` at the root is skipped.
	Syntax i;
	scope(exit) free(i);
	assert(skim("}\nx : T\n", i) && fp.dynarray.length(i.errors) == 1 && fp.dynarray.length(i.records) == 1);

	// Lists that stop partway do not parse: `deduced` without `type`, `=` without a default, and a trailing comma.
	Syntax j;
	scope(exit) free(j);
	assert(skim("a : (x: deduced y) -> T\nb : (x: T = ) -> T\nc : (x: T, ) -> T\nd : T = f(x, )\nok : T\n", j));
	assert(fp.dynarray.length(j.errors) == 4 && fp.dynarray.length(j.records) == 1);

	// Recovery skips a failed declaration's braces whole.
	Syntax k;
	scope(exit) free(k);
	assert(skim("x : = { y }\nz : T\n", k) && fp.dynarray.length(k.errors) == 1 && fp.dynarray.length(k.records) == 1);

	// A refused allocation at any step fails the skim and leaves the syntax empty; budgets cover every step.
	immutable everything = "w : f64 = 2.50000000000000000000000000000000000000000000000000000000000000000000\nlanguage \"c\" { x }\nblk : block = {\n\tb : = 2\n\ts : p = \"a\\tb\"\n\tc : T = tail f(x, y) <\"g.doir\":1:2>\n}\nf : (a: T, b: deduced type) -> (c: U) -> V\nbig : u64 = 99999999999999999999\n";
	Syntax whole;
	scope(exit) free(whole);
	assert(skim(everything, whole) && fp.dynarray.length(whole.errors) == 3);
	for (size_t budget = 0;; ++budget) {
		Syntax rationed;
		scope(exit) free(rationed);
		auto allocator = fp.testing.limitAllocations(budget);
		immutable skimmed = skim(everything, rationed);
		fp.testing.restoreAllocator(allocator);
		if (skimmed) {
			assert(fp.dynarray.length(rationed.records) == fp.dynarray.length(whole.records) && fp.dynarray.length(rationed.errors) == fp.dynarray.length(whole.errors));
			break;
		}
		assert(rationed.tokens is null && rationed.records is null && rationed.errors is null);
	}
}

unittest { // building: each declaration form writes its builder components
	{
		// An unclosed block after a line break leaves the declaration valueless, and building it agrees with the skim.
		Built b;
		scope(exit) release(b);
		immutable source = "n : e\n= {";
		b.store = ecrs.context.create();
		assert(skim(source, b.syntax) && fp.dynarray.length(b.syntax.records) == 1 && fp.dynarray.length(b.syntax.errors) == 1);
		b.builder = Builder(&b.store, &b.strings, ecrs.context.addEntity(b.store));
		assert(build(b.syntax, source, 0, b.builder));
		assert(!ecrs.context.hasComponent!(doir.components.ast.Block)(b.store, b.builder.declaration));
	}
	{
		Built b;
		scope(exit) release(b);
		buildOne(b, "export six : std.u8 = 6\n");
		assert(ecrs.context.getComponent!(doir.components.ast.ConstantVal)(b.store, b.builder.declaration).integerValue == 6);
		assert(ecrs.context.getComponent!(doir.components.ast.Flags)(b.store, b.builder.declaration).flags == (doir.components.ast.Flags.Comptime | doir.components.ast.Flags.Export));
		assert(doir.strings.text(b.strings, ecrs.context.getComponent!(doir.components.ast.LookupTypeOf)(b.store, b.builder.declaration).name) == "std.u8");
	}
	{
		// Negative constants keep their sign, as a two's-complement integer or a negative float.
		Built b;
		scope(exit) release(b);
		buildOne(b, "negative : i32 = -42\n");
		auto value = ecrs.context.getComponent!(doir.components.ast.ConstantVal)(b.store, b.builder.declaration);
		assert(value.kind == doir.components.ast.ConstantVal.Kind.negativeInteger && value.integerValue == ulong.max - 41);
	}
	{
		Built b;
		scope(exit) release(b);
		buildOne(b, "negative : f64 = -1.5\n");
		auto value = ecrs.context.getComponent!(doir.components.ast.ConstantVal)(b.store, b.builder.declaration);
		assert(value.kind == doir.components.ast.ConstantVal.Kind.float_ && value.floatValue == -1.5);
	}
	{
		Built b;
		scope(exit) release(b);
		buildOne(b, "s : p = \"a\\tb\\u00e9\" <\"gen.doir\":3-4:5>\n");
		auto bytes = ecrs.context.getComponent!(doir.components.ast.ConstantVal)(b.store, b.builder.declaration).bytesValue;
		assert(doir.strings.text(b.strings, bytes) == "a\tb\xC3\xA9");
		assert(b.builder.annotated && b.builder.annotation.file == "gen.doir");
		assert(b.builder.annotation.start == diagnose.LineColumn(3, 5) && b.builder.annotation.end == diagnose.LineColumn(4, 5));
	}
	{
		Built b;
		scope(exit) release(b);
		buildOne(b, "r : p = \"\"\"raw \\n\"\"\" ; c : u = 'x'\n");
		assert(doir.strings.text(b.strings, ecrs.context.getComponent!(doir.components.ast.ConstantVal)(b.store, b.builder.declaration).bytesValue) == "raw \\n");
	}
	{
		Built b;
		scope(exit) release(b);
		buildOne(b, `e : p = "\a\b\f\n\r\v\"\?\\\%"` ~ "\n");
		assert(doir.strings.text(b.strings, ecrs.context.getComponent!(doir.components.ast.ConstantVal)(b.store, b.builder.declaration).bytesValue) == "\a\b\f\n\r\v\"?\\%");
	}
	{
		// A float, and an unquoted source annotation.
		Built b;
		scope(exit) release(b);
		buildOne(b, "h : f32 = 1.5 <f.doir:7:2>\n");
		auto value = ecrs.context.getComponent!(doir.components.ast.ConstantVal)(b.store, b.builder.declaration);
		assert(value.kind == doir.components.ast.ConstantVal.Kind.float_ && value.floatValue == 1.5);
		assert(b.builder.annotation.file == "f.doir" && b.builder.annotation.start == diagnose.LineColumn(7, 2));
	}
	{
		// A float longer than the stack buffer.
		Built b;
		scope(exit) release(b);
		buildOne(b, "w : f64 = 2.50000000000000000000000000000000000000000000000000000000000000000000\n");
		assert(ecrs.context.getComponent!(doir.components.ast.ConstantVal)(b.store, b.builder.declaration).floatValue == 2.5);
	}
	{
		// V-Literal: a float too large for a double rounds to the nearest, an infinity, rather than failing.
		Built b;
		scope(exit) release(b);
		buildOne(b, "i : f64 = -1e999\n");
		assert(ecrs.context.getComponent!(doir.components.ast.ConstantVal)(b.store, b.builder.declaration).floatValue == -double.infinity);
	}
	{
		Built b;
		scope(exit) release(b);
		buildOne(b, "sum : std.u8 = tail std.add(a, %\"b c\")\n");
		assert(doir.strings.text(b.strings, ecrs.context.getComponent!(doir.components.ast.LookupCall)(b.store, b.builder.declaration).name) == "std.add");
		auto args = ecrs.context.getComponent!(doir.components.ast.LookupFunctionInputs)(b.store, b.builder.declaration).names.p;
		assert(fp.dynarray.length(args) == 2 && doir.strings.text(b.strings, args[1]) == "b c");
		assert(ecrs.context.getComponent!(doir.components.ast.Flags)(b.store, b.builder.declaration).flags == doir.components.ast.Flags.Tail);
	}
	{
		Built b;
		scope(exit) release(b);
		buildOne(b, "color : alias = vec3\n");
		assert(ecrs.context.hasComponent!(doir.components.ast.LookupAlias)(b.store, b.builder.declaration));
		assert(!ecrs.context.hasComponent!(doir.components.ast.LookupTypeOf)(b.store, b.builder.declaration));
	}
	{
		Built b;
		scope(exit) release(b);
		buildOne(b, "x : T = y\n");
		assert(doir.strings.text(b.strings, ecrs.context.getComponent!(doir.components.ast.LookupValue)(b.store, b.builder.declaration).name) == "y");
	}
	{
		// A named function type: the declaration is the function type; a deduced parameter, a default, and a function-typed parameter.
		Built b;
		scope(exit) release(b);
		buildOne(b, "id_t : type = (T: deduced type, v: T = 0, f: (x: T) -> T, _: u8 = z) -> T\n");
		immutable e = b.builder.declaration;
		auto inputs = ecrs.context.getComponent!(doir.components.ast.FunctionInputs)(b.store, b.builder.declaration).related;
		assert(fp.dynarray.length(inputs) == 4);
		assert(doir.strings.text(b.strings, ecrs.context.getComponent!(doir.components.ast.LookupTypeOf)(b.store, inputs[0]).name) == doir.components.ast.deducedTypeName);
		assert(ecrs.context.getComponent!(doir.components.ast.ConstantVal)(b.store, inputs[1]).integerValue == 0);
		immutable functionType = ecrs.context.getComponent!(doir.components.ast.TypeOf)(b.store, inputs[2]).type;
		assert(ecrs.context.getComponent!(doir.components.ast.Parent)(b.store, functionType).parent == e);
		assert(!ecrs.context.hasComponent!(doir.components.ast.Name)(b.store, inputs[3]));
		assert(doir.strings.text(b.strings, ecrs.context.getComponent!(doir.components.ast.LookupValue)(b.store, inputs[3]).name) == "z");
		assert(doir.strings.text(b.strings, ecrs.context.getComponent!(doir.components.ast.LookupFunctionReturn)(b.store, b.builder.declaration).name) == "T");
		// Parts come parents first: the parameters, and the function type before its own parameter.
		assert(fp.dynarray.length(b.builder.parts) == 6 && b.builder.parts[3] == functionType);
		auto span = ecrs.context.getComponent!(doir.components.source.SourceSpan)(b.store, inputs[1]);
		assert(b.syntax.tokens !is null);
		immutable source = "id_t : type = (T: deduced type, v: T = 0, f: (x: T) -> T, _: u8 = z) -> T\n";
		assert(source[span.offset .. span.offset + span.length] == "v: T = 0");
	}
	{
		// A function with its type in place, and its body skipped: nested declarations build from their own records.
		Built b;
		scope(exit) release(b);
		buildOne(b, "f : (a: T) -> U = {\n\t_ : _ = std.return(a)\n}\n");
		immutable e = b.builder.declaration;
		assert(ecrs.context.hasComponent!(doir.components.ast.Block)(b.store, e));
		assert(fp.dynarray.length(ecrs.context.getComponent!(doir.components.ast.Block)(b.store, b.builder.declaration).related) == 0);
		assert(ecrs.context.getComponent!(doir.components.ast.TypeOf)(b.store, b.builder.declaration).type == b.builder.parts[0]);
	}
	{
		Built b;
		scope(exit) release(b);
		buildOne(b, "vec : type = {\n\tx : f32\n}\n");
		assert(ecrs.context.hasComponent!(doir.components.ast.TypeDefinition)(b.store, b.builder.declaration));
	}
	{
		Built b;
		scope(exit) release(b);
		buildOne(b, "m : namespace = {\n}\n");
		assert(ecrs.context.getComponent!(doir.components.ast.Flags)(b.store, b.builder.declaration).flags == doir.components.ast.Flags.Namespace);
		assert(removeParsed(b.store, b.builder.declaration));
		assert(!ecrs.context.hasComponent!(doir.components.ast.Flags)(b.store, b.builder.declaration));
	}

	// A refused allocation at any step of any form fails the build, rather than asserting or writing through a missing component.
	foreach (source; [
		"export six : std.u8 = 6\n",
		"negative : i32 = -42\n",
		"s : p = \"a\\tb\\u00e9\" <\"gen.doir\":3-4:5>\n",
		"r : p = \"\"\"raw\"\"\"\n",
		"w : f64 = 2.50000000000000000000000000000000000000000000000000000000000000000000\n",
		"sum : std.u8 = tail std.add(a, %\"b c\")\n",
		"color : alias = vec3\n",
		"x : T = y\n",
		"id_t : type = (T: deduced type, v: T = 0, f: (x: T) -> T, _: u8 = z) -> T\n",
		"f : (a: T) -> U = {\n\t_ : _ = std.return(a)\n}\n",
		"curried : (a: T) -> (b: U) -> V\n",
		"vec : type = {\n}\n",
		"m : namespace = {\n}\n",
	]) buildRationed(source);
}
