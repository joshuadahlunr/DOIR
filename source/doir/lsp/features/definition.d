/// Go to definition for the language server (`roadmap.md` Phase 3): `textDocument/definition`, resolving the name at the cursor outward through the enclosing blocks and then down a dotted path (`doir.lsp.store.resolve`).
module doir.lsp.features.definition;

static import fp.string;

static import bc.json;

static import doir.lsp.session;
static import doir.lsp.store;
static import doir.source;

public import ecrs.registry : invalidEntity;

@nogc nothrow:

/// Answers a `textDocument/definition` request with where the identifier at its position is declared, or null.
///
/// Examples:
/// ---
/// doir.lsp.session.Fixture f;
/// assert(doir.lsp.session.open(f, "x : T = 1\ny : T = x\n"));
/// scope(exit) doir.lsp.session.free(f);
/// assert(doir.lsp.session.parse(f, `{"textDocument":{"uri":"file:///t.doir"},"position":{"line":1,"character":8}}`));
/// definition(f.s, doir.lsp.session.params(f), doir.lsp.session.id(f));
/// assert(doir.lsp.session.responds(f, `"range":{"start":{"line":0,"character":0}`));
/// ---
package(doir) void definition(ref doir.lsp.session.Session s, bc.json.Value params, bc.json.Value id) {
	auto o = doir.lsp.session.documentOf(s, params, id);
	if (o is null) return;
	const text = doir.source.textOf(*s.engine, o.file);
	immutable found = doir.lsp.store.declarationAt(s, o.file, doir.lsp.session.offsetAt(s, params["position"], text)).declaration;
	bc.json.Document d;
	auto response = doir.lsp.session.response(d, id);
	if (found.e == invalidEntity) bc.json.set(response, "result", null);
	else {
		auto location = bc.json.setObject(response, "result");
		bc.json.set(location, "uri", fp.string.slice(o.uri));
		doir.lsp.session.range(s, bc.json.setObject(location, "range"), text, found.start, found.end);
	}
	doir.lsp.session.send(s, d);
}
