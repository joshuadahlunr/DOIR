/// What every handler of the DOIR language server (`doir.lsp.server`) shares: the session, its open documents, and writing responses with their positions in the client's encoding (`roadmap.md` Phase 3).
module doir.lsp.session;

static import fp.dynarray;
static import fp.io;
static import fp.rope;
static import fp.string;

static import bc.json;
static import bc.jsonrpc;
static import ecrs.context;

static import doir.lsp.positions;
static import doir.query;
static import doir.source;
static import doir.strings;

public import ecrs.registry : EntityId, invalidEntity;

@nogc nothrow:


// --- state -------------------------------------------------------------------

/// A document the client opened, by its URI, and the file it is in the store.
package(doir) struct Opened {
	char* uri; /// An fp string.
	EntityId file; ///
	long version_; ///
	bool open; /// Closed documents keep their file, so reopening one finds it.
	bool stale; /// Changed since its diagnostics were last published.
}

/// The server's state between messages.
package(doir) struct Session {
	doir.query.QueryEngine* engine; ///
	doir.strings.Strings* strings; ///
	int output; /// Where messages to the client go.
	doir.lsp.positions.Encoding encoding = doir.lsp.positions.Encoding.utf16; ///
	doir.lsp.positions.LineCache lines; /// Reset before each message, since an edit may free the text it describes.
	Opened* opened; /// An fp dynarray.
	bool shutdown; ///
}

// --- messages ----------------------------------------------------------------

/// Sends message `d` to the client and frees it; a message an edit could not finish, or the client cannot take, is logged and dropped.
///
/// Examples:
/// ---
/// static import bc.json;
/// Fixture f;
/// assert(open(f, ""));
/// scope(exit) free(f);
/// bc.json.Document d;
/// cast(void) bc.json.setObject(d);
/// send(f.s, d);
/// assert(responds(f, "{}"));
/// ---
package(doir) void send(ref Session s, ref bc.json.Document d) {
	scope(exit) bc.json.free(d);
	if (d.refused) cast(void) fp.io.print(fp.io.Console.error, "doir --lsp: out of memory writing a message; it was dropped\n");
	else if (!bc.jsonrpc.send(s.output, bc.json.json(d))) cast(void) fp.io.print(fp.io.Console.error, "doir --lsp: cannot write to the client\n");
}

/// Makes `d` a response to the request `id`, `null` if it is missing, and returns it for the caller to set its `"result"` and `send` it.
///
/// Examples:
/// ---
/// static import bc.json;
/// bc.json.Document d;
/// scope(exit) bc.json.free(d);
/// auto request = bc.json.parse(`{"id":7}`);
/// scope(exit) bc.json.free(request.document);
/// bc.json.set(response(d, bc.json.root(request.document)["id"]), "result", null);
/// assert(bc.json.json(d) == `{"jsonrpc":"2.0","id":7,"result":null}`);
/// ---
package(doir) bc.json.Value response(ref bc.json.Document d, bc.json.Value id) {
	auto o = bc.json.setObject(d);
	bc.json.set(o, "jsonrpc", "2.0");
	if (bc.json.exists(id)) bc.json.set(o, "id", id);
	else bc.json.set(o, "id", null);
	return o;
}

/// Answers the request `id` with a null result.
///
/// Examples:
/// ---
/// Fixture f;
/// assert(open(f, ""));
/// scope(exit) free(f);
/// respondNull(f.s, id(f));
/// assert(responds(f, `"result":null`));
/// ---
package(doir) void respondNull(ref Session s, bc.json.Value id) {
	bc.json.Document d;
	bc.json.set(response(d, id), "result", null);
	send(s, d);
}

