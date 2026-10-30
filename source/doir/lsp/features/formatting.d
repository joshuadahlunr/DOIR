/// Formatting for the language server (`roadmap.md` Phase 3): `doir.format`'s edits for the whole file, a range, or the line of a `}` just typed, laid out as the client's `doir.format` settings say.
module doir.lsp.features.formatting;

static import fp.dynarray;
static import fp.pointer;
static import fp.rope;
static import fp.string;

static import bc.json;

static import doir.format;
static import doir.lsp.positions;
static import doir.lsp.session;
static import doir.lsp.store;
static import doir.source;

public import ecrs.registry : EntityId, invalidEntity;

@nogc nothrow:

/// Reads the `doir.format` settings object `settings` into `s.format`: `minify`, a boolean, `semicolons`, one of `kept`, `newlines` and `newlinesAfterBraces`, `definitionColons` and `parameterColons`, each `spaced` or `attached`, and `braces`, one of `kept`, `sameLine` and `nextLine`. A member that is absent, or not one of those, leaves its option as it was.
///
/// Examples:
/// ---
/// doir.lsp.session.Fixture f;
/// assert(doir.lsp.session.open(f, ""));
/// scope(exit) doir.lsp.session.free(f);
/// assert(doir.lsp.session.parse(f, `{"minify":true,"braces":"sideways"}`));
/// readFormatSettings(f.s, doir.lsp.session.params(f));
/// assert(f.s.format.minify && f.s.format.braces == doir.format.Braces.kept);
/// ---
package(doir) void readFormatSettings(ref doir.lsp.session.Session s, bc.json.Value settings) {
	s.format.minify = bc.json.boolean(settings["minify"]).get(s.format.minify);
	switch (bc.json.view(settings["semicolons"])) {
		case "kept": s.format.semicolons = doir.format.Semicolons.kept; break;
		case "newlines": s.format.semicolons = doir.format.Semicolons.newlines; break;
		case "newlinesAfterBraces": s.format.semicolons = doir.format.Semicolons.newlinesAfterBraces; break;
		default: break;
	}
	switch (bc.json.view(settings["definitionColons"])) {
		case "spaced": s.format.definitionColons = doir.format.Colons.spaced; break;
		case "attached": s.format.definitionColons = doir.format.Colons.attached; break;
		default: break;
	}
	switch (bc.json.view(settings["parameterColons"])) {
		case "spaced": s.format.parameterColons = doir.format.Colons.spaced; break;
		case "attached": s.format.parameterColons = doir.format.Colons.attached; break;
		default: break;
	}
	switch (bc.json.view(settings["braces"])) {
		case "kept": s.format.braces = doir.format.Braces.kept; break;
		case "sameLine": s.format.braces = doir.format.Braces.sameLine; break;
		case "nextLine": s.format.braces = doir.format.Braces.nextLine; break;
		default: break;
	}
}

// Shows `message` to the user as a `window/showMessage` of LSP MessageType `type` (1 error, 2 warning, 3 info).
private void showMessage(ref doir.lsp.session.Session s, long type, const(char)[] message) {
	bc.json.Document d;
	auto root = bc.json.setObject(d);
	bc.json.set(root, "jsonrpc", "2.0");
	bc.json.set(root, "method", "window/showMessage");
	auto params = bc.json.setObject(root, "params");
	bc.json.set(params, "type", type);
	bc.json.set(params, "message", message);
	doir.lsp.session.send(s, d);
}

// Where `format` may start for an edit at byte `at` of `file`: the start of the line holding the root declaration `at` is in, if nothing precedes the declaration there, else the file's start.
private size_t formatStart(ref doir.lsp.session.Session s, const fp.rope.Rope text, EntityId file, size_t at) {
	immutable found = doir.lsp.store.childAt(s, doir.source.rootOf(*s.engine, file), 0, at);
	if (found.e == invalidEntity) return 0;
	size_t line, character;
	doir.lsp.positions.positionOf(text, doir.lsp.positions.Encoding.utf8, found.start, line, character);
	char* before = fp.rope.text(text, found.start - character, found.start).get(null);
	scope(exit) fp.string.free(before);
	if (character && before is null) return 0;
	return fp.string.trimStart(fp.string.slice(before), " \t").length == 0 ? found.start - character : 0;
}

