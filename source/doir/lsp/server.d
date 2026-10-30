/// The DOIR language server (`roadmap.md` Phase 3), `doir --lsp`: one server for every editor, speaking LSP over a pair of file descriptors. It keeps each open document as a file in the store, commits each edit with `doir.source.commitEdit`, so a keystroke costs in proportion to the block it is in, and publishes the file's diagnostics once a burst of edits has been drained. Each request beyond the lifecycle and document sync is answered by a module of `doir.lsp.features`.
///
/// Positions are UTF-8 when the client offers it, as Neovim does, since the store counts bytes, and UTF-16 otherwise, the only encoding VS Code speaks (`doir.lsp.positions`).
///
/// Examples:
/// ---
/// static import fp.io;
/// static import bc.jsonrpc;
/// auto input = fp.io.createPipe().get, output = fp.io.createPipe().get;
/// assert(bc.jsonrpc.send(input.writing, `{"jsonrpc":"2.0","id":1,"method":"shutdown"}`));
/// assert(bc.jsonrpc.send(input.writing, `{"jsonrpc":"2.0","method":"exit"}`));
/// assert(run(input.reading, output.writing) == 0);
/// assert(fp.io.close(input.reading) && fp.io.close(input.writing) && fp.io.close(output.reading) && fp.io.close(output.writing));
/// ---
module doir.lsp.server;

static import fp.dynarray;
static import fp.io;
static import fp.pointer;
static import fp.rope;
static import fp.string;
static import fp.string.ascii;

static import bc.http.message;
static import bc.json;
static import bc.jsonrpc;
static import bc.threadpool;
static import diagnose;
static import ecrs.context;

static import doir.checks;
static import doir.components.source;
static import doir.lsp.features.definition;
static import doir.lsp.features.folding;
static import doir.lsp.features.formatting;
static import doir.lsp.features.hover;
static import doir.lsp.features.selection;
static import doir.lsp.features.semantic;
static import doir.lsp.features.signature;
static import doir.lsp.features.symbols;
static import doir.lsp.positions;
static import doir.lsp.session;
static import doir.lsp.tokens;
static import doir.query;
static import doir.source;
static import doir.strings;

public import ecrs.registry : EntityId, invalidEntity;

@nogc nothrow:


// --- documents ---------------------------------------------------------------

// The path a `file://` URI names, percent-decoded, as a new fp string; any other URI is its own path. Null on refusal or for an empty URI.
private char* pathOf(const(char)[] uri) {
	static immutable scheme = "file://";
	return bc.http.message.percentDecoded(fp.string.startsWith(uri, scheme) ? uri[scheme.length .. $] : uri).get(null);
}


// --- diagnostics -------------------------------------------------------------

// The byte offset of a libdiagnose position, 1-based with column 0 meaning the line's end.
private size_t offsetOf(const fp.rope.Rope text, diagnose.LineColumn at) {
	immutable start = fp.rope.lineStart(text, at.line - 1);
	if (start == fp.pointer.notFound) return fp.rope.length(text);
	if (at.column == 0) return fp.rope.lineEnd(text, start);
	return start + at.column - 1;
}

// A rule tag at the start of `message`, such as `V-Literal`, which the client shows as the diagnostic's code.
private const(char)[] ruleTag(const(char)[] message) {
	size_t i = 0;
	while (i < message.length && fp.string.ascii.isUpper(message[i])) ++i;
	if (i == 0 || i >= message.length || message[i] != '-') return null;
	size_t j = i + 1;
	while (j < message.length && fp.string.ascii.isLetter(message[j])) ++j;
	return j > i + 1 && j < message.length && message[j] == ':' ? message[0 .. j] : null;
}

