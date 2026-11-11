/// The document outline for the language server (`roadmap.md` Phase 3): `textDocument/documentSymbol` from `Block`, `Name` and `SourceSpan`.
module doir.lsp.features.symbols;

static import fp.rope;
static import fp.tree;

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

// Appends to `list` the symbols of the declarations under `root`, each with those nested in it as children.
private void symbols(ref doir.lsp.session.Session s, bc.json.Value list, const fp.rope.Rope text, EntityId root) {
	// Each open declaration's first byte, and the array its children's symbols go in.
	size_t[doir.source.BlockTree.maxDepth + 1] starts = void;
	bc.json.Value[doir.source.BlockTree.maxDepth + 1] lists = void;
	starts[0] = 0;
	lists[0] = list;
	auto w = fp.tree.walk(doir.source.BlockTree(s.engine.store), root);
	foreach (step; w) {
		if (step.event != fp.tree.Event.enter || step.depth == 0) continue;
		immutable child = step.index;
		immutable span = ecrs.context.getComponent!(doir.components.source.SourceSpan)(*s.engine.store, child);
		immutable start = starts[step.depth] = starts[step.depth - 1] + span.offset, end = start + span.length;
		auto n = ecrs.context.findComponent!(doir.components.ast.Name)(*s.engine.store, child);
		const name = n is null ? "_" : doir.strings.text(*s.strings, n.value);
		// The name is the declaration's first word, after `export` if it has one.
		immutable at = !fp.rope.equalAt(text, start, name) && fp.rope.equalAt(text, start, "export ") ? start + 7 : start;
		auto symbol = bc.json.appendObject(lists[step.depth - 1]);
		bc.json.set(symbol, "name", name);
		if (auto t = ecrs.context.findComponent!(doir.components.ast.LookupTypeOf)(*s.engine.store, child))
			bc.json.set(symbol, "detail", doir.strings.text(*s.strings, t.name));
		bc.json.set(symbol, "kind", doir.lsp.store.symbolKind(s, child));
		// The selection first: it shares the range's first line, so the line found for one serves the other.
		doir.lsp.session.range(s, bc.json.setObject(symbol, "selectionRange"), text, at, at + name.length < end ? at + name.length : end);
		doir.lsp.session.range(s, bc.json.setObject(symbol, "range"), text, start, end);
		if (doir.lsp.store.childrenOf(s, child).length) lists[step.depth] = bc.json.setArray(symbol, "children");
	}
	assert(w.status == fp.tree.Status.ok, "doir.lsp.features.symbols: blocks nested deeper than a commit builds (IL-Nest)");
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
	symbols(s, bc.json.setArray(doir.lsp.session.response(d, id), "result"), doir.source.textOf(*s.engine, o.file), doir.source.rootOf(*s.engine, o.file));
	doir.lsp.session.send(s, d);
}
