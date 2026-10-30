/// LSP positions (`roadmap.md` Phase 3): a line and a character offset in the encoding the client and server agreed on, converted to and from the byte offsets the store keeps. Only the line in question is read, through the text's line index (`fp.rope`), so a conversion costs the length of one line, not the file.
///
/// VS Code counts characters in UTF-16 code units; Neovim offers UTF-8, which needs no conversion at all.
///
/// Examples:
/// ---
/// static import fp.rope;
/// auto t = fp.rope.create("ab\ncé😀d\n").get;
/// scope(exit) fp.rope.free(t);
/// assert(offsetOf(t, Encoding.utf16, 1, 4) == 3 + 7); // c, é, the two units of 😀
/// size_t line, character;
/// positionOf(t, Encoding.utf16, 10, line, character);
/// assert(line == 1 && character == 4);
/// ---
module doir.lsp.positions;

static import fp.pointer;
static import fp.rope;
static import fp.string.utf;

@nogc nothrow:


/// How a position's character counts: the bytes of UTF-8, or the code units of UTF-16.
enum Encoding : ubyte { utf8, utf16 }

// Where line `line` of `text` starts and ends, its newline left out; the last line for one past the end.
private void lineBounds(const fp.rope.Rope text, size_t line, out size_t start, out size_t end) {
	start = fp.rope.lineStart(text, line);
	if (start == fp.pointer.notFound) start = end = fp.rope.length(text);
	else end = fp.rope.lineEnd(text, start);
}

// Calls `f` with each code point's first byte offset and its UTF-16 length, from `start` until `f` returns false or `end` is reached; the byte offset it stopped at.
private size_t walk(alias f)(const fp.rope.Rope text, size_t start, size_t end) {
	char[256] chunk;
	size_t at = start;
	while (at < end) {
		immutable n = end - at < chunk.length ? end - at : chunk.length;
		fp.rope.copy(text, at, at + n, chunk[0 .. n]);
		size_t i = 0;
		while (i < n) {
			immutable size = fp.string.utf.sequenceLength(chunk[i]);
			// A code point split across chunks is read whole from the next one.
			if (i + size > n && at + n < end) break;
			if (!f(at + i, fp.string.utf.utf16Units(chunk[i]))) return at + i;
			i += size;
		}
		at += i;
	}
	return end;
}

/// The byte offset in `text` of line `line`, character `character` counted in `encoding`; a character past its line's end is the line's end, and a line past the text's end is the text's end, as LSP asks.
///
/// Examples:
/// ---
/// static import fp.rope;
/// auto t = fp.rope.create("x\nyz\n").get;
/// scope(exit) fp.rope.free(t);
/// assert(offsetOf(t, Encoding.utf8, 1, 1) == 3 && offsetOf(t, Encoding.utf8, 1, 9) == 4 && offsetOf(t, Encoding.utf8, 7, 0) == 5);
/// ---
size_t offsetOf(const fp.rope.Rope text, Encoding encoding, size_t line, size_t character) {
	size_t start, end;
	lineBounds(text, line, start, end);
	if (encoding == Encoding.utf8) return character < end - start ? start + character : end;
	size_t units = 0;
	return walk!((at, width) {
		if (units + width > character) return false;
		units += width;
		return true;
	})(text, start, end);
}

/// The line and character, counted in `encoding`, of byte `at` of `text`, which may be its length.
///
/// Examples:
/// ---
/// static import fp.rope;
/// auto t = fp.rope.create("x\né!\n").get;
/// scope(exit) fp.rope.free(t);
/// size_t line, character;
/// positionOf(t, Encoding.utf16, 4, line, character);
/// assert(line == 1 && character == 1);
/// ---
void positionOf(const fp.rope.Rope text, Encoding encoding, size_t at, out size_t line, out size_t character) {
	line = fp.rope.lineOf(text, at);
	immutable start = fp.rope.lineStart(text, line);
	if (encoding == Encoding.utf8) {
		character = at - start;
		return;
	}
	size_t units = 0;
	cast(void) walk!((offset, width) {
		units += width;
		return true;
	})(text, start, at);
	character = units;
}


