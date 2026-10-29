/// The recursive-descent parser over the lexer's tokens (`roadmap.md` Phase 2), its rules named as `doir.peg`'s so the two can be diffed: `_` skips newlines and trivia, `wsc` trivia only, and each rule restores the token position when it fails, as PEG does.
///
/// It runs in two modes. `skim` parses a whole file into one `Record` per declaration, in preorder, with the declaration's tokens and its hash, and the syntax errors it recovered from; it reads only the tokens, so files can be skimmed in parallel. `build` parses one record's tokens again and writes its components through `doir.builders`, skipping its nested block, whose declarations have records of their own. The input commit (`doir.source`) matches records against the previous parse and builds only the ones that are new or changed.
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

static import core.stdc.stdlib;
static import core.stdc.string;
static import std.typecons;

static import fp.dynarray;
static import fp.fnv1a;
static import fp.pointer;
static import fp.string;

static import diagnose;
static import ecrs.context;

static import doir.strings;
static import doir.builders;
static import doir.components;
static import doir.engine.locations;
static import doir.syntax.lexer;

public import ecrs.registry : EntityId, invalidEntity;
public import doir.syntax.lexer : Token, TokenKind;

@nogc nothrow:


// --- types and layout --------------------------------------------------------

/// The token index that names no token.
enum uint noToken = uint.max;

/// How deeply blocks and function types may nest before the parser reports it rather than recurse further.
enum uint maxNesting = 256;

/// One parsed declaration: where its tokens are, the records of the declarations nested in its block, and its hash.
struct Record {
	uint first; /// The index of its first token.
	uint terminator; /// The index of its `Terminator` token (a newline, `;` or the `end`).
	uint end; /// The index of the record after its last nested one; its nested records are those between it and `end`.
	uint name = noToken; /// The index of its name token, or `noToken` for `_`.
	uint blockOpen = noToken; /// The `{` of its block value, or `noToken`.
	uint blockClose = noToken; /// The `}` of its block value, or `noToken`.
	uint spanStart; /// The byte offset of its first token.
	uint spanEnd; /// The byte offset after its last token before the terminator.
	ulong hash; /// Its non-trivia tokens, its nested declarations each replaced by a placeholder, and its terminator left out.
}

/// Which part of a declaration the parser was reading when a syntax error stopped it, so the error can say what belongs there.
enum Where : ubyte {
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
	Where where; /// For `syntax`, what the parse was reading at `at`.
	uint declaration = noToken; /// For `syntax`, the first token of the declaration being read, or `noToken`.
}

/// A skimmed file: its tokens, its records in preorder and its syntax errors. Plain data, released by `free`.
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
			if (t.kind == TokenKind.end) return fp.string.createFromConcatenation("syntax error, the file ends ", where);
			if (t.kind == TokenKind.newline) return fp.string.createFromConcatenation("syntax error, the line ends ", where);
			if (t.kind == TokenKind.unterminated) return fp.string.makeDynamic(unclosed[t.attempted] ? unclosed[t.attempted] : "syntax error, this token is never finished");
			if (splitArrow(syntax, source, error)) return fp.string.makeDynamic("syntax error, the arrow `->` is split by a space");
			if (t.kind == TokenKind.invalid) return fp.string.makeDynamic("syntax error, DOIR has no use for this character");
			auto spelled = doir.syntax.lexer.text(t, source);
			if (spelled.length > 32) spelled = spelled[0 .. 32];
			return fp.string.createFromConcatenation("syntax error, unexpected '", spelled, "' ", where);
		case SyntaxError.Kind.nesting:
			return fp.string.makeDynamic("blocks and function types nest too deeply");
		case SyntaxError.Kind.language:
			return fp.string.createFromConcatenation("I-Language: no frontend is registered for language ", doir.syntax.lexer.text(syntax.tokens[error.token], source));
		case SyntaxError.Kind.literal:
			return fp.string.makeDynamic(error.message);
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
		case Where.afterType:
			return startsValue(unexpected) && (error.expected & (1u << TokenKind.equals)) ? "insert `=` here" : null;
		case Where.type, Where.returnType:
			return error.expected & (1u << TokenKind.identifier) ? "insert a type or `_` here" : null;
		case Where.parameterType:
			return error.expected & (1u << TokenKind.identifier) ? "insert a type here" : null;
		case Where.value:
			return ended ? "insert a value here, such as `0`, a name or a block in braces" : "replace this with a value: a constant, a name, a call, a block or a function type";
		case Where.colon:
			return unexpected == TokenKind.equals ? "insert `: _` here" : null;
		case Where.afterParameter:
			return unexpected == TokenKind.identifier && sameLine ? "insert `,` here" : null;
		case Where.callArgument:
			if (unexpected == TokenKind.identifier && sameLine) return "insert `,` here";
			return constantKinds & (1u << unexpected) ? "replace this constant with the name of a declaration that holds it" : null;
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
	size_t depth = 0;
	for (size_t i = error.token; i-- > 0;) {
		immutable t = syntax.tokens[i];
		if (t.kind == TokenKind.rightBrace || t.kind == TokenKind.rightParen) ++depth;
		else if (t.kind == TokenKind.leftBrace || t.kind == TokenKind.leftParen) {
			if (depth) {
				--depth;
				continue;
			}
			immutable closer = t.kind == TokenKind.leftBrace ? TokenKind.rightBrace : TokenKind.rightParen;
			return error.expected & (1u << closer) ? t.start : fp.pointer.notFound;
		}
	}
	return fp.pointer.notFound;
}

// What a hint calls each token kind, or null if no rule expects it. Tables, not switches: the lexer and `note` never produce some kinds.
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

// Where each `Where` is, as a message ends: "unexpected '{' after the declared type".
private immutable string[Where.max + 1] whereText = [
	Where.declaration: "where a declaration should start",
	Where.colon: "after the declaration's name",
	Where.type: "where the declared type should be",
	Where.afterType: "after the declared type",
	Where.value: "where the value after `=` should be",
	Where.afterValue: "after the declaration's value",
	Where.parameter: "in a parameter list",
	Where.parameterColon: "after a parameter's name",
	Where.parameterType: "where a parameter's type should be",
	Where.afterParameter: "after a parameter",
	Where.parameterDefault: "where a parameter's default value should be",
	Where.returnType: "where the return type after `->` should be",
	Where.callArgument: "in a call's arguments",
	Where.block: "inside a block",
	Where.language: "in a `language` block",
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
		if (auto name = spelling[kind]) names[n++] = name;
	}
	if (allConstants) names[n++] = "a constant";
	if (n == 0) return fp.string.makeDynamic(expected & (1u << TokenKind.end) ? "remove everything from here to the end of the file" : "remove this, or finish the declaration before it");
	char* out_ = fp.string.makeDynamic("insert ");
	bool ok = out_ !is null;
	foreach (i; 0 .. n)
		ok = ok && (i == 0 || fp.string.concatenate(out_, i + 1 == n ? " or " : ", ") !is null) && fp.string.concatenate(out_, names[i]) !is null;
	if (ok && fp.string.concatenate(out_, " here") !is null) return out_;
	fp.string.free(out_);
	return null;
}

/// Writes how to fix `error` in `syntax`, parsed from `source`, to `out_`, a new fp string, or null if allocation fails. A diagnostic draws it at `error.at`.
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
			if (t.kind == TokenKind.unterminated) return fp.string.makeDynamic(closing[t.attempted] ? closing[t.attempted] : "finish or remove this token");
			if (splitArrow(syntax, source, error)) return fp.string.makeDynamic("remove the space between `-` and `>`");
			if (t.kind == TokenKind.invalid) return fp.string.makeDynamic("remove this character; no token starts with it");
			if (auto specific = contextHint(syntax, error)) return fp.string.makeDynamic(specific);
			immutable open = opening(syntax, error);
			if (open != fp.pointer.notFound) return fp.string.createFromConcatenation("insert `", source[open] == '{' ? "}" : ")", "` here to close the `", source[open .. open + 1], "` left open");
			return expectedHint(error.expected);
		case SyntaxError.Kind.nesting:
			return fp.string.format("move some of these blocks or function types into declarations of their own; at most %u may nest", maxNesting);
		case SyntaxError.Kind.language:
			return fp.string.makeDynamic("remove this block, or rewrite it in DOIR");
		case SyntaxError.Kind.literal:
			return fp.string.makeDynamic(error.fix);
	}
}

