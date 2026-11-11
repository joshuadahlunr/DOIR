/// The lexer: a file's text as a token stream, trivia included, that both the parser and the editor's highlighting read (`roadmap.md` Phase 2).
///
/// It decides what each token is, following `doir.peg`'s lexical rules and their PEG ordered choice exactly: identifiers and keywords (from the tables `tools/gen_tables.py` generates), constants, comments, and `newline` as a token of its own, so a newline inside a `LongComment` is never one.
/// A `language` body (`matching_braces`) and a `SourceInfo` are single opaque tokens, since neither is made of DOIR tokens.
/// Whether a `newline` is a `Terminator` depends on the production, so the parser decides it.
///
/// Lexing reads only the text, so files can be lexed in parallel.
///
/// Examples:
/// ---
/// static import fp.dynarray;
/// auto tokens = lex("x : std.u8 = 5\n");
/// scope(exit) fp.dynarray.free(tokens);
/// assert(tokens[0].kind == TokenKind.identifier && tokens[1].kind == TokenKind.colon);
/// assert(text(tokens[fp.dynarray.length(tokens) - 2], "x : std.u8 = 5\n") == "\n");
/// ---
module doir.syntax.lexer;

static import fp.dynarray;
static import fp.string;
static import fp.string.ascii;
static import fp.string.utf;
version(unittest) static import fp.testing;

static import doir.syntax.tables;

@nogc nothrow:


// --- types and layout --------------------------------------------------------

/// What a token is.
enum TokenKind : ubyte {
	whitespace, /// A run of `wsc` whitespace: trivia.
	lineComment, /// `//` or `#` to the end of the line: trivia.
	longComment, /// `/* ... */`: trivia, newlines included.
	newline, /// `\n`, `\r\n` or `\r`; a `Terminator` where the grammar has `wsc`, whitespace where it has `_`.
	identifier, /// `Identifier`, `%"quoted"` included.
	keyword, /// A word of `Keywords`, which no identifier is.
	integer, /// `IntegerConstant`, optionally preceded by `-`.
	float_, /// `FloatConstant`, optionally preceded by `-`.
	string_, /// `'"' StringChar* '"'`.
	rawString, /// `RawString`.
	character, /// `'\'' StringChar '\''`.
	colon, /// `:`.
	equals, /// `=`.
	comma, /// `,`.
	leftParen, /// `(`.
	rightParen, /// `)`.
	leftBrace, /// `{`.
	rightBrace, /// `}`.
	arrow, /// `->`.
	semicolon, /// `;`, a `Terminator`.
	sourceInfo, /// A whole `SourceInfo`, `<"file":1-2:3-4>`.
	languageBody, /// The `matching_braces` of a `language` block, braces included.
	invalid, /// A character no token starts with; parsing fails at its start.
	unterminated, /// A token that started but did not finish, `attempted` saying which; lexing failed at its end.
	end, /// The end of the text, a `Terminator`; always the last token.
}

/// A token: its kind and where it is in the text.
struct Token {
	TokenKind kind; /// What it is.
	TokenKind attempted; /// For `unterminated`, the kind it would have been; otherwise `kind`.
	uint start; /// Its byte offset.
	uint length; /// Its length in bytes.
}

/// Whether tokens of `kind` are trivia, which `wsc` skips: whitespace and comments, but not newlines.
///
/// Examples:
/// ---
/// assert(isTrivia(TokenKind.lineComment) && !isTrivia(TokenKind.newline));
/// ---
bool isTrivia(TokenKind kind) {
	return kind <= TokenKind.longComment;
}

/// The text of `token` in `source`, the text it was lexed from.
///
/// Examples:
/// ---
/// assert(text(Token(TokenKind.identifier, TokenKind.identifier, 2, 3), "x abc") == "abc");
/// ---
const(char)[] text(Token token, const(char)[] source) {
	return source[token.start .. token.start + token.length];
}


// --- character classes -------------------------------------------------------

