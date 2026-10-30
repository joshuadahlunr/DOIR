/// Semantic tokens for the language server (`roadmap.md` Phase 3), by range and for the whole file: lexed from the text as they are encoded (`doir.lsp.tokens`), not read from the store, since trivia never becomes entities.
module doir.lsp.features.semantic;

static import fp.dynarray;
static import fp.rope;
static import fp.string;

static import bc.json;

static import doir.lsp.positions;
static import doir.lsp.session;
static import doir.lsp.store;
static import doir.lsp.tokens;
static import doir.source;

@nogc nothrow:

/// Answers a `textDocument/semanticTokens/full` request, or `…/range` if `ranged`, with the tokens of the document or of the lines of `params.range`.
///
/// Examples:
/// ---
/// doir.lsp.session.Fixture f;
/// assert(doir.lsp.session.open(f, "x : T = 1\n"));
/// scope(exit) doir.lsp.session.free(f);
/// assert(doir.lsp.session.parse(f, `{"textDocument":{"uri":"file:///t.doir"}}`));
/// semanticTokens(f.s, doir.lsp.session.params(f), doir.lsp.session.id(f), false);
/// assert(doir.lsp.session.responds(f, `"data":[0,0,1,`));
/// ---
package(doir) void semanticTokens(ref doir.lsp.session.Session s, bc.json.Value params, bc.json.Value id, bool ranged) {
	auto o = doir.lsp.session.documentOf(s, params, id);
	if (o is null) return;
	const text = doir.source.textOf(*s.engine, o.file);
	size_t from = 0, start = 0, end = fp.rope.length(text);
	if (ranged) {
		auto r = params["range"];
		start = doir.lsp.session.offsetAt(s, r["start"], text);
		end = doir.lsp.session.offsetAt(s, r["end"], text);
		// Lexing starts where a declaration does, where the whole file's tokens start too, and reads to the end of the range's last line.
		fp.dynarray.free(doir.lsp.store.enclosingAt(s, o.file, start, from));
		end = fp.rope.lineEnd(text, end);
		if (start > end) start = end;
	}
	auto copied = fp.rope.text(text, from, end);
	char* bytes = copied.get(null);
	scope(exit) fp.string.free(bytes);
	uint* data = null;
	scope(exit) fp.dynarray.free(data);
	size_t line, character;
	doir.lsp.positions.positionOf(text, s.encoding, from, line, character);
	if (copied.isNull || !doir.lsp.tokens.encode(fp.string.slice(bytes), s.encoding, line, character, start - from, end - from, data)) {
		doir.lsp.session.respondError(s, id, -32_603, "out of memory highlighting the document");
		return;
	}
	bc.json.Document d;
	auto numbers = bc.json.setArray(bc.json.setObject(doir.lsp.session.response(d, id), "result"), "data");
	bc.json.appendAll(numbers, fp.dynarray.slice(data));
	doir.lsp.session.send(s, d);
}