// `source` from declaration `first` to `at`, the part an example rewrites, or null when it is too long or spans lines to quote.
private const(char)[] writtenSoFar(ref const Syntax syntax, const(char)[] source, uint first, uint at) {
	if (first == noToken) return null;
	auto written = source[syntax.tokens[first].start .. at];
	while (written.length && (written[$ - 1] == ' ' || written[$ - 1] == '\t')) written = written[0 .. $ - 1];
	if (written.length == 0 || written.length > 48 || fp.string.contains(written, "\n", 0)) return null;
	return written;
}

/// Writes an explanation of `error` in `syntax`, parsed from `source`, for someone new to DOIR, to a new fp string: how DOIR writes what the parse was reading, with an example, quoting the declaration where that helps. A diagnostic shows it as its closing note, after the hint. Returns null if allocation fails.
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
			return fp.string.makeDynamic("Each block or function type written inside another adds a level. Declaring the inner ones separately, under names of their own, keeps the nesting shallow.");
		case SyntaxError.Kind.language:
			return fp.string.makeDynamic("A `language` block holds code in another language for a frontend to translate into DOIR, and this compiler has no frontend for that language.");
		case SyntaxError.Kind.literal:
			return fp.string.makeDynamic("DOIR stores every constant exactly, so a constant it cannot store exactly is an error rather than being rounded or cut short.");
	}
	immutable t = syntax.tokens[error.token];
	if (t.kind == TokenKind.unterminated) return fp.string.makeDynamic("Everything from where it starts to the end of the file was read as part of it, so errors reported after it may go away once it is closed.");
	if (splitArrow(syntax, source, error)) return fp.string.makeDynamic("An arrow is the two characters `->` written together, as in `(a: std.u8) -> std.u8`. With a space between them, DOIR reads `-` and `>` as two characters, and neither means anything alone.");
	if (t.kind == TokenKind.invalid) return fp.string.makeDynamic("DOIR code is made of names, constants, comments and the punctuation `:`, `=`, `,`, `(`, `)`, `{`, `}`, `->` and `;`. A stray character is often left over from another language or from pasted text.");
	final switch (error.where) {
		case Where.declaration:
			return fp.string.makeDynamic("Each line of DOIR declares one name, written `name : type = value`, as in `count : std.u8 = 5`; the `= value` part is optional. A line starts with the name it declares.");
		case Where.colon:
			if (t.kind == TokenKind.equals) return fp.string.makeDynamic("Every declaration names its type between its name and `=`, as in `count : std.u8 = 5`. Write `_` as the type to have the compiler work it out: `count : _ = 5`.");
			return fp.string.makeDynamic("A declaration's name is followed by `:` and its type, as in `count : std.u8`. A name cannot contain spaces; join words with `_`, as in `item_count`.");
		case Where.type:
			if (t.kind == TokenKind.equals) return fp.string.makeDynamic("Every declaration names its type between `:` and `=`. Write `_` there to have the compiler work the type out, as in `count : _ = 5`.");
			return fp.string.makeDynamic("After `:` comes the declared type: a name such as `std.u8` or `namespace`, or a function type such as `(a: std.u8) -> std.u8`.");
		case Where.afterType:
			if (startsValue(t.kind)) {
				const written = writtenSoFar(syntax, source, error.declaration, error.at);
				const what = t.kind == TokenKind.leftBrace ? "A block in braces is a value, and a declaration's value" : "A declaration's value";
				const next = t.kind == TokenKind.leftBrace ? "{" : doir.syntax.lexer.text(t, source);
				if (written is null || next.length > 32) return fp.string.createFromConcatenation(what, " comes after `=`, as in `count : std.u8 = 5`.");
				return fp.string.createFromConcatenation(what, " comes after `=`: write `", written, " = ", next, "`.");
			}
			return fp.string.makeDynamic("A declaration ends at the end of its line or at `;`. Between its type and its end there can only be `=` and a value, as in `count : std.u8 = 5`; anything else goes on a line of its own.");
		case Where.value:
			return fp.string.makeDynamic("After `=` comes the declaration's value: a constant such as `5` or `\"text\"`, the name of another declaration, a call such as `add(a, b)`, a block in braces, or a function type. To declare a name without a value, leave out the `=`.");
		case Where.afterValue:
			return fp.string.makeDynamic("A declaration holds one value and ends at the end of its line or at `;`. Put the next declaration on a line of its own, or separate the two with `;`.");
		case Where.parameter:
			return fp.string.makeDynamic("A function type lists its parameters between `(` and `)`, each written `name : type` and separated by `,`, as in `(a: std.u8, b: std.u8) -> std.u8`; `()` takes none.");
		case Where.parameterColon:
			return fp.string.makeDynamic("Each parameter is written `name : type`, as in `(count: std.u8)`, so its name needs `:` and a type after it.");
		case Where.parameterType:
			return fp.string.makeDynamic("A parameter's type follows its `:`, as in `(count: std.u8)`.");
		case Where.afterParameter:
			return fp.string.makeDynamic("Separate parameters with `,` and close the list with `)`, as in `(a: std.u8, b: std.u8)`. A default value follows `=`, as in `(a: std.u8 = 0)`.");
		case Where.parameterDefault:
			return fp.string.makeDynamic("A parameter's default value is a constant or the name of a declaration, as in `(a: std.u8 = 0)`.");
		case Where.returnType:
			return fp.string.makeDynamic("After `->` comes the type the function returns, as in `(a: std.u8) -> std.u8`, or `_` to have the compiler work it out.");
		case Where.callArgument:
			return fp.string.makeDynamic("A call's arguments are names of declarations, separated by `,`, as in `add(a, b)`. To pass a constant, declare it first, as in `five : std.u8 = 5`, and pass `five`.");
		case Where.block:
			return fp.string.makeDynamic("Every `{` needs a matching `}`. The declarations between them belong to the block, one per line or separated by `;`.");
		case Where.language:
			return fp.string.makeDynamic("A `language` block is written `language \"name\" { ... }`: the language's name in quotes, then its code in braces.");
	}
}


// --- literals ----------------------------------------------------------------

private uint hexValue(char c) {
	return c <= '9' ? c - '0' : (c | 0x20) - 'a' + 10;
}

// The `StringChar` at `s[i]`, which the lexer matched: its value, an escaped byte (`\x`, octal) flagged by `isByte`.
private uint stringChar(const(char)[] s, ref size_t i, out bool isByte, out bool overflow) {
	if (s[i] != '\\') {
		bool valid;
		return fp.string.decodeUtf8(s, i, valid);
	}
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
			while (i < s.length && (base == 16 ? fp.string.isHexDigit(s[i]) : (s[i] >= '0' && s[i] <= '7'))) {
				value = value * base + hexValue(s[i++]);
				if (value > 0x10FFFF) overflow = true;
			}
			isByte = true;
			return cast(uint) value;
		case 'u', 'U':
			immutable n = e == 'u' ? 4 : 8;
			uint value = 0;
			foreach (k; 0 .. n) value = value * 16 + hexValue(s[i++]);
			if (value > 0x10FFFF || (value >= 0xD800 && value <= 0xDFFF)) overflow = true;
			return value;
		default: return e; // ' " ? \ %
	}
}