// The ASCII rows of the tables, one bit per class, so the common case is a single load.
private enum ubyte startBit = 1, continueBit = 2, spaceBit = 4;
private immutable ubyte[0x80] ascii = () {
	ubyte[0x80] t;
	foreach (c; 0 .. 0x80) {
		immutable letter = (c | 0x20) >= 'a' && (c | 0x20) <= 'z' || c == '_';
		if (letter) t[c] |= startBit | continueBit;
		if (c >= '0' && c <= '9') t[c] |= continueBit;
		if (c == ' ' || c == '\t' || c == '\v' || c == '\f') t[c] |= spaceBit;
	}
	return t;
}();

/// Whether code point `c` may start an identifier (`UnicodeIdentifierStart`).
///
/// Examples:
/// ---
/// assert(isIdentifierStart('_') && isIdentifierStart(0x3B1) && !isIdentifierStart('1'));
/// ---
bool isIdentifierStart(uint c) {
	if (c < 0x80) return (ascii[c] & startBit) != 0;
	return fp.string.utf.inRanges(doir.syntax.tables.identifierStart[], c);
}

/// Whether code point `c` may continue an identifier (`UnicodeIdentifierContinue`); `.` may too, but is not in this class.
///
/// Examples:
/// ---
/// assert(isIdentifierContinue('1') && !isIdentifierContinue('.'));
/// ---
bool isIdentifierContinue(uint c) {
	if (c < 0x80) return (ascii[c] & continueBit) != 0;
	return fp.string.utf.inRanges(doir.syntax.tables.identifierContinue[], c);
}

/// Whether code point `c` is `wsc` whitespace; newlines are not.
///
/// Examples:
/// ---
/// assert(isWhitespace(' ') && isWhitespace(0x2028) && !isWhitespace('\n'));
/// ---
bool isWhitespace(uint c) {
	if (c < 0x80) return (ascii[c] & spaceBit) != 0;
	return fp.string.utf.inRanges(doir.syntax.tables.whitespace[], c);
}

private enum size_t failed = size_t.max;

// The code point at `i` and the index after it; an invalid byte decodes as one code point no class contains.
private uint decode(const(char)[] s, ref size_t i) {
	assert(i < s.length, "doir.syntax.lexer: decoding past the source");
	if (s[i] < 0x80) return s[i++];
	bool valid;
	immutable start = i;
	immutable c = fp.string.utf.decode(s, i, valid);
	if (!valid) {
		i = start + 1;
		return uint.max;
	}
	assert(i > start + 1 && i <= s.length && i - start <= 4, "doir.syntax.lexer: a sequence that did not advance by its length");
	return c;
}

private bool digitAt(const(char)[] s, size_t i) { return i < s.length && fp.string.ascii.isDigit(s[i]); }
private bool hexDigitAt(const(char)[] s, size_t i) { return i < s.length && fp.string.ascii.isHexDigit(s[i]); }
private bool charAt(const(char)[] s, size_t i, char c) { return i < s.length && s[i] == c; }

private size_t skipDigits(const(char)[] s, size_t i) { while (digitAt(s, i)) ++i; return i; }
private size_t skipHex(const(char)[] s, size_t i) { while (hexDigitAt(s, i)) ++i; return i; }


// --- lexical rules -----------------------------------------------------------

/// `IntegerConstant <- ('0x' HexDigit+) / ('0b' [01]+) / ('0' [0-7]*) / ([1-9][0-9]*)`: the index after the integer at `i`, or `size_t.max`.
///
/// Examples:
/// ---
/// assert(integerEnd("0x1F;", 0) == 4 && integerEnd("09", 0) == 1 && integerEnd("x", 0) == size_t.max);
/// ---
size_t integerEnd(const(char)[] s, size_t i) {
	if (fp.string.startsWith(s, "0x", i) && hexDigitAt(s, i + 2)) return skipHex(s, i + 2);
	if (fp.string.startsWith(s, "0b", i) && (charAt(s, i + 2, '0') || charAt(s, i + 2, '1'))) {
		i += 2;
		while (charAt(s, i, '0') || charAt(s, i, '1')) ++i;
		return i;
	}
	if (charAt(s, i, '0')) {
		++i;
		while (i < s.length && s[i] >= '0' && s[i] <= '7') ++i;
		return i;
	}
	if (i < s.length && s[i] >= '1' && s[i] <= '9') return skipDigits(s, i + 1);
	return failed;
}

