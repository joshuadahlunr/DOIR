/// Folding ranges for the language server (`roadmap.md` Phase 3): each block over several lines, from `Block` and `SourceSpan`, and the comments, which are trivia, by a lexing pass.
module doir.lsp.features.folding;

static import fp.rope;
static import fp.string;

static import bc.json;
static import ecrs.context;

static import doir.components.ast;
static import doir.components.source;
static import doir.lsp.positions;
static import doir.lsp.session;
static import doir.lsp.store;
static import doir.source;
static import doir.syntax.lexer;

public import ecrs.registry : EntityId;

@nogc nothrow:

// bounded: doir.syntax.parser.maxNesting, the deepest blocks a commit builds
// Appends to `ranges` the folding ranges of `block`'s blocks over several lines, and theirs.
private void foldings(ref doir.lsp.session.Session s, bc.json.Value ranges, const fp.rope.Rope text, EntityId block, size_t base) {
	foreach (child; doir.lsp.store.childrenOf(s, block)) {
		immutable span = ecrs.context.getComponent!(doir.components.source.SourceSpan)(*s.engine.store, child);
		immutable start = base + span.offset;
		if (!ecrs.context.hasComponent!(doir.components.ast.Block)(*s.engine.store, child)) continue;
		size_t first, last, character;
		doir.lsp.positions.positionOf(text, s.encoding, start, first, character);
		doir.lsp.positions.positionOf(text, s.encoding, start + span.length, last, character);
		if (last > first) {
			auto range = bc.json.appendObject(ranges);
			bc.json.set(range, "startLine", first);
			bc.json.set(range, "endLine", last);
		}
		foldings(s, ranges, text, child, start);
	}
}

// Appends to `ranges` a folding range of kind `comment` from line `first` to `last`, if they differ.
private void commentFolding(bc.json.Value ranges, size_t first, size_t last) {
	if (last <= first) return;
	auto range = bc.json.appendObject(ranges);
	bc.json.set(range, "startLine", first);
	bc.json.set(range, "endLine", last);
	bc.json.set(range, "kind", "comment");
}

// Appends to `ranges` folds for `text`'s comments, which the store lacks: runs of line-comment lines and multi-line block comments.
// False on refusal.
private bool commentFoldings(bc.json.Value ranges, const fp.rope.Rope text) {
	immutable length = fp.rope.length(text);
	char* bytes = fp.rope.text(text, 0, length).get(null);
	scope(exit) fp.string.free(bytes);
	if (bytes is null) return length == 0;
	auto source = bytes[0 .. length];
	auto cursor = doir.syntax.lexer.Cursor(source);
	size_t line = 0, runStart = 0, runEnd = 0;
	bool blank = true, inRun = false; // whether the line has only whitespace so far, and whether a run of comment lines is open
	while (cursor.at < source.length) {
		immutable t = doir.syntax.lexer.next(cursor);
		const token = doir.syntax.lexer.text(t, source);
		switch (t.kind) with (doir.syntax.lexer.TokenKind) {
			case whitespace: continue;
			case newline:
				++line;
				blank = true;
				continue;
			case lineComment:
				if (blank && inRun && runEnd + 1 == line) runEnd = line;
				else if (blank) {
					if (inRun) commentFolding(ranges, runStart, runEnd);
					runStart = runEnd = line;
					inRun = true;
				}
				blank = false;
				continue;
			default: break;
		}
		blank = false;
		size_t lines = 0;
		foreach (c; token) lines += c == '\n';
		if (t.kind == doir.syntax.lexer.TokenKind.longComment) commentFolding(ranges, line, line + lines);
		line += lines;
	}
	if (inRun) commentFolding(ranges, runStart, runEnd);
	return true;
}

/// Answers a `textDocument/foldingRange` request with the document's blocks and comments over several lines.
///
/// Examples:
/// ---
/// doir.lsp.session.Fixture f;
/// assert(doir.lsp.session.open(f, "n : namespace = {\n}\n"));
/// scope(exit) doir.lsp.session.free(f);
/// assert(doir.lsp.session.parse(f, `{"textDocument":{"uri":"file:///t.doir"}}`));
/// foldingRange(f.s, doir.lsp.session.params(f), doir.lsp.session.id(f));
/// assert(doir.lsp.session.responds(f, `"result":[{"startLine":0,"endLine":1}]`));
/// ---
package(doir) void foldingRange(ref doir.lsp.session.Session s, bc.json.Value params, bc.json.Value id) {
	auto o = doir.lsp.session.documentOf(s, params, id);
	if (o is null) return;
	const text = doir.source.textOf(*s.engine, o.file);
	bc.json.Document d;
	auto ranges = bc.json.setArray(doir.lsp.session.response(d, id), "result");
	foldings(s, ranges, text, doir.source.rootOf(*s.engine, o.file), 0);
	if (!commentFoldings(ranges, text)) {
		bc.json.free(d);
		doir.lsp.session.respondError(s, id, -32_603, "out of memory finding the comments to fold");
		return;
	}
	doir.lsp.session.send(s, d);
}
