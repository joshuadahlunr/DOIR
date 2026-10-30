/// Selection ranges for the language server (`roadmap.md` Phase 3): from the identifier at the cursor through the declarations enclosing it to the file.
module doir.lsp.features.selection;

static import fp.dynarray;
static import fp.pointer;
static import fp.rope;
static import fp.string;

static import bc.json;

static import doir.lsp.session;
static import doir.lsp.store;
static import doir.source;

@nogc nothrow:

/// Answers a `textDocument/selectionRange` request: for each position, the identifier there inside each declaration enclosing it, then the file.
///
/// Examples:
/// ---
/// doir.lsp.session.Fixture f;
/// assert(doir.lsp.session.open(f, "x : T = 1\n"));
/// scope(exit) doir.lsp.session.free(f);
/// assert(doir.lsp.session.parse(f, `{"textDocument":{"uri":"file:///t.doir"},"positions":[{"line":0,"character":4}]}`));
/// selectionRange(f.s, doir.lsp.session.params(f), doir.lsp.session.id(f));
/// assert(doir.lsp.session.responds(f, `"parent":{"range":{"start":{"line":0,"character":0}`));
/// ---
package(doir) void selectionRange(ref doir.lsp.session.Session s, bc.json.Value params, bc.json.Value id) {
	auto o = doir.lsp.session.documentOf(s, params, id);
	if (o is null) return;
	const text = doir.source.textOf(*s.engine, o.file);
	bc.json.Document d;
	auto ranges = bc.json.setArray(doir.lsp.session.response(d, id), "result");
	foreach (position; bc.json.elements(params["positions"])) {
		immutable at = doir.lsp.session.offsetAt(s, position, text);
		size_t boundary, nameStart;
		doir.lsp.store.Found* chain = doir.lsp.store.enclosingAt(s, o.file, at, boundary);
		scope(exit) fp.dynarray.free(chain);
		char* name = doir.lsp.store.identifierAt(text, at, nameStart);
		scope(exit) fp.string.free(name);
		size_t lastStart = fp.pointer.notFound, lastEnd;
		bc.json.Value current;
		// Each range is the parent of the one before, so one equal to it adds nothing.
		void level(size_t start, size_t end) {
			if (start == lastStart && end == lastEnd) return;
			current = bc.json.exists(current) ? bc.json.setObject(current, "parent") : bc.json.appendObject(ranges);
			doir.lsp.session.range(s, bc.json.setObject(current, "range"), text, start, end);
			lastStart = start;
			lastEnd = end;
		}
		level(name is null ? at : nameStart, name is null ? at : nameStart + fp.string.length(name));
		foreach_reverse (ref f; fp.dynarray.slice(chain)) level(f.start, f.end);
		level(0, fp.rope.length(text));
	}
	doir.lsp.session.send(s, d);
}