// `[pP][-+]? [0-9]+` or `[eE][-+]? [0-9]+`, or `i` itself when it is absent, as `?` makes it.
private size_t exponentEnd(const(char)[] s, size_t i, char lower, char upper) {
	assert(i <= s.length, "doir.syntax.lexer: an exponent past the source");
	if (!charAt(s, i, lower) && !charAt(s, i, upper)) return i;
	size_t j = i + 1;
	if (charAt(s, j, '+') || charAt(s, j, '-')) ++j;
	immutable end = digitAt(s, j) ? skipDigits(s, j) : i;
	assert(end == i || (end > j && end <= s.length), "doir.syntax.lexer: an exponent with no digits");
	return end;
}

/// `FloatConstant`, hexadecimal or decimal: the index after the float at `i`, or `size_t.max`.
///
/// Examples:
/// ---
/// assert(floatEnd("1.5e3 ", 0) == 5 && floatEnd(".5", 0) == 2 && floatEnd("0x1p4", 0) == 5 && floatEnd("12", 0) == size_t.max);
/// ---
size_t floatEnd(const(char)[] s, size_t i) {
	if (fp.string.startsWith(s, "0x", i)) {
		immutable m = i + 2;
		// `HexDigit* '.' HexDigit+ / HexDigit+ '.' HexDigit*`
		immutable lead = skipHex(s, m);
		if (charAt(s, lead, '.') && (hexDigitAt(s, lead + 1) || lead > m))
			return exponentEnd(s, skipHex(s, lead + 1), 'p', 'P');
		// '0x' HexDigit+ HexExponent
		if (lead > m) {
			immutable e = exponentEnd(s, lead, 'p', 'P');
			if (e > lead) return e;
		}
	}
	immutable lead = skipDigits(s, i);
	if (charAt(s, lead, '.') && (digitAt(s, lead + 1) || lead > i))
		return exponentEnd(s, skipDigits(s, lead + 1), 'e', 'E');
	if (lead > i) {
		immutable e = exponentEnd(s, lead, 'e', 'E');
		if (e > lead) return e;
	}
	return failed;
}

/// `StringChar`: the index after the character or escape at `i`, or `size_t.max`.
///
/// Examples:
/// ---
/// assert(stringCharEnd(`\x41"`, 0) == 4 && stringCharEnd(`"`, 0) == size_t.max && stringCharEnd("é", 0) == 2);
/// ---
size_t stringCharEnd(const(char)[] s, size_t i) {
	if (i >= s.length || s[i] == '"' || s[i] == '\n' || s[i] == '\r') return failed;
	if (s[i] != '\\') {
		cast(void) decode(s, i);
		return i;
	}
	if (i + 1 >= s.length) return failed;
	immutable e = s[i + 1];
	switch (e) {
		case '\'', '"', '?', '\\', '%', 'a', 'b', 'f', 'n', 'r', 't', 'v': return i + 2;
		case '0': .. case '7':
			size_t j = i + 1;
			while (j < s.length && s[j] >= '0' && s[j] <= '7') ++j;
			return j;
		case 'x': return hexDigitAt(s, i + 2) ? skipHex(s, i + 2) : failed;
		case 'u', 'U':
			immutable want = e == 'u' ? 4 : 8;
			foreach (k; 0 .. want) if (!hexDigitAt(s, i + 2 + k)) return failed;
			return i + 2 + want;
		default: return failed;
	}
}

