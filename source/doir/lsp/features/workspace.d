/// Workspace symbols for the language server (`roadmap.md` Phase 3): the open documents' declarations whose names contain the query, ignoring the case of ASCII letters.
module doir.lsp.features.workspace;

static import fp.dynarray;
static import fp.pointer;
static import fp.rope;
static import fp.string;
static import fp.string.ascii;

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

// How many workspace symbols one answer lists at most; an editor asks again as more of the query is typed.
private enum size_t symbolLimit = 1000;

// bounded: doir.syntax.parser.maxNesting, the deepest blocks a commit builds
// Appends to `symbols` the declarations of `block`, which starts at `base` in document `o`, whose names contain `query`, below `container`, counting them in `written`.
private void workspaceSymbols(ref doir.lsp.session.Session s, bc.json.Value symbols, ref doir.lsp.session.Opened o, const fp.rope.Rope text, EntityId block, size_t base, const(char)[] query, const(char)[] container, ref size_t written) {
	foreach (child; doir.lsp.store.childrenOf(s, block)) {
		if (written == symbolLimit) return;
		immutable span = ecrs.context.getComponent!(doir.components.source.SourceSpan)(*s.engine.store, child);
		immutable start = base + span.offset;
		auto n = ecrs.context.findComponent!(doir.components.ast.Name)(*s.engine.store, child);
		const name = n is null ? "" : doir.strings.text(*s.strings, n.value);
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
		if (doir.lsp.store.childrenOf(s, child).length) workspaceSymbols(s, symbols, o, text, child, start, query, name, written);
	}
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
		if (o.open) workspaceSymbols(s, symbols, o, doir.source.textOf(*s.engine, o.file), doir.source.rootOf(*s.engine, o.file), 0, query is null ? "" : fp.string.slice(query), "", written);
	doir.lsp.session.send(s, d);
}
