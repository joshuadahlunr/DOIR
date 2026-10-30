/// Inlay hints for the language server (`roadmap.md` Phase 3): the parameter each argument of a call in the range binds, walking only the declarations the range overlaps.
module doir.lsp.features.inlay;

static import fp.dynarray;
static import fp.rope;

static import bc.json;
static import ecrs.context;

static import doir.components.ast;
static import doir.components.source;
static import doir.lsp.session;
static import doir.lsp.store;
static import doir.source;
static import doir.strings;
static import doir.syntax.lexer;

public import ecrs.registry : EntityId, invalidEntity;

@nogc nothrow:

// Appends to `hints` an inlay hint before each argument of call declaration `call` of `file`, naming the parameter it binds, unless the argument is that name already.
private void callHints(ref doir.lsp.session.Session s, bc.json.Value hints, const fp.rope.Rope text, EntityId file, doir.lsp.store.Found call) {
	auto store = s.engine.store;
	auto callee = ecrs.context.findComponent!(doir.components.ast.LookupCall)(*store, call.e);
	immutable target = doir.lsp.store.resolve(s, file, call.start, doir.strings.text(*s.strings, callee.name));
	immutable type = target.e == invalidEntity ? invalidEntity : doir.lsp.store.functionTypeOf(s, file, target);
	if (type == invalidEntity) return;
	auto inputs = fp.dynarray.slice(ecrs.context.getComponent!(doir.components.ast.FunctionInputs)(*store, type).related);
	char* bytes = fp.rope.text(text, call.start, call.end).get(null);
	scope(exit) fp.dynarray.free(bytes);
	if (bytes is null) return;
	auto source = bytes[0 .. call.end - call.start];
	auto cursor = doir.syntax.lexer.Cursor(source);
	// The arguments are in the first parenthesis after the declaration's `=`, its type's own parameters coming before it.
	size_t depth = 0, argument = 0;
	bool afterEquals = false, inArguments = false, expecting = false;
	while (cursor.at < source.length) {
		immutable t = doir.syntax.lexer.next(cursor);
		switch (t.kind) with (doir.syntax.lexer.TokenKind) {
			case equals: afterEquals = afterEquals || depth == 0; break;
			case leftParen:
				if (afterEquals && depth == 0) inArguments = expecting = true;
				++depth;
				break;
			case rightParen:
				if (depth) --depth;
				if (inArguments && depth == 0) return;
				break;
			case comma:
				if (inArguments && depth == 1) {
					++argument;
					expecting = true;
				}
				break;
			case identifier:
				if (!inArguments || depth != 1 || !expecting) break;
				expecting = false;
				immutable p = doir.lsp.store.parameterOf(s, inputs, argument);
				auto name = p < inputs.length ? ecrs.context.findComponent!(doir.components.ast.Name)(*store, inputs[p]) : null;
				if (name is null || doir.strings.text(*s.strings, name.value) == doir.syntax.lexer.text(t, source)) break;
				auto hint = bc.json.appendObject(hints);
				doir.lsp.session.position(s, bc.json.setObject(hint, "position"), text, call.start + t.start);
				bc.json.set(hint, "label", doir.strings.text(*s.strings, name.value));
				bc.json.set(hint, "kind", 2); // Parameter
				bc.json.set(hint, "paddingRight", true);
				break;
			default: break;
		}
	}
}

// Appends to `hints` the hints of every call declaration below `block`, which starts at `base`, that overlaps bytes `low` to `high`.
private void hintsIn(ref doir.lsp.session.Session s, bc.json.Value hints, const fp.rope.Rope text, EntityId file, EntityId block, size_t base, size_t low, size_t high) {
	auto children = doir.lsp.store.childrenOf(s, block);
	immutable first = doir.lsp.store.childrenBefore(s, children, base, low);
	foreach (child; children[first ? first - 1 : 0 .. $]) {
		immutable span = ecrs.context.getComponent!(doir.components.source.SourceSpan)(*s.engine.store, child);
		immutable start = base + span.offset, end = start + span.length;
		if (start > high) break;
		if (end < low) continue;
		if (ecrs.context.hasComponent!(doir.components.ast.Block)(*s.engine.store, child)) hintsIn(s, hints, text, file, child, start, low, high);
		else if (ecrs.context.hasComponent!(doir.components.ast.LookupCall)(*s.engine.store, child)) callHints(s, hints, text, file, doir.lsp.store.Found(child, start, end));
	}
}

/// Answers a `textDocument/inlayHint` request with the parameter names of the arguments of the calls in `params.range`.
///
/// Examples:
/// ---
/// doir.lsp.session.Fixture f;
/// assert(doir.lsp.session.open(f, "g : (a: T) -> T\ny : T = g(b)\n"));
/// scope(exit) doir.lsp.session.free(f);
/// assert(doir.lsp.session.parse(f, `{"textDocument":{"uri":"file:///t.doir"},"range":{"start":{"line":0,"character":0},"end":{"line":2,"character":0}}}`));
/// inlayHint(f.s, doir.lsp.session.params(f), doir.lsp.session.id(f));
/// assert(doir.lsp.session.responds(f, `"label":"a"`));
/// ---
package(doir) void inlayHint(ref doir.lsp.session.Session s, bc.json.Value params, bc.json.Value id) {
	auto o = doir.lsp.session.documentOf(s, params, id);
	if (o is null) return;
	const text = doir.source.textOf(*s.engine, o.file);
	auto r = params["range"];
	immutable low = doir.lsp.session.offsetAt(s, r["start"], text), high = doir.lsp.session.offsetAt(s, r["end"], text);
	bc.json.Document d;
	hintsIn(s, bc.json.setArray(doir.lsp.session.response(d, id), "result"), text, o.file, doir.source.rootOf(*s.engine, o.file), 0, low, high);
	doir.lsp.session.send(s, d);
}