// `'"' StringChar* '"'` from `i`, at its opening quote: its end, or the negated position it failed at.
private size_t quotedEnd(const(char)[] s, size_t i, ref size_t failedAt) {
	assert(charAt(s, i, '"'), "doir.syntax.lexer: a quoted string that does not open with a quote");
	size_t j = i + 1;
	for (;;) {
		immutable next = stringCharEnd(s, j);
		if (next == failed) break;
		assert(next > j, "doir.syntax.lexer: a string character that did not advance");
		j = next;
	}
	if (charAt(s, j, '"')) return j + 1;
	failedAt = j;
	return failed;
}

// RawString: an opening run of n >= 3 quotes, closed by the first run of n quotes not followed by another.
private size_t rawStringEnd(const(char)[] s, size_t i) {
	assert(i < s.length, "doir.syntax.lexer: a raw string past the source");
	size_t n = 0;
	while (charAt(s, i + n, '"')) ++n;
	if (n < 3) return failed;
	for (size_t j = i + n; j < s.length; ++j) {
		if (s[j] != '"') continue;
		size_t run = 0;
		while (charAt(s, j + run, '"')) ++run;
		assert(run >= 1 && j + run <= s.length, "doir.syntax.lexer: a run of quotes past the source");
		if (run >= n) return j + run;
		j += run - 1;
	}
	return failed;
}

// SourceInfo from `i`, at its `<`: its end, or `failed` with `failedAt` set to where it stopped.
private size_t sourceInfoEnd(const(char)[] s, size_t i, ref size_t failedAt) {
	size_t p = failed;
	if (charAt(s, i + 1, '"')) {
		size_t j = i + 2;
		while (j < s.length && s[j] != '"') ++j;
		if (fp.string.startsWith(s, "\":", j)) p = j + 2;
	}
	if (p == failed) {
		size_t j = i + 1;
		while (j < s.length && s[j] != ':') ++j;
		if (j >= s.length) {
			failedAt = j;
			return failed;
		}
		p = j + 1;
	}
	foreach (part; 0 .. 2) {
		immutable first = integerEnd(s, p);
		if (first == failed) {
			failedAt = p;
			return failed;
		}
		p = first;
		if (charAt(s, p, '-')) {
			immutable second = integerEnd(s, p + 1);
			if (second != failed) p = second;
		}
		immutable want = part == 0 ? ':' : '>';
		if (!charAt(s, p, want)) {
			failedAt = p;
			return failed;
		}
		++p;
	}
	assert(p > i && p <= s.length && s[p - 1] == '>', "doir.syntax.lexer: source info that does not end at its `>`");
	return p;
}

// `matching_braces` from `i`, at its `{`; braces inside it count whatever surrounds them.
private size_t matchingBracesEnd(const(char)[] s, size_t i) {
	assert(charAt(s, i, '{'), "doir.syntax.lexer: matching braces from something that is not a `{`");
	size_t depth = 0;
	foreach (j; i .. s.length) {
		if (s[j] == '{') ++depth;
		else if (s[j] == '}' && --depth == 0) return j + 1;
		assert(depth > 0, "doir.syntax.lexer: a brace count that fell to zero without closing");
	}
	return failed;
}

// The end of the identifier characters from `i`, whose first qualifies: `.` is not one, so `tail.x` starts with the keyword `tail`.
private size_t wordEnd(const(char)[] s, size_t i) {
	immutable start = i;
	cast(void) decode(s, i);
	assert(i > start, "doir.syntax.lexer: a word of no characters");
	while (i < s.length) {
		immutable b = s[i];
		if (b < 0x80) {
			if (!(ascii[b] & continueBit)) break;
			++i;
			continue;
		}
		size_t j = i;
		if (!isIdentifierContinue(decode(s, j))) break;
		i = j;
	}
	return i;
}

// `([.] / UnicodeIdentifierContinue)*` from `i`.
private size_t dottedEnd(const(char)[] s, size_t i) {
	assert(i <= s.length, "doir.syntax.lexer: a dotted name past the source");
	while (i < s.length) {
		immutable b = s[i];
		if (b < 0x80) {
			if (b != '.' && !(ascii[b] & continueBit)) break;
			++i;
			continue;
		}
		size_t j = i;
		if (!isIdentifierContinue(decode(s, j))) break;
		i = j;
	}
	return i;
}

