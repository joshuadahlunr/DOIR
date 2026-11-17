/// Workspace symbols for the language server (`roadmap.md` Phase 3): the open documents' declarations whose names contain the query, ignoring the case of ASCII letters.
module doir.lsp.features.workspace;

static import fp.dynarray;
static import fp.pointer;
static import fp.rope;
static import fp.string;
static import fp.string.ascii;
static import fp.tree;

static import bc.json;
static import ecrs.context;

static import doir.core.components.ast;
static import doir.core.components.source;
static import doir.lsp.session;
static import doir.lsp.store;
static import doir.source;
static import doir.core.strings;

public import ecrs.registry : EntityId;

@nogc nothrow:

// How many workspace symbols one answer lists at most; an editor asks again as more of the query is typed.
private enum size_t symbolLimit = 1000;

// Appends to `symbols` the declarations under `root` in document `o` whose names contain `query`, each with the name of the one it is nested in, counting them in `written`.
private void workspaceSymbols(ref doir.lsp.session.Session s, bc.json.Value symbols, ref doir.lsp.session.Opened o, const fp.rope.Rope text, EntityId root, const(char)[] query, ref size_t written) {
	// Each open declaration's first byte and name.
	size_t[doir.source.BlockTree.maxDepth + 1] starts = void;
	const(char)[][doir.source.BlockTree.maxDepth + 1] names = void;
	starts[0] = 0;
	names[0] = null;
	auto w = fp.tree.walk(doir.source.BlockTree(s.engine.store), root);
	foreach (step; w) {
		if (step.event != fp.tree.Event.enter || step.depth == 0) continue;
		if (written == symbolLimit) return;
		immutable child = step.index;
		const container = names[step.depth - 1];
		immutable span = ecrs.context.getComponent!(doir.core.components.source.SourceSpan)(*s.engine.store, child);
		immutable start = starts[step.depth] = starts[step.depth - 1] + span.offset;
		auto n = ecrs.context.findComponent!(doir.core.components.ast.Name)(*s.engine.store, child);
		const name = names[step.depth] = n is null ? "" : doir.core.strings.text(*s.strings, n.value);
		if (name.length && fp.string.ascii.findIgnoringCase(name, query) != fp.pointer.notFound) {
			++written;
			auto symbol = bc.json.appendObject(symbols);
			bc.json.set(symbol, "name", name);
			bc.json.set(symbol, "kind", doir.lsp.store.symbolKind(s, child));
			if (container.length) bc.json.set(symbol, "containerName", container);
			auto location = bc.json.setObject(symbol, "location");
			bc.json.set(location, "uri", fp.string.slice(o.uri));
			doir.lsp.session.range(s, bc.json.setObject(location, "range"), text, start, start + span.length);
		}
	}
	assert(w.status == fp.tree.Status.ok, "doir.lsp.features.workspace: blocks nested deeper than a commit builds (IL-Nest)");
}

/// Answers a `workspace/symbol` request with the declarations of the open documents whose names contain `params.query`, ignoring the case of ASCII letters.
///
/// Examples:
/// ---
/// doir.lsp.session.Fixture f;
/// assert(doir.lsp.session.open(f, "Value : T = 1\nother : T = 2\n"));
/// scope(exit) doir.lsp.session.free(f);
/// assert(doir.lsp.session.parse(f, `{"query":"val"}`));
/// workspaceSymbol(f.s, doir.lsp.session.params(f), doir.lsp.session.id(f));
/// assert(doir.lsp.session.responds(f, `"result":[{"name":"Value"`));
/// ---
package(doir) void workspaceSymbol(ref doir.lsp.session.Session s, bc.json.Value params, bc.json.Value id) {
	auto decoded = bc.json.decode(params["query"]);
	if (decoded.isNull) return doir.lsp.session.respondError(s, id, -32_603, "out of memory reading the query");
	char* query = decoded.get;
	scope(exit) fp.string.free(query);
	bc.json.Document d;
	auto symbols = bc.json.setArray(doir.lsp.session.response(d, id), "result");
	size_t written = 0;
	foreach (ref o; fp.dynarray.slice(s.opened))
		if (o.open) workspaceSymbols(s, symbols, o, doir.source.textOf(*s.engine, o.file), doir.source.rootOf(*s.engine, o.file), query is null ? "" : fp.string.slice(query), written);
	doir.lsp.session.send(s, d);
}