/// What `positionOf` remembers of the line it last converted an offset on, and how far into it it has counted, so offsets met in increasing order on one line cost one line lookup and one pass over its bytes, as a response's many ranges do. It holds no memory; reset it to `LineCache.init` before the text it was used on changes.
struct LineCache {
	fp.rope.Rope text; /// The text it describes.
	size_t line = fp.pointer.notFound; /// The line, or `fp.pointer.notFound` for none.
	size_t start; /// The line's first byte.
	size_t next; /// The next line's first byte, or one past the text's end on the last line.
	size_t counted; /// The bytes from `start` whose UTF-16 code units are counted.
	size_t units; /// Those code units.
}

/// The line and character, counted in `encoding`, of byte `at` of `text`, as the plain `positionOf` gives them, reusing and updating what `cache` remembers.
///
/// Examples:
/// ---
/// static import fp.rope;
/// auto t = fp.rope.create("x\né!😀y\n").get;
/// scope(exit) fp.rope.free(t);
/// LineCache cache;
/// size_t line, character;
/// positionOf(cache, t, Encoding.utf16, 5, line, character);
/// assert(line == 1 && character == 2);
/// positionOf(cache, t, Encoding.utf16, 9, line, character);
/// assert(line == 1 && character == 4);
/// ---
void positionOf(ref LineCache cache, const fp.rope.Rope text, Encoding encoding, size_t at, out size_t line, out size_t character) {
	if (cache.text != text || cache.line == fp.pointer.notFound || at < cache.start || at >= cache.next) {
		// Kept only to compare with the next text, never read through.
		cache = LineCache(cast(fp.rope.Rope) text, fp.rope.lineOf(text, at));
		cache.start = fp.rope.lineStart(text, cache.line);
		immutable following = fp.rope.lineStart(text, cache.line + 1);
		cache.next = following == fp.pointer.notFound ? fp.rope.length(text) + 1 : following;
	}
	line = cache.line;
	if (encoding == Encoding.utf8) {
		character = at - cache.start;
		return;
	}
	if (cache.start + cache.counted > at) cache.counted = cache.units = 0;
	size_t units = cache.units;
	cast(void) walk!((offset, width) {
		units += width;
		return true;
	})(text, cache.start + cache.counted, at);
	cache.counted = at - cache.start;
	cache.units = character = units;
}


unittest { // utf-8 and utf-16 positions round-trip on lines with multi-byte and astral characters, and clamp past a line's end
	auto t = fp.rope.create("aé\r\n😀x\nlast").get;
	scope(exit) fp.rope.free(t);
	foreach (encoding; [Encoding.utf8, Encoding.utf16])
		foreach (at; [0, 1, 3, 5, 9, 10, 11, 15]) {
			size_t line, character;
			positionOf(t, encoding, at, line, character);
			assert(offsetOf(t, encoding, line, character) == at);
		}
	size_t line, character;
	positionOf(t, Encoding.utf16, 10, line, character);
	assert(line == 1 && character == 3);
	assert(offsetOf(t, Encoding.utf16, 1, 1) == 5); // inside the surrogate pair: the character's start
	assert(offsetOf(t, Encoding.utf16, 0, 99) == 3); // the line's end, before its \r\n
	assert(offsetOf(t, Encoding.utf8, 2, 4) == 15 && offsetOf(t, Encoding.utf8, 9, 0) == 15);
	// The cache gives what a plain conversion does, met in either order.
	static immutable size_t[9] offsets = [0, 1, 3, 5, 9, 10, 11, 13, 15];
	foreach (encoding; [Encoding.utf8, Encoding.utf16])
		foreach (backwards; [false, true]) {
			LineCache cache;
			foreach (i; 0 .. offsets.length) {
				immutable at = offsets[backwards ? $ - 1 - i : i];
				size_t plainLine, plainCharacter, cachedLine, cachedCharacter;
				positionOf(t, encoding, at, plainLine, plainCharacter);
				positionOf(cache, t, encoding, at, cachedLine, cachedCharacter);
				assert(plainLine == cachedLine && plainCharacter == cachedCharacter);
			}
		}
}