// `Keywords`: a whole word, which no identifier character follows.
private bool isKeyword(const(char)[] word) {
	foreach (k; doir.syntax.tables.keywords) if (word == k) return true;
	return false;
}


// --- lexing ------------------------------------------------------------------

/// Whether `lex` emits trivia tokens.
/// The parser needs none, since trivia is the gap between the tokens around it; highlighting asks for them.
enum Trivia : bool {
	skip = false, /// Whitespace and comments are left out; an unclosed `/*` is still an `unterminated` token.
	keep = true, /// Every byte belongs to a token.
}

// About one token per this many bytes of DOIR without trivia, as `standard.doir` measures: the first guess at the array's size.
private enum size_t bytesPerToken = 6;

/// A position in a text being lexed one token at a time, for a scan that needs each token only once; `lex` stores what `next` hands out.
struct Cursor {
	const(char)[] source; /// The text.
	size_t at; /// The byte offset of the next token.
	private int language; // `language` _ string _ `{`: 1 after the keyword, 2 after the name, so the next `{` opens a body
}

// The end of a number whose digits start at `digits`, the token at `start`, setting `kind` to `float_` or `integer`; one byte, left `invalid`, if neither fits.
pragma(inline, true)
private size_t numberEnd(const(char)[] source, size_t start, size_t digits, ref TokenKind kind) {
	immutable f = floatEnd(source, digits);
	if (f != failed) {
		kind = TokenKind.float_;
		return f;
	}
	immutable n = integerEnd(source, digits);
	if (n == failed) return start + 1;
	kind = TokenKind.integer;
	return n;
}

// The end of the string, raw string or character at `i`, setting `kind`, and `unterminated` if it does not close.
pragma(inline, true)
private size_t quotedTokenEnd(const(char)[] source, size_t i, ref TokenKind kind, ref bool unterminated) {
	if (source[i] == '"') {
		immutable raw = rawStringEnd(source, i);
		if (raw != failed) {
			kind = TokenKind.rawString;
			return raw;
		}
		kind = TokenKind.string_;
		size_t at;
		immutable e = quotedEnd(source, i, at);
		if (e != failed) return e;
		unterminated = true;
		return at;
	}
	kind = TokenKind.character;
	immutable e = stringCharEnd(source, i + 1);
	if (e != failed && charAt(source, e, '\'')) return e + 1;
	unterminated = true;
	return e == failed ? i + 1 : e;
}

// The end of the token at `i` that no ASCII rule took, setting `kind`: Unicode whitespace, a keyword, an identifier, or one character left `invalid`.
pragma(inline, true)
private size_t wordOrSpaceEnd(const(char)[] source, size_t i, ref TokenKind kind) {
	size_t j = i;
	immutable codepoint = decode(source, j);
	if (isWhitespace(codepoint)) {
		kind = TokenKind.whitespace;
		while (j < source.length) {
			size_t k = j;
			if (!isWhitespace(decode(source, k))) break;
			j = k;
		}
		return j;
	}
	if (!isIdentifierStart(codepoint)) return j;
	immutable end = wordEnd(source, i);
	// Keywords are 4 to 8 bytes; anything else is an identifier without comparing.
	if (end - i >= 4 && end - i <= 8 && isKeyword(source[i .. end])) {
		kind = TokenKind.keyword;
		return end;
	}
	kind = TokenKind.identifier;
	return dottedEnd(source, end);
}

