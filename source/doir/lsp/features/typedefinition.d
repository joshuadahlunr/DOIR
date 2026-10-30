/// Go to type definition for the language server (`roadmap.md` Phase 3): `textDocument/typeDefinition`, resolving the type the declaration at the cursor is written with from where that declaration is.
module doir.lsp.features.typedefinition;

static import fp.string;

static import bc.json;
static import ecrs.context;

static import doir.components.ast;
static import doir.lsp.session;
static import doir.lsp.store;
static import doir.source;
static import doir.strings;

public import ecrs.registry : invalidEntity;

@nogc nothrow:

/// Answers a `textDocument/typeDefinition` request with where the type of the declaration the identifier at its position names is declared, or null.
///
/// Examples:
/// ---
/// doir.lsp.session.Fixture f;
/// assert(doir.lsp.session.open(f, "p : type = {}\nx : p = 1\ny : T = x\n"));
/// scope(exit) doir.lsp.session.free(f);
/// assert(doir.lsp.session.parse(f, `{"textDocument":{"uri":"file:///t.doir"},"position":{"line":2,"character":8}}`));
/// typeDefinition(f.s, doir.lsp.session.params(f), doir.lsp.session.id(f));
/// assert(doir.lsp.session.responds(f, `"range":{"start":{"line":0,"character":0}`));
/// ---
package(doir) void typeDefinition(ref doir.lsp.session.Session s, bc.json.Value params, bc.json.Value id) {
	auto o = doir.lsp.session.documentOf(s, params, id);
	if (o is null) return;
	const text = doir.source.textOf(*s.engine, o.file);
	auto found = doir.lsp.store.declarationAt(s, o.file, doir.lsp.session.offsetAt(s, params["position"], text)).declaration;
	// The type is named where the declaration is, so it is looked up from there.
	if (found.e != invalidEntity) {
		auto type = ecrs.context.findComponent!(doir.components.ast.LookupTypeOf)(*s.engine.store, found.e);
		found = type is null ? doir.lsp.store.Found(invalidEntity) : doir.lsp.store.resolve(s, o.file, found.start, doir.strings.text(*s.strings, type.name));
	}
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