// Sends `o`'s diagnostics: its syntax errors, each at its range with its hint, the other positions it points at as related information, and its fixes as `data`.
private void publish(ref doir.lsp.session.Session s, ref doir.lsp.session.Opened o) {
	o.stale = false;
	diagnose.Manager manager;
	scope(exit) diagnose.free(manager);
	if (o.open && !doir.source.reportSyntaxErrors(*s.engine, o.file, manager)) cast(void) fp.io.print(fp.io.Console.error, "doir --lsp: out of memory gathering diagnostics\n");
	// The checks report to the engine's manager, from their memos when nothing they read changed.
	s.engine.diagnostics = &manager;
	if (o.open && !doir.checks.check(*s.engine, o.file)) cast(void) fp.io.print(fp.io.Console.error, "doir --lsp: out of memory checking a document\n");
	s.engine.diagnostics = null;
	const text = doir.source.textOf(*s.engine, o.file);
	bc.json.Document message;
	auto root = bc.json.setObject(message);
	bc.json.set(root, "jsonrpc", "2.0");
	bc.json.set(root, "method", "textDocument/publishDiagnostics");
	auto params = bc.json.setObject(root, "params");
	bc.json.set(params, "uri", fp.string.slice(o.uri));
	if (o.open) bc.json.set(params, "version", o.version_);
	auto diagnostics = bc.json.setArray(params, "diagnostics");
	// The checks replay every file's memoized diagnostics, so only this document's are kept.
	const path = doir.strings.text(*s.strings, ecrs.context.getComponent!(doir.components.source.SourceFile)(*s.engine.store, o.file).path);
	foreach (ref d; fp.dynarray.slice(manager.diagnostics)) {
		if (d.location.file != path) continue;
		const text_ = fp.string.slice(d.message);
		auto annotations = fp.dynarray.slice(d.annotations);
		auto diagnostic = bc.json.appendObject(diagnostics);
		doir.lsp.session.range(s, bc.json.setObject(diagnostic, "range"), text, offsetOf(text, d.location.start), offsetOf(text, d.location.end));
		bc.json.set(diagnostic, "severity", d.kind == diagnose.Kind.error ? 1 : d.kind == diagnose.Kind.warning ? 2 : d.kind == diagnose.Kind.note ? 3 : 4);
		bc.json.set(diagnostic, "source", "doir");
		if (auto tag = ruleTag(text_)) bc.json.set(diagnostic, "code", tag);
		// The hint goes in the message, on its second line, then the note: every client shows the message, few show related information inline.
		const hint = annotations.length && annotations[0].message !is null ? fp.string.slice(annotations[0].message) : null;
		const note = fp.string.slice(d.note);
		char* full = hint is null && note.length == 0 ? null : fp.string.joined(text_, "\n", hint is null ? note : hint, hint is null || note.length == 0 ? "" : "\n", hint is null ? "" : note).get(null);
		scope(exit) fp.string.free(full);
		bc.json.set(diagnostic, "message", full !is null ? fp.string.slice(full) : text_);
		// The client hands `data` back with a `codeAction` request, so the fixes travel with the diagnostic rather than being looked up again.
		if (fp.dynarray.length(d.fixes)) {
			auto fixes = bc.json.setArray(bc.json.setObject(diagnostic, "data"), "fixes");
			foreach (ref f; fp.dynarray.slice(d.fixes)) {
				auto fix = bc.json.appendObject(fixes);
				bc.json.set(fix, "title", fp.string.slice(f.title));
				if (f.preferred) bc.json.set(fix, "isPreferred", true);
				doir.lsp.session.range(s, bc.json.setObject(fix, "range"), text, offsetOf(text, f.range.start), offsetOf(text, f.range.end));
				bc.json.set(fix, "newText", fp.string.slice(f.replacement));
			}
		}
		if (annotations.length > 1) {
			auto related = bc.json.setArray(diagnostic, "relatedInformation");
			foreach (ref a; annotations[1 .. $]) {
				if (a.file.length) continue;
				immutable at = offsetOf(text, a.position);
				auto information = bc.json.appendObject(related);
				auto location = bc.json.setObject(information, "location");
				bc.json.set(location, "uri", fp.string.slice(o.uri));
				doir.lsp.session.range(s, bc.json.setObject(location, "range"), text, at, at);
				bc.json.set(information, "message", fp.string.slice(a.message));
			}
		}
	}
	doir.lsp.session.send(s, message);
}


// --- handlers ----------------------------------------------------------------