/// The token at `cursor.at`, trivia included, advancing past it; `cursor.at` must be below the text's length.
/// It cannot fail.
///
/// Examples:
/// ---
/// auto cursor = Cursor("a -> b");
/// assert(next(cursor).kind == TokenKind.identifier && next(cursor).kind == TokenKind.whitespace);
/// assert(next(cursor).kind == TokenKind.arrow && cursor.at == 4);
/// ---
pragma(inline, true)
Token next(ref Cursor cursor) @trusted {
	const source = cursor.source;
	int language = cursor.language;
	size_t i = cursor.at;
	assert(i < source.length, "doir.lexer: lexing past the end of the source");
	immutable start = i;
	TokenKind kind = TokenKind.invalid, attempted;
	bool unterminated = false;
	immutable c = source[i];

	if (c == ' ' || c == '\t') {
		kind = TokenKind.whitespace;
		while (i < source.length && (source[i] == ' ' || source[i] == '\t')) ++i;
	} else if (c == '\n') { kind = TokenKind.newline; ++i; }
	else if (c == '\r') { kind = TokenKind.newline; i += charAt(source, i + 1, '\n') ? 2 : 1; }
	else if ((c == '/' && charAt(source, i + 1, '/')) || c == '#') {
		kind = TokenKind.lineComment;
		while (i < source.length && source[i] != '\n' && source[i] != '\r') ++i;
	} else if (c == '/' && charAt(source, i + 1, '*')) {
		kind = TokenKind.longComment;
		i += 2;
		while (i < source.length && !fp.string.startsWith(source, "*/", i)) ++i;
		if (i < source.length) i += 2;
		else unterminated = true;
	} else if (c == '{' && language == 2) {
		kind = TokenKind.languageBody;
		immutable e = matchingBracesEnd(source, i);
		if (e == failed) { i = source.length; unterminated = true; }
		else i = e;
	} else if (c == ':') { kind = TokenKind.colon; ++i; }
	else if (c == '=') { kind = TokenKind.equals; ++i; }
	else if (c == ',') { kind = TokenKind.comma; ++i; }
	else if (c == '(') { kind = TokenKind.leftParen; ++i; }
	else if (c == ')') { kind = TokenKind.rightParen; ++i; }
	else if (c == '{') { kind = TokenKind.leftBrace; ++i; }
	else if (c == '}') { kind = TokenKind.rightBrace; ++i; }
	else if (c == ';') { kind = TokenKind.semicolon; ++i; }
	else if (c == '-' && charAt(source, i + 1, '>')) { kind = TokenKind.arrow; i += 2; }
	else if (c == '-' && (digitAt(source, i + 1) || charAt(source, i + 1, '.'))) i = numberEnd(source, i, i + 1, kind);
	else if (c == '<') {
		kind = TokenKind.sourceInfo;
		size_t at;
		immutable e = sourceInfoEnd(source, i, at);
		if (e == failed) { i = at; unterminated = true; }
		else i = e;
	} else if (fp.string.ascii.isDigit(c) || c == '.') i = numberEnd(source, i, i, kind);
	else if (c == '"' || c == '\'') i = quotedTokenEnd(source, i, kind, unterminated);
	else if (c == '%') {
		kind = TokenKind.identifier;
		size_t at;
		immutable quoted = charAt(source, i + 1, '"') ? quotedEnd(source, i + 1, at) : failed;
		if (quoted != failed) i = quoted;
		else {
			// `([%] / UnicodeIdentifierStart) ([.] / UnicodeIdentifierContinue)*`, whose first character qualifies.
			cast(void) decode(source, i);
			i = dottedEnd(source, i);
		}
	} else i = wordOrSpaceEnd(source, i, kind);

	assert(i > start && i <= source.length, "doir.lexer: a token that consumed nothing, or ran past the source");
	attempted = kind;
	if (unterminated) kind = TokenKind.unterminated;

	if (kind == TokenKind.keyword && source[start .. i] == "language") language = 1;
	else if (kind == TokenKind.string_ && language == 1) language = 2;
	else if (!isTrivia(kind) && kind != TokenKind.newline) language = 0;
	cursor.at = i;
	cursor.language = language;
	return Token(kind, attempted, cast(uint) start, cast(uint) (i - start));
}