/// Answers the request `id` with the JSON-RPC error `code` and `message`, which should say how to fix what went wrong.
///
/// Examples:
/// ---
/// Fixture f;
/// assert(open(f, ""));
/// scope(exit) free(f);
/// respondError(f.s, id(f), -32_601, "the DOIR server does not handle this method");
/// assert(responds(f, `"code":-32601`));
/// ---
package(doir) void respondError(ref Session s, bc.json.Value id, long code, const(char)[] message) {
	bc.json.Document d;
	auto error = bc.json.setObject(response(d, id), "error");
	bc.json.set(error, "code", code);
	bc.json.set(error, "message", message);
	send(s, d);
}


// --- documents ---------------------------------------------------------------

/// The document the client knows as `uri`, open or closed, or null if it never opened one.
///
/// Examples:
/// ---
/// Fixture f;
/// assert(open(f, ""));
/// scope(exit) free(f);
/// assert(find(f.s, "file:///t.doir").open && find(f.s, "file:///u.doir") is null);
/// ---
package(doir) Opened* find(ref Session s, const(char)[] uri) {
	foreach (ref o; fp.dynarray.slice(s.opened))
		if (fp.string.slice(o.uri) == uri) return &o;
	return null;
}


// --- positions ---------------------------------------------------------------

/// Fills object `into` with byte `at` of `text` as an LSP position in the session's encoding.
///
/// Examples:
/// ---
/// static import bc.json;
/// Fixture f;
/// assert(open(f, "x : T = 1\ny\n"));
/// scope(exit) free(f);
/// bc.json.Document d;
/// scope(exit) bc.json.free(d);
/// position(f.s, bc.json.setObject(d), doir.source.textOf(f.engine, f.s.opened[0].file), 10);
/// assert(bc.json.json(d) == `{"line":1,"character":0}`);
/// ---
package(doir) void position(ref Session s, bc.json.Value into, const fp.rope.Rope text, size_t at) {
	size_t line, character;
	doir.lsp.positions.positionOf(s.lines, text, s.encoding, at, line, character);
	bc.json.set(into, "line", line);
	bc.json.set(into, "character", character);
}

/// Fills object `into` with bytes `start` to `end` of `text` as an LSP range; an `end` before `start` is taken as `start`.
///
/// Examples:
/// ---
/// static import bc.json;
/// Fixture f;
/// assert(open(f, "x : T = 1\n"));
/// scope(exit) free(f);
/// bc.json.Document d;
/// scope(exit) bc.json.free(d);
/// range(f.s, bc.json.setObject(d), doir.source.textOf(f.engine, f.s.opened[0].file), 4, 5);
/// assert(bc.json.json(d) == `{"start":{"line":0,"character":4},"end":{"line":0,"character":5}}`);
/// ---
package(doir) void range(ref Session s, bc.json.Value into, const fp.rope.Rope text, size_t start, size_t end) {
	position(s, bc.json.setObject(into, "start"), text, start);
	position(s, bc.json.setObject(into, "end"), text, end > start ? end : start);
}


// --- testing -----------------------------------------------------------------