// Decodes `content`'s `StringChar`s, appending UTF-8 to `out_` unless null. Returns the error or null; on a refused append sets `refused` and stops.
private string decodeString(const(char)[] content, char** out_, ref bool refused) {
	size_t i = 0;
	while (i < content.length) {
		immutable start = i;
		bool isByte, overflow;
		immutable value = stringChar(content, i, isByte, overflow);
		if (overflow || (isByte && value > 0xFF)) return "V-Literal: an escape in a string must be a byte or a Unicode scalar value";
		if (out_ is null) continue;
		bool appended;
		if (content[start] != '\\') appended = fp.string.concatenate(*out_, content[start .. i]) !is null;
		else if (isByte || value < 0x80) appended = fp.string.append(*out_, cast(char) value) !is null;
		else appended = fp.string.appendCodepoint(*out_, value) == fp.string.Utf8Error.none;
		if (!appended) {
			refused = true;
			return null;
		}
	}
	return null;
}

// An integer literal's value; `overflow` if it needs more than 64 bits.
private ulong integerValue(const(char)[] s, out bool overflow) {
	uint base = 10;
	size_t i = 0;
	if (s.length > 2 && s[0] == '0' && s[1] == 'x') { base = 16; i = 2; }
	else if (s.length > 2 && s[0] == '0' && s[1] == 'b') { base = 2; i = 2; }
	else if (s.length > 1 && s[0] == '0') { base = 8; i = 1; }
	ulong value = 0;
	for (; i < s.length; ++i) {
		immutable d = hexValue(s[i]);
		if (value > (ulong.max - d) / base) overflow = true;
		value = value * base + d;
	}
	return value;
}

// Null if copying a long literal is refused.
private std.typecons.Nullable!double floatValue(const(char)[] s) @trusted {
	char[64] buffer = void;
	if (s.length < buffer.length) {
		core.stdc.string.memcpy(buffer.ptr, s.ptr, s.length);
		buffer[s.length] = 0;
		return typeof(return)(core.stdc.stdlib.strtod(buffer.ptr, null));
	}
	auto copy = fp.string.makeDynamic(s);
	if (copy is null) return typeof(return).init;
	scope(exit) fp.string.free(copy);
	return typeof(return)(core.stdc.stdlib.strtod(copy, null));
}

// The content of a raw string token, between its delimiters.
private const(char)[] rawContent(const(char)[] s) {
	size_t n = 0;
	while (s[n] == '"') ++n;
	return s[n .. $ - n];
}


