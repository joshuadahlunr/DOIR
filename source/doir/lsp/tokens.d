/// Semantic tokens for the language server (`roadmap.md` Phase 3): highlighting from the lexer's tokens, not the store, since trivia never becomes entities. Text is lexed as it is encoded, one token at a time, so highlighting a range costs that range and keeps no token array.
///
/// An identifier's type comes from its neighbours: a declaration's name is followed by `:`, a type follows `:` or `->`, and a call's callee is followed by `(`.
///
/// Examples:
/// ---
/// static import fp.dynarray;
/// static import doir.lsp.positions;
/// uint* data = null;
/// scope(exit) fp.dynarray.free(data);
/// assert(encode("x : T = 1\n", doir.lsp.positions.Encoding.utf16, 0, 0, 0, size_t.max, data));
/// // x, `:`, T, `=`, 1: five tokens of five integers each
/// assert(fp.dynarray.length(data) == 25 && data[3] == Type.variable && data[4] == Modifier.declaration);
/// assert(data[5 * 2 + 3] == Type.type && data[5 * 4 + 3] == Type.number);
/// ---
module doir.lsp.tokens;

static import fp.dynarray;
static import fp.string.utf;

static import doir.lsp.positions;
static import doir.syntax.lexer;

@nogc nothrow:


/// The token types the server's legend lists, in this order.
enum Type : uint { keyword, variable, type, function_, string_, number, comment, operator, macro_ }

/// The legend's names for `Type`, as LSP's predefined types spell them.
static immutable string[9] typeNames = ["keyword", "variable", "type", "function", "string", "number", "comment", "operator", "macro"];

/// The token modifiers, as bits.
enum Modifier : uint { declaration = 1 }

/// The legend's names for `Modifier`'s bits, in bit order.
static immutable string[1] modifierNames = ["declaration"];

// Where encoding has reached in its text: a byte offset, and the line and character it is at in the file.
private struct Place {
	size_t at, line, character;
}

private void advance(const(char)[] text, doir.lsp.positions.Encoding encoding, ref Place p, size_t to) {
	foreach (c; text[p.at .. to]) {
		if (c == '\n') {
			++p.line;
			p.character = 0;
		} else if (encoding == doir.lsp.positions.Encoding.utf8) ++p.character;
		else p.character += fp.string.utf.utf16Units(c);
	}
	p.at = to;
}

private struct Encoder {
	const(char)[] text;
	doir.lsp.positions.Encoding encoding;
	size_t start, end;
	Place place;
	size_t lastLine, lastCharacter;
	uint** data;
	bool refused;
}

// Appends `token` as `type`, a line at a time, if it reaches into the requested range.
private void emit(ref Encoder e, doir.syntax.lexer.Token token, uint type, uint modifiers) {
	immutable from = token.start, to = token.start + token.length;
	if (to <= e.start || from >= e.end || e.refused) return;
	advance(e.text, e.encoding, e.place, from);
	while (e.place.at < to) {
		size_t lineEnd = e.place.at;
		while (lineEnd < to && e.text[lineEnd] != '\n') ++lineEnd;
		Place end = e.place;
		advance(e.text, e.encoding, end, lineEnd);
		immutable length = end.character - e.place.character;
		if (length) {
			immutable deltaLine = e.place.line - e.lastLine;
			immutable deltaStart = deltaLine ? e.place.character : e.place.character - e.lastCharacter;
			uint[5] five = [cast(uint) deltaLine, cast(uint) deltaStart, cast(uint) length, type, modifiers];
			if (!fp.dynarray.concatenate(*e.data, five[])) {
				e.refused = true;
				return;
			}
			e.lastLine = e.place.line;
			e.lastCharacter = e.place.character;
		}
		e.place = end;
		if (lineEnd < to) advance(e.text, e.encoding, e.place, lineEnd + 1);
	}
}

// The type a token that is not an identifier shows as, or uint.max for none.
private uint typeOf(doir.syntax.lexer.TokenKind kind) {
	final switch (kind) with (doir.syntax.lexer.TokenKind) {
		case keyword: return Type.keyword;
		case integer, float_: return Type.number;
		case string_, rawString, character, languageBody: return Type.string_;
		case lineComment, longComment: return Type.comment;
		case colon, equals, comma, arrow: return Type.operator;
		case sourceInfo: return Type.macro_;
		case identifier, whitespace, newline, leftParen, rightParen, leftBrace, rightBrace, semicolon, invalid, unterminated, end: return uint.max;
	}
}