/// Lexes `source` into a new fp dynarray of tokens in order, ending with one `end` token; with `Trivia.keep` they cover every byte.
/// A character no rule matches becomes an `invalid` token, and a token that does not finish an `unterminated` one, so lexing always reaches the end.
///
/// Returns null if allocation fails.
///
/// Examples:
/// ---
/// static import fp.dynarray;
/// auto tokens = lex("a /* x */ -> b", Trivia.keep);
/// scope(exit) fp.dynarray.free(tokens);
/// assert(tokens[2].kind == TokenKind.longComment && tokens[4].kind == TokenKind.arrow);
/// auto bare = lex("a /* x */ -> b");
/// scope(exit) fp.dynarray.free(bare);
/// assert(bare[1].kind == TokenKind.arrow && fp.dynarray.length(bare) == 4);
/// ---
Token* lex(const(char)[] source, Trivia trivia = Trivia.skip) @trusted {
	assert(source.length < uint.max, "doir.lexer: source too long");
	Token* out_ = null;
	if (fp.dynarray.reserve(out_, source.length / bytesPerToken + 16) is null) return null;
	auto cursor = Cursor(source);
	while (cursor.at < source.length) {
		immutable t = next(cursor);
		if ((trivia || !isTrivia(t.kind)) && !fp.dynarray.pushBack(out_, t)) {
			fp.dynarray.free(out_);
			return null;
		}
	}
	if (fp.dynarray.pushBack(out_, Token(TokenKind.end, TokenKind.end, cast(uint) source.length, 0))) return out_;
	fp.dynarray.free(out_);
	return null;
}


version(unittest) {

	// The kinds of `source`'s tokens, trivia left out, `end` included; lexing without trivia must give the same tokens.
	private bool kindsAre(const(char)[] source, const(TokenKind)[] expected...) {
		auto all = lex(source, Trivia.keep), bare = lex(source);
		scope(exit) { fp.dynarray.free(all); fp.dynarray.free(bare); }
		size_t n = 0;
		foreach (t; fp.dynarray.slice(all)) {
			if (isTrivia(t.kind)) continue;
			if (n >= expected.length || expected[n] != t.kind || n >= fp.dynarray.length(bare) || bare[n] != t) return false;
			++n;
		}
		return n == expected.length && fp.dynarray.length(bare) == n;
	}
}

unittest { // the ASCII fast paths classify as the generated tables do
	foreach (uint c; 0 .. 0x80) {
		assert(isIdentifierStart(c) == fp.string.utf.inRanges(doir.syntax.tables.identifierStart[], c));
		assert(isIdentifierContinue(c) == fp.string.utf.inRanges(doir.syntax.tables.identifierContinue[], c));
		assert(isWhitespace(c) == fp.string.utf.inRanges(doir.syntax.tables.whitespace[], c));
	}
}