/// Answers a `textDocument/formatting`, `rangeFormatting` or `onTypeFormatting` request with `doir.format`'s edits: for the whole file, or for the lines of `params.range`, or for the line of `params.position` (on typing `}`).
///
/// Examples:
/// ---
/// doir.lsp.session.Fixture f;
/// assert(doir.lsp.session.open(f, "x:T=1\n"));
/// scope(exit) doir.lsp.session.free(f);
/// assert(doir.lsp.session.parse(f, `{"textDocument":{"uri":"file:///t.doir"},"options":{"tabSize":4,"insertSpaces":false}}`));
/// formatting(f.s, doir.lsp.session.params(f), doir.lsp.session.id(f));
/// assert(doir.lsp.session.responds(f, `"newText":"x : T = 1"`));
/// ---
package(doir) void formatting(ref doir.lsp.session.Session s, bc.json.Value params, bc.json.Value id) {
	auto o = doir.lsp.session.documentOf(s, params, id);
	if (o is null) return;
	const text = doir.source.textOf(*s.engine, o.file);
	immutable length = fp.rope.length(text);
	size_t low = 0, high = length;
	auto r = params["range"], p = params["position"];
	if (bc.json.exists(r) || bc.json.exists(p)) {
		immutable start = doir.lsp.session.offsetAt(s, bc.json.exists(r) ? r["start"] : p, text);
		immutable end = bc.json.exists(r) ? doir.lsp.session.offsetAt(s, r["end"], text) : start;
		size_t line, character;
		doir.lsp.positions.positionOf(text, doir.lsp.positions.Encoding.utf8, start, line, character);
		low = start - character;
		high = fp.rope.lineEnd(text, end);
	}
	immutable from = formatStart(s, text, o.file, low);
	// The text reaches to the end of the root declaration `high` is in, so no token is cut.
	immutable last = doir.lsp.store.childAt(s, doir.source.rootOf(*s.engine, o.file), 0, high);
	size_t to = length;
	if (last.e != invalidEntity && high < last.end) {
		to = fp.rope.lineEnd(text, last.end);
	}
	auto copied = fp.rope.text(text, from, to);
	char* bytes = copied.get(null);
	scope(exit) fp.string.free(bytes);
	doir.format.Formatted f;
	scope(exit) doir.format.free(f);
	// Minifying puts the file on one line, which only means something for the whole file.
	doir.format.Options options = s.format;
	options.minify = options.minify && low == 0 && high == length;
	if (copied.isNull || !doir.format.format(fp.string.slice(bytes), 0, f, options)) {
		doir.lsp.session.respondError(s, id, -32_603, "out of memory formatting the document");
		return;
	}
	if (f.unlexed != fp.pointer.notFound) {
		// Formatting changes nothing then, so without a word the request would seem ignored.
		char* message = fp.string.joined("DOIR cannot format this file: line ", fp.rope.lineOf(text, from + f.unlexed) + 1, " has a string or comment that never closes, or a character no token starts with; fix it and format again").get(null);
		scope(exit) fp.string.free(message);
		if (message !is null) showMessage(s, 2, fp.string.slice(message));
	}
	bc.json.Document d;
	auto edits = bc.json.setArray(doir.lsp.session.response(d, id), "result");
	foreach (ref e; fp.dynarray.slice(f.edits)) {
		if (from + e.start < low || from + e.start > high) continue;
		auto edit = bc.json.appendObject(edits);
		doir.lsp.session.range(s, bc.json.setObject(edit, "range"), text, from + e.start, from + e.end);
		bc.json.set(edit, "newText", e.length ? f.text[e.from .. e.from + e.length] : "");
	}
	doir.lsp.session.send(s, d);
}