private void initialize(ref doir.lsp.session.Session s, bc.json.Value params, bc.json.Value id) {
	doir.lsp.features.formatting.readFormatSettings(s, params["initializationOptions"]["format"]);
	foreach (offered; bc.json.elements(params["capabilities"]["general"]["positionEncodings"]))
		if (bc.json.view(offered) == "utf-8") s.encoding = doir.lsp.positions.Encoding.utf8;
	bc.json.Document d;
	auto result = bc.json.setObject(doir.lsp.session.response(d, id), "result");
	auto capabilities = bc.json.setObject(result, "capabilities");
	bc.json.set(capabilities, "positionEncoding", s.encoding == doir.lsp.positions.Encoding.utf8 ? "utf-8" : "utf-16");
	auto sync = bc.json.setObject(capabilities, "textDocumentSync");
	bc.json.set(sync, "openClose", true);
	bc.json.set(sync, "change", 2); // incremental
	auto semantic = bc.json.setObject(capabilities, "semanticTokensProvider");
	auto legend = bc.json.setObject(semantic, "legend");
	auto types = bc.json.setArray(legend, "tokenTypes");
	bc.json.appendAll(types, doir.lsp.tokens.typeNames[]);
	auto modifiers = bc.json.setArray(legend, "tokenModifiers");
	bc.json.appendAll(modifiers, doir.lsp.tokens.modifierNames[]);
	bc.json.set(semantic, "full", true);
	bc.json.set(semantic, "range", true);
	bc.json.set(capabilities, "documentSymbolProvider", true);
	bc.json.set(capabilities, "foldingRangeProvider", true);
	bc.json.set(capabilities, "definitionProvider", true);
	bc.json.set(capabilities, "hoverProvider", true);
	bc.json.set(capabilities, "selectionRangeProvider", true);
	auto signature = bc.json.setArray(bc.json.setObject(capabilities, "signatureHelpProvider"), "triggerCharacters");
	bc.json.append(signature, "(");
	bc.json.append(signature, ",");
	bc.json.set(capabilities, "documentFormattingProvider", true);
	bc.json.set(capabilities, "documentRangeFormattingProvider", true);
	bc.json.set(bc.json.setObject(capabilities, "documentOnTypeFormattingProvider"), "firstTriggerCharacter", "}");
	bc.json.set(bc.json.setObject(result, "serverInfo"), "name", "doir");
	doir.lsp.session.send(s, d);
}

// Commits `text` whole as `o`'s new contents.
private void commitWhole(ref doir.lsp.session.Session s, ref doir.lsp.session.Opened o, const(char)[] text) {
	if (doir.source.commit(*s.engine, *s.strings, o.file, text) == fp.pointer.allocationRefused) cast(void) fp.io.print(fp.io.Console.error, "doir --lsp: out of memory committing a document; it keeps its previous text\n");
}

private void didOpen(ref doir.lsp.session.Session s, bc.json.Value params) {
	auto document = params["textDocument"];
	auto decodedUri = bc.json.decode(document["uri"]), decodedText = bc.json.decode(document["text"]);
	char* uri = decodedUri.isNull ? null : decodedUri.get;
	char* text = decodedText.isNull ? null : decodedText.get;
	scope(exit) fp.string.free(text);
	if (decodedUri.isNull || decodedText.isNull || uri is null) {
		fp.string.free(uri);
		cast(void) fp.io.print(fp.io.Console.error, "doir --lsp: out of memory, or no URI, opening a document\n");
		return;
	}
	auto o = doir.lsp.session.find(s, fp.string.slice(uri));
	if (o !is null) fp.string.free(uri);
	else {
		char* path = pathOf(fp.string.slice(uri));
		scope(exit) fp.string.free(path);
		immutable file = path is null ? invalidEntity : doir.source.addFile(*s.engine, *s.strings, fp.string.slice(path));
		if (file == invalidEntity || !fp.dynarray.pushBack(s.opened, doir.lsp.session.Opened(uri, file))) {
			fp.string.free(uri);
			cast(void) fp.io.print(fp.io.Console.error, "doir --lsp: out of memory opening a document\n");
			return;
		}
		o = &s.opened[fp.dynarray.length(s.opened) - 1];
	}
	o.open = o.stale = true;
	o.version_ = bc.json.integer(document["version"]).get(0);
	commitWhole(s, *o, fp.string.slice(text));
}

