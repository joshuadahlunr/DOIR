/// The document outline for the language server (`roadmap.md` Phase 3): `textDocument/documentSymbol` from `Block`, `Name` and `SourceSpan`.
module doir.lsp.features.symbols;

static import fp.rope;

static import bc.json;
static import ecrs.context;

static import doir.components.ast;
static import doir.components.source;
static import doir.lsp.session;
static import doir.lsp.store;
static import doir.source;
static import doir.strings;

public import ecrs.registry : EntityId;

@nogc nothrow:

// bounded: doir.syntax.parser.maxNesting, the deepest blocks a commit builds
// Appends to `list` the symbols of `block`'s declarations, each with its own as children.
private void symbols(ref doir.lsp.session.Session s, bc.json.Value list, const fp.rope.Rope text, EntityId block, size_t base) {
	foreach (child; doir.lsp.store.childrenOf(s, block)) {
		immutable span = ecrs.context.getComponent!(doir.components.source.SourceSpan)(*s.engine.store, child);
		immutable start = base + span.offset, end = start + span.length;
		auto n = ecrs.context.findComponent!(doir.components.ast.Name)(*s.engine.store, child);
		const name = n is null ? "_" : doir.strings.text(*s.strings, n.value);
		// The name is the declaration's first word, after `export` if it has one.
		immutable at = !fp.rope.equalAt(text, start, name) && fp.rope.equalAt(text, start, "export ") ? start + 7 : start;
		auto symbol = bc.json.appendObject(list);
		bc.json.set(symbol, "name", name);
		if (auto t = ecrs.context.findComponent!(doir.components.ast.LookupTypeOf)(*s.engine.store, child))
			bc.json.set(symbol, "detail", doir.strings.text(*s.strings, t.name));
		bc.json.set(symbol, "kind", doir.lsp.store.symbolKind(s, child));
		// The selection first: it shares the range's first line, so the line found for one serves the other.
		doir.lsp.session.range(s, bc.json.setObject(symbol, "selectionRange"), text, at, at + name.length < end ? at + name.length : end);
		doir.lsp.session.range(s, bc.json.setObject(symbol, "range"), text, start, end);
		if (doir.lsp.store.childrenOf(s, child).length) symbols(s, bc.json.setArray(symbol, "children"), text, child, start);
	}
}

/// Answers a `textDocument/documentSymbol` request with the document's declarations, nested as their blocks are.
///
/// Examples:
/// ---
/// doir.lsp.session.Fixture f;
/// assert(doir.lsp.session.open(f, "x : T = 1\n"));
/// scope(exit) doir.lsp.session.free(f);
/// assert(doir.lsp.session.parse(f, `{"textDocument":{"uri":"file:///t.doir"}}`));
/// documentSymbol(f.s, doir.lsp.session.params(f), doir.lsp.session.id(f));
/// assert(doir.lsp.session.responds(f, `"name":"x","detail":"T"`));
/// ---
package(doir) void documentSymbol(ref doir.lsp.session.Session s, bc.json.Value params, bc.json.Value id) {
	auto o = doir.lsp.session.documentOf(s, params, id);
	if (o is null) return;
	bc.json.Document d;
	symbols(s, bc.json.setArray(doir.lsp.session.response(d, id), "result"), doir.source.textOf(*s.engine, o.file), doir.source.rootOf(*s.engine, o.file), 0);
	doir.lsp.session.send(s, d);
}
