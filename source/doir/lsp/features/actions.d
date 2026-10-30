/// Code actions for the language server (`roadmap.md` Phase 3): the quick fixes each diagnostic carries, as `diagnose.Diagnostic.Fix`, which `publish` sends in the diagnostic's `data` and the client hands back; the checks' hints need a choice the author makes, so they carry none.
module doir.lsp.features.actions;

static import fp.string;

static import bc.json;

static import doir.lsp.session;

@nogc nothrow:

/// Answers a `textDocument/codeAction` request with a quick fix for each fix in the `data` of the diagnostics it names, as `publish` wrote them: a missing closer's `)`, the `=` before a value, or an arrow written together.
///
/// Examples:
/// ---
/// doir.lsp.session.Fixture f;
/// assert(doir.lsp.session.open(f, "f : (a: T\n"));
/// scope(exit) doir.lsp.session.free(f);
/// assert(doir.lsp.session.parse(f, `{"textDocument":{"uri":"file:///t.doir"},"context":{"diagnostics":[{"range":{"start":{"line":0,"character":9},"end":{"line":0,"character":9}},"message":"unclosed","data":{"fixes":[{"title":"Insert","isPreferred":true,"range":{"start":{"line":0,"character":9},"end":{"line":0,"character":9}},"newText":")"}]}}]}}`));
/// codeAction(f.s, doir.lsp.session.params(f), doir.lsp.session.id(f));
/// assert(doir.lsp.session.responds(f, `"newText":")"`));
/// ---
package(doir) void codeAction(ref doir.lsp.session.Session s, bc.json.Value params, bc.json.Value id) {
	auto o = doir.lsp.session.documentOf(s, params, id);
	if (o is null) return;
	bc.json.Document d;
	auto actions = bc.json.setArray(doir.lsp.session.response(d, id), "result");
	foreach (diagnostic; bc.json.elements(params["context"]["diagnostics"])) {
		foreach (fix; bc.json.elements(diagnostic["data"]["fixes"])) {
			if (!bc.json.exists(fix["title"]) || !bc.json.exists(fix["range"]) || !bc.json.exists(fix["newText"])) continue;
			auto action = bc.json.appendObject(actions);
			bc.json.set(action, "title", fix["title"]);
			bc.json.set(action, "kind", "quickfix");
			if (bc.json.boolean(fix["isPreferred"]).get(false)) bc.json.set(action, "isPreferred", true);
			bc.json.append(bc.json.setArray(action, "diagnostics"), diagnostic);
			auto changes = bc.json.setObject(bc.json.setObject(action, "edit"), "changes");
			auto edit = bc.json.appendObject(bc.json.setArray(changes, fp.string.slice(o.uri)));
			bc.json.set(edit, "range", fix["range"]);
			bc.json.set(edit, "newText", fix["newText"]);
		}
	}
	doir.lsp.session.send(s, d);
}
