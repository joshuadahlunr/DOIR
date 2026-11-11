/// Completion for the language server (`roadmap.md` Phase 3): the names of every block enclosing the cursor, an inner one shadowing an outer, and the keywords, or after `a.` the entries of the block `a` resolves to, each through the block's name index (`doir.names`).
module doir.lsp.features.completion;

static import std.algorithm.sorting;

static import fp.dynarray;
static import fp.pointer;
static import fp.rope;
static import fp.string;

static import bc.json;
static import ecrs.context;

static import doir.components.ast;
static import doir.format;
static import doir.lsp.positions;
static import doir.lsp.session;
static import doir.lsp.store;
static import doir.names;
static import doir.query;
static import doir.source;
static import doir.strings;
static import doir.syntax.tables;

public import ecrs.registry : EntityId, invalidEntity;

@nogc nothrow:

// A name completion offers, and how deep the block listing it is, so an inner one shadows an outer.
private struct Candidate {
	doir.strings.StringId name;
	size_t depth;
	EntityId e;
}

// The LSP CompletionItemKind of declaration `e`.
private long completionKind(ref doir.lsp.session.Session s, EntityId e) {
	switch (doir.lsp.store.symbolKind(s, e)) {
		case 3: return 9; // Module
		case 23: return 22; // Struct
		case 12: return 3; // Function
		case 14: return 21; // Constant
		default: return 6; // Variable
	}
}

// Answers request `id` with the candidates in `found`, sorted, each name once, and the keywords starting with `partial` unless `qualified`.
private void respond(ref doir.lsp.session.Session s, bc.json.Value id, Candidate* found, const(char)[] partial, bool qualified) {
	// By name, and the deepest first among those sharing one, so it shadows the rest.
	std.algorithm.sorting.sort!((ref a, ref b) => a.name != b.name ? a.name.value < b.name.value : a.depth > b.depth)(fp.dynarray.slice(found));
	// The client filters what it shows as more is typed; past this many it asks again.
	enum size_t limit = 1000;
	bc.json.Document d;
	auto result = bc.json.setObject(doir.lsp.session.response(d, id), "result");
	auto items = bc.json.setArray(result, "items");
	size_t written = 0;
	foreach (i, ref c; fp.dynarray.slice(found)) {
		if (i && found[i - 1].name == c.name) continue; // shadowed by a deeper one, sorted first
		if (written++ == limit) break;
		auto item = bc.json.appendObject(items);
		bc.json.set(item, "label", doir.strings.text(*s.strings, c.name));
		bc.json.set(item, "kind", completionKind(s, c.e));
		if (auto t = ecrs.context.findComponent!(doir.components.ast.LookupTypeOf)(*s.engine.store, c.e))
			bc.json.set(item, "detail", doir.strings.text(*s.strings, t.name));
	}
	if (!qualified)
		foreach (keyword; doir.syntax.tables.keywords) {
			if (!fp.string.startsWith(keyword, partial) || written > limit) continue;
			++written;
			auto item = bc.json.appendObject(items);
			bc.json.set(item, "label", keyword);
			bc.json.set(item, "kind", 14); // Keyword
		}
	bc.json.set(result, "isIncomplete", written > limit);
	doir.lsp.session.send(s, d);
}

/// Answers a `textDocument/completion` request with the names a read at the cursor may name, each starting with what is typed before it.
///
/// Examples:
/// ---
/// doir.lsp.session.Fixture f;
/// assert(doir.lsp.session.open(f, "value : T = 1\ny : T = v\n"));
/// scope(exit) doir.lsp.session.free(f);
/// assert(doir.lsp.session.parse(f, `{"textDocument":{"uri":"file:///t.doir"},"position":{"line":1,"character":9}}`));
/// completion(f.s, doir.lsp.session.params(f), doir.lsp.session.id(f));
/// assert(doir.lsp.session.responds(f, `"items":[{"label":"value"`));
/// ---
package(doir) void completion(ref doir.lsp.session.Session s, bc.json.Value params, bc.json.Value id) {
	auto o = doir.lsp.session.documentOf(s, params, id);
	if (o is null) return;
	const text = doir.source.textOf(*s.engine, o.file);
	immutable at = doir.lsp.session.offsetAt(s, params["position"], text);
	size_t line, character;
	doir.lsp.positions.positionOf(text, doir.lsp.positions.Encoding.utf8, at, line, character);
	char* before = fp.rope.text(text, at - character, at).get(null);
	scope(exit) fp.string.free(before);
	auto typed = fp.string.slice(before);
	size_t start = typed.length;
	while (start && doir.format.wordByte(typed[start - 1])) --start;
	auto word = typed[start .. $];
	immutable lastDot = fp.string.findLast(word, '.');
	immutable dot = lastDot == fp.pointer.notFound ? 0 : lastDot + 1;
	auto partial = word[dot .. $];
	Candidate* found = null;
	scope(exit) fp.dynarray.free(found);
	bool refused = character && before is null;
	void gather(EntityId block, size_t depth) {
		auto entries = doir.query.query!(doir.names.EntriesByName)(*s.engine, doir.names.EntriesByName.Key([block]));
		if (entries is null) {
			refused = true;
			return;
		}
		foreach (e; fp.dynarray.slice(entries.related)) {
			immutable name = ecrs.context.getComponent!(doir.components.ast.Name)(*s.engine.store, e).value;
			const spelled = doir.strings.text(*s.strings, name);
			if (!fp.string.startsWith(spelled, partial)) continue;
			refused = refused || !fp.dynarray.pushBack(found, Candidate(name, depth, e));
		}
	}
	if (dot) {
		immutable target = doir.lsp.store.resolve(s, o.file, at - character + start, word[0 .. dot - 1]);
		if (target.e != invalidEntity) gather(target.e, 0);
	} else {
		size_t boundary;
		doir.lsp.store.Found* chain = doir.lsp.store.enclosingAt(s, o.file, at, boundary);
		scope(exit) fp.dynarray.free(chain);
		gather(doir.source.rootOf(*s.engine, o.file), 0);
		foreach (i, ref f; fp.dynarray.slice(chain))
			if (ecrs.context.hasComponent!(doir.components.ast.Block)(*s.engine.store, f.e)) gather(f.e, i + 1);
	}
	if (refused) {
		doir.lsp.session.respondError(s, id, -32_603, "out of memory listing completions");
		return;
	}
	respond(s, id, found, partial, dot != 0);
}
