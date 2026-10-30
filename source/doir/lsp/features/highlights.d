/// Document highlights for the language server (`roadmap.md` Phase 3): lexes the block declaring the name at the cursor, or the whole file for a namespace's member, which dotted names reach from anywhere, and keeps each name or dotted segment that resolves to the same declaration.
module doir.lsp.features.highlights;

static import fp.pointer;
static import fp.rope;
static import fp.string;

static import bc.json;
static import ecrs.context;

static import doir.components.ast;
static import doir.components.source;
static import doir.lsp.session;
static import doir.lsp.store;
static import doir.source;
static import doir.strings;
static import doir.syntax.lexer;

public import ecrs.registry : invalidEntity;

@nogc nothrow:

/// Answers a `textDocument/documentHighlight` request: every place in the block declaring the name at the cursor, or the file for a namespace's member or a root declaration, where a name or a segment of a dotted one resolves to the same declaration, its own name marked as the write.
///
/// Examples:
/// ---
/// doir.lsp.session.Fixture f;
/// assert(doir.lsp.session.open(f, "x : T = 1\ny : T = x\n"));
/// scope(exit) doir.lsp.session.free(f);
/// assert(doir.lsp.session.parse(f, `{"textDocument":{"uri":"file:///t.doir"},"position":{"line":1,"character":8}}`));
/// documentHighlight(f.s, doir.lsp.session.params(f), doir.lsp.session.id(f));
/// assert(doir.lsp.session.responds(f, `"kind":3},{"range":{"start":{"line":1,"character":8}`));
/// ---
package(doir) void documentHighlight(ref doir.lsp.session.Session s, bc.json.Value params, bc.json.Value id) {
	auto o = doir.lsp.session.documentOf(s, params, id);
	if (o is null) return;
	const text = doir.source.textOf(*s.engine, o.file);
	immutable at = doir.lsp.session.offsetAt(s, params["position"], text);
	size_t nameStart;
	char* name = doir.lsp.store.identifierAt(text, at, nameStart);
	scope(exit) fp.string.free(name);
	// Of a dotted name, the cursor's segment is the one meant, as `math` in `math.pi`.
	auto spelled = name is null ? "" : fp.string.slice(name);
	immutable dot = fp.string.find(spelled, '.', at - nameStart);
	immutable segmentEnd = dot == fp.pointer.notFound ? spelled.length : dot;
	immutable target = spelled.length ? doir.lsp.store.resolve(s, o.file, at, spelled[0 .. segmentEnd]) : doir.lsp.store.Found(invalidEntity);
	if (target.e == invalidEntity) return doir.lsp.session.respondNull(s, id);
	auto store = s.engine.store;
	auto targetName = ecrs.context.findComponent!(doir.components.ast.Name)(*store, target.e);
	if (targetName is null) return doir.lsp.session.respondNull(s, id);
	const wanted = doir.strings.text(*s.strings, targetName.value);
	// The declaration's own name follows `export`, if it has one.
	immutable declared = !fp.rope.equalAt(text, target.start, wanted) && fp.rope.equalAt(text, target.start, "export ") ? target.start + 7 : target.start;
	// A namespace's members are read through dotted names from anywhere; anything else only inside the block declaring it.
	size_t from = 0, to = fp.rope.length(text);
	auto parent = ecrs.context.findComponent!(doir.components.ast.Parent)(*store, target.e);
	auto parentFlags = parent is null ? null : ecrs.context.findComponent!(doir.components.ast.Flags)(*store, parent.parent);
	immutable namespace = parentFlags !is null && (parentFlags.flags & doir.components.ast.Flags.Namespace);
	if (parent !is null && !namespace && !ecrs.context.hasComponent!(doir.components.source.InFile)(*store, parent.parent) && ecrs.context.hasComponent!(doir.components.source.SourceSpan)(*store, parent.parent)) {
		from = target.start - ecrs.context.getComponent!(doir.components.source.SourceSpan)(*s.engine.store, target.e).offset;
		to = from + ecrs.context.getComponent!(doir.components.source.SourceSpan)(*s.engine.store, parent.parent).length;
	}
	auto copied = fp.rope.text(text, from, to);
	if (copied.isNull) return doir.lsp.session.respondError(s, id, -32_603, "out of memory reading the document");
	char* bytes = copied.get;
	scope(exit) fp.string.free(bytes);
	auto source = fp.string.slice(bytes);
	bc.json.Document d;
	auto highlights = bc.json.setArray(doir.lsp.session.response(d, id), "result");
	auto cursor = doir.syntax.lexer.Cursor(source);
	while (cursor.at < source.length) {
		immutable t = doir.syntax.lexer.next(cursor);
		if (t.kind != doir.syntax.lexer.TokenKind.identifier) continue;
		const token = doir.syntax.lexer.text(t, source);
		for (size_t start = 0; start < token.length;) {
			immutable nextDot = fp.string.find(token, '.', start);
			immutable end = nextDot == fp.pointer.notFound ? token.length : nextDot;
			if (token[start .. end] == wanted && doir.lsp.store.resolve(s, o.file, from + t.start, token[0 .. end]).e == target.e) {
				immutable where = from + t.start + start;
				auto highlight = bc.json.appendObject(highlights);
				doir.lsp.session.range(s, bc.json.setObject(highlight, "range"), text, where, where + wanted.length);
				bc.json.set(highlight, "kind", where == declared ? 3 : 2); // Write, Read
			}
			start = end + 1;
		}
	}
	doir.lsp.session.send(s, d);
}
