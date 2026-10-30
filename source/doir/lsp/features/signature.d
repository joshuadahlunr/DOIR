/// Signature help for the language server (`roadmap.md` Phase 3): lexes back to the innermost open call and lists the parameters of the function type its callee resolves to, the active one counted past deduced parameters, which a call never writes (`D-Deduce`).
module doir.lsp.features.signature;

static import fp.dynarray;
static import fp.rope;
static import fp.string;

static import bc.json;
static import ecrs.context;

static import doir.components.ast;
static import doir.lsp.session;
static import doir.lsp.store;
static import doir.source;
static import doir.strings;
static import doir.syntax.lexer;

public import ecrs.registry : invalidEntity;

@nogc nothrow:

// A call the cursor is inside, as `signatureHelp` finds it: where its callee is written, and how many arguments precede the cursor.
private struct OpenCall {
	size_t start, length; // the callee; length 0 for a parenthesis no name precedes, such as a function type's
	uint commas;
}

/// Answers a `textDocument/signatureHelp` request with the parameters of the innermost call the cursor is inside, resolved through the store, or null outside a call.
///
/// Examples:
/// ---
/// doir.lsp.session.Fixture f;
/// assert(doir.lsp.session.open(f, "g : (a: T) -> T\ny : T = g(\n"));
/// scope(exit) doir.lsp.session.free(f);
/// assert(doir.lsp.session.parse(f, `{"textDocument":{"uri":"file:///t.doir"},"position":{"line":1,"character":10}}`));
/// signatureHelp(f.s, doir.lsp.session.params(f), doir.lsp.session.id(f));
/// assert(doir.lsp.session.responds(f, `"label":"g(a: T) -> T"`));
/// ---
package(doir) void signatureHelp(ref doir.lsp.session.Session s, bc.json.Value params, bc.json.Value id) {
	auto o = doir.lsp.session.documentOf(s, params, id);
	if (o is null) return;
	const text = doir.source.textOf(*s.engine, o.file);
	immutable at = doir.lsp.session.offsetAt(s, params["position"], text);
	size_t from;
	fp.dynarray.free(doir.lsp.store.enclosingAt(s, o.file, at, from));
	char* bytes = fp.rope.text(text, from, at).get(null);
	scope(exit) fp.dynarray.free(bytes);
	OpenCall* open = null;
	scope(exit) fp.dynarray.free(open);
	if (bytes !is null) {
		auto source = bytes[0 .. at - from];
		auto cursor = doir.syntax.lexer.Cursor(source);
		doir.syntax.lexer.Token previous;
		while (cursor.at < source.length) {
			immutable t = doir.syntax.lexer.next(cursor);
			switch (t.kind) with (doir.syntax.lexer.TokenKind) {
				case whitespace, newline, lineComment, longComment: continue;
				case leftParen:
					immutable call = previous.kind == identifier ? OpenCall(from + previous.start, previous.length) : OpenCall(from, 0);
					if (!fp.dynarray.pushBack(open, call)) {
						doir.lsp.session.respondError(s, id, -32_603, "out of memory finding the call");
						return;
					}
					break;
				case rightParen: if (fp.dynarray.length(open)) cast(void) fp.dynarray.removeLast(open); break;
				case comma: if (fp.dynarray.length(open)) ++open[fp.dynarray.length(open) - 1].commas; break;
				default: break;
			}
			previous = t;
		}
	}
	immutable n = fp.dynarray.length(open);
	if (n == 0 || open[n - 1].length == 0) return doir.lsp.session.respondNull(s, id);
	immutable call = open[n - 1];
	char* callee = fp.rope.text(text, call.start, call.start + call.length).get(null);
	scope(exit) fp.dynarray.free(callee);
	immutable target = callee is null ? doir.lsp.store.Found(invalidEntity) : doir.lsp.store.resolve(s, o.file, call.start, callee[0 .. call.length]);
	immutable type = target.e == invalidEntity ? invalidEntity : doir.lsp.store.functionTypeOf(s, o.file, target);
	if (type == invalidEntity) return doir.lsp.session.respondNull(s, id);
	auto store = s.engine.store;
	auto inputs = fp.dynarray.slice(ecrs.context.getComponent!(doir.components.ast.FunctionInputs)(*store, type).related);
	char* label = null;
	scope(exit) fp.dynarray.free(label);
	bool fits = fp.string.append(label, callee[0 .. call.length], "(");
	size_t[2]* parameters = null; // each parameter's start and end in `label`
	scope(exit) fp.dynarray.free(parameters);
	foreach (i, p; inputs) {
		auto name = ecrs.context.findComponent!(doir.components.ast.Name)(*store, p);
		auto ofType = ecrs.context.findComponent!(doir.components.ast.LookupTypeOf)(*store, p);
		immutable start = fp.dynarray.length(label) + (i ? 2 : 0);
		fits = fits && fp.string.append(label, i ? ", " : "", name is null ? "_" : doir.strings.text(*s.strings, name.value), ofType is null ? "" : ": ", ofType is null ? "" : doir.strings.text(*s.strings, ofType.name));
		fits = fits && fp.dynarray.pushBack(parameters, cast(size_t[2]) [start, fp.dynarray.length(label)]);
	}
	auto returns = ecrs.context.findComponent!(doir.components.ast.LookupFunctionReturn)(*store, type);
	fits = fits && fp.string.append(label, ")", returns is null ? "" : " -> ", returns is null ? "" : doir.strings.text(*s.strings, returns.name));
	if (!fits) return doir.lsp.session.respondError(s, id, -32_603, "out of memory describing the signature");
	auto written = label[0 .. fp.dynarray.length(label)];
	bc.json.Document d;
	auto result = bc.json.setObject(doir.lsp.session.response(d, id), "result");
	auto signature = bc.json.appendObject(bc.json.setArray(result, "signatures"));
	bc.json.set(signature, "label", written);
	auto list = bc.json.setArray(signature, "parameters");
	foreach (ref span; fp.dynarray.slice(parameters)) bc.json.set(bc.json.appendObject(list), "label", written[span[0] .. span[1]]);
	bc.json.set(result, "activeSignature", 0);
	bc.json.set(result, "activeParameter", doir.lsp.store.parameterOf(s, inputs, call.commas));
	doir.lsp.session.send(s, d);
}