/// The interned name an identifier spells: `%"text"` names `text`, its escapes decoded (spec Part I); any other spells itself.
///
/// Returns `noName` if allocation fails, leaving `strings` as it was.
///
/// Examples:
/// ---
/// static import doir.strings;
/// doir.strings.Strings strings;
/// scope(exit) doir.strings.free(strings);
/// assert(nameOf(`%"a b"`, strings) == doir.strings.intern(strings, "a b"));
/// assert(doir.strings.text(strings, nameOf("std.u8", strings)) == "std.u8");
/// ---
doir.strings.StringId nameOf(const(char)[] spelled, ref doir.strings.Strings strings) {
	doir.strings.StringId id;
	if (spelled.length >= 3 && spelled[0] == '%' && spelled[1] == '"') {
		char* decoded = null;
		scope(exit) fp.string.free(decoded);
		bool refused = false;
		cast(void) decodeString(spelled[2 .. $ - 1], &decoded, refused);
		if (refused) return doir.strings.noName;
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
	diagnose.Detailed annotation; /// Out: the declaration's `SourceAnnotation`, if `annotated`.
	bool annotated; /// Out: whether it has one.
}

private struct Parser {
	const(char)[] source;
	const(Token)[] tokens;
	size_t pos;
	uint furthest; // byte offset of the furthest failure in the current statement
	uint furthestToken;
	bool failed; // whether any failure was noted in the current statement
	uint expected; // the kinds tried at `furthest`, as `SyntaxError.expected`
	Where where; // what the rules are reading now
	Where furthestWhere; // what they were reading at `furthest`
	uint declaration = noToken; // the first token of the innermost declaration being read
	uint furthestDeclaration = noToken; // `declaration` at `furthest`
	bool tooDeep;
	bool refused; // an allocation was refused; every rule stops and the entry point returns false
	uint depth;
	Syntax* syntax; // skimming
	Builder* build; // building; null while skimming or validating
	const(Record)* record; // the record being built
	uint record_; // the record being skimmed
}

private bool refuse(ref Parser p) {
	p.refused = true;
	return false;
}

private void note(ref Parser p, TokenKind expected) {
	static assert(TokenKind.max < SyntaxError.expected.sizeof * 8, "SyntaxError.expected holds a bit per TokenKind");
	immutable t = p.tokens[p.pos];
	// `_` and `wsc` try a comment between any two tokens, so an unclosed one fails at its end wherever it is.
	immutable reached = t.attempted == expected || t.attempted == TokenKind.longComment;
	immutable at = t.kind == TokenKind.unterminated && reached ? t.start + t.length : t.start;
	if (p.failed && at == p.furthest) p.expected |= 1u << expected;
	else if (!p.failed || at > p.furthest) p.expected = 1u << expected;
	if (!p.failed || at >= p.furthest) {
		p.furthest = at;
		p.furthestToken = cast(uint) p.pos;
		p.furthestWhere = p.where;
		p.furthestDeclaration = p.declaration;
		p.failed = true;
	}
}

private bool at(ref Parser p, TokenKind kind) {
	if (p.tokens[p.pos].kind == kind) return true;
	note(p, kind);
	return false;
}

private bool atWord(ref Parser p, TokenKind kind, const(char)[] word) {
	immutable t = p.tokens[p.pos];
	if (t.kind == kind && doir.syntax.lexer.text(t, p.source) == word) return true;
	note(p, kind);
	return false;
}

// `wsc`
private void skipWsc(ref Parser p) {
	while (doir.syntax.lexer.isTrivia(p.tokens[p.pos].kind)) ++p.pos;
}

// `_`
private void skip_(ref Parser p) {
	while (doir.syntax.lexer.isTrivia(p.tokens[p.pos].kind) || p.tokens[p.pos].kind == TokenKind.newline) ++p.pos;
}

// The byte offset after the last non-trivia token before `p.pos`.
private uint lastEnd(ref Parser p, size_t from) {
	size_t i = p.pos;
	while (i > from && (doir.syntax.lexer.isTrivia(p.tokens[i - 1].kind) || p.tokens[i - 1].kind == TokenKind.newline)) --i;
	immutable t = p.tokens[i - 1];
	return t.start + t.length;
}

private bool enter(ref Parser p) {
	if (p.depth >= maxNesting) {
		p.tooDeep = true;
		return false;
	}
	++p.depth;
	return true;
}

private void error(ref Parser p, SyntaxError.Kind kind, uint at, uint token, string message = null, string fix = null, uint expected = 0) {
	if (p.syntax is null) return;
	auto e = SyntaxError(kind, at, token, message, fix, expected);
	if (kind == SyntaxError.Kind.syntax) {
		e.where = p.furthestWhere;
		e.declaration = p.furthestDeclaration;
	}
	if (!fp.dynarray.pushBack(p.syntax.errors, e)) p.refused = true;
}

// The intern functions return `noName` and set `p.refused` if allocation fails.
private doir.strings.StringId intern(ref Parser p, size_t token) {
	immutable id = nameOf(doir.syntax.lexer.text(p.tokens[token], p.source), *p.build.strings);
	if (id == doir.strings.noName) p.refused = true;
	return id;
}

private doir.strings.StringId intern(ref Parser p, const(char)[] spelled) {
	immutable id = doir.strings.intern(*p.build.strings, spelled);
	if (id == doir.strings.noName) p.refused = true;
	return id;
}

private EntityId takePart(ref Parser p) {
	auto b = p.build;
	immutable n = fp.dynarray.length(b.parts);
	immutable reused = n < b.reuse.length;
	immutable e = reused ? b.reuse[n] : ecrs.context.addEntity(*b.store);
	if (e == invalidEntity) {
		p.refused = true;
		return invalidEntity;
	}
	if (fp.dynarray.pushBack(b.parts, e)) return e;
	if (!reused) cast(void) ecrs.context.removeEntity(*b.store, e); // if refused, an orphan nothing reaches
	p.refused = true;
	return invalidEntity;
}

private bool setSpan(ref Parser p, EntityId e, uint parentStart, uint start, uint end) {
	// Set rather than written in place: a reused part keeps its span, and the commit's transaction must be able to restore it.
	return ecrs.context.setComponent!(doir.engine.locations.SourceSpan)(*p.build.store, e, doir.engine.locations.SourceSpan(start - parentStart, end - start)) || refuse(p);
}

/// A parsed type position: a name, or a function type written in place.
private struct ParsedType {
	uint name = noToken; // the identifier, or noToken
	EntityId entity = invalidEntity; // while building, the function type
}

private bool isName(ref Parser p, ParsedType type, const(char)[] word) {
	return type.name != noToken && doir.syntax.lexer.text(p.tokens[type.name], p.source) == word;
}

// Calls `f` with the type as `attach*` takes it: the interned name or function type entity. Returns `f`'s result, or false on refused interning.
private bool withType(alias f)(ref Parser p, ParsedType type) {
	if (type.entity != invalidEntity) return f(type.entity);
	immutable name = intern(p, type.name);
	return name != doir.strings.noName && f(name);
}

/// A parsed constant's payload.
private struct ParsedConstant {
	doir.components.ConstantVal value;
}

// Constant <- FloatConstant / IntegerConstant / RawString / '"' StringChar* '"' / '\'' StringChar '\''
private std.typecons.Nullable!ParsedConstant constant(ref Parser p) {
	immutable t = p.tokens[p.pos];
	const spelled = doir.syntax.lexer.text(t, p.source);
	ParsedConstant out_;
	switch (t.kind) {
		case TokenKind.float_:
			immutable value = floatValue(spelled);
			if (value.isNull) {
				cast(void) refuse(p);
				return typeof(return).init;
			}
			out_.value = doir.components.ConstantVal.float_(value.get);
			break;
		case TokenKind.integer:
			bool overflow;
			out_.value = doir.components.ConstantVal.integer(integerValue(spelled, overflow));
			if (overflow) error(p, SyntaxError.Kind.literal, t.start, cast(uint) p.pos, "V-Literal: an integer literal must fit in 64 bits", "write a value below 2^64");
			break;
		case TokenKind.rawString, TokenKind.string_:
			const content = t.kind == TokenKind.rawString ? rawContent(spelled) : spelled[1 .. $ - 1];
			if (p.build is null) {
				if (t.kind == TokenKind.string_) {
					bool unused;
					immutable problem = decodeString(content, null, unused);
					if (problem !is null) error(p, SyntaxError.Kind.literal, t.start, cast(uint) p.pos, problem, "keep `\\x` and octal escapes at or below 0xFF, and `\\u` and `\\U` escapes to Unicode scalar values");
				}
				break;
			}
			doir.strings.StringId bytes;
			if (t.kind == TokenKind.rawString) bytes = intern(p, content);
			else {
				char* decoded = null;
				scope(exit) fp.string.free(decoded);
				bool refused = false;
				cast(void) decodeString(content, &decoded, refused);
				if (refused) {
					cast(void) refuse(p);
					return typeof(return).init;
				}
				bytes = intern(p, fp.string.slice(decoded));
			}
			if (bytes == doir.strings.noName) return typeof(return).init;
			out_.value = doir.components.ConstantVal.bytes(bytes);
			break;
		case TokenKind.character:
			size_t i = 1;
			bool isByte, overflow;
			out_.value = doir.components.ConstantVal.integer(stringChar(spelled, i, isByte, overflow));
			if (overflow) error(p, SyntaxError.Kind.literal, t.start, cast(uint) p.pos, "V-Literal: a character literal must be a Unicode scalar value", "use a code point up to U+10FFFF, outside the surrogates U+D800 to U+DFFF");
			break;
		default:
			foreach (kind; [TokenKind.float_, TokenKind.integer, TokenKind.rawString, TokenKind.string_, TokenKind.character]) note(p, kind);
			return typeof(return).init;
	}
	++p.pos;
	return typeof(return)(out_);
}

// Parses in skimming mode and rewinds, so a build makes no part for a function type that does not parse whole.
private bool validates(alias rule)(ref Parser p) {
	immutable save = p.pos;
	auto build = p.build;
	p.build = null;
	immutable ok = rule(p);
	p.build = build;
	p.pos = save;
	return ok;
}

// Type <- FunctionType / Identifier; a function type is built as a part owned by `owner`, whose span starts at `ownerStart`.
private std.typecons.Nullable!ParsedType type(ref Parser p, EntityId owner, uint ownerStart) {
	if (p.tokens[p.pos].kind == TokenKind.leftParen) {
		if (p.build is null) {
			if (functionType(p, invalidEntity, 0)) return typeof(return)(ParsedType.init);
		} else if (validates!(q => functionType(q, invalidEntity, 0))(p)) {
			immutable start = p.tokens[p.pos].start;
			immutable e = takePart(p);
			if (e == invalidEntity) return typeof(return).init;
			immutable typeName = intern(p, "type");
			if (typeName == doir.strings.noName) return typeof(return).init;
			if (!doir.builders.attachInPlaceFunctionType(*p.build.store, e, owner, typeName)) {
				cast(void) refuse(p);
				return typeof(return).init;
			}
			if (!functionType(p, e, start)) {
				assert(p.refused, "doir.parser: a validated function type did not build");
				return typeof(return).init;
			}
			if (!setSpan(p, e, ownerStart, start, lastEnd(p, 0))) return typeof(return).init;
			return typeof(return)(ParsedType(noToken, e));
		}
		if (p.refused) return typeof(return).init;
	}
	if (!at(p, TokenKind.identifier)) return typeof(return).init;
	return typeof(return)(ParsedType(cast(uint) p.pos++));
}

// parameter <- Identifier _ ':'_ deducible_type
// deducible_type <- ('deduced' _ 'type' _) / (Type _ ('='_ (Constant / Identifier) _)?)
private bool parameter(ref Parser p, EntityId ft, uint ftStart) {
	immutable start = p.pos;
	p.where = Where.parameter;
	if (!at(p, TokenKind.identifier)) return false;
	immutable name = cast(uint) p.pos++;
	skip_(p);
	p.where = Where.parameterColon;
	if (!at(p, TokenKind.colon)) { p.pos = start; return false; }
	++p.pos;
	skip_(p);
	p.where = Where.parameterType;

	bool deduced = false;
	if (atWord(p, TokenKind.keyword, "deduced")) {
		immutable save = p.pos;
		++p.pos;
		skip_(p);
		if (atWord(p, TokenKind.identifier, "type")) {
			++p.pos;
			skip_(p);
			deduced = true;
		} else p.pos = save;
	}

	ParsedType paramType;
	ParsedConstant defaultConstant;
	uint defaultName = noToken;
	bool hasDefault = false;
	// The parameter's entity is taken before its type's, so its parts stay in parent-first order.
	immutable e = p.build is null ? invalidEntity : takePart(p);
	if (p.refused) return false;
	if (!deduced) {
		auto parsedType = type(p, ft, ftStart);
		if (parsedType.isNull) {
			assert(p.build is null || p.refused);
			p.pos = start;
			return false;
		}
		paramType = parsedType.get;
		skip_(p);
		immutable save = p.pos;
		p.where = Where.afterParameter;
		if (at(p, TokenKind.equals)) {
			++p.pos;
			skip_(p);
			p.where = Where.parameterDefault;
			auto parsedDefault = constant(p);
			if (!parsedDefault.isNull) {
				defaultConstant = parsedDefault.get;
				hasDefault = true;
			} else if (p.refused) return false;
			else if (at(p, TokenKind.identifier)) { defaultName = cast(uint) p.pos++; hasDefault = true; }
			if (hasDefault) skip_(p);
			else p.pos = save;
		}
	}
	if (p.build is null) return true;

	auto store = p.build.store;
	immutable unnamed = doir.syntax.lexer.text(p.tokens[name], p.source) == "_";
	immutable named = unnamed ? doir.strings.noName : intern(p, name);
	if (p.refused) return false;
	bool ok;
	if (deduced) {
		immutable deducedType = intern(p, doir.components.deducedTypeName);
		ok = deducedType != doir.strings.noName && doir.builders.attachParameter(*store, e, ft, named, deducedType);
	} else ok = withType!(t => doir.builders.attachParameter(*store, e, ft, named, t))(p, paramType);
	if (ok && hasDefault && defaultName != noToken) {
		immutable value = intern(p, defaultName);
		ok = value != doir.strings.noName && doir.builders.setDefault(*store, e, value);
	} else if (ok && hasDefault) ok = doir.builders.setDefault(*store, e, defaultConstant.value);
	if (!ok) return refuse(p);
	return setSpan(p, e, ftStart, p.tokens[start].start, lastEnd(p, start));
}

// FunctionType <- '('_ (parameter (','_ parameter)*)? ')' (_ '->'_ Type)?; while building, its parameters and return type go on `ft`.
private bool functionType(ref Parser p, EntityId ft, uint ftStart) {
	if (!at(p, TokenKind.leftParen)) return false;
	if (!enter(p)) return false;
	scope(exit) --p.depth;
	immutable start = p.pos;
	++p.pos;
	skip_(p);
	immutable any = parameter(p, ft, ftStart);
	if (any) {
		for (;;) {
			immutable save = p.pos;
			p.where = Where.afterParameter;
			if (!at(p, TokenKind.comma)) break;
			++p.pos;
			skip_(p);
			if (!parameter(p, ft, ftStart)) {
				if (p.refused) return false;
				p.pos = save;
				break;
			}
		}
	} else if (p.refused) return false;
	p.where = any ? Where.afterParameter : Where.parameter;
	if (!at(p, TokenKind.rightParen)) {
		p.pos = start;
		return false;
	}
	++p.pos;
	immutable save = p.pos;
	skip_(p);
	if (at(p, TokenKind.arrow)) {
		++p.pos;
		skip_(p);
		p.where = Where.returnType;
		auto returned = type(p, ft, ftStart);
		if (!returned.isNull) {
			if (p.build is null || withType!(t => doir.builders.setReturnType(*p.build.store, ft, t))(p, returned.get)) return true;
			return refuse(p);
		}
		if (p.refused) return false;
	}
	p.pos = save;
	return true;
}

/// A parsed call.
private struct ParsedCall {
	uint flags;
	uint callee;
	uint* arguments; // token indices, an fp dynarray
}

// function_call <- (('flatten' / 'inline' / 'tail') _)? Identifier _ '('_ (Identifier _ (','_ Identifier _)*)? ')' wsc
private bool functionCall(ref Parser p, ref ParsedCall out_) {
	immutable start = p.pos;
	if (p.tokens[p.pos].kind == TokenKind.keyword) {
		const word = doir.syntax.lexer.text(p.tokens[p.pos], p.source);
		if (word == "flatten") out_.flags = doir.components.Flags.Flatten;
		else if (word == "inline") out_.flags = doir.components.Flags.Inline;
		else if (word == "tail") out_.flags = doir.components.Flags.Tail;
		if (out_.flags) {
			++p.pos;
			skip_(p);
		}
	} else note(p, TokenKind.keyword);
	if (!at(p, TokenKind.identifier)) { p.pos = start; return false; }
	out_.callee = cast(uint) p.pos++;
	skip_(p);
	if (!at(p, TokenKind.leftParen)) { p.pos = start; return false; }
	++p.pos;
	skip_(p);
	p.where = Where.callArgument;
	if (at(p, TokenKind.identifier)) {
		if (!fp.dynarray.pushBack(out_.arguments, cast(uint) p.pos++)) return refuse(p);
		skip_(p);
		for (;;) {
			immutable save = p.pos;
			if (!at(p, TokenKind.comma)) break;
			++p.pos;
			skip_(p);
			if (!at(p, TokenKind.identifier)) {
				p.pos = save;
				break;
			}
			if (!fp.dynarray.pushBack(out_.arguments, cast(uint) p.pos++)) return refuse(p);
			skip_(p);
		}
	}
	if (!at(p, TokenKind.rightParen)) { p.pos = start; return false; }
	++p.pos;
	skipWsc(p);
	return true;
}

// Block <- '{'_ assignment* '}'; while skimming, each failed assignment is reported and skipped.
private bool block(ref Parser p) {
	if (!at(p, TokenKind.leftBrace)) return false;
	if (p.build !is null) {
		assert(p.pos == p.record.blockOpen);
		p.pos = p.record.blockClose + 1;
		return true;
	}
	if (!enter(p)) return false;
	scope(exit) --p.depth;
	immutable start = p.pos;
	immutable owner = p.record_;
	++p.pos;
	skip_(p);
	for (;;) {
		immutable t = p.tokens[p.pos].kind;
		if (t == TokenKind.rightBrace) break;
		if (t == TokenKind.end) {
			p.where = Where.block;
			note(p, TokenKind.rightBrace);
			p.pos = start;
			return false;
		}
		statement(p);
		if (p.refused) return false;
	}
	p.syntax.records[owner].blockOpen = cast(uint) start;
	p.syntax.records[owner].blockClose = cast(uint) p.pos;
	++p.pos;
	return true;
}

/// Which `assignment_value` alternative matched.
private enum Value : ubyte { none, constant, block, call, reference, functionType }

// change_language <- 'language' _ '"' StringChar* '"'_ matching_braces _
private bool changeLanguage(ref Parser p) {
	immutable start = p.pos;
	++p.pos;
	skip_(p);
	p.where = Where.language;
	if (!at(p, TokenKind.string_)) { p.pos = start; return false; }
	immutable name = cast(uint) p.pos++;
	skip_(p);
	if (!at(p, TokenKind.languageBody)) { p.pos = start; return false; }
	++p.pos;
	skip_(p);
	error(p, SyntaxError.Kind.language, p.tokens[start].start, name);
	return true;
}

private ulong mix(ulong h, ulong value) {
	return (h ^ value) * 0x100000001b3;
}

// A token's text, eight bytes at a time, for `hashOf`.
private ulong hashText(const(char)[] text) @trusted {
	ulong h = text.length * 0x9e3779b97f4a7c15;
	size_t i = 0;
	for (; i + 8 <= text.length; i += 8) {
		ulong word;
		core.stdc.string.memcpy(&word, text.ptr + i, 8);
		h = (h ^ word) * 0xff51afd7ed558ccd;
		h ^= h >> 32;
	}
	ulong tail = 0;
	foreach (k; i .. text.length) tail = tail << 8 | cast(ubyte) text[k];
	h = (h ^ tail) * 0xc4ceb9fe1a85ec53;
	return h ^ (h >> 29);
}

// The hash of record `r`: its non-trivia tokens, each nested record a placeholder, the terminator left out.
private ulong hashOf(ref Parser p, size_t r) {
	auto records = p.syntax.records;
	ulong h = 0xcbf29ce484222325;
	size_t child = r + 1;
	size_t t = records[r].first;
	while (t < records[r].terminator) {
		if (child < records[r].end && t == records[child].first) {
			h = mix(h, 0x9e3779b97f4a7c15);
			t = records[child].terminator + 1;
			child = records[child].end;
			continue;
		}
		immutable token = p.tokens[t++];
		if (doir.syntax.lexer.isTrivia(token.kind) || token.kind == TokenKind.newline || token.kind == TokenKind.semicolon) continue;
		h = mix(h, token.kind);
		h = mix(h, hashText(doir.syntax.lexer.text(token, p.source)));
	}
	return h;
}

// SourceInfo's location, its file name interned. Null if interning is refused.
private std.typecons.Nullable!(diagnose.Detailed) annotation(ref Parser p, size_t token) {
	auto s = doir.syntax.lexer.text(p.tokens[token], p.source);
	size_t i = 1;
	const(char)[] file;
	// As the lexer decided: the quoted form only if the first quote after `<"` is followed by `:`.
	immutable quote = s[1] == '"' ? fp.string.find(s, "\"", 2) : size_t.max;
	if (quote != size_t.max && quote + 1 < s.length && s[quote + 1] == ':') {
		immutable close = quote;
		file = s[2 .. close];
		i = close + 2;
	} else {
		immutable colon = fp.string.find(s, ":", 1);
		file = s[1 .. colon];
		i = colon + 1;
	}
	ulong[4] values;
	bool[2] ranged;
	foreach (part; 0 .. 2) {
		immutable first = doir.syntax.lexer.integerAt(s, i);
		bool overflow;
		values[part * 2] = integerValue(s[i .. first], overflow);
		i = first;
		values[part * 2 + 1] = values[part * 2];
		if (s[i] == '-') {
			immutable second = doir.syntax.lexer.integerAt(s, i + 1);
			if (second != size_t.max) {
				values[part * 2 + 1] = integerValue(s[i + 1 .. second], overflow);
				i = second;
			}
		}
		++i;
	}
	immutable name = intern(p, file);
	if (name == doir.strings.noName) return typeof(return).init;
	return typeof(return)(diagnose.Detailed(doir.strings.text(*p.build.strings, name),
		diagnose.Pair(cast(size_t) values[0], cast(size_t) values[2]), diagnose.Pair(cast(size_t) values[1], cast(size_t) values[3])));
}

// assignment <- change_language / ('export' _)? Identifier _ ':'_ Type wsc (_ '='_ assignment_value)? (SourceInfo wsc)? Terminator _
// assignment_value <- Constant wsc / Block wsc / function_call / Identifier wsc / Type wsc
private bool assignment(ref Parser p) {
	immutable start = p.pos;
	p.where = Where.declaration;
	if (atWord(p, TokenKind.keyword, "language")) return changeLanguage(p);
	immutable outerDeclaration = p.declaration;
	p.declaration = cast(uint) start;
	scope(exit) p.declaration = outerDeclaration;

	// While skimming, the record is reserved first so it precedes its nested ones.
	immutable outer = p.record_;
	immutable r = p.syntax is null ? 0 : cast(uint) fp.dynarray.length(p.syntax.records);
	if (p.syntax !is null) {
		if (!fp.dynarray.pushBack(p.syntax.records, Record.init)) return refuse(p);
		p.record_ = r;
	}
	scope(exit) p.record_ = outer;
	bool fail() {
		p.pos = start;
		if (p.syntax !is null) cast(void) fp.dynarray.popBackCount(p.syntax.records, fp.dynarray.length(p.syntax.records) - r);
		return false;
	}

	immutable e = p.build is null ? invalidEntity : p.build.declaration;
	immutable declStart = p.tokens[start].start;
	bool exported = false;
	if (atWord(p, TokenKind.keyword, "export")) {
		++p.pos;
		skip_(p);
		exported = true;
	}
	if (!at(p, TokenKind.identifier)) return fail();
	immutable name = cast(uint) p.pos++;
	skip_(p);
	p.where = Where.colon;
	if (!at(p, TokenKind.colon)) return fail();
	++p.pos;
	skip_(p);
	p.where = Where.type;
	auto parsedType = type(p, e, declStart);
	if (parsedType.isNull) return p.refused ? false : fail();
	immutable declared = parsedType.get;
	skipWsc(p);

	Value value = Value.none;
	ParsedConstant constantValue;
	ParsedCall call;
	scope(exit) fp.dynarray.free(call.arguments);
	uint reference = noToken;
	immutable beforeValue = p.pos;
	skip_(p);
	p.where = Where.afterType;
	if (at(p, TokenKind.equals)) {
		++p.pos;
		skip_(p);
		p.where = Where.value;
		auto parsedConstant = constant(p);
		if (!parsedConstant.isNull) {
			constantValue = parsedConstant.get;
			value = Value.constant;
		} else if (block(p)) value = Value.block;
		else if (functionCall(p, call)) value = Value.call;
		else if (at(p, TokenKind.identifier)) {
			reference = cast(uint) p.pos++;
			value = Value.reference;
		} else if (p.tokens[p.pos].kind == TokenKind.leftParen) {
			if (p.build is null) {
				if (functionType(p, invalidEntity, 0)) value = Value.functionType;
			} else if (validates!(q => functionType(q, invalidEntity, 0))(p)) {
				auto store = p.build.store;
				if (!withType!(t => doir.builders.attachFunctionType(*store, e, t))(p, declared)) return refuse(p);
				if (!functionType(p, e, declStart)) {
					assert(p.refused, "doir.parser: a validated function type did not build");
					return false;
				}
				value = Value.functionType;
			}
		}
		if (p.refused) return false;
		if (value == Value.none) p.pos = beforeValue;
		else if (value != Value.call) skipWsc(p);
	} else p.pos = beforeValue;
	p.where = value == Value.none ? Where.afterType : Where.afterValue;

	uint info = noToken;
	if (at(p, TokenKind.sourceInfo)) {
		info = cast(uint) p.pos++;
		skipWsc(p);
	}
	immutable terminatorKind = p.tokens[p.pos].kind;
	if (terminatorKind != TokenKind.newline && terminatorKind != TokenKind.semicolon && terminatorKind != TokenKind.end) {
		note(p, TokenKind.newline);
		return fail();
	}
	immutable terminator = cast(uint) p.pos;
	immutable spanEnd = lastEnd(p, start);
	if (terminatorKind != TokenKind.end) ++p.pos;
	skip_(p);

	if (p.syntax !is null) {
		auto record = &p.syntax.records[r];
		record.first = cast(uint) start;
		record.terminator = terminator;
		record.end = cast(uint) fp.dynarray.length(p.syntax.records);
		record.name = doir.syntax.lexer.text(p.tokens[name], p.source) == "_" ? noToken : name;
		record.spanStart = declStart;
		record.spanEnd = spanEnd;
		record.hash = hashOf(p, r);
	}
	if (p.build is null) return true;

	auto store = p.build.store;
	bool ok = true;
	final switch (value) {
		case Value.none:
			ok = withType!(t => doir.builders.attachValueless(*store, e, t))(p, declared);
			break;
		case Value.constant:
			ok = withType!(t => doir.builders.attachConstant(*store, e, t, constantValue.value))(p, declared);
			break;
		case Value.block:
			if (isName(p, declared, "namespace")) ok = doir.builders.attachNamespace(*store, e).block != invalidEntity;
			else if (isName(p, declared, "type")) ok = withType!(t => doir.builders.attachAggregate(*store, e, t).block != invalidEntity)(p, declared);
			else ok = withType!(t => doir.builders.attachBlock(*store, e, t).block != invalidEntity)(p, declared);
			break;
		case Value.call:
			doir.strings.StringId* arguments = null;
			scope(exit) fp.dynarray.free(arguments);
			foreach (a; fp.dynarray.slice(call.arguments)) {
				immutable argument = intern(p, a);
				if (argument == doir.strings.noName || !fp.dynarray.pushBack(arguments, argument)) return refuse(p);
			}
			immutable callee = intern(p, call.callee);
			if (callee == doir.strings.noName) return false;
			ok = withType!(t => doir.builders.attachCall(*store, e, t, callee, fp.dynarray.slice(arguments)))(p, declared)
				&& (!call.flags || doir.builders.addFlags(*store, e, call.flags));
			break;
		case Value.reference:
			immutable target = intern(p, reference);
			if (target == doir.strings.noName) return false;
			if (isName(p, declared, "alias")) ok = doir.builders.attachAlias(*store, e, target);
			else ok = withType!(t => doir.builders.attachReference(*store, e, t, target))(p, declared);
			break;
		case Value.functionType:
			break;
	}
	if (!ok || (exported && !doir.builders.addFlags(*store, e, doir.components.Flags.Export))) return refuse(p);
	if (info != noToken) {
		auto location = annotation(p, info);
		if (location.isNull) return false;
		p.build.annotation = location.get;
		p.build.annotated = true;
	}
	return true;
}

// One assignment; while skimming, a failed one is reported and skipped to the next terminator at its brace depth, or its block's end.
private void statement(ref Parser p) {
	immutable start = p.pos;
	p.failed = false;
	p.tooDeep = false;
	if (assignment(p) || p.refused) return;
	// A block that fails where a statement inside it already did adds what it expected there to that error rather than repeating it.
	auto last = p.syntax is null || fp.dynarray.length(p.syntax.errors) == 0 ? null : fp.dynarray.back(p.syntax.errors);
	if (p.tooDeep) error(p, SyntaxError.Kind.nesting, p.tokens[start].start, cast(uint) start);
	else if (last !is null && last.kind == SyntaxError.Kind.syntax && last.token == p.furthestToken) last.expected |= p.expected;
	else error(p, SyntaxError.Kind.syntax, p.furthest, p.furthestToken, null, null, p.expected);

	size_t depth = 0;
	for (;;) {
		immutable t = p.tokens[p.pos].kind;
		if (t == TokenKind.end) break;
		if (t == TokenKind.leftBrace) ++depth;
		else if (t == TokenKind.rightBrace) {
			if (depth == 0) break;
			--depth;
		} else if ((t == TokenKind.newline || t == TokenKind.semicolon) && depth == 0) {
			++p.pos;
			break;
		}
		++p.pos;
	}
	if (p.pos == start && p.tokens[p.pos].kind != TokenKind.end) ++p.pos;
	skip_(p);
}


// --- entry points ------------------------------------------------------------

/// Lexes and parses `source` into `out_`, which must be empty: a record for every declaration that parses, in preorder, and the syntax errors in the rest, each failed declaration skipped to the next terminator at its brace depth so its siblings still parse. Reads nothing but `source`.
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
bool skim(const(char)[] source, ref Syntax out_) {
	assert(out_.tokens is null && out_.records is null && out_.errors is null);
	out_.tokens = doir.syntax.lexer.lex(source);
	if (out_.tokens is null) return false;
	Parser p;
	p.source = source;
	p.tokens = fp.dynarray.slice(out_.tokens);
	p.syntax = &out_;
	p.record_ = uint.max;
	skip_(p);
	while (!p.refused && p.tokens[p.pos].kind != TokenKind.end) statement(p);
	if (!p.refused) return true;
	free(out_);
	return false;
}

/// Writes record `r` of `syntax`, skimmed from `source`, into `builder.declaration` through `doir.builders`: its type, value, flags and parts, but not its `Name`, `Parent`, span or nested declarations, which the commit writes. Parts reuse `builder.reuse` in order before new entities are made; each gets its `SourceSpan`.
///
/// Returns false if allocation fails, leaving the declaration and `builder.parts` partly built; the parts taken so far are still listed there.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import fp.dynarray;
/// static import doir.strings;
/// static import doir.components;
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
/// assert(ecrs.context.getComponent!(doir.components.TypeOf)(store, b.declaration).type == b.parts[0]);
/// ---
bool build(ref const Syntax syntax, const(char)[] source, size_t r, ref Builder builder) {
	version(unittest) ++builds;
	Parser p;
	p.source = source;
	p.tokens = fp.dynarray.slice(syntax.tokens);
	p.build = &builder;
	p.record = &syntax.records[r];
	p.pos = syntax.records[r].first;
	if (assignment(p)) return true;
	assert(p.refused, "doir.parser: a skimmed record did not build");
	return false;
}

/// The components `build` writes, which a rebuild removes first. `Name` and `Parent` are among them, written by the builders on parts and by the commit on declarations.
alias ParsedComponents = imported!"std.meta".AliasSeq!(doir.components.Name, doir.components.Parent, doir.components.Block, doir.components.TypeOf, doir.components.TypeDefinition, doir.components.FunctionInputs, doir.components.FunctionReturn, doir.components.ConstantVal, doir.components.Flags, doir.components.LookupTypeOf, doir.components.LookupFunctionReturn, doir.components.LookupCall, doir.components.LookupFunctionInputs, doir.components.LookupAlias, doir.components.LookupValue, doir.engine.locations.SourceAnnotation);

/// Removes every component the parse wrote on `e`, leaving what queries produced on it.
///
/// Returns false only inside a store transaction whose journal cannot grow, having removed some of them; the transaction's rollback restores them.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// immutable e = ecrs.context.addEntity(store);
/// ecrs.context.addComponent!(doir.components.Flags)(store, e).flags = 1;
/// assert(removeParsed(store, e));
/// assert(!ecrs.context.hasComponent!(doir.components.Flags)(store, e));
/// ---
bool removeParsed(ref ecrs.context.Context store, EntityId e) {
	static foreach (C; ParsedComponents)
		if (ecrs.context.hasComponent!C(store, e) && !ecrs.context.removeComponent!C(store, e)) return false;
	return true;
}


version(unittest) {
	static import doir.testing;

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
			auto allocator = doir.testing.beginRationedAllocator(budget);
			immutable built = build(b.syntax, source, 0, b.builder);
			fp.pointer.allocFunction = allocator;
			if (!built) continue;
			assert(fp.dynarray.length(b.builder.parts) == fp.dynarray.length(whole.builder.parts));
			assert(b.builder.annotated == whole.builder.annotated);
			return;
		}
	}
}