private void didChange(ref doir.lsp.session.Session s, bc.json.Value params) {
	auto document = params["textDocument"];
	auto o = doir.lsp.session.find(s, bc.json.view(document["uri"]));
	if (o is null || !o.open) {
		cast(void) fp.io.print(fp.io.Console.error, "doir --lsp: a change to a document that is not open\n");
		return;
	}
	o.version_ = bc.json.integer(document["version"]).get(o.version_);
	o.stale = true;
	foreach (change; bc.json.elements(params["contentChanges"])) {
		auto decoded = bc.json.decode(change["text"]);
		char* text = decoded.isNull ? null : decoded.get;
		scope(exit) fp.string.free(text);
		if (decoded.isNull) {
			cast(void) fp.io.print(fp.io.Console.error, "doir --lsp: out of memory reading a change; the document is out of step until it is reopened\n");
			return;
		}
		auto r = change["range"];
		if (!bc.json.exists(r)) {
			commitWhole(s, *o, fp.string.slice(text));
			continue;
		}
		const current = doir.source.textOf(*s.engine, o.file);
		size_t[2] at;
		static immutable string[2] ends = ["start", "end"];
		foreach (k, end; ends) {
			auto p = r[end];
			at[k] = doir.lsp.positions.offsetOf(current, s.encoding, bc.json.integer(p["line"]).get(0), bc.json.integer(p["character"]).get(0));
		}
		if (at[1] < at[0]) at[1] = at[0];
		if (doir.source.commitEdit(*s.engine, *s.strings, o.file, at[0], at[1], fp.string.slice(text)) == fp.pointer.allocationRefused)
			cast(void) fp.io.print(fp.io.Console.error, "doir --lsp: out of memory committing a change; the document keeps its previous text\n");
	}
}

private void didClose(ref doir.lsp.session.Session s, bc.json.Value params) {
	auto o = doir.lsp.session.find(s, bc.json.view(params["textDocument"]["uri"]));
	if (o is null) return;
	o.open = false;
	// A closed document's diagnostics are cleared: the client shows only open ones.
	publish(s, *o);
}

// Handles one message; sets `exit` when the client asks to.
private void handle(ref doir.lsp.session.Session s, const(char)[] message, ref bool exit) {
	s.lines = doir.lsp.positions.LineCache.init;
	s.refused = s.engine.refused = false;
	auto parsed = bc.json.parse(message);
	scope(exit) bc.json.free(parsed.document);
	if (parsed.status != bc.json.Status.ok) {
		if (parsed.status == bc.json.Status.malformed) doir.lsp.session.respondError(s, bc.json.Value.init, -32_700, "the message is not JSON");
		else cast(void) fp.io.print(fp.io.Console.error, "doir --lsp: out of memory parsing a message\n");
		return;
	}
	auto request = bc.json.root(parsed.document);
	const method = bc.json.view(request["method"]);
	auto id = request["id"], params = request["params"];
	switch (method) {
		case "initialize": initialize(s, params, id); break;
		case "shutdown":
			s.shutdown = true;
			doir.lsp.session.respondNull(s, id);
			break;
		case "exit": exit = true; break;
		case "textDocument/didOpen": didOpen(s, params); break;
		case "textDocument/didChange": didChange(s, params); break;
		case "textDocument/didClose": didClose(s, params); break;
		case "workspace/didChangeConfiguration": doir.lsp.features.formatting.readFormatSettings(s, params["settings"]["doir"]["format"]); break;
		case "textDocument/semanticTokens/full": doir.lsp.features.semantic.semanticTokens(s, params, id, false); break;
		case "textDocument/semanticTokens/range": doir.lsp.features.semantic.semanticTokens(s, params, id, true); break;
		case "textDocument/documentSymbol": doir.lsp.features.symbols.documentSymbol(s, params, id); break;
		case "textDocument/foldingRange": doir.lsp.features.folding.foldingRange(s, params, id); break;
		case "textDocument/definition": doir.lsp.features.definition.definition(s, params, id); break;
		case "textDocument/hover": doir.lsp.features.hover.hover(s, params, id); break;
		case "textDocument/selectionRange": doir.lsp.features.selection.selectionRange(s, params, id); break;
		case "textDocument/signatureHelp": doir.lsp.features.signature.signatureHelp(s, params, id); break;
		case "textDocument/formatting", "textDocument/rangeFormatting", "textDocument/onTypeFormatting": doir.lsp.features.formatting.formatting(s, params, id); break;
		default:
			// Notifications it does not know, `initialized` and `$/cancelRequest` among them, need nothing; requests get an error.
			if (bc.json.exists(id)) doir.lsp.session.respondError(s, id, -32_601, "the DOIR server does not handle this method");
	}
}


// --- running -----------------------------------------------------------------