unittest { // tokens cover the text, and follow the grammar's ordered choices
	with (TokenKind) {
		assert(kindsAre("x : std.u8 = 5\n", identifier, colon, identifier, equals, integer, newline, end));
		assert(kindsAre("a;b\r\nc\rd", identifier, semicolon, identifier, newline, identifier, newline, identifier, end));

		// Numbers: floats first, then integers, each rule possessive as PEG is.
		assert(kindsAre("1.5 .5 1. 0x1.8p3 0x1p4 1e5", float_, float_, float_, float_, float_, float_, end));
		assert(kindsAre("0x1F 0b101 017 42", integer, integer, integer, integer, end));
		assert(kindsAre("-1.5 -.5 -1. -0x1.8p3 -0x1p4 -1e5", float_, float_, float_, float_, float_, float_, end));
		assert(kindsAre("-0x1F -0b101 -017 -42", integer, integer, integer, integer, end));
		assert(kindsAre("09", integer, integer, end)); // '0' [0-7]* stops before 9
		assert(kindsAre("1e", integer, identifier, end)); // an exponent needs digits
		assert(kindsAre("0x", integer, identifier, end));
		assert(kindsAre(".", invalid, end));
		assert(kindsAre("- 5", invalid, integer, end)); // the sign must touch its number
		assert(kindsAre("-.", invalid, invalid, end));
		assert(kindsAre("->", arrow, end));

		// Strings: a raw string first, then a quoted one; `""""""` with no close is two empty strings and a third.
		assert(kindsAre(`"a\n\x41" 'c' '\'' """r"aw"""`, string_, character, character, rawString, end));
		assert(kindsAre(`""""""`, string_, string_, string_, end));
		assert(kindsAre("\"abc\nx", unterminated, newline, identifier, end));
		assert(kindsAre("\"abc\rx", unterminated, newline, identifier, end) && kindsAre("\"abc\r\nx", unterminated, newline, identifier, end)); // a lone `\r` breaks a line too
		assert(kindsAre(`"\101\0"`, string_, end));
		assert(kindsAre(`"\q"`, unterminated, invalid, identifier, unterminated, end)); // no such escape
		assert(kindsAre(`'ab'`, unterminated, identifier, unterminated, end));

		// Identifiers: dots continue one, keywords are whole words, `%` starts one or quotes it.
		assert(kindsAre("std.types.pointer a. %1 %\"any text\" %", identifier, identifier, identifier, identifier, identifier, end));
		assert(kindsAre("export exported tail.x deduced type", keyword, identifier, keyword, invalid, identifier, keyword, identifier, end));
		assert(kindsAre("αβ _x a.β", identifier, identifier, identifier, end));
		assert(kindsAre("\xFF", invalid, end)); // invalid UTF-8 is one code point no class contains

		// Comments: a long one swallows its newlines; a line comment stops at `\n` or `\r`.
		assert(kindsAre("a /* \n */ b // c\r\nd # e", identifier, identifier, newline, identifier, end));
		assert(kindsAre("a // c\rd", identifier, newline, identifier, end));
		assert(kindsAre("/* open", unterminated, end));

		// Opaque tokens.
		assert(kindsAre(`x : T = 1 <"f.doir":1-2:3-4>`, identifier, colon, identifier, equals, integer, sourceInfo, end));
		assert(kindsAre("x : T <f:1:2>", identifier, colon, identifier, sourceInfo, end));
		assert(kindsAre("x : T <f:1:", identifier, colon, identifier, unterminated, end));
		assert(kindsAre("<f", unterminated, end));
		assert(kindsAre("<f:1x", unterminated, identifier, end));
		assert(kindsAre("language \"c\" { open", keyword, string_, unterminated, end));
		assert(kindsAre("language \"c\" /* */ {int f() { \"}\" }\n}", keyword, string_, languageBody, newline, rightBrace, end)); // a brace in foreign code counts even inside its strings
		assert(kindsAre("language \"c\" { if (a) { b; } }\nx", keyword, string_, languageBody, newline, identifier, end));
		assert(kindsAre("{ }", leftBrace, rightBrace, end));
		assert(kindsAre("@", invalid, end));
	}

	// Unicode whitespace is trivia, and U+2028 is not a newline.
	auto tokens = lex("a\xE2\x80\xA8\xE3\x80\x80b", Trivia.keep);
	scope(exit) fp.dynarray.free(tokens);
	assert(fp.dynarray.length(tokens) == 4 && tokens[1].kind == TokenKind.whitespace && tokens[1].length == 6);

	// Input denser than the first guess grows the array: a token per byte.
	char[1000] dense = ';';
	auto many = lex(dense[]);
	scope(exit) fp.dynarray.free(many);
	assert(fp.dynarray.length(many) == dense.length + 1 && many[999].kind == TokenKind.semicolon && many[999].start == 999);

	// A refused allocation while growing frees what was lexed and returns null.
	auto previous = fp.testing.limitAllocations(1);
	assert(lex(dense[]) is null);
	fp.testing.restoreAllocator(previous);

	// Every byte belongs to exactly one token, in order.
	static immutable source = "x : (a: T, b: deduced type) -> U = {\n\t_ : _ = tail f(a, b) <g:1:1>; # c\n}\n";
	auto all = lex(source, Trivia.keep);
	scope(exit) fp.dynarray.free(all);
	size_t at = 0;
	foreach (t; fp.dynarray.slice(all)) {
		assert(t.start == at);
		at += t.length;
	}
	assert(at == source.length);
}
