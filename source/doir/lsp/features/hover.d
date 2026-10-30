/// Hover for the language server (`roadmap.md` Phase 3): the declaration the name at the cursor resolves to, up to the brace opening its block, then its documentation as `doir_doc` reads it, the comment lines directly above it and its trailing comment.
module doir.lsp.features.hover;

static import std.typecons;

static import fp.dynarray;
static import fp.rope;
static import fp.string;

static import bc.json;
static import ecrs.context;

static import doir.components.ast;
static import doir.lsp.positions;
static import doir.lsp.session;
static import doir.lsp.store;
static import doir.source;
static import doir.syntax.lexer;

public import ecrs.registry : invalidEntity;

@nogc nothrow:

// A comment's text, a slice of the buffer it was read into.
private struct Comment {
	const(char)[] text;
}

// The text, after its marker and one space, of the `//` or `#` comment that bytes `start` to `end` of `text` hold with only whitespace; null if they hold anything else, or on refusal. `buffer` holds the copied bytes the text is in; the caller frees it.
private std.typecons.Nullable!Comment lineCommentIn(const fp.rope.Rope text, size_t start, size_t end, ref char* buffer) {
	fp.string.free(buffer);
	buffer = fp.rope.text(text, start, end).get(null);
	if (buffer is null) return typeof(return).init;
	auto source = buffer[0 .. end - start];
	auto cursor = doir.syntax.lexer.Cursor(source);
	typeof(return) comment;
	while (cursor.at < source.length) {
		immutable t = doir.syntax.lexer.next(cursor);
		if (t.kind == doir.syntax.lexer.TokenKind.whitespace || t.kind == doir.syntax.lexer.TokenKind.newline) continue;
		if (t.kind != doir.syntax.lexer.TokenKind.lineComment || !comment.isNull) return typeof(return).init;
		auto body_ = doir.syntax.lexer.text(t, source);
		body_ = body_[body_[0] == '#' ? 1 : 2 .. $];
		comment = Comment(body_.length && body_[0] == ' ' ? body_[1 .. $] : body_);
	}
	return comment;
}

// Appends the documentation of the declaration at `found` to `out_`, as `doir_doc` reads it: the comment lines directly above it, each a paragraph, then its trailing comment. False on refusal.
private bool appendDocumentation(const fp.rope.Rope text, doir.lsp.store.Found found, ref char* out_) {
	char* buffer = null;
	scope(exit) fp.dynarray.free(buffer);
	size_t line, character;
	doir.lsp.positions.positionOf(text, doir.lsp.positions.Encoding.utf8, found.start, line, character);
	// A declaration documented from above starts its line; one after another on the same line has only a trailing comment.
	buffer = fp.rope.text(text, found.start - character, found.start).get(null);
	if (character && buffer is null) return false;
	immutable above = fp.string.trimStart(buffer[0 .. character], " \t").length == 0;
	size_t first = line;
	while (above && first > 0 && !lineCommentIn(text, fp.rope.lineStart(text, first - 1), fp.rope.lineEnd(text, fp.rope.lineStart(text, first - 1)), buffer).isNull) --first;
	bool written = false;
	foreach (l; first .. line) {
		auto comment = lineCommentIn(text, fp.rope.lineStart(text, l), fp.rope.lineEnd(text, fp.rope.lineStart(text, l)), buffer);
		if (comment.isNull || !fp.string.append(out_, written ? "\n\n" : "", comment.get.text)) return false; // read above, so null is a refusal
		written = true;
	}
	immutable lineEnd = fp.rope.lineEnd(text, found.end);
	if (found.end >= lineEnd) return true;
	auto trailing = lineCommentIn(text, found.end, lineEnd, buffer);
	return trailing.isNull || fp.string.append(out_, written ? "\n\n" : "", trailing.get.text);
}

// Appends the declaration at `found` as hover shows it to `out_`: its text up to the brace opening its block, if it has one, or all of it. False on refusal.
private bool appendHeader(ref doir.lsp.session.Session s, const fp.rope.Rope text, doir.lsp.store.Found found, ref char* out_) {
	char* bytes = fp.rope.text(text, found.start, found.end).get(null);
	scope(exit) fp.dynarray.free(bytes);
	if (bytes is null) return found.end <= found.start;
	auto source = bytes[0 .. found.end - found.start];
	auto header = source;
	if (ecrs.context.hasComponent!(doir.components.ast.Block)(*s.engine.store, found.e)) {
		auto cursor = doir.syntax.lexer.Cursor(source);
		int depth = 0;
		while (cursor.at < source.length) {
			immutable t = doir.syntax.lexer.next(cursor);
			if (t.kind == doir.syntax.lexer.TokenKind.leftParen) ++depth;
			else if (t.kind == doir.syntax.lexer.TokenKind.rightParen) --depth;
			else if (t.kind == doir.syntax.lexer.TokenKind.leftBrace && depth == 0) {
				header = source[0 .. t.start];
				break;
			}
		}
	}
	header = fp.string.trimEnd(header);
	return fp.string.append(out_, header, header.length < source.length ? " { … }" : "");
}

/// Answers a `textDocument/hover` request with the header and documentation of what the identifier at its position resolves to, as Markdown, or null.
///
/// Examples:
/// ---
/// doir.lsp.session.Fixture f;
/// assert(doir.lsp.session.open(f, "x : T = 1 // one\ny : T = x\n"));
/// scope(exit) doir.lsp.session.free(f);
/// assert(doir.lsp.session.parse(f, `{"textDocument":{"uri":"file:///t.doir"},"position":{"line":1,"character":8}}`));
/// hover(f.s, doir.lsp.session.params(f), doir.lsp.session.id(f));
/// assert(doir.lsp.session.responds(f, `"value":"`~"```"~`doir\nx : T = 1\n`~"```"~`\n\none"`));
/// ---
package(doir) void hover(ref doir.lsp.session.Session s, bc.json.Value params, bc.json.Value id) {
	auto o = doir.lsp.session.documentOf(s, params, id);
	if (o is null) return;
	const text = doir.source.textOf(*s.engine, o.file);
	immutable named = doir.lsp.store.declarationAt(s, o.file, doir.lsp.session.offsetAt(s, params["position"], text));
	immutable found = named.declaration;
	if (found.e == invalidEntity) return doir.lsp.session.respondNull(s, id);
	char* markdown = null;
	scope(exit) fp.dynarray.free(markdown);
	char* documentation = null;
	scope(exit) fp.dynarray.free(documentation);
	if (!fp.string.append(markdown, "```doir\n") || !appendHeader(s, text, found, markdown) || !fp.string.append(markdown, "\n```") || !appendDocumentation(text, found, documentation)
		|| !fp.string.append(markdown, fp.dynarray.length(documentation) ? "\n\n" : "", documentation is null ? "" : documentation[0 .. fp.dynarray.length(documentation)]))
		return doir.lsp.session.respondError(s, id, -32_603, "out of memory describing the declaration");
	bc.json.Document d;
	auto result = bc.json.setObject(doir.lsp.session.response(d, id), "result");
	auto contents = bc.json.setObject(result, "contents");
	bc.json.set(contents, "kind", "markdown");
	bc.json.set(contents, "value", markdown[0 .. fp.dynarray.length(markdown)]);
	doir.lsp.session.range(s, bc.json.setObject(result, "range"), text, named.start, named.end);
	doir.lsp.session.send(s, d);
}