unittest { // skimming: records in preorder, hashes that ignore trivia, and recovery
	Syntax a, b;
	scope(exit) { free(a); free(b); }

	// Nested declarations follow their parent; a parent's hash ignores what is inside its block.
	assert(skim("ns : namespace = {\n\tx : T = 1\n\ty : T\n}\nz : T = 2\n", a));
	assert(skim("ns : namespace = {\n\tx : T = 7 // seven\n\ty : T\n}\nz : T=2;\n", b));
	assert(fp.dynarray.length(a.records) == 4 && a.records[0].end == 3 && a.records[3].end == 4);
	assert(a.records[0].hash == b.records[0].hash && a.records[1].hash != b.records[1].hash);
	assert(a.records[2].hash == b.records[2].hash && a.records[3].hash == b.records[3].hash);
	assert(a.records[2].name != noToken && a.records[0].blockOpen != noToken);

	// The span covers the declaration's text, and not its terminator.
	immutable source = "x : T = 5 ; # c\n_ : _ = std.return(x) <f:1:2>\n";
	Syntax c;
	scope(exit) free(c);
	assert(skim(source, c) && fp.dynarray.length(c.records) == 2);
	assert(source[c.records[0].spanStart .. c.records[0].spanEnd] == "x : T = 5");
	assert(source[c.records[1].spanStart .. c.records[1].spanEnd] == "_ : _ = std.return(x) <f:1:2>");
	assert(c.records[1].name == noToken);

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
	assert(fp.string.slice(literal) == "V-Literal: an integer literal must fit in 64 bits", "write a value below 2^64");

	// Too deep a nesting is reported rather than overflowing the stack.
	char* deep = null;
	scope(exit) fp.string.free(deep);
	foreach (i; 0 .. maxNesting + 1) assert(fp.string.concatenate(deep, "x : T = {\n") !is null);
	Syntax h;
	scope(exit) free(h);
	assert(skim(fp.string.slice(deep), h) && fp.dynarray.length(h.errors) >= 1 && h.errors[0].kind == SyntaxError.Kind.nesting);
	foreach (err; fp.dynarray.slice(h.errors)) assert(err.kind != SyntaxError.Kind.syntax || h.tokens[err.token].kind == TokenKind.end);
	char* nested = describe(h, fp.string.slice(deep), h.errors[0]);
	scope(exit) fp.string.free(nested);
	assert(fp.string.slice(nested) == "blocks and function types nest too deeply");

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
		auto allocator = doir.testing.beginRationedAllocator(budget);
		immutable skimmed = skim(everything, rationed);
		fp.pointer.allocFunction = allocator;
		if (skimmed) {
			assert(fp.dynarray.length(rationed.records) == fp.dynarray.length(whole.records) && fp.dynarray.length(rationed.errors) == fp.dynarray.length(whole.errors));
			break;
		}
		assert(rationed.tokens is null && rationed.records is null && rationed.errors is null);
	}
}