version (unittest) {
	static import fp.pointer;

	/// A session with one open document, `file:///t.doir`, for examples and tests: a request's params are parsed into `request` by `parse` and given by `params`, its id is `id`, and what the session sends is read back by `responds`. Set it up in place with `open`, since the session points into it.
	package(doir) struct Fixture {
		ecrs.context.Context store; ///
		doir.query.QueryEngine engine; ///
		doir.strings.Strings strings; ///
		Session s; ///
		bc.json.Document request; /// The params `parse` read last.
		bc.json.Document requestId; /// The id `id` gives: `1`.
		private bool live; // whether `open` made the store and engine, which only it may free
		private fp.io.Pipe pipe;
		private bc.jsonrpc.Reader reader;
	}

	/// Sets up `f` with `text` committed as its open document. False if a pipe or an allocation is refused; `f` must still be freed.
	///
	/// Examples:
	/// ---
	/// Fixture f;
	/// assert(open(f, "x : T = 1\n"));
	/// free(f);
	/// ---
	package(doir) bool open(ref Fixture f, const(char)[] text) @trusted {
		f.store = ecrs.context.create();
		f.engine = doir.query.create(f.store);
		f.engine.strings = &f.strings;
		f.engine.edgesMissing = true;
		f.live = true;
		auto pipe = fp.io.createPipe();
		if (pipe.isNull) return false;
		f.pipe = pipe.get;
		f.s = Session(&f.engine, &f.strings, f.pipe.writing);
		f.reader = bc.jsonrpc.Reader(f.pipe.reading);
		f.requestId = bc.json.parse("1").document;
		if (!bc.json.exists(bc.json.root(f.requestId))) return false;
		immutable file = doir.source.addFile(f.engine, f.strings, "/t.doir");
		char* uri = fp.string.clone("file:///t.doir").get(null);
		if (file == invalidEntity || uri is null || !fp.dynarray.pushBack(f.s.opened, Opened(uri, file, 1, true))) {
			fp.string.free(uri);
			return false;
		}
		return doir.source.commit(f.engine, f.strings, file, text) != fp.pointer.allocationRefused;
	}

	/// Parses `json` into `f.request`, whose root a handler then takes as its params from `params`. False, leaving `f.request` empty, if it is not JSON or on refusal.
	///
	/// Examples:
	/// ---
	/// Fixture f;
	/// assert(open(f, ""));
	/// scope(exit) free(f);
	/// assert(parse(f, `{"query":"x"}`) && !parse(f, "{"));
	/// ---
	package(doir) bool parse(ref Fixture f, const(char)[] json) {
		bc.json.free(f.request);
		auto parsed = bc.json.parse(json);
		f.request = parsed.document;
		return parsed.status == bc.json.Status.ok;
	}

	/// The params `parse` read last: `f.request`'s root.
	///
	/// Examples:
	/// ---
	/// static import bc.json;
	/// Fixture f;
	/// assert(open(f, ""));
	/// scope(exit) free(f);
	/// assert(parse(f, `{"query":"x"}`) && bc.json.view(params(f)["query"]) == "x");
	/// ---
	package(doir) bc.json.Value params(ref Fixture f) {
		return bc.json.root(f.request);
	}

	/// The id of the request a test makes: `1`.
	///
	/// Examples:
	/// ---
	/// static import bc.json;
	/// Fixture f;
	/// assert(open(f, ""));
	/// scope(exit) free(f);
	/// assert(bc.json.integer(id(f)).get == 1);
	/// ---
	package(doir) bc.json.Value id(ref Fixture f) {
		return bc.json.root(f.requestId);
	}

	/// Reads the next message the session sent, which must have been sent, and whether it contains `expected`.
	///
	/// Examples:
	/// ---
	/// Fixture f;
	/// assert(open(f, ""));
	/// scope(exit) free(f);
	/// respondNull(f.s, id(f));
	/// assert(responds(f, `"id":1`));
	/// ---
	package(doir) bool responds(ref Fixture f, const(char)[] expected) {
		return fp.string.contains(bc.jsonrpc.next(f.reader), expected);
	}

	/// Releases everything `f` holds, set up or not.
	///
	/// Examples:
	/// ---
	/// Fixture f;
	/// free(f);
	/// ---
	package(doir) void free(ref Fixture f) @trusted {
		foreach (ref o; fp.dynarray.slice(f.s.opened)) fp.string.free(o.uri);
		fp.dynarray.free(f.s.opened);
		f.s.opened = null;
		bc.json.free(f.request);
		bc.json.free(f.requestId);
		bc.jsonrpc.free(f.reader);
		immutable int[2] descriptors = [f.pipe.reading, f.pipe.writing];
		foreach (descriptor; descriptors)
			if (descriptor >= 0) cast(void) fp.io.close(descriptor); // a test's pipe; nothing to recover
		f.pipe = fp.io.Pipe.init;
		if (f.live) {
			doir.query.free(f.engine);
			doir.strings.free(f.strings);
			ecrs.context.free(f.store);
			f.live = false;
		}
	}
}