/// Serves LSP: reads messages from `input` and writes responses and notifications to `output` until the client sends `exit` or `input` ends. It keeps its own store, and skims large files on a thread pool if one can be started.
///
/// Returns 0 if the client asked to shut down before it exited, 1 otherwise, as LSP's `exit` asks.
///
/// Examples:
/// ---
/// static import fp.io;
/// auto input = fp.io.createPipe().get, output = fp.io.createPipe().get;
/// assert(fp.io.close(input.writing));
/// assert(run(input.reading, output.writing) == 1); // input ended without a shutdown
/// assert(fp.io.close(input.reading) && fp.io.close(output.reading) && fp.io.close(output.writing));
/// ---
int run(int input, int output) {
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	auto engine = doir.query.create(store);
	scope(exit) doir.query.free(engine);
	// Opening a file need not wait for the reverse edges; they are built once its first diagnostics are out.
	engine.edgesMissing = true;
	engine.workers = bc.threadpool.create();
	scope(exit) bc.threadpool.free(engine.workers);
	doir.strings.Strings strings;
	scope(exit) doir.strings.free(strings);
	engine.strings = &strings;
	auto s = doir.lsp.session.Session(&engine, &strings, output);
	scope(exit) {
		foreach (ref o; fp.dynarray.slice(s.opened)) fp.string.free(o.uri);
		fp.dynarray.free(s.opened);
	}

	auto reader = bc.jsonrpc.Reader(input);
	scope(exit) bc.jsonrpc.free(reader);
	for (;;) {
		auto message = bc.jsonrpc.next(reader);
		if (message is null) break;
		bool exit;
		handle(s, message, exit);
		if (exit) return s.shutdown ? 0 : 1;
		// A burst of edits is drained before any diagnostics go out, so typing commits each keystroke but publishes once.
		if (!bc.jsonrpc.buffered(reader))
			foreach (ref o; fp.dynarray.slice(s.opened))
				if (o.stale) publish(s, o);
		if (engine.edgesMissing && !bc.jsonrpc.buffered(reader) && !doir.query.buildDependents(engine)) cast(void) fp.io.print(fp.io.Console.error, "doir --lsp: out of memory building reverse dependency edges; edits re-check by walking dependencies\n");
	}
	return s.shutdown ? 0 : 1;
}


unittest { // a `file://` URI's path is percent-decoded; any other URI is its own path
	static import fp.testing;
	static immutable string[2][4] paths = [["file:///a%20b%2Fc.doir", "/a b/c.doir"], ["file:///odd%2g%2", "/odd%2g%2"], ["untitled:x", "untitled:x"], ["file:///%41%62", "/Ab"]];
	foreach (pair; paths) {
		char* path = pathOf(pair[0]);
		scope(exit) fp.string.free(path);
		assert(fp.string.slice(path) == pair[1]);
	}
	assert(pathOf("") is null);
	auto previous = fp.testing.limitAllocations(0);
	char* refused = pathOf("file:///x");
	fp.testing.restoreAllocator(previous);
	assert(refused is null);
}

unittest { // the test fixture: set up under a refused allocation it reports failure and still frees; a handler reads its params and answers its id
	static import fp.testing;
	for (size_t budget = 0;; ++budget) {
		doir.lsp.session.Fixture f;
		scope(exit) doir.lsp.session.free(f);
		auto allocator = fp.testing.limitAllocations(budget);
		immutable opened = doir.lsp.session.open(f, "x : T = 1\ny : T = x\n");
		fp.testing.restoreAllocator(allocator);
		if (!opened) continue;
		assert(!doir.lsp.session.parse(f, "{") && doir.lsp.session.parse(f, `{"textDocument":{"uri":"file:///t.doir"},"position":{"line":1,"character":8}}`));
		doir.lsp.features.definition.definition(f.s, doir.lsp.session.params(f), doir.lsp.session.id(f));
		assert(doir.lsp.session.responds(f, `"range":{"start":{"line":0,"character":0}`));
		doir.lsp.session.respondNull(f.s, doir.lsp.session.id(f));
		assert(!doir.lsp.session.responds(f, `"error"`));
		break;
	}
}

unittest { // the server exits 0 when input ends after a shutdown, and 1 when it ends before one
	static immutable bool[2] shutdowns = [false, true];
	foreach (shutdown; shutdowns) {
		auto input = fp.io.createPipe().get, output = fp.io.createPipe().get;
		static immutable message = "Content-Length: 46\r\n\r\n{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"shutdown\"}  ";
		if (shutdown) assert(fp.io.writeAll(input.writing, message));
		assert(fp.io.close(input.writing));
		assert(run(input.reading, output.writing) == (shutdown ? 0 : 1));
		assert(fp.io.close(input.reading) && fp.io.close(output.reading) && fp.io.close(output.writing));
	}
}