unittest { // building: each declaration form writes its builder components
	{
		Built b;
		scope(exit) release(b);
		buildOne(b, "export six : std.u8 = 6\n");
		assert(ecrs.context.getComponent!(doir.components.ConstantVal)(b.store, b.builder.declaration).integerValue == 6);
		assert(ecrs.context.getComponent!(doir.components.Flags)(b.store, b.builder.declaration).flags == (doir.components.Flags.Comptime | doir.components.Flags.Export));
		assert(doir.strings.text(b.strings, ecrs.context.getComponent!(doir.components.LookupTypeOf)(b.store, b.builder.declaration).name) == "std.u8");
	}
	{
		Built b;
		scope(exit) release(b);
		buildOne(b, "s : p = \"a\\tb\\u00e9\" <\"gen.doir\":3-4:5>\n");
		auto bytes = ecrs.context.getComponent!(doir.components.ConstantVal)(b.store, b.builder.declaration).bytesValue;
		assert(doir.strings.text(b.strings, bytes) == "a\tb\xC3\xA9");
		assert(b.builder.annotated && b.builder.annotation.file == "gen.doir");
		assert(b.builder.annotation.start == diagnose.Pair(3, 5) && b.builder.annotation.end == diagnose.Pair(4, 5));
	}
	{
		Built b;
		scope(exit) release(b);
		buildOne(b, "r : p = \"\"\"raw \\n\"\"\" ; c : u = 'x'\n");
		assert(doir.strings.text(b.strings, ecrs.context.getComponent!(doir.components.ConstantVal)(b.store, b.builder.declaration).bytesValue) == "raw \\n");
	}
	{
		Built b;
		scope(exit) release(b);
		buildOne(b, `e : p = "\a\b\f\n\r\v\"\?\\\%"` ~ "\n");
		assert(doir.strings.text(b.strings, ecrs.context.getComponent!(doir.components.ConstantVal)(b.store, b.builder.declaration).bytesValue) == "\a\b\f\n\r\v\"?\\%");
	}
	{
		// A float, and an unquoted source annotation.
		Built b;
		scope(exit) release(b);
		buildOne(b, "h : f32 = 1.5 <f.doir:7:2>\n");
		auto value = ecrs.context.getComponent!(doir.components.ConstantVal)(b.store, b.builder.declaration);
		assert(value.kind == doir.components.ConstantVal.Kind.float_ && value.floatValue == 1.5);
		assert(b.builder.annotation.file == "f.doir" && b.builder.annotation.start == diagnose.Pair(7, 2));
	}
	{
		// A float longer than the stack buffer.
		Built b;
		scope(exit) release(b);
		buildOne(b, "w : f64 = 2.50000000000000000000000000000000000000000000000000000000000000000000\n");
		assert(ecrs.context.getComponent!(doir.components.ConstantVal)(b.store, b.builder.declaration).floatValue == 2.5);
	}
	{
		Built b;
		scope(exit) release(b);
		buildOne(b, "sum : std.u8 = tail std.add(a, %\"b c\")\n");
		assert(doir.strings.text(b.strings, ecrs.context.getComponent!(doir.components.LookupCall)(b.store, b.builder.declaration).name) == "std.add");
		auto args = ecrs.context.getComponent!(doir.components.LookupFunctionInputs)(b.store, b.builder.declaration).names;
		assert(fp.dynarray.length(args) == 2 && doir.strings.text(b.strings, args[1]) == "b c");
		assert(ecrs.context.getComponent!(doir.components.Flags)(b.store, b.builder.declaration).flags == doir.components.Flags.Tail);
	}
	{
		Built b;
		scope(exit) release(b);
		buildOne(b, "color : alias = vec3\n");
		assert(ecrs.context.hasComponent!(doir.components.LookupAlias)(b.store, b.builder.declaration));
		assert(!ecrs.context.hasComponent!(doir.components.LookupTypeOf)(b.store, b.builder.declaration));
	}
	{
		Built b;
		scope(exit) release(b);
		buildOne(b, "x : T = y\n");
		assert(doir.strings.text(b.strings, ecrs.context.getComponent!(doir.components.LookupValue)(b.store, b.builder.declaration).name) == "y");
	}
	{
		// A named function type: the declaration is the function type; a deduced parameter, a default, and a function-typed parameter.
		Built b;
		scope(exit) release(b);
		buildOne(b, "id_t : type = (T: deduced type, v: T = 0, f: (x: T) -> T, _: u8 = z) -> T\n");
		immutable e = b.builder.declaration;
		auto inputs = ecrs.context.getComponent!(doir.components.FunctionInputs)(b.store, b.builder.declaration).related;
		assert(fp.dynarray.length(inputs) == 4);
		assert(doir.strings.text(b.strings, ecrs.context.getComponent!(doir.components.LookupTypeOf)(b.store, inputs[0]).name) == doir.components.deducedTypeName);
		assert(ecrs.context.getComponent!(doir.components.ConstantVal)(b.store, inputs[1]).integerValue == 0);
		immutable ft = ecrs.context.getComponent!(doir.components.TypeOf)(b.store, inputs[2]).type;
		assert(ecrs.context.getComponent!(doir.components.Parent)(b.store, ft).parent == e);
		assert(!ecrs.context.hasComponent!(doir.components.Name)(b.store, inputs[3]));
		assert(doir.strings.text(b.strings, ecrs.context.getComponent!(doir.components.LookupValue)(b.store, inputs[3]).name) == "z");
		assert(doir.strings.text(b.strings, ecrs.context.getComponent!(doir.components.LookupFunctionReturn)(b.store, b.builder.declaration).name) == "T");
		// Parts come parents first: the parameters, and the function type before its own parameter.
		assert(fp.dynarray.length(b.builder.parts) == 6 && b.builder.parts[3] == ft);
		auto span = ecrs.context.getComponent!(doir.engine.locations.SourceSpan)(b.store, inputs[1]);
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
		assert(ecrs.context.hasComponent!(doir.components.Block)(b.store, e));
		assert(fp.dynarray.length(ecrs.context.getComponent!(doir.components.Block)(b.store, b.builder.declaration).related) == 0);
		assert(ecrs.context.getComponent!(doir.components.TypeOf)(b.store, b.builder.declaration).type == b.builder.parts[0]);
	}
	{
		Built b;
		scope(exit) release(b);
		buildOne(b, "vec : type = {\n\tx : f32\n}\n");
		assert(ecrs.context.hasComponent!(doir.components.TypeDefinition)(b.store, b.builder.declaration));
	}
	{
		Built b;
		scope(exit) release(b);
		buildOne(b, "m : namespace = {\n}\n");
		assert(ecrs.context.getComponent!(doir.components.Flags)(b.store, b.builder.declaration).flags == doir.components.Flags.Namespace);
		assert(removeParsed(b.store, b.builder.declaration));
		assert(!ecrs.context.hasComponent!(doir.components.Flags)(b.store, b.builder.declaration));
	}

	// A refused allocation at any step of any form fails the build, rather than asserting or writing through a missing component.
	foreach (source; [
		"export six : std.u8 = 6\n",
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