/// Appends to `data` the semantic tokens of `text` that reach into bytes `start` to `end`, as LSP's five integers each, relative to the token before. `text` must begin where a token of the whole file begins, at `line` and `character` of the file, so it lexes as the file does; a token cut off at its end is shown as what it would have been.
///
/// Returns false if allocation is refused, having appended some of the tokens.
///
/// Examples:
/// ---
/// static import fp.dynarray;
/// static import doir.lsp.positions;
/// uint* data = null;
/// scope(exit) fp.dynarray.free(data);
/// assert(encode("/* a\nb */ x\n", doir.lsp.positions.Encoding.utf8, 0, 0, 0, size_t.max, data));
/// assert(fp.dynarray.length(data) == 15 && data[2] == 4 && data[5] == 1 && data[7] == 4); // the comment, a line at a time
/// ---
bool encode(const(char)[] text, doir.lsp.positions.Encoding encoding, size_t line, size_t character, size_t start, size_t end, ref uint* data) @trusted {
	// The first token is placed from the file's start, as LSP counts it.
	Encoder e = Encoder(text, encoding, start, end, Place(0, line, character), 0, 0, &data);
	auto cursor = doir.syntax.lexer.Cursor(text);
	// An identifier waits for the next significant token, which says what it is; trivia after it waits with it, to keep the tokens in order.
	doir.syntax.lexer.Token pending;
	bool hasPending;
	doir.syntax.lexer.Token* held = null;
	scope(exit) fp.dynarray.free(held);
	auto previous = doir.syntax.lexer.TokenKind.newline;
	void settle(doir.syntax.lexer.TokenKind next) {
		if (!hasPending) return;
		immutable after = previous == doir.syntax.lexer.TokenKind.colon || previous == doir.syntax.lexer.TokenKind.arrow;
		if (next == doir.syntax.lexer.TokenKind.colon) emit(e, pending, Type.variable, Modifier.declaration);
		else if (after) emit(e, pending, Type.type, 0);
		else if (next == doir.syntax.lexer.TokenKind.leftParen) emit(e, pending, Type.function_, 0);
		else emit(e, pending, Type.variable, 0);
		foreach (t; fp.dynarray.slice(held)) {
			immutable type = typeOf(t.kind == doir.syntax.lexer.TokenKind.unterminated ? t.attempted : t.kind);
			if (type != uint.max) emit(e, t, type, 0);
		}
		fp.dynarray.clear(held);
		hasPending = false;
		previous = doir.syntax.lexer.TokenKind.identifier;
	}
	while (cursor.at < text.length && !e.refused) {
		auto t = doir.syntax.lexer.next(cursor);
		immutable kind = t.kind == doir.syntax.lexer.TokenKind.unterminated ? t.attempted : t.kind;
		if (t.start >= end && !hasPending) break;
		if (doir.syntax.lexer.isTrivia(kind) || kind == doir.syntax.lexer.TokenKind.newline) {
			if (hasPending && doir.syntax.lexer.isTrivia(kind)) {
				if (!fp.dynarray.pushBack(held, t)) e.refused = true;
			} else if (typeOf(kind) != uint.max) emit(e, t, typeOf(kind), 0);
			continue;
		}
		settle(kind);
		if (kind == doir.syntax.lexer.TokenKind.identifier) {
			pending = t;
			hasPending = true;
			continue;
		}
		if (typeOf(kind) != uint.max) emit(e, t, typeOf(kind), 0);
		previous = kind;
	}
	settle(doir.syntax.lexer.TokenKind.end);
	return !e.refused;
}


unittest { // identifiers by their neighbours, in both encodings, and a token split across lines and characters
	uint* data = null;
	scope(exit) fp.dynarray.free(data);
	static immutable source = "f : (a: T) -> U\n_ : _ = g(f) // é\n";
	assert(encode(source, doir.lsp.positions.Encoding.utf16, 0, 0, 0, size_t.max, data));
	// f, `:`, `(`a, `:`, T, `->`, U, _, `:`, _, `=`, g, f, comment
	with (Type) {
		static immutable uint[14] expected = [variable, operator, variable, operator, type, operator, type, variable, operator, type, operator, function_, variable, comment];
		assert(fp.dynarray.length(data) == expected.length * 5);
		foreach (i, type; expected) assert(data[i * 5 + 3] == type);
	}
	immutable comment = fp.dynarray.length(data) - 5;
	assert(data[comment + 2] == 4); // `// é`, four UTF-16 units
	fp.dynarray.clear(data);
	assert(encode(source, doir.lsp.positions.Encoding.utf8, 0, 0, 0, size_t.max, data));
	assert(data[fp.dynarray.length(data) - 5 + 2] == 5); // five bytes

	// Only tokens reaching into the range, positions still counted from the text's start.
	fp.dynarray.clear(data);
	assert(encode(source, doir.lsp.positions.Encoding.utf8, 3, 2, 16, 21, data));
	assert(fp.dynarray.length(data) == 15 && data[0] == 4 && data[1] == 0 && data[5] == 0 && data[6] == 2);
}
