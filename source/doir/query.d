/// The demand-driven query engine over the libECRS store (`roadmap.md` Phase 1). A query instance is an entity: its key, value, dependencies, outputs, diagnostics and revisions are components, so a renumbering covers them like any other (`E-Remap`).
///
/// A query type `Q` is a struct declaring `Key`, `Value` and `static Value compute(ref QueryEngine, Key) @nogc nothrow`. `Key` and `Value` are plain data compared by their bytes, unless `Q` declares `static bool keyEqual(ref const Key, ref const Key)` with `static size_t keyHash(ref const Key)`, or `static bool valueEqual(ref const Value, ref const Value)`. A `Key` or `Value` that holds entity ids does so by mixing in `ecrs.relation.Relates`, or by being an `ecrs.relation.Relation`, and the engine renumbers it through that (`E-Remap`). `Q` may declare `static Value cycleFallback(ref QueryEngine, Key)`, the answer a demand for it gets while it is already running, and `static bool describeKey(ref const Key, ref char*)`, which appends the key to a cycle report and returns false if the string could not grow.
///
/// Validation follows Salsa's revisions: inputs carry `ChangedAt`, query entities carry `ChangedAt` and `VerifiedAt`, and a query re-runs only when a dependency changed after it was last verified. A re-run whose value and produced components are unchanged keeps its old `ChangedAt` (early cutoff). Unlike Salsa, a change is also pushed: each entity lists the queries that read it (`Dependents`), `markChanged` marks them and their dependents stale, and a query no change reached is reused without visiting its dependencies, unless reusing it reports diagnostics, which come from walking them. So re-validating a tree of queries after an edit costs in proportion to what the edit reached. Dependencies are on whole entities; per (entity, component type) dependencies are the refinement if the extra re-verification shows up in profiles.
///
/// A component a query produces is read through that query: a reader demands the producer first, so it depends on it, and the producer's `ChangedAt` moves when what it produced changes.
///
/// A refused allocation fails every query running at the time (`fail`): each keeps no value and its demand returns null, so nothing built on a partial run is memoized, and the next demand runs it again. `QueryEngine.refused` records that it happened. The calls a query makes report it through their results as well, so a `compute` can stop early; one that hits a refused allocation of its own calls `fail`.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// struct Double {
/// 	alias Key = int;
/// 	alias Value = int;
/// 	static int compute(ref QueryEngine engine, int key) @nogc nothrow { return key * 2; }
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = create(store);
/// scope(exit) free(engine);
/// assert(*query!Double(engine, 21) == 42);
/// ---
module doir.query;

static import core.atomic;
static import core.stdc.stdio;
static import core.stdc.stdlib;
static import core.stdc.string;
static import core.sys.posix.sched;
static import std.typecons;

static import fp.dynarray;
static import fp.hash;
static import fp.hashtable;
static import fp.lifecycle;
static import fp.pointer;
static import fp.string;
version(unittest) static import fp.testing;

static import bc.spinlock;
static import bc.threadpool;
static import diagnose;
static import ecrs.context;
static import ecrs.registry;
static import ecrs.relation;
static import ecrs.storage;

static import doir.engine.locations;
static import doir.engine.positions;
static import doir.strings;
static import doir.components.query;

public import ecrs.registry : EntityId, invalidEntity;

@nogc nothrow:


// --- types and layout --------------------------------------------------------

/// A point in the engine's history. Revision 0 means "before anything was recorded".
alias Revision = ulong;

/// True if `Q` follows the query protocol `doir.query` documents. A key's lifetime must be its bytes, since the index holds a bit copy of it.
enum isQuery(Q) = is(Q.Key) && is(Q.Value) && fp.lifecycle.isBitMoveable!(Q.Key) && __traits(compiles, (ref QueryEngine engine, Q.Key key) @nogc nothrow {
	Q.Value value = Q.compute(engine, key);
});

private bool keysEqual(Q)(ref const Q.Key a, ref const Q.Key b) @trusted {
	static if (__traits(hasMember, Q, "keyEqual")) return Q.keyEqual(a, b);
	else return core.stdc.string.memcmp(&a, &b, Q.Key.sizeof) == 0;
}

private size_t keyHash(Q)(ref const Q.Key key) @trusted {
	static if (__traits(hasMember, Q, "keyEqual")) {
		static assert(__traits(hasMember, Q, "keyHash"), Q.stringof ~ " declares keyEqual without keyHash");
		return Q.keyHash(key);
	} else return fp.hash.murmur((cast(const(ubyte)*) &key)[0 .. Q.Key.sizeof]);
}

private bool valuesEqual(Q)(ref const Q.Value a, ref const Q.Value b) @trusted {
	static if (__traits(hasMember, Q, "valueEqual")) return Q.valueEqual(a, b);
	else static if (!fp.lifecycle.isBitMoveable!(Q.Value)) static assert(false, Q.stringof ~ " owns memory in its value, so it must declare valueEqual");
	else return core.stdc.string.memcmp(&a, &b, Q.Value.sizeof) == 0;
}

private struct TableEntry(Q) {
	mixin ecrs.relation.Relates!"query";
	Q.Key key;
}

private size_t hashTableEntry(Q)(inout(ubyte)[] bytes) @trusted {
	return keyHash!Q((cast(const(TableEntry!Q)*) bytes.ptr).key);
}

private bool equalTableEntry(Q)(inout(ubyte)[] a, inout(ubyte)[] b) @trusted {
	return keysEqual!Q((cast(const(TableEntry!Q)*) a.ptr).key, (cast(const(TableEntry!Q)*) b.ptr).key);
}

/// The index from key to query entity for query type `Q`, held as a component on an entity of its own. A renumbering rewrites its keys and ids in place and leaves it to be rehashed on its next use (`E-Remap`). Keys that a compaction maps to the same key keep one query entity; the others are no longer found.
///
/// Examples:
/// ---
/// struct Square {
/// 	alias Key = int;
/// 	alias Value = int;
/// 	static int compute(ref QueryEngine engine, int key) @nogc nothrow { return key * key; }
/// }
/// QueryTable!Square table;
/// table.finalize();
/// ---
struct QueryTable(Q) {
	private TableEntry!Q* table = null;
	private bool stale = false; // entries were rewritten in place and may sit under their old hashes

	/// The `E-Remap` hook libECRS finds by name: rewrites every entry in place and marks the table stale, since a rewritten key hashes differently. A hook cannot fail, so the rehash, which allocates, waits for the next lookup.
	///
	/// Examples:
	/// ---
	/// static import ecrs.relation;
	/// struct Same {
	/// 	alias Key = ecrs.relation.Relation!1;
	/// 	alias Value = ecrs.relation.Relation!1;
	/// 	static Value compute(ref QueryEngine engine, Key key) @nogc nothrow { return key; }
	/// }
	/// QueryTable!Same table;
	/// immutable EntityId[2] remap = [0, 1];
	/// QueryTable!Same.remapEntities(table, remap[]);
	/// table.finalize();
	/// ---
	static void remapEntities(ref QueryTable self, const(EntityId)[] remap) @trusted @nogc nothrow {
		foreach (stored; fp.hashtable.occupied(self.table)) {
			auto entry = self.table + (stored - self.table); // the iterator yields const pointers
			static if (ecrs.registry.hasRemapEntities!(Q.Key)) Q.Key.remapEntities(entry.key, remap);
			TableEntry!Q.remapEntities(*entry, remap);
		}
		self.stale = true;
	}

	/// Releases the table when the component is removed.
	///
	/// Examples:
	/// ---
	/// struct Unit {
	/// 	alias Key = int;
	/// 	alias Value = int;
	/// 	static int compute(ref QueryEngine engine, int key) @nogc nothrow { return 0; }
	/// }
	/// QueryTable!Unit t;
	/// t.finalize();
	/// ---
	void finalize() @nogc nothrow { fp.hashtable.free(table); }
}

private enum size_t noFrame = size_t.max;

private struct Frame {
	EntityId query;
	size_t created;
	size_t head = noFrame; // the lowest frame whose cycle fallback this run's value rests on
	bool cycle; // this run took part in a cycle
	bool usedAsHead; // a demand above got this frame's cycle fallback
	EntityId* provisional; // finished queries resting on this frame's fallback
	bool refused; // an allocation was refused during this run, so it keeps no value
	bool withheldBelow; // a query this run demanded holds diagnostics a worker withheld
	EntityId* reporting; // the queries this run demanded that hold diagnostics, or have one below them that does, in order, for `ReportingBelow`
}

/// The depth of nested demands and re-validations a new engine allows before reporting `Q-Cycle`, well inside a default 8 MiB stack.
enum size_t defaultDepthLimit = 4096;

/// The engine: the store it works on, the current revision, where diagnostics go, the order keys of lexical positions, and the stack of running queries. Renumber the store only through `doir.query.renumber` and `compact`, which require that no query is running.
struct QueryEngine {
	ecrs.context.Context* store; /// The store, which must outlive the engine.
	Revision revision = 1; /// The current revision.
	size_t depthLimit = defaultDepthLimit; /// How deep demands may nest before `Q-Cycle` is reported instead of overflowing the stack.
	diagnose.Manager* diagnostics = null; /// Where reported diagnostics go, each once per revision; null discards them, though queries still record theirs.
	bool refused = false; /// Set when an allocation was refused: every query running at the time failed, keeping no value, or a diagnostic was lost on its way to `diagnostics`. The engine never clears it.
	doir.engine.positions.Positions positions; /// The order keys of every positioned effect and read (`C-Order`), made with `doir.positions.between`.
	bc.threadpool.ThreadPool* workers = null; /// Threads for work that touches no shared state, such as skimming a large file's chunks; null does that work on the calling thread. The engine borrows it.
	doir.strings.Strings* strings = null; /// The interned names its queries read, as checks read declarations' names; the engine borrows it.
	bool edgesMissing = false; /// Set while the reverse dependency edges (`Dependents`) are not kept: when a refused allocation lost one, or from the start for an engine that defers them, as one that never sees an edit should. Meanwhile queries record none, and no query is reused without checking its dependencies, since a change may not reach it. `buildDependents` builds them all and clears it.
	package(doir) Frame* stack = null;
	package(doir) size_t depth = 0;
	package(doir) EntityId* pending = null; /// Stale queries `settle` has yet to bring up to date.
	package(doir) bc.spinlock.SpinLock pendingLock; /// Guards `pending` while an input commit's workers mark entities.
	package(doir) bool settling = false; /// `settle` is running, so diagnostics are withheld for the demands that reach them.
}

// The `Running.owner` of a query the calling thread runs; a batch's workers are `firstWorker` on.
private enum uint callingThread = 1, firstWorker = 2;

// A query entity a worker may not add: `add` adds it between rounds, at the key in the worker's bytes `from .. to`.
private struct Request {
	bool function(ref QueryEngine engine, const(ubyte)[] key) @nogc nothrow add;
	size_t from, to;
}

// What a batch's workers share: its demands, this round's indices, which were handed back, what each worker waits on (`Q-Cycle`), and whether any withheld diagnostics.
private struct Batch(Q) {
	QueryEngine* engine;
	const(Q.Key)[] keys;
	const(size_t)[] round;
	bool* handedBack; // one per key
	EntityId* waitingOn; // indexed by owner
	size_t owners; // its length
	shared size_t next; // the next index of `round` a worker takes
	shared bool withheld;
}

// A reverse dependency edge a worker added or dropped, from the entity read to the query that read it, for the engine's thread to apply.
private struct Edge {
	mixin ecrs.relation.Relates!("from", "to");
	bool added;
}

// A worker thread's state in a batch: its stack of running queries, their depth, whether it handed the demand back, and the entities it requested.
private struct Worker {
	Frame* stack;
	size_t depth;
	uint self; // its `Running.owner`
	bool handedBack;
	EntityId* waitingOn; // the batch's
	size_t owners; // the length of `waitingOn`
	Request** requests; // its job's
	ubyte** keys; // the requests' keys
	Edge** edges; // its job's
}

// Thread-local: the state of the batch job this thread runs, or null on the engine's own thread.
private Worker* worker;

private ref Frame* stackOf(return ref QueryEngine engine) {
	return worker is null ? engine.stack : worker.stack;
}


// --- the running query -------------------------------------------------------

// Whether no query is running, as entering a revision, an input commit and a renumbering require.
private bool idle(ref QueryEngine engine) {
	return fp.dynarray.length(stackOf(engine)) == 0;
}

private size_t frameOf(ref QueryEngine engine, EntityId q) {
	if (idle(engine)) return noFrame;
	auto running = ecrs.context.findComponent!(doir.components.query.Running)(*engine.store, q);
	if (running is null || core.atomic.atomicLoad(*cast(shared(uint)*) &running.owner) != (worker is null ? callingThread : worker.self)) return noFrame;
	return running.frame;
}

/// Reports a refused allocation the running query met on its own, outside the engine's calls: it and every query below it fail, keeping no value, and `engine.refused` is set. The whole stack fails because a query failing alone could memoize a value built on a failed demand's null. Its `compute` should then return at once; the value it returns is discarded.
///
/// Examples:
/// ---
/// static import fp.dynarray;
/// static import ecrs.context;
/// struct Grow {
/// 	alias Key = int;
/// 	alias Value = int;
/// 	static int compute(ref QueryEngine engine, int key) @nogc nothrow {
/// 		fail(engine); // as if a pushBack of its own had been refused
/// 		return key;
/// 	}
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// QueryEngine engine;
/// engine.store = &store;
/// scope(exit) free(engine);
/// assert(query!Grow(engine, 1) is null && engine.refused);
/// ---
void fail(ref QueryEngine engine) {
	// A null from a demand a worker handed back is no refusal, though the query seeing it may call this.
	if (worker is null) engine.refused = true;
	else if (!worker.handedBack) core.atomic.atomicStore(*cast(shared(bool)*) &engine.refused, true);
	foreach (ref frame; fp.dynarray.slice(stackOf(engine))) frame.refused = true;
}

// On a worker, gives its demand back to the engine's thread: every running query fails, keeping no value, without setting `engine.refused`.
private void handBack(ref QueryEngine engine) {
	assert(worker !is null);
	worker.handedBack = true;
	foreach (ref frame; fp.dynarray.slice(worker.stack)) frame.refused = true;
}

/// The running query entity whose run is innermost, or `invalidEntity` outside any query.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// QueryEngine engine;
/// engine.store = &store;
/// scope(exit) free(engine);
/// assert(currentQuery(engine) == invalidEntity);
/// ---
EntityId currentQuery(ref QueryEngine engine) {
	return idle(engine) ? invalidEntity : fp.dynarray.back(stackOf(engine)).query;
}

// How many of a query's latest reads `read` searches for a repeat.
private enum size_t recentReads = 16;

/// Records that the running query read entity `e`, so a later change to `e` re-runs it. Reads made outside any query are not recorded. If `e` is a provisional answer, the running query's value rests on the same cycle fallback (`Q-Cycle`). Do not record reads of `SourceSpan` or `SourceLocation`: spans are untracked. Returns false on a refused allocation, which fails the running queries (`fail`).
///
/// Examples:
/// ---
/// static import doir.query;
/// static import ecrs.relation;
/// static import ecrs.context;
/// struct Count {
/// 	alias Key = ecrs.relation.Relation!1;
/// 	alias Value = int;
/// 	static int compute(ref QueryEngine engine, Key key) @nogc nothrow {
/// 		immutable input = key.related[0];
/// 		if (!read(engine, input)) return 0;
/// 		return cast(int) doir.query.changedAt(engine, input);
/// 	}
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// QueryEngine engine;
/// engine.store = &store;
/// scope(exit) free(engine);
/// immutable input = ecrs.context.addEntity(store);
/// assert(doir.query.markChanged(engine, input));
/// assert(*query!Count(engine, Count.Key([input])) == 1);
/// doir.query.beginRevision(engine);
/// assert(doir.query.markChanged(engine, input));
/// assert(*query!Count(engine, Count.Key([input])) == 2);
/// ---
bool read(ref QueryEngine engine, EntityId e) {
	auto stack = stackOf(engine);
	immutable n = fp.dynarray.length(stack);
	if (n == 0) return true;
	auto top = &stack[n - 1];
	if (top.query == e) return true;
	if (auto provisional = ecrs.context.findComponent!(doir.components.query.ProvisionalOn)(*engine.store, e)) {
		if (worker !is null) {
			handBack(engine);
			return false;
		}
		immutable h = frameOf(engine, provisional.head);
		assert(h != noFrame);
		top.cycle = true;
		if (h < n - 1 && h < top.head) top.head = h;
	}
	auto deps = &ecrs.context.getComponent!(doir.components.query.DependsOn)(*engine.store, top.query);
	// Only the latest reads are searched, so recording thousands stays linear; a repeat further back only costs a re-check.
	auto recorded = fp.dynarray.slice(deps.related);
	foreach (d; recorded[recorded.length > recentReads ? recorded.length - recentReads : 0 .. $])
		if (d == e) return true;
	if (fp.dynarray.pushBack(deps.related, e)) return true;
	fail(engine);
	return false;
}

/// Marks every query that read `e` stale, to be brought up to date before the next demand (`settle`): one whose value then changes marks its own dependents in turn, and one that keeps it stops the change there. `doir.query.markChanged` calls it for each changed input, and an input commit calls it before removing an entity, whose id may be handed out again. A refused allocation sets `engine.edgesMissing`.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import ecrs.relation;
/// struct Get {
/// 	alias Key = ecrs.relation.Relation!1;
/// 	alias Value = bool;
/// 	static bool compute(ref QueryEngine engine, Key key) @nogc nothrow { return read(engine, key.related[0]); }
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// QueryEngine engine;
/// engine.store = &store;
/// scope(exit) free(engine);
/// immutable input = ecrs.context.addEntity(store);
/// assert(*query!Get(engine, Get.Key([input])));
/// invalidate(engine, input); // as an input commit does before removing it
/// assert(*query!Get(engine, Get.Key([input]))); // checked again before it is reused
/// ---
void invalidate(ref QueryEngine engine, EntityId e) {
	auto dependents = ecrs.context.findComponent!(doir.components.query.Dependents)(*engine.store, e);
	if (dependents is null) return;
	foreach (q; fp.dynarray.slice(dependents.related)) {
		auto verified = ecrs.context.findComponent!(doir.components.query.VerifiedAt)(*engine.store, q);
		// One verified in this revision read its dependencies as they are now. An input commit's workers mark concurrently, so one claims each query.
		if (verified is null || core.atomic.atomicLoad(*cast(shared(Revision)*) &verified.revision) == engine.revision || !core.atomic.cas(cast(shared(bool)*) &verified.stale, false, true)) continue;
		bc.spinlock.writeLock(engine.pendingLock);
		immutable queued = fp.dynarray.pushBack(engine.pending, q);
		bc.spinlock.writeUnlock(engine.pendingLock);
		if (!queued) core.atomic.atomicStore(*cast(shared(bool)*) &engine.edgesMissing, true);
	}
}

/// Records that the running query wrote component `item.component` on `item.entity`, to be removed by `item.strip` before the query runs again and when it is evicted, and hashed by `item.hash` for early cutoff. Unless `unique`, a repeat record of the same pair in one run is ignored. Use `doir.query.produce` for a whole component; this is for components that several queries write parts of, such as effect logs. Returns false on a refused allocation, which fails the running queries (`fail`).
///
/// Examples:
/// ---
/// static import doir.components.query;
/// static import fp.dynarray;
/// static import ecrs.context;
/// static import ecrs.registry;
/// static void strip(ref ecrs.context.Context store, EntityId e, size_t c, EntityId owner) @nogc nothrow {}
/// static size_t hash(ref const ecrs.context.Context store, EntityId e, size_t c, EntityId owner) @nogc nothrow { return 0; }
/// struct Claim {
/// 	alias Key = int;
/// 	alias Value = size_t;
/// 	static size_t compute(ref QueryEngine engine, int key) @nogc nothrow {
/// 		immutable item = doir.components.query.Produced([currentQuery(engine)], ecrs.registry.componentId!int(), &strip, &hash);
/// 		if (!recordProduced(engine, item, false) || !recordProduced(engine, item, false)) return 0;
/// 		return fp.dynarray.length(ecrs.context.getComponent!(doir.components.query.Produces)(*engine.store, currentQuery(engine)).items);
/// 	}
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// QueryEngine engine;
/// engine.store = &store;
/// scope(exit) free(engine);
/// assert(*query!Claim(engine, 1) == 1);
/// ---
bool recordProduced(ref QueryEngine engine, doir.components.query.Produced item, bool unique) {
	immutable q = currentQuery(engine);
	assert(q != invalidEntity, "doir.query: writing a component outside a query");
	if (worker !is null) {
		handBack(engine); // the component's storage may need to grow
		return false;
	}
	auto produces = &ecrs.context.getComponent!(doir.components.query.Produces)(*engine.store, q);
	if (!unique)
		foreach (existing; fp.dynarray.slice(produces.items))
			if (existing.entity == item.entity && existing.component == item.component) return true;
	if (fp.dynarray.pushBack(produces.items, item)) return true;
	fail(engine);
	return false;
}

/// The `StripFunction` of a whole component: removes it if `e` still has it.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import ecrs.registry;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// immutable e = ecrs.context.addEntity(store);
/// *ecrs.context.addComponent!int(store, e) = 1;
/// stripComponent(store, e, ecrs.registry.componentId!int(), invalidEntity);
/// assert(!ecrs.context.hasComponent!int(store, e));
/// ---
package(doir) void stripComponent(ref ecrs.context.Context store, EntityId e, size_t component, EntityId owner) {
	if (ecrs.context.hasComponent(store, e, component)) cast(void) ecrs.context.removeComponent(store, e, component); // queries run outside transactions, where removal cannot fail
}

/// The `HashFunction` of a whole component `C`: `C.contentHash` if `C` declares one, its bytes otherwise, and 0 if `e` no longer has it.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import ecrs.registry;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// immutable e = ecrs.context.addEntity(store);
/// immutable id = ecrs.registry.componentId!int();
/// assert(hashComponent!int(store, e, id, invalidEntity) == 0);
/// *ecrs.context.addComponent!int(store, e) = 1;
/// assert(hashComponent!int(store, e, id, invalidEntity) != 0);
/// ---
package(doir) size_t hashComponent(C)(ref const ecrs.context.Context store, EntityId e, size_t component, EntityId owner) @trusted {
	static if (ecrs.storage.isTag!C) return ecrs.context.hasComponent(store, e, component) ? 1 : 0;
	else {
		auto c = cast(const(C)*) ecrs.context.findComponent(store, e, component, C.sizeof);
		if (c is null) return 0;
		static if (__traits(hasMember, C, "contentHash")) return C.contentHash(*c);
		else return fp.hash.murmur((cast(const(ubyte)*) c)[0 .. C.sizeof]);
	}
}

// The running query's next created entity: the one its previous run made at that sequence number, or a fresh one.
private EntityId nextCreated(ref QueryEngine engine) {
	assert(!idle(engine), "doir.query: creating an entity outside a query");
	if (worker !is null) {
		handBack(engine);
		return invalidEntity;
	}
	auto frame = fp.dynarray.back(engine.stack);
	auto creates = &ecrs.context.getComponent!(doir.components.query.Creates)(*engine.store, frame.query);
	immutable sequence = frame.created++;
	if (sequence < fp.dynarray.length(creates.related)) return creates.related[sequence];
	immutable e = ecrs.context.addEntity(*engine.store);
	if (e != invalidEntity && fp.dynarray.pushBack(creates.related, e)) return e;
	if (e != invalidEntity) cast(void) ecrs.context.removeEntity(*engine.store, e); // if refused, an orphan nothing reaches
	fail(engine);
	return invalidEntity;
}

// A copy of the fp string `message`, a null `char*` for a null `message`. Null if refused.
private std.typecons.Nullable!(char*) copyText(const(char)* message) {
	auto copy = fp.string.makeDynamic(fp.string.slice(message));
	if (copy is null && message !is null) return typeof(return).init;
	return typeof(return)(copy);
}

// Copies `d` to `engine.diagnostics`, the hint annotating `subject`, or as the closing note if unlocated. Refusal drops it and sets `engine.refused` without failing any query.
private bool emit(ref QueryEngine engine, ref const doir.components.query.QueryDiagnostic d) {
	if (engine.diagnostics is null) return true;
	diagnose.Diagnostic out_;
	out_.kind = d.kind;
	auto location = doir.engine.locations.locate(*engine.store, d.subject);
	if (!location.isNull) out_.location = location.get;
	auto message = copyText(d.message);
	bool ok = !message.isNull;
	if (ok) out_.message = message.get;
	if (ok && d.hint !is null) {
		auto hint = copyText(d.hint);
		if (hint.isNull) ok = false;
		else if (location.isNull) out_.additionalNote = hint.get;
		else {
			auto annotation = diagnose.Diagnostic.Annotation(out_.location.start, null, hint.get);
			ok = diagnose.pushAnnotation(out_, annotation);
			if (!ok) fp.string.free(annotation.message);
		}
	}
	foreach (ref a; fp.dynarray.slice(d.annotations)) {
		if (!ok || location.isNull) break;
		auto where = doir.engine.locations.locate(*engine.store, a.target);
		if (where.isNull) continue;
		auto text = copyText(a.message);
		if (text.isNull) {
			ok = false;
			break;
		}
		auto annotation = diagnose.Diagnostic.Annotation(where.get.start, where.get.file == out_.location.file ? null : where.get.file, text.get);
		ok = diagnose.pushAnnotation(out_, annotation);
		if (!ok) fp.string.free(annotation.message);
	}
	if (ok && diagnose.push(*engine.diagnostics, out_) !is null) return true;
	diagnose.free(out_);
	engine.refused = true;
	return false;
}

// Stores `d`, taken over, on the running query, or outside one reports and frees it. A refusal frees it and fails the running queries.
private bool recordDiagnostic(ref QueryEngine engine, doir.components.query.QueryDiagnostic d) {
	immutable q = currentQuery(engine);
	if (q == invalidEntity) {
		immutable emitted = emit(engine, d);
		doir.components.query.freeDiagnostic(d);
		return emitted;
	}
	if (fp.dynarray.pushBack(ecrs.context.getComponent!(doir.components.query.QueryDiagnostics)(*engine.store, q).items, d)) return true;
	doir.components.query.freeDiagnostic(d);
	fail(engine);
	return false;
}


// --- running and validating queries ------------------------------------------

private extern(C) int compareEntities(const(void)* a, const(void)* b) @trusted {
	immutable x = *cast(const(EntityId)*) a, y = *cast(const(EntityId)*) b;
	return x < y ? -1 : x > y;
}

// Adds query `q` to the `Dependents` of `from`, or drops it. False on a refused allocation.
private bool applyEdge(ref QueryEngine engine, EntityId from, EntityId q, bool added) {
	if (added) {
		auto list = ecrs.context.getOrAddComponent!(doir.components.query.Dependents)(*engine.store, from);
		return list !is null && fp.dynarray.pushBack(list.related, q);
	}
	auto list = ecrs.context.findComponent!(doir.components.query.Dependents)(*engine.store, from);
	if (list is null) return true;
	auto items = fp.dynarray.slice(list.related);
	foreach (i, d; items)
		if (d == q) {
			items[i] = items[$ - 1];
			cast(void) fp.dynarray.popBack(list.related);
			break;
		}
	return true;
}

// The reverse edges a batch recorded from entities in partition `part` of `parts`, so no two shares touch one entity's `Dependents`.
private struct EdgeShare {
	QueryEngine* engine;
	const(Edge)[][] lists;
	size_t part, parts;
	bool ok = true;
}

private void applyShare(void* arg) @nogc nothrow {
	auto share = cast(EdgeShare*) arg;
	foreach (list; share.lists)
		foreach (ref edge; list)
			if (share.ok && edge.from % share.parts == share.part) share.ok = applyEdge(*share.engine, edge.from, edge.to, edge.added);
}

// How many reverse edges are worth sharing among the workers.
private enum size_t parallelEdges = 4096;

// Applies the reverse edges `lists` hold, shared among `engine.workers` by the entity they come from when there are many. A refused allocation sets `edgesMissing`.
private void applyEdges(ref QueryEngine engine, const(Edge)[][] lists) {
	size_t total = 0;
	foreach (list; lists) total += list.length;
	immutable workers = engine.workers is null ? 1 : bc.threadpool.workerCount(engine.workers);
	EdgeShare* shares = null;
	bc.threadpool.Job* work = null;
	scope(exit) {
		fp.dynarray.free(shares);
		fp.dynarray.free(work);
	}
	if (total >= parallelEdges && workers >= 2 && ecrs.context.prepareConcurrentAdds!(doir.components.query.Dependents)(*engine.store, total)
		&& fp.dynarray.reserve(shares, workers) !is null && fp.dynarray.reserve(work, workers) !is null) {
		foreach (w; 0 .. workers) {
			cast(void) fp.dynarray.pushBack(shares, EdgeShare(&engine, lists, w, workers)); // reserved
			cast(void) fp.dynarray.pushBack(work, bc.threadpool.Job(&applyShare, &shares[w])); // reserved
		}
		ecrs.context.beginConcurrentWrites(*engine.store);
		immutable ran = bc.threadpool.run(engine.workers, fp.dynarray.slice(work));
		ecrs.context.endConcurrentWrites(*engine.store);
		if (ran) {
			foreach (ref share; fp.dynarray.slice(shares)) if (!share.ok) engine.edgesMissing = true;
			return;
		}
	}
	foreach (list; lists)
		foreach (ref edge; list)
			if (!applyEdge(engine, edge.from, edge.to, edge.added)) engine.edgesMissing = true;
}

// The reverse edges into the queries `queries` lists, whose reads `reads` holds, from entities in partition `part` of `parts`, so no two shares touch one entity's `Dependents`. `counts` and `lists`, indexed by entity, are shared, each share using only its own entities' entries.
private struct BuildShare {
	QueryEngine* engine;
	const(EntityId)[] queries;
	const(EntityId)[][] reads;
	uint[] counts;
	doir.components.query.Dependents*[] lists;
	size_t part, parts;
	bool ok = true;
}

// Counts the share's edges per entity first, so each `Dependents` is found and sized once rather than once per edge.
private void buildShare(void* arg) @nogc nothrow @trusted {
	auto share = cast(BuildShare*) arg;
	foreach (i; 0 .. share.queries.length)
		foreach (d; share.reads[i])
			if (d % share.parts == share.part) ++share.counts[d];
	// Each list grows to its final length here; `counts` then holds where its next edge goes.
	for (size_t d = share.part; d < share.counts.length; d += share.parts) {
		if (share.counts[d] == 0) continue;
		auto list = ecrs.context.getOrAddComponent!(doir.components.query.Dependents)(*share.engine.store, cast(EntityId) d);
		immutable had = list is null ? 0 : fp.dynarray.length(list.related);
		if (list is null || fp.dynarray.growToSize(list.related, had + share.counts[d]) is null) {
			share.ok = false;
			return;
		}
		share.lists[d] = list;
		share.counts[d] = cast(uint) had;
	}
	foreach (i, q; share.queries)
		foreach (d; share.reads[i])
			if (d % share.parts == share.part) share.lists[d].related[share.counts[d]++] = q;
}

/// Builds every reverse dependency edge (`Dependents`) from what each query read in its last run, replacing any there were, and clears `engine.edgesMissing`, so a change is pushed to the queries it reaches from then on. An engine that defers its edges (`edgesMissing` set from the start) calls it before the first edit it wants to cost in proportion to what the edit reaches; it shares the work among `engine.workers`. No query may be running.
///
/// Returns false on a refused allocation, leaving `edgesMissing` set.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// QueryEngine engine;
/// engine.store = &store;
/// scope(exit) free(engine);
/// engine.edgesMissing = true;
/// assert(buildDependents(engine) && !engine.edgesMissing);
/// ---
bool buildDependents(ref QueryEngine engine) @trusted {
	assert(fp.dynarray.length(engine.stack) == 0, "doir.query: buildDependents while a query runs");
	auto store = engine.store;
	auto existing = ecrs.context.getStorage(*store, ecrs.registry.componentId!(doir.components.query.Dependents)(), doir.components.query.Dependents.sizeof);
	if (existing is null) return false;
	foreach (e; ecrs.storage.owners(*existing))
		if (e != invalidEntity) fp.dynarray.clear(ecrs.context.getComponent!(doir.components.query.Dependents)(*store, e).related);
	// Each query's reads are gathered here, so the workers never read an index list another of them may be growing.
	EntityId* queries = null;
	const(EntityId)[]* reads = null;
	BuildShare* shares = null;
	bc.threadpool.Job* work = null;
	scope(exit) {
		fp.dynarray.free(queries);
		fp.dynarray.free(reads);
		fp.dynarray.free(shares);
		fp.dynarray.free(work);
	}
	auto made = ecrs.context.getStorage(*store, ecrs.registry.componentId!(doir.components.query.DependsOn)(), doir.components.query.DependsOn.sizeof);
	if (made is null) return false;
	size_t total = 0, bound = 0;
	foreach (q; ecrs.storage.owners(*made)) {
		if (q == invalidEntity) continue;
		auto read = fp.dynarray.slice(ecrs.context.getComponent!(doir.components.query.DependsOn)(*store, q).related);
		if (!fp.dynarray.pushBack(queries, q) || !fp.dynarray.pushBack(reads, read)) return false;
		total += read.length;
		foreach (d; read) if (d >= bound) bound = d + 1;
	}
	auto counts = cast(uint*) core.stdc.stdlib.calloc(bound, uint.sizeof);
	auto lists = cast(doir.components.query.Dependents**) core.stdc.stdlib.calloc(bound, (doir.components.query.Dependents*).sizeof);
	scope(exit) {
		core.stdc.stdlib.free(counts);
		core.stdc.stdlib.free(lists);
	}
	if (bound && (counts is null || lists is null)) return false;
	immutable workers = engine.workers is null ? 1 : bc.threadpool.workerCount(engine.workers);
	immutable n = fp.dynarray.length(queries);
	if (total >= parallelEdges && workers >= 2 && ecrs.context.prepareConcurrentAdds!(doir.components.query.Dependents)(*store, total)
		&& fp.dynarray.reserve(shares, workers) !is null && fp.dynarray.reserve(work, workers) !is null) {
		foreach (w; 0 .. workers) {
			cast(void) fp.dynarray.pushBack(shares, BuildShare(&engine, queries[0 .. n], reads[0 .. n], counts[0 .. bound], lists[0 .. bound], w, workers)); // reserved
			cast(void) fp.dynarray.pushBack(work, bc.threadpool.Job(&buildShare, &shares[w])); // reserved
		}
		ecrs.context.beginConcurrentWrites(*store);
		immutable ran = bc.threadpool.run(engine.workers, fp.dynarray.slice(work));
		ecrs.context.endConcurrentWrites(*store);
		if (ran) {
			bool ok = true;
			foreach (ref share; fp.dynarray.slice(shares)) ok = ok && share.ok;
			engine.edgesMissing = !ok;
			return ok;
		}
	}
	// Whatever a share counted before its pool refused the run is counted again.
	foreach (ref c; counts[0 .. bound]) c = 0;
	auto one = BuildShare(&engine, queries[0 .. n], reads[0 .. n], counts[0 .. bound], lists[0 .. bound], 0, 1);
	buildShare(&one);
	engine.edgesMissing = !one.ok;
	return one.ok;
}

// Updates `q`'s reverse edges from `before`, its previous run's reads, which this sorts, to its latest; a worker defers them. Refusal sets `edgesMissing`.
private void recordEdges(ref QueryEngine engine, EntityId q, EntityId[] before) @trusted {
	if (core.atomic.atomicLoad(*cast(shared(bool)*) &engine.edgesMissing)) return; // `buildDependents` builds them from scratch
	auto now = fp.dynarray.slice(ecrs.context.getComponent!(doir.components.query.DependsOn)(*engine.store, q).related);
	bool ok = true;
	void edge(EntityId from, bool added) {
		if (ok) ok = worker is null ? applyEdge(engine, from, q, added) : fp.dynarray.pushBack(*worker.edges, Edge([from, q], added));
	}
	EntityId* sorted = null;
	scope(exit) fp.dynarray.free(sorted);
	// A first run adds every edge unsorted; a repeated read past `read`'s window only costs a spare edge.
	if (before.length == 0) foreach (d; now) edge(d, true);
	else if (now.length && !fp.dynarray.concatenate(sorted, now)) ok = false;
	else {
		auto after = fp.dynarray.slice(sorted);
		core.stdc.stdlib.qsort(before.ptr, before.length, EntityId.sizeof, &compareEntities);
		if (after.length) core.stdc.stdlib.qsort(after.ptr, after.length, EntityId.sizeof, &compareEntities);
		size_t i = 0, j = 0;
		while (i < before.length || j < after.length) {
			immutable dropped = j == after.length || (i < before.length && before[i] < after[j]);
			immutable added = !dropped && (i == before.length || after[j] < before[i]);
			immutable d = dropped ? before[i] : after[j];
			if (dropped || added) edge(d, added);
			while (i < before.length && before[i] == d) ++i;
			while (j < after.length && after[j] == d) ++j;
		}
	}
	if (ok) return;
	if (worker is null) engine.edgesMissing = true;
	else core.atomic.atomicStore(*cast(shared(bool)*) &engine.edgesMissing, true);
}

private void removeProduced(ref QueryEngine engine, EntityId q) {
	auto produces = &ecrs.context.getComponent!(doir.components.query.Produces)(*engine.store, q);
	foreach (item; fp.dynarray.slice(produces.items)) item.strip(*engine.store, item.entity, item.component, q);
	if (produces.items !is null) fp.dynarray.clear(produces.items);
}

private size_t hashProduced(ref QueryEngine engine, EntityId q) {
	size_t h = 0xcbf29ce484222325;
	foreach (item; fp.dynarray.slice(ecrs.context.getComponent!(doir.components.query.Produces)(*engine.store, q).items)) {
		h = fp.hash.mix(h, item.entity);
		h = fp.hash.mix(h, item.component);
		h = fp.hash.mix(h, item.hash(*engine.store, item.entity, item.component, q));
	}
	return h;
}

// Removes the entities past `keep`, which the latest run no longer created. One the store refuses to free stays listed for later reuse or removal.
private void removeCreated(ref QueryEngine engine, EntityId q, size_t keep) {
	auto creates = &ecrs.context.getComponent!(doir.components.query.Creates)(*engine.store, q);
	while (fp.dynarray.length(creates.related) > keep && ecrs.context.removeEntity(*engine.store, *fp.dynarray.back(creates.related)))
		cast(void) fp.dynarray.popBack(creates.related);
}

private void clearDiagnostics(ref QueryEngine engine, EntityId q) {
	auto list = &ecrs.context.getComponent!(doir.components.query.QueryDiagnostics)(*engine.store, q);
	foreach (ref d; fp.dynarray.slice(list.items)) doir.components.query.freeDiagnostic(d);
	if (list.items !is null) fp.dynarray.clear(list.items);
}

// Reports `q`'s diagnostics; a worker or `settle` instead marks `q` withheld if it or a query below it, as `below` says, has any, for `flushWithheld`.
private void emitAll(ref QueryEngine engine, EntityId q, bool below) {
	auto list = fp.dynarray.slice(ecrs.context.getComponent!(doir.components.query.QueryDiagnostics)(*engine.store, q).items);
	immutable withhold = worker !is null || engine.settling;
	ecrs.context.getComponent!(doir.components.query.Running)(*engine.store, q).withheld = withhold && (below || list.length);
	if (withhold) return;
	foreach (ref d; list) cast(void) emit(engine, d); // a lost diagnostic is recorded in engine.refused
}

// Reports, in the order the engine's thread would have, the diagnostics workers withheld at `q` and the queries it depends on.
private void flushWithheld(ref QueryEngine engine, EntityId q) {
	auto running = ecrs.context.findComponent!(doir.components.query.Running)(*engine.store, q);
	if (running is null || !running.withheld) return;
	running.withheld = false;
	// A withheld query holds diagnostics, so its reader lists it among those it reports.
	immutable n = fp.dynarray.length(ecrs.context.getComponent!(doir.components.query.ReportingBelow)(*engine.store, q).related);
	foreach (i; 0 .. n) flushWithheld(engine, ecrs.context.getComponent!(doir.components.query.ReportingBelow)(*engine.store, q).related[i]);
	emitAll(engine, q, false);
}

private QueryTable!Q* tableOf(Q)(ref QueryEngine engine) @trusted {
	// Looked up through a const store, which never creates the storage: a worker may not.
	auto storage = cast(ecrs.storage.Storage*) ecrs.context.getStorage(*cast(const(ecrs.context.Context)*) engine.store, ecrs.registry.componentId!(QueryTable!Q)());
	if (storage !is null)
		foreach (slot; 0 .. ecrs.storage.size(*storage))
			if (ecrs.storage.owner(*storage, slot) != invalidEntity) return &ecrs.storage.get!(QueryTable!Q)(*storage, slot);
	return null;
}

// Rehashes a table a renumbering left stale. Returns false if the rehash was refused, leaving it stale.
private bool rehashIfStale(Q)(ref QueryTable!Q table) {
	if (!table.stale) return true;
	if (fp.hashtable.rehash(table.table, 0) != fp.pointer.notFound) return false;
	table.stale = false;
	return true;
}

/// The query entity of `Q` at `key`, or `invalidEntity` if `Q` was never demanded there. It cannot fail: when a table a renumbering left stale cannot be rehashed, it is searched entry by entry.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// struct Never {
/// 	alias Key = int;
/// 	alias Value = int;
/// 	static int compute(ref QueryEngine engine, int key) @nogc nothrow { return key; }
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// QueryEngine engine;
/// engine.store = &store;
/// assert(find!Never(engine, 1) == invalidEntity);
/// ---
package(doir) EntityId find(Q)(ref QueryEngine engine, const Q.Key key) @trusted {
	auto table = tableOf!Q(engine);
	if (table is null) return invalidEntity;
	const(TableEntry!Q)* found = null;
	// A worker leaves a stale table to the engine's thread, since rehashing writes it.
	if (!table.stale || (worker is null && rehashIfStale(*table))) found = fp.hashtable.find(table.table, TableEntry!Q([invalidEntity], key));
	else
		foreach (stored; fp.hashtable.occupied(table.table))
			if (stored.query != invalidEntity && keysEqual!Q(stored.key, key)) {
				found = stored;
				break;
			}
	return found is null ? invalidEntity : found.query;
}

// Indexes `q` under `key`, reusing an entry whose query a renumbering removed. Returns false on a refused allocation, leaving the index as it was.
private bool index(Q)(ref QueryEngine engine, ref const Q.Key key, EntityId q) @trusted {
	auto table = tableOf!Q(engine);
	if (table is null) {
		fp.hashtable.Config config;
		config.hashFunction = &hashTableEntry!Q;
		config.equalFunction = &equalTableEntry!Q;
		auto fresh = fp.hashtable.create!(TableEntry!Q)(config);
		if (fresh is null) return false;
		immutable holder = ecrs.context.addEntity(*engine.store);
		table = holder == invalidEntity ? null : ecrs.context.addComponent!(QueryTable!Q)(*engine.store, holder);
		if (table is null) {
			if (holder != invalidEntity) cast(void) ecrs.context.removeEntity(*engine.store, holder); // if refused, an orphan nothing reaches
			fp.hashtable.free(fresh);
			return false;
		}
		table.table = fresh;
	}
	if (!rehashIfStale(*table)) return false;
	if (auto dead = fp.hashtable.find(table.table, TableEntry!Q([invalidEntity], key))) {
		dead.related[0] = q;
		return true;
	}
	return fp.hashtable.insert(table.table, TableEntry!Q([q], key)) !is null;
}

private bool describe(Q)(ref QueryEngine engine, EntityId q, ref char* out_) @trusted {
	if (fp.string.concatenate(out_, __traits(identifier, Q)) is null) return false;
	auto key = &ecrs.context.getComponent!(doir.components.query.QueryKey!Q)(*engine.store, q).key;
	static if (__traits(hasMember, Q, "describeKey")) {
		return Q.describeKey(*key, out_);
	} else static if (__traits(isIntegral, Q.Key)) {
		static if (__traits(isUnsigned, Q.Key)) auto text = fp.string.format("(%llu)", cast(ulong) *key);
		else auto text = fp.string.format("(%lld)", cast(long) *key);
		if (text is null) return false;
		scope(exit) fp.string.free(text);
		return fp.string.concatenate(out_, fp.string.slice(text)) !is null;
	} else return true;
}

// Adds and indexes a query entity for `Q` at `key`. Returns `invalidEntity` on a refused allocation.
private EntityId add(Q)(ref QueryEngine engine, ref const Q.Key key) {
	auto store = engine.store;
	immutable q = ecrs.context.addEntity(*store);
	if (q == invalidEntity) return invalidEntity;
	auto k = ecrs.context.addComponent!(doir.components.query.QueryKey!Q)(*store, q);
	if (k !is null) k.key = key;
	auto info = k is null ? null : ecrs.context.addComponent!(doir.components.query.QueryInfo)(*store, q);
	if (info !is null) *info = doir.components.query.QueryInfo(&refresh!Q, &reset!Q, &describe!Q);
	if (info !is null
		&& ecrs.context.addComponent!(doir.components.query.ChangedAt)(*store, q) !is null
		&& ecrs.context.addComponent!(doir.components.query.VerifiedAt)(*store, q) !is null
		&& ecrs.context.addComponent!(doir.components.query.DependsOn)(*store, q) !is null
		&& ecrs.context.addComponent!(doir.components.query.ReportingBelow)(*store, q) !is null
		&& ecrs.context.addComponent!(doir.components.query.Produces)(*store, q) !is null
		&& ecrs.context.addComponent!(doir.components.query.Creates)(*store, q) !is null
		&& ecrs.context.addComponent!(doir.components.query.QueryDiagnostics)(*store, q) !is null
		&& ecrs.context.addComponent!(doir.components.query.Running)(*store, q) !is null
		&& ecrs.context.addComponent!(doir.components.query.QueryValue!Q)(*store, q) !is null
		&& index!Q(engine, key, q))
		return q;
	cast(void) ecrs.context.removeEntity(*store, q); // if refused, an orphan no index reaches
	return invalidEntity;
}

/// How to fix a `Q-Cycle` chain, the closing note of its report.
package(doir) enum cycleHint = "each query in the chain needs the next; break the loop by removing one of those dependencies, such as an import that leads back to its own file";

/// How to fix demands nested past the depth limit, the closing note of its report.
package(doir) enum depthHint = "nest these declarations or imports less deeply, or raise the engine's depth limit";

// Records a `Q-Cycle` error naming the frames from `from` up and back. On refusal returns false, failing the running queries so none memoizes without it.
private bool reportChain(ref QueryEngine engine, const(char)[] headline, size_t from) {
	char* message = fp.string.makeDynamic(headline);
	bool built = message !is null;
	auto stack = stackOf(engine);
	foreach (frame; stack[from .. fp.dynarray.length(stack)])
		built = built && ecrs.context.getComponent!(doir.components.query.QueryInfo)(*engine.store, frame.query).describe(engine, frame.query, message)
			&& fp.string.concatenate(message, " -> ") !is null;
	immutable head = stack[from].query;
	built = built && ecrs.context.getComponent!(doir.components.query.QueryInfo)(*engine.store, head).describe(engine, head, message);
	char* hint = built ? fp.string.makeDynamic(cycleHint) : null;
	if (hint !is null) return recordDiagnostic(engine, doir.components.query.QueryDiagnostic([invalidEntity], diagnose.Kind.error, message, hint));
	fp.string.free(message);
	fail(engine);
	return false;
}

// Records a `Q-Cycle` error for demands nested past the depth limit at `q`, failing the running queries on a refused allocation as `reportChain` does.
private void reportDepth(ref QueryEngine engine, EntityId q) {
	char* message = fp.string.format("Q-Cycle: queries nest deeper than the limit of %llu at ", cast(ulong) engine.depthLimit);
	char* hint = message !is null && ecrs.context.getComponent!(doir.components.query.QueryInfo)(*engine.store, q).describe(engine, q, message) ? fp.string.makeDynamic(depthHint) : null;
	if (hint !is null) cast(void) recordDiagnostic(engine, doir.components.query.QueryDiagnostic([invalidEntity], diagnose.Kind.error, message, hint)); // fails the running queries itself
	else {
		fp.string.free(message);
		fail(engine);
	}
}

/// Whether query entity `q` is running: on the stack, below or at the innermost query.
///
/// Examples:
/// ---
/// QueryEngine engine;
/// assert(!running(engine, 1));
/// ---
package(doir) bool running(ref QueryEngine engine, EntityId q) {
	return frameOf(engine, q) != noFrame;
}

/// Reports, on the innermost query, that it needs an effect of running query `q` (`Q-Cycle`), naming the chain from `q` up, and marks that chain as part of a cycle. Returns false on a refused allocation, which fails the running queries (`fail`) rather than lose the report.
///
/// Examples:
/// ---
/// static import diagnose;
/// static import ecrs.context;
/// struct Waits {
/// 	alias Key = int;
/// 	alias Value = int;
/// 	static int compute(ref QueryEngine engine, int key) @nogc nothrow {
/// 		assert(reportRunning(engine, currentQuery(engine)));
/// 		return key;
/// 	}
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// diagnose.Manager manager;
/// scope(exit) diagnose.free(manager);
/// QueryEngine engine;
/// engine.store = &store;
/// engine.diagnostics = &manager;
/// scope(exit) free(engine);
/// assert(*query!Waits(engine, 0) == 0);
/// assert(diagnose.count(manager) == 1);
/// ---
package(doir) bool reportRunning(ref QueryEngine engine, EntityId q) {
	immutable h = frameOf(engine, q);
	assert(h != noFrame);
	if (worker !is null) {
		handBack(engine); // cycles are settled on the engine's thread
		return false;
	}
	foreach (ref frame; engine.stack[h .. fp.dynarray.length(engine.stack)]) frame.cycle = true;
	return reportChain(engine, "Q-Cycle: a read needs an effect of a query that is still running: ", h);
}

// True if no dependency changed since `q` was verified, refreshing query dependencies first (early cutoff). Sets `withheld` if one holds diagnostics a worker withheld, and appends to the fp dynarray `reporting` each that holds any. False on a refused allocation too, so `q` runs again.
private bool dependenciesUnchanged(ref QueryEngine engine, EntityId q, ref bool withheld, ref EntityId* reporting) {
	immutable verified = ecrs.context.getComponent!(doir.components.query.VerifiedAt)(*engine.store, q).revision;
	immutable n = fp.dynarray.length(ecrs.context.getComponent!(doir.components.query.DependsOn)(*engine.store, q).related);
	foreach (i; 0 .. n) {
		immutable d = ecrs.context.getComponent!(doir.components.query.DependsOn)(*engine.store, q).related[i];
		auto info = ecrs.context.findComponent!(doir.components.query.QueryInfo)(*engine.store, d);
		if (info !is null) {
			if (!info.refresh(engine, d)) return false;
			withheld = withheld || ecrs.context.getComponent!(doir.components.query.Running)(*engine.store, d).withheld;
			if (core.atomic.atomicLoad(*cast(shared(bool)*) &ecrs.context.getComponent!(doir.components.query.VerifiedAt)(*engine.store, d).reports) && !fp.dynarray.pushBack(reporting, d)) return false;
		}
		auto changed = ecrs.context.findComponent!(doir.components.query.ChangedAt)(*engine.store, d);
		if (changed !is null && changed.revision > verified) return false;
	}
	return true;
}

// Whether `q` is current without checking its dependencies: run before, not stale, no edge missing and not in a cycle. Reusing it still walks to the queries below it that hold diagnostics (`ReportingBelow`).
private bool current(ref QueryEngine engine, EntityId q) {
	auto verified = &ecrs.context.getComponent!(doir.components.query.VerifiedAt)(*engine.store, q);
	return core.atomic.atomicLoad(*cast(shared(Revision)*) &verified.revision) != 0 && !core.atomic.atomicLoad(*cast(shared(bool)*) &verified.stale)
		&& !core.atomic.atomicLoad(*cast(shared(bool)*) &engine.edgesMissing) && !ecrs.context.hasComponent!(doir.components.query.InCycle)(*engine.store, q);
}

// Whether `q` is current and no query below it holds diagnostics, so reusing it visits nothing.
private bool unchanged(ref QueryEngine engine, EntityId q) {
	return current(engine, q) && !core.atomic.atomicLoad(*cast(shared(bool)*) &ecrs.context.getComponent!(doir.components.query.VerifiedAt)(*engine.store, q).reportsBelow);
}

// Records `q` current in this revision, with `reporting`, an fp dynarray of the queries below it that hold diagnostics, as its `ReportingBelow`; `reporting` is left holding the list it replaced, for the caller to free. The revision is released last, publishing the value and flags with it.
private void confirm(ref QueryEngine engine, EntityId q, ref EntityId* reporting) {
	auto verified = &ecrs.context.getComponent!(doir.components.query.VerifiedAt)(*engine.store, q);
	auto list = &ecrs.context.getComponent!(doir.components.query.ReportingBelow)(*engine.store, q).related;
	auto old = *list;
	*list = reporting;
	reporting = old;
	immutable below = fp.dynarray.length(*list) != 0;
	immutable reports = below || fp.dynarray.length(ecrs.context.getComponent!(doir.components.query.QueryDiagnostics)(*engine.store, q).items);
	// Whether it reports is not part of its value, so its readers, which may be reused without walking to it, are told when that changes.
	immutable flipped = reports != core.atomic.atomicLoad(*cast(shared(bool)*) &verified.reports);
	core.atomic.atomicStore(*cast(shared(bool)*) &verified.reportsBelow, below);
	core.atomic.atomicStore(*cast(shared(bool)*) &verified.reports, reports);
	if (flipped && worker is null) invalidate(engine, q);
	core.atomic.atomicStore(*cast(shared(bool)*) &verified.stale, false);
	core.atomic.atomicStore(*cast(shared(Revision)*) &verified.revision, engine.revision);
}

private void clearProvisional(ref QueryEngine engine, EntityId p) {
	if (ecrs.context.hasComponent!(doir.components.query.ProvisionalOn)(*engine.store, p)) cast(void) ecrs.context.removeComponent!(doir.components.query.ProvisionalOn)(*engine.store, p);
}

// Settles queries resting on `self`'s fallback, moving those a lower fallback still holds up. Returns false on refusal, discarding any it could not move.
private bool settleProvisional(ref QueryEngine engine, ref Frame self, size_t index, bool fallbackHeld) {
	if (!self.usedAsHead) return true;
	bool moved = true;
	immutable lower = self.head < index;
	foreach (p; fp.dynarray.slice(self.provisional)) {
		if (fallbackHeld && lower && moved) {
			ecrs.context.getComponent!(doir.components.query.ProvisionalOn)(*engine.store, p).head = engine.stack[self.head].query;
			if (fp.dynarray.pushBack(engine.stack[self.head].provisional, p)) continue;
			moved = false;
		}
		clearProvisional(engine, p);
		if (!fallbackHeld || lower) ecrs.context.getComponent!(doir.components.query.QueryInfo)(*engine.store, p).reset(engine, p);
	}
	fp.dynarray.free(self.provisional);
	return moved;
}

// Marks `q` provisional if it rests on a lower frame's fallback, and tags it if its run joined a cycle. Returns false on refusal.
private bool markCycle(ref QueryEngine engine, EntityId q, ref Frame self, size_t index) {
	if (self.head < index) {
		auto head = &engine.stack[self.head];
		auto mark = ecrs.context.getOrAddComponent!(doir.components.query.ProvisionalOn)(*engine.store, q);
		if (mark is null) return false;
		mark.head = head.query;
		if (!fp.dynarray.pushBack(head.provisional, q)) {
			clearProvisional(engine, q);
			return false;
		}
	}
	immutable tagged = ecrs.context.hasComponent!(doir.components.query.InCycle)(*engine.store, q);
	if (self.cycle && !tagged) return ecrs.context.addComponent!(doir.components.query.InCycle)(*engine.store, q) !is null;
	if (!self.cycle && tagged) cast(void) ecrs.context.removeComponent!(doir.components.query.InCycle)(*engine.store, q);
	return true;
}

// Runs `q` and stores its value. Returns false, leaving `q` reset, if a refused allocation failed the run here or in a query it demanded.
private bool execute(Q)(ref QueryEngine engine, EntityId q) {
	auto store = engine.store;
	removeProduced(engine, q);
	clearDiagnostics(engine, q);
	clearProvisional(engine, q);
	// What it read before is kept to update its reverse edges against.
	auto deps = &ecrs.context.getComponent!(doir.components.query.DependsOn)(*store, q);
	EntityId* before = deps.related;
	deps.related = null;
	scope(exit) fp.dynarray.free(before);
	immutable fresh = ecrs.context.getComponent!(doir.components.query.VerifiedAt)(*store, q).revision == 0;

	if (!fp.dynarray.pushBack(stackOf(engine), Frame(q, 0))) {
		deps.related = before;
		before = null;
		fail(engine);
		reset!Q(engine, q);
		return false;
	}
	auto running = &ecrs.context.getComponent!(doir.components.query.Running)(*store, q);
	running.frame = fp.dynarray.length(stackOf(engine)) - 1;
	if (worker is null) running.owner = callingThread; // a worker claimed it already
	auto key = ecrs.context.getComponent!(doir.components.query.QueryKey!Q)(*store, q).key;
	auto value = Q.compute(engine, key);
	auto frame = *fp.dynarray.back(stackOf(engine));
	scope(exit) fp.dynarray.free(frame.reporting); // or the list `confirm` replaced with it
	cast(void) fp.dynarray.popBack(stackOf(engine));
	running = &ecrs.context.getComponent!(doir.components.query.Running)(*store, q);
	running.frame = noFrame;
	if (worker is null) running.owner = 0;
	immutable index = fp.dynarray.length(stackOf(engine));

	if (frame.refused) {
		// It keeps what it read before, which its reverse edges still list.
		deps = &ecrs.context.getComponent!(doir.components.query.DependsOn)(*store, q);
		fp.dynarray.free(deps.related);
		deps.related = before;
		before = null;
		fp.lifecycle.endLifetime(value);
		cast(void) settleProvisional(engine, frame, index, false);
		reset!Q(engine, q);
		return false;
	}
	removeCreated(engine, q, frame.created);
	recordEdges(engine, q, fp.dynarray.slice(before));
	auto stored = &ecrs.context.getComponent!(doir.components.query.QueryValue!Q)(*store, q);
	immutable hash = hashProduced(engine, q);
	auto produces = &ecrs.context.getComponent!(doir.components.query.Produces)(*store, q);
	bool changed = fresh || produces.hash != hash;
	produces.hash = hash;
	if (fresh || !valuesEqual!Q(stored.value, value)) {
		fp.lifecycle.moveInto(stored.value, value);
		changed = true;
	} else fp.lifecycle.endLifetime(value);
	if (changed) {
		ecrs.context.getComponent!(doir.components.query.ChangedAt)(*store, q).revision = engine.revision;
		// A worker runs only queries `settle` left current or new ones, which nothing reads yet.
		if (worker is null) invalidate(engine, q);
	}
	if (worker !is null) emitAll(engine, q, frame.withheldBelow);
	confirm(engine, q, frame.reporting);

	bool fallbackHeld = true;
	static if (__traits(hasMember, Q, "cycleFallback"))
		if (frame.usedAsHead) {
			auto assumed = Q.cycleFallback(engine, key);
			fallbackHeld = valuesEqual!Q(ecrs.context.getComponent!(doir.components.query.QueryValue!Q)(*store, q).value, assumed);
			fp.lifecycle.endLifetime(assumed);
		}
	if (!settleProvisional(engine, frame, index, fallbackHeld) || !markCycle(engine, q, frame, index)) {
		fail(engine);
		reset!Q(engine, q);
		return false;
	}
	if (worker is null) emitAll(engine, q, frame.withheldBelow);
	return true;
}

// Whether `q` was verified in the current revision, which a worker may have just done.
private bool verifiedNow(ref QueryEngine engine, EntityId q) {
	return core.atomic.atomicLoad(*cast(shared(Revision)*) &ecrs.context.getComponent!(doir.components.query.VerifiedAt)(*engine.store, q).revision) == engine.revision;
}

// Whether a worker may bring `q` up to date: re-running it removes nothing, since it produced and created nothing and joined no cycle.
private bool plain(ref QueryEngine engine, EntityId q) {
	auto store = engine.store;
	return fp.dynarray.length(ecrs.context.getComponent!(doir.components.query.Produces)(*store, q).items) == 0
		&& fp.dynarray.length(ecrs.context.getComponent!(doir.components.query.Creates)(*store, q).related) == 0
		&& !ecrs.context.hasComponent!(doir.components.query.InCycle)(*store, q)
		&& !ecrs.context.hasComponent!(doir.components.query.ProvisionalOn)(*store, q);
}

// On a worker, waits until no thread runs `q`, as rustc's `QueryLatch` does; false if the waits loop back here, a cycle across threads (`Q-Cycle`).
private bool await(ref QueryEngine engine, ref doir.components.query.Running running) {
	for (;;) {
		uint owner = core.atomic.atomicLoad(*cast(shared(uint)*) &running.owner);
		if (owner == 0) return true;
		// Each hop is another worker, so a chain longer than the workers loops among others, who find it themselves.
		for (size_t hops = 0; owner >= firstWorker && hops < worker.owners; ++hops) {
			if (owner == worker.self) return false;
			immutable next = core.atomic.atomicLoad(*cast(shared(EntityId)*) &worker.waitingOn[owner]);
			if (next == invalidEntity) break;
			owner = core.atomic.atomicLoad(*cast(shared(uint)*) &ecrs.context.getComponent!(doir.components.query.Running)(*engine.store, next).owner);
		}
		cast(void) core.sys.posix.sched.sched_yield();
	}
}

// `refresh` on a worker: claims `q`, waiting while another worker runs it, then validates or re-runs it, handing back what the engine's thread must do.
private bool refreshShared(Q)(ref QueryEngine engine, EntityId q) {
	auto running = &ecrs.context.getComponent!(doir.components.query.Running)(*engine.store, q);
	// Nothing runs an unchanged query, so confirming one with no diagnostics to withhold needs no claim.
	if (unchanged(engine, q) && !core.atomic.atomicLoad(*cast(shared(bool)*) &ecrs.context.getComponent!(doir.components.query.VerifiedAt)(*engine.store, q).reports)) {
		core.atomic.atomicStore(*cast(shared(Revision)*) &ecrs.context.getComponent!(doir.components.query.VerifiedAt)(*engine.store, q).revision, engine.revision);
		return true;
	}
	for (;;) {
		if (verifiedNow(engine, q)) return true;
		if (core.atomic.cas(cast(shared(uint)*) &running.owner, 0u, worker.self)) break;
		core.atomic.atomicStore(*cast(shared(EntityId)*) &worker.waitingOn[worker.self], q);
		immutable free = await(engine, *running);
		core.atomic.atomicStore(*cast(shared(EntityId)*) &worker.waitingOn[worker.self], invalidEntity);
		if (!free) {
			handBack(engine);
			return false;
		}
	}
	scope(exit) core.atomic.atomicStore(*cast(shared(uint)*) &running.owner, 0u);
	if (verifiedNow(engine, q)) return true;
	if (unchanged(engine, q)) {
		emitAll(engine, q, false);
		core.atomic.atomicStore(*cast(shared(Revision)*) &ecrs.context.getComponent!(doir.components.query.VerifiedAt)(*engine.store, q).revision, engine.revision);
		return true;
	}
	if (!plain(engine, q) || worker.depth >= engine.depthLimit) {
		handBack(engine);
		return false;
	}
	++worker.depth;
	scope(exit) --worker.depth;
	// As `refresh`: current, so only the queries below it holding diagnostics are visited.
	if (current(engine, q)) {
		bool below = false;
		for (size_t i = 0; i < fp.dynarray.length(ecrs.context.getComponent!(doir.components.query.ReportingBelow)(*engine.store, q).related); ++i) {
			immutable d = ecrs.context.getComponent!(doir.components.query.ReportingBelow)(*engine.store, q).related[i];
			if (!ecrs.context.getComponent!(doir.components.query.QueryInfo)(*engine.store, d).refresh(engine, d)) return false;
			below = below || ecrs.context.getComponent!(doir.components.query.Running)(*engine.store, d).withheld;
		}
		emitAll(engine, q, below);
		core.atomic.atomicStore(*cast(shared(Revision)*) &ecrs.context.getComponent!(doir.components.query.VerifiedAt)(*engine.store, q).revision, engine.revision);
		return true;
	}
	bool withheld = false;
	EntityId* reporting = null;
	scope(exit) fp.dynarray.free(reporting);
	if (ecrs.context.getComponent!(doir.components.query.VerifiedAt)(*engine.store, q).revision == 0 || !dependenciesUnchanged(engine, q, withheld, reporting)) return execute!Q(engine, q);
	emitAll(engine, q, withheld);
	confirm(engine, q, reporting);
	return true;
}

private bool refresh(Q)(ref QueryEngine engine, EntityId q) {
	if (frameOf(engine, q) != noFrame) return false;
	if (worker !is null) return refreshShared!Q(engine, q);
	auto store = engine.store;
	immutable verified = ecrs.context.getComponent!(doir.components.query.VerifiedAt)(*store, q).revision;
	if (verified == engine.revision) {
		if (!engine.settling) flushWithheld(engine, q);
		return true;
	}
	if (unchanged(engine, q)) {
		ecrs.context.getComponent!(doir.components.query.VerifiedAt)(*store, q).revision = engine.revision;
		emitAll(engine, q, false);
		return true;
	}
	if (engine.depth >= engine.depthLimit) {
		reportDepth(engine, q);
		return false;
	}
	++engine.depth;
	scope(exit) --engine.depth;
	// Current, so nothing it read changed: only the queries below it holding diagnostics are visited, to report them in order.
	if (current(engine, q)) {
		ecrs.context.getComponent!(doir.components.query.VerifiedAt)(*store, q).revision = engine.revision;
		bool withheld = false;
		for (size_t i = 0; i < fp.dynarray.length(ecrs.context.getComponent!(doir.components.query.ReportingBelow)(*store, q).related); ++i) {
			immutable d = ecrs.context.getComponent!(doir.components.query.ReportingBelow)(*store, q).related[i];
			if (!ecrs.context.getComponent!(doir.components.query.QueryInfo)(*store, d).refresh(engine, d)) return false;
			withheld = withheld || ecrs.context.getComponent!(doir.components.query.Running)(*store, d).withheld;
		}
		emitAll(engine, q, withheld);
		return true;
	}
	bool withheld = false;
	EntityId* reporting = null;
	scope(exit) fp.dynarray.free(reporting);
	if (verified == 0 || ecrs.context.hasComponent!(doir.components.query.InCycle)(*store, q) || !dependenciesUnchanged(engine, q, withheld, reporting)) return execute!Q(engine, q);
	confirm(engine, q, reporting);
	emitAll(engine, q, withheld);
	return true;
}

private void reset(Q)(ref QueryEngine engine, EntityId q) {
	assert(frameOf(engine, q) == noFrame);
	removeProduced(engine, q);
	removeCreated(engine, q, 0);
	clearDiagnostics(engine, q);
	clearProvisional(engine, q);
	// The value stays as a component, emptied, so a worker re-running `q` never adds one.
	auto stored = &ecrs.context.getComponent!(doir.components.query.QueryValue!Q)(*engine.store, q);
	fp.lifecycle.endLifetime(stored.value);
	stored.value = Q.Value.init;
	ecrs.context.getComponent!(doir.components.query.VerifiedAt)(*engine.store, q).revision = 0;
	// Its next run may answer differently. A worker resets only a query it ran because it was stale, so its dependents are already.
	if (worker is null) invalidate(engine, q);
}

private bool addRequested(Q)(ref QueryEngine engine, const(ubyte)[] key) @trusted {
	auto k = cast(const(Q.Key)*) key.ptr;
	return find!Q(engine, *k) != invalidEntity || add!Q(engine, *k) != invalidEntity;
}

// Asks the engine's thread to add `Q`'s query entity at `key`; if the request cannot be stored, the demand still goes back to it.
private void request(Q)(ref const Q.Key key) @trusted {
	auto keys = worker.keys;
	immutable from = fp.dynarray.length(*keys);
	if (fp.dynarray.concatenate(*keys, (cast(const(ubyte)*) &key)[0 .. Q.Key.sizeof]))
		cast(void) fp.dynarray.pushBack(*worker.requests, Request(&addRequested!Q, from, from + Q.Key.sizeof));
}

// A demand for `q`, which is running in frame `h`: every frame from `h` up is part of the cycle.
private const(Q.Value)* cycle(Q)(ref QueryEngine engine, EntityId q, size_t h) {
	immutable top = fp.dynarray.length(engine.stack) - 1;
	foreach (ref frame; engine.stack[h .. top + 1]) frame.cycle = true;
	if (!read(engine, q)) return null;
	static if (__traits(hasMember, Q, "cycleFallback")) {
		static Q.Value fallback;
		fp.lifecycle.endLifetime(fallback);
		fallback = Q.cycleFallback(engine, ecrs.context.getComponent!(doir.components.query.QueryKey!Q)(*engine.store, q).key);
		engine.stack[h].usedAsHead = true;
		if (h < top && h < engine.stack[top].head) engine.stack[top].head = h;
		return &fallback;
	} else {
		cast(void) reportChain(engine, "Q-Cycle: a query needs its own answer: ", h); // the demand returns null either way
		return null;
	}
}

/// The value of `Q` at `key`, computed on first demand and re-validated against the current revision on every later one. Records the read in the running query, if any.
///
/// A demand for a query that is already running is a cycle (`Q-Cycle`). If `Q` declares `cycleFallback`, the demand gets that value, and every query whose value rests on it stays provisional until the running one finishes: if its answer equals the fallback they are kept, and otherwise they are reset, to run again on their next demand. This suits a fallback that assumes the coinductive answer, as structural equivalence assumes a pair under comparison equal (`S-Struct`, `TF-Self`). Without a fallback, the cycle is reported as an error naming the chain of queries that closes it, and the demand returns null. A demand nested deeper than `engine.depthLimit` is reported and returns null too, rather than overflowing the stack. So does a demand whose run, or any run below it, met a refused allocation (`fail`); then `engine.refused` is set.
///
/// The pointer is valid until the next structural change to the store, or for a fallback, the next fallback of `Q`.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// struct Loop {
/// 	alias Key = int;
/// 	alias Value = bool;
/// 	static bool compute(ref QueryEngine engine, int key) @nogc nothrow { return query!Loop(engine, key) is null; }
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// QueryEngine engine;
/// engine.store = &store;
/// scope(exit) free(engine);
/// assert(*query!Loop(engine, 1)); // the inner demand saw the cycle
/// ---
const(Q.Value)* query(Q)(ref QueryEngine engine, Q.Key key) if (isQuery!Q) {
	if (worker is null && idle(engine)) cast(void) settle(engine); // a failure is recorded in `edgesMissing`
	auto q = find!Q(engine, key);
	// A worker adds no entity and settles no cycle: the engine's thread does, when the demand is handed back.
	if (q == invalidEntity && worker !is null) {
		request!Q(key);
		handBack(engine);
		return null;
	}
	if (q == invalidEntity && (q = add!Q(engine, key)) == invalidEntity) {
		fail(engine);
		return null;
	}
	immutable h = frameOf(engine, q);
	if (h != noFrame && worker !is null) {
		handBack(engine);
		return null;
	}
	if (h != noFrame) return cycle!Q(engine, q, h);
	if (!refresh!Q(engine, q) || !read(engine, q)) return null;
	if (!idle(engine) && core.atomic.atomicLoad(*cast(shared(bool)*) &ecrs.context.getComponent!(doir.components.query.VerifiedAt)(*engine.store, q).reports)) {
		auto top = fp.dynarray.back(stackOf(engine));
		immutable n = fp.dynarray.length(top.reporting);
		if ((n == 0 || top.reporting[n - 1] != q) && !fp.dynarray.pushBack(top.reporting, q)) {
			fail(engine);
			return null;
		}
	}
	if ((worker !is null || engine.settling) && !idle(engine) && ecrs.context.getComponent!(doir.components.query.Running)(*engine.store, q).withheld)
		fp.dynarray.back(stackOf(engine)).withheldBelow = true;
	return &ecrs.context.getComponent!(doir.components.query.QueryValue!Q)(*engine.store, q).value;
}

/// Brings every stale query that another query reads up to date (`invalidate`), so that afterwards a query that is not stale is current and is reused without visiting its dependencies. One nothing reads stays stale until it is demanded, as everything not reached by a change stays unrun. One whose value changes marks its dependents stale in turn; one that keeps its value stops the change there (early cutoff). Their diagnostics are withheld until a demand reaches them, to be reported in the order that demand would report them. Demands call it first; it requires an idle engine.
///
/// Returns false if a demand failed, a refused allocation or a `Q-Cycle` past the depth limit; `engine.edgesMissing` is then set, so no query is reused unchecked.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// QueryEngine engine;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// engine.store = &store;
/// scope(exit) free(engine);
/// assert(settle(engine));
/// ---
package(doir) bool settle(ref QueryEngine engine) {
	assert(idle(engine) && worker is null, "doir.query: settling inside a query");
	if (fp.dynarray.length(engine.pending) == 0) return true;
	engine.settling = true;
	scope(exit) engine.settling = false;
	while (fp.dynarray.length(engine.pending)) {
		immutable q = *fp.dynarray.back(engine.pending);
		cast(void) fp.dynarray.popBack(engine.pending);
		auto verified = ecrs.context.findComponent!(doir.components.query.VerifiedAt)(*engine.store, q);
		auto info = ecrs.context.findComponent!(doir.components.query.QueryInfo)(*engine.store, q);
		// One never run or reset since runs when demanded, and one nothing reads cannot pass a change on, so it waits for its demand too.
		auto readers = ecrs.context.findComponent!(doir.components.query.Dependents)(*engine.store, q);
		if (verified is null || info is null || verified.revision == 0 || !verified.stale || readers is null || fp.dynarray.length(readers.related) == 0) continue;
		if (!info.refresh(engine, q)) {
			engine.edgesMissing = true;
			fp.dynarray.clear(engine.pending);
			return false;
		}
	}
	return true;
}

/// Frees what the query entity of `Q` at `key` holds: its value, diagnostics, the components it produced and the entities it created. The entity keeps its key and `ChangedAt`, so dependents still see it, and the next demand re-runs it. Does nothing if `Q` was never demanded at `key`.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// struct Halve {
/// 	alias Key = int;
/// 	alias Value = int;
/// 	static int compute(ref QueryEngine engine, int key) @nogc nothrow { return key / 2; }
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// QueryEngine engine;
/// engine.store = &store;
/// scope(exit) free(engine);
/// assert(*query!Halve(engine, 2) == 1);
/// evict!Halve(engine, 2);
/// assert(*query!Halve(engine, 2) == 1);
/// ---
void evict(Q)(ref QueryEngine engine, Q.Key key) if (isQuery!Q) {
	immutable q = find!Q(engine, key);
	if (q == invalidEntity) return;
	reset!Q(engine, q);
}

/// Whether `Q` at `key` holds a value a demand would reuse without running anything or checking its dependencies: nothing it depends on changed since it was last verified. A demand still walks to the queries below it that hold diagnostics, to report them, visiting only those (`ReportingBelow`). A walk over many queries can skip those, and batch the rest with `demandEach`.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// struct Third {
/// 	alias Key = int;
/// 	alias Value = int;
/// 	static int compute(ref QueryEngine engine, int key) @nogc nothrow { return key / 3; }
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// QueryEngine engine;
/// engine.store = &store;
/// scope(exit) free(engine);
/// assert(!upToDate!Third(engine, 3));
/// assert(*query!Third(engine, 3) == 1 && upToDate!Third(engine, 3));
/// ---
package(doir) bool upToDate(Q)(ref QueryEngine engine, const Q.Key key) if (isQuery!Q) {
	cast(void) settle(engine); // a failure is recorded in `edgesMissing`
	immutable q = find!Q(engine, key);
	return q != invalidEntity && current(engine, q);
}

// One worker's share of a batch: the batch, the `Running.owner` it claims queries as, and the query entities it asked for this round.
private struct BatchJob(Q) {
	Batch!Q* batch;
	uint self;
	Request* requests;
	ubyte* keys;
	Edge* edges;
}

// How many demands a worker takes at once, so workers rarely contend for the batch's counter.
private enum size_t batchStride = 16;

// How many rounds a batch runs before the engine's thread takes what is left, as each round can only reveal entities one demand deeper.
private enum size_t batchRounds = 16;

private void runBatch(Q)(void* arg) @nogc nothrow {
	auto job = cast(BatchJob!Q*) arg;
	auto batch = job.batch;
	Worker state = Worker(null, 0, job.self, false, batch.waitingOn, batch.owners, &job.requests, &job.keys, &job.edges);
	worker = &state;
	scope(exit) {
		worker = null;
		fp.dynarray.free(state.stack);
	}
	for (;;) {
		immutable from = core.atomic.atomicOp!"+="(batch.next, batchStride) - batchStride;
		if (from >= batch.round.length) break;
		foreach (i; batch.round[from .. from + batchStride < batch.round.length ? from + batchStride : batch.round.length]) {
			state.handedBack = false;
			auto value = query!Q(*batch.engine, batch.keys[i]);
			batch.handedBack[i] = state.handedBack;
			if (value !is null && !core.atomic.atomicLoad(batch.withheld) && ecrs.context.getComponent!(doir.components.query.Running)(*batch.engine.store, find!Q(*batch.engine, batch.keys[i])).withheld)
				core.atomic.atomicStore(batch.withheld, true);
		}
	}
}

/// Demands `Q` at each of `keys`, as calling `query` on each in turn would, its diagnostics reported in that order, but on `engine.workers` when it has two or more: each worker takes demands as it frees up, and a query two of them need runs once while the other waits for it, as rustc's `QueryLatch` does. Work only the engine's thread may do, adding an entity or a component or settling a cycle (`Q-Cycle`), hands the demand back to it, to run once the workers finish. Values are read afterwards with `query`, which finds them up to date. Requires an idle engine.
///
/// Returns false if an allocation was refused, as `engine.refused` records; some demands then keep no value.
///
/// Examples:
/// ---
/// static import bc.threadpool;
/// static import ecrs.context;
/// struct Twice {
/// 	alias Key = int;
/// 	alias Value = int;
/// 	static int compute(ref QueryEngine engine, int key) @nogc nothrow { return 2 * key; }
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// QueryEngine engine;
/// engine.store = &store;
/// engine.workers = bc.threadpool.create(2);
/// scope(exit) bc.threadpool.free(engine.workers);
/// scope(exit) free(engine);
/// immutable int[3] keys = [1, 2, 3];
/// assert(demandEach!Twice(engine, keys[]) && *query!Twice(engine, 3) == 6);
/// ---
bool demandEach(Q)(ref QueryEngine engine, const(Q.Key)[] keys) @trusted if (isQuery!Q) {
	assert(idle(engine), "doir.query: a batch of demands inside a query");
	cast(void) settle(engine); // a failure is recorded in `edgesMissing`
	immutable workers = engine.workers is null ? 1 : bc.threadpool.workerCount(engine.workers);
	bool serially() {
		foreach (key; keys)
			if (query!Q(engine, key) is null && engine.refused) return false;
		return !engine.refused;
	}
	if (workers < 2 || keys.length < 2) return serially();
	// Workers add no entities, so every demand's query entity is made here first.
	EntityId* entities = null;
	size_t* round = null;
	bool* handedBack = null;
	EntityId* waitingOn = null;
	BatchJob!Q* jobs = null;
	bc.threadpool.Job* work = null;
	scope(exit) {
		fp.dynarray.free(entities);
		fp.dynarray.free(round);
		fp.dynarray.free(handedBack);
		fp.dynarray.free(waitingOn);
		foreach (ref job; fp.dynarray.slice(jobs)) {
			fp.dynarray.free(job.requests);
			fp.dynarray.free(job.keys);
			fp.dynarray.free(job.edges);
		}
		fp.dynarray.free(jobs);
		fp.dynarray.free(work);
	}
	immutable owners = firstWorker + workers;
	if (fp.dynarray.growToSize(entities, keys.length) is null || fp.dynarray.growToSize(round, keys.length) is null || fp.dynarray.growToSize(handedBack, keys.length) is null
		|| fp.dynarray.growToSize(waitingOn, owners) is null || fp.dynarray.reserve(jobs, workers) is null || fp.dynarray.reserve(work, workers) is null)
		return serially();
	foreach (i, ref key; keys) {
		if ((entities[i] = find!Q(engine, key)) == invalidEntity && (entities[i] = add!Q(engine, key)) == invalidEntity) {
			engine.refused = true;
			return false;
		}
		round[i] = i;
	}
	waitingOn[0 .. owners] = invalidEntity;
	Batch!Q batch;
	batch.engine = &engine;
	batch.keys = keys;
	batch.handedBack = handedBack;
	batch.waitingOn = waitingOn;
	batch.owners = owners;
	foreach (w; 0 .. workers) {
		cast(void) fp.dynarray.pushBack(jobs, BatchJob!Q(&batch, cast(uint) (firstWorker + w))); // reserved
		cast(void) fp.dynarray.pushBack(work, bc.threadpool.Job(&runBatch!Q, &jobs[w])); // reserved
	}
	size_t remaining = keys.length;
	foreach (r; 0 .. batchRounds) {
		batch.round = round[0 .. remaining];
		batch.next = 0;
		// The phase asserts that no worker changes the store's structure.
		ecrs.context.beginConcurrentWrites(*engine.store);
		immutable ran = bc.threadpool.run(engine.workers, fp.dynarray.slice(work));
		ecrs.context.endConcurrentWrites(*engine.store);
		const(Edge)[]* lists = null;
		foreach (ref job; fp.dynarray.slice(jobs))
			if (!fp.dynarray.pushBack(lists, fp.dynarray.slice(job.edges))) engine.edgesMissing = true;
		if (!engine.edgesMissing) applyEdges(engine, fp.dynarray.slice(lists));
		fp.dynarray.free(lists);
		foreach (ref job; fp.dynarray.slice(jobs))
			if (job.edges !is null) fp.dynarray.clear(job.edges);
		if (!ran) {
			foreach (i; round[0 .. remaining]) handedBack[i] = true;
			break;
		}
		// The entities the workers asked for are added here, so the demands that needed them can run again in another round.
		bool added = false;
		foreach (ref job; fp.dynarray.slice(jobs)) {
			foreach (ref wanted; fp.dynarray.slice(job.requests)) {
				if (!wanted.add(engine, job.keys[wanted.from .. wanted.to])) {
					engine.refused = true;
					return false;
				}
				added = true;
			}
			if (job.requests !is null) fp.dynarray.clear(job.requests);
			if (job.keys !is null) fp.dynarray.clear(job.keys);
		}
		size_t kept = 0;
		foreach (i; round[0 .. remaining]) if (handedBack[i]) round[kept++] = i;
		remaining = kept;
		if (!added || remaining == 0) break;
	}
	foreach (i, ref key; keys) {
		if (handedBack[i]) {
			if (query!Q(engine, key) is null && engine.refused) return false;
		} else flushWithheld(engine, entities[i]); // `settle` may have withheld some too
	}
	return !engine.refused;
}


// --- creation and freeing ----------------------------------------------------

/// Starts an engine on `store`, which must outlive it.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = create(store);
/// scope(exit) free(engine);
/// assert(engine.revision == 1);
/// ---
QueryEngine create(ref ecrs.context.Context store) {
	QueryEngine out_;
	out_.store = &store;
	return out_;
}

/// Releases the engine's own memory and its positions. Query entities stay in the store.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// QueryEngine engine;
/// engine.store = &store;
/// free(engine);
/// ---
void free(ref QueryEngine engine) {
	assert(idle(engine));
	fp.dynarray.free(engine.stack);
	fp.dynarray.free(engine.pending);
	doir.engine.positions.free(engine.positions);
}


// --- inputs ------------------------------------------------------------------

/// Starts a new revision. Call once per batch of input changes (one input commit), before `markChanged`.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = create(store);
/// scope(exit) free(engine);
/// beginRevision(engine);
/// assert(engine.revision == 2);
/// ---
void beginRevision(ref QueryEngine engine) {
	assert(idle(engine));
	++engine.revision;
}

/// Records that input entity `e` changed in the current revision, and marks every query that depends on it stale (`invalidate`), so the next demand of one checks it again; a query no change reaches is reused without visiting its dependencies. An input commit calls this for every entity it creates or whose components it replaces, since a freed id may be handed out again. Returns false if the store refused the record, leaving `e` as it was.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = create(store);
/// scope(exit) free(engine);
/// immutable e = ecrs.context.addEntity(store);
/// assert(markChanged(engine, e));
/// assert(changedAt(engine, e) == engine.revision);
/// ---
bool markChanged(ref QueryEngine engine, EntityId e) {
	assert(idle(engine));
	// Set rather than written in place, so a transaction around an input commit can undo it; a stale mark it leaves only costs a check.
	if (!ecrs.context.setComponent!(doir.components.query.ChangedAt)(*engine.store, e, doir.components.query.ChangedAt(engine.revision))) return false;
	invalidate(engine, e);
	return true;
}

/// The revision `e` last changed in; 0 if it never has.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = create(store);
/// scope(exit) free(engine);
/// assert(changedAt(engine, ecrs.context.addEntity(store)) == 0);
/// ---
Revision changedAt(ref QueryEngine engine, EntityId e) {
	auto changed = ecrs.context.findComponent!(doir.components.query.ChangedAt)(*engine.store, e);
	return changed is null ? 0 : changed.revision;
}


// --- inside a running query --------------------------------------------------

/// Adds component `C` to `e` on behalf of the running query, which owns it: it is removed before the query runs again and when the query is evicted. `e` must not already have a `C`. Its contents count toward early cutoff, hashed by `C.contentHash(ref const C)` if `C` declares one and by their bytes otherwise, so a component holding pointers should declare one. Returns null on a refused allocation, which fails the running queries (`fail`).
///
/// Examples:
/// ---
/// static import ecrs.relation;
/// static import ecrs.context;
/// struct Size { int value; }
/// struct Annotate {
/// 	alias Key = ecrs.relation.Relation!1;
/// 	alias Value = bool;
/// 	static bool compute(ref QueryEngine engine, Key key) @nogc nothrow {
/// 		immutable e = key.related[0];
/// 		auto size = produce!Size(engine, e);
/// 		if (size is null) return false;
/// 		size.value = 4;
/// 		return true;
/// 	}
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = create(store);
/// scope(exit) free(engine);
/// immutable e = ecrs.context.addEntity(store);
/// assert(*query!Annotate(engine, Annotate.Key([e])));
/// assert(ecrs.context.getComponent!Size(store, e).value == 4);
/// ---
C* produce(C)(ref QueryEngine engine, EntityId e) {
	immutable id = ecrs.registry.componentId!C();
	if (!recordProduced(engine, doir.components.query.Produced([e], id, &stripComponent, &hashComponent!C), true)) return null;
	auto component = ecrs.context.addComponent!C(*engine.store, e);
	if (component is null) fail(engine);
	return component;
}

/// Creates an entity owned by the running query, with a `Provenance` naming `origin`, the entity it is derived from. The n-th call in a run returns the entity the n-th call returned in the previous run, so values holding created ids stay equal across re-runs (as rustc's `create_def` does). Returns `invalidEntity` on a refused allocation, which fails the running queries (`fail`).
///
/// Examples:
/// ---
/// static import doir.components.query;
/// static import ecrs.relation;
/// static import ecrs.context;
/// struct Make {
/// 	alias Key = ecrs.relation.Relation!1;
/// 	alias Value = ecrs.relation.Relation!1;
/// 	static Value compute(ref QueryEngine engine, Key key) @nogc nothrow { return Value([createEntity(engine, key.related[0])]); }
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = create(store);
/// scope(exit) free(engine);
/// immutable from = ecrs.context.addEntity(store);
/// immutable made = query!Make(engine, Make.Key([from])).related[0];
/// assert(ecrs.context.getComponent!(doir.components.query.Provenance)(store, made).origin == from);
/// ---
EntityId createEntity(ref QueryEngine engine, EntityId origin) {
	immutable e = nextCreated(engine);
	if (e == invalidEntity) return invalidEntity;
	auto provenance = produce!(doir.components.query.Provenance)(engine, e);
	if (provenance is null) return invalidEntity;
	provenance.origin = origin;
	return e;
}

/// Another entity a reported diagnostic involves, `target`, with what part it plays, such as "first made visible here".
struct Related {
	mixin ecrs.relation.Relates!"target";
	const(char)[] message; /// What part it plays.
}

/// Reports a diagnostic about `subject` (`invalidEntity` for none), with `hint` saying how to fix it, drawn as an annotation at `subject`, and an annotation at each of the `related` entities. A `subject` without a location gets the hint as its closing note instead (`AGENTS.md`, Diagnostics). Inside a query it is stored on the running query entity and reported again whenever that memo is reused in a later revision, so a cached answer reports what a fresh one does; outside any query it goes straight to `engine.diagnostics`. Returns false on a refused allocation, which loses the diagnostic and fails the running queries (`fail`).
///
/// Examples:
/// ---
/// static import fp.string;
/// static import ecrs.context;
/// static import diagnose;
/// struct Warn {
/// 	alias Key = int;
/// 	alias Value = int;
/// 	static int compute(ref QueryEngine engine, int key) @nogc nothrow {
/// 		if (!report(engine, invalidEntity, diagnose.Kind.warning, "careful", "be less careless")) return 0;
/// 		return key;
/// 	}
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// diagnose.Manager manager;
/// scope(exit) diagnose.free(manager);
/// auto engine = create(store);
/// scope(exit) free(engine);
/// engine.diagnostics = &manager;
/// assert(*query!Warn(engine, 1) == 1);
/// assert(diagnose.count(manager) == 1 && fp.string.slice(manager.diagnostics[0].additionalNote) == "be less careless");
/// ---
bool report(ref QueryEngine engine, EntityId subject, diagnose.Kind kind, const(char)[] message, const(char)[] hint, const(Related)[] related = null) {
	assert(hint.length, "every diagnostic says how to fix it");
	auto d = doir.components.query.QueryDiagnostic([subject], kind, fp.string.makeDynamic(message), fp.string.makeDynamic(hint));
	bool ok = (d.message !is null || message.length == 0) && d.hint !is null
		&& (related.length == 0 || fp.dynarray.reserve(d.annotations, related.length) !is null);
	foreach (r; related) {
		if (!ok) break;
		auto a = doir.components.query.QueryAnnotation([r.target], fp.string.makeDynamic(r.message));
		ok = (a.message !is null || r.message.length == 0) && fp.dynarray.pushBack(d.annotations, a); // reserved above
		if (!ok) fp.string.free(a.message);
	}
	if (ok) return recordDiagnostic(engine, d);
	doir.components.query.freeDiagnostic(d);
	fail(engine);
	return false;
}


// --- renumbering -------------------------------------------------------------

/// Renumbers the store's entities, `order[i]` being the entity that becomes `i`, as `ecrs.context.reorderEntities` does: every entity-valued component, query keys, values, dependencies, tables and effect logs included, in one step (`E-Remap`). Only between levels or edits: no query may be running.
///
/// Returns false if allocation fails, leaving the store as it was.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = create(store);
/// scope(exit) free(engine);
/// immutable a = ecrs.context.addEntity(store), b = ecrs.context.addEntity(store);
/// *ecrs.context.addComponent!int(store, a) = 7;
/// immutable size_t[3] order = [0, 2, 1];
/// assert(renumber(engine, order[]));
/// assert(ecrs.context.getComponent!int(store, b) == 7);
/// ---
bool renumber(ref QueryEngine engine, const(size_t)[] order) {
	assert(idle(engine), "doir.query: renumbering while a query runs (E-Remap)");
	// Pending stale queries are held by id, so they are brought up to date first.
	cast(void) settle(engine); // a failure is recorded in `edgesMissing`
	return ecrs.context.reorderEntities(*engine.store, order);
}

/// Renumbers the live entities densely, as `ecrs.context.compact` does, under the same conditions as `renumber` (`E-Remap`).
///
/// Returns false if allocation fails, leaving the store as it was.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = create(store);
/// scope(exit) free(engine);
/// immutable a = ecrs.context.addEntity(store), b = ecrs.context.addEntity(store);
/// *ecrs.context.addComponent!int(store, b) = 7;
/// assert(ecrs.context.removeEntity(store, a));
/// assert(compact(engine));
/// assert(ecrs.context.getComponent!int(store, a) == 7);
/// ---
bool compact(ref QueryEngine engine) {
	assert(idle(engine), "doir.query: renumbering while a query runs (E-Remap)");
	// Pending stale queries are held by id, so they are brought up to date first.
	cast(void) settle(engine); // a failure is recorded in `edgesMissing`
	return ecrs.context.compact(*engine.store);
}


version(unittest) {
	static import fp.dynarray;

	static import fp.pointer;
	static import doir.testing;

	private __gshared int runs;

	private struct Amount {
		int value;
	}


	private struct Input {
		alias Key = ecrs.relation.Relation!1;
		alias Value = int;
		static int compute(ref QueryEngine engine, Key key) @nogc nothrow {
			immutable e = key.related[0];
			++runs;
			if (!read(engine, e)) return 0;
			return ecrs.context.getComponent!Amount(*engine.store, e).value;
		}
	}

	private struct IsPositive {
		alias Key = ecrs.relation.Relation!1;
		alias Value = bool;
		static bool compute(ref QueryEngine engine, Key key) @nogc nothrow {
			immutable e = key.related[0];
			++runs;
			auto amount = query!Input(engine, Input.Key([e]));
			if (amount is null || (*amount < 0 && !report(engine, e, diagnose.Kind.warning, "negative", "make it positive"))) return false;
			return *amount > 0;
		}
	}

	private struct Sign {
		alias Key = ecrs.relation.Relation!1;
		alias Value = int;
		static int compute(ref QueryEngine engine, Key key) @nogc nothrow {
			immutable e = key.related[0];
			++runs;
			auto positive = query!IsPositive(engine, IsPositive.Key([e]));
			if (positive is null) return 0;
			return *positive ? 1 : -1;
		}
	}

	// Parity warns when the amount is odd, its value staying 0, so whether it reports changes without its value changing.
	private struct Parity {
		alias Key = ecrs.relation.Relation!1;
		alias Value = int;
		static int compute(ref QueryEngine engine, Key key) @nogc nothrow {
			auto amount = query!Input(engine, Input.Key([key.related[0]]));
			if (amount !is null && *amount % 2) cast(void) report(engine, key.related[0], diagnose.Kind.warning, "odd", "make it even"); // a refusal fails this query
			return 0;
		}
	}

	private struct Wrap {
		alias Key = ecrs.relation.Relation!1;
		alias Value = int;
		static int compute(ref QueryEngine engine, Key key) @nogc nothrow {
			auto parity = query!Parity(engine, Parity.Key([key.related[0]]));
			return parity is null ? -1 : *parity;
		}
	}

	private struct Twin {
		alias Key = int;
		alias Value = ecrs.relation.Relation!1;
		static Value compute(ref QueryEngine engine, int key) @nogc nothrow {
			++runs;
			auto e = createEntity(engine, invalidEntity);
			if (e == invalidEntity) return Value.init; // on a worker, handed back
			auto amount = produce!Amount(engine, e);
			if (amount is null) return Value.init;
			amount.value = key;
			return Value([e]);
		}
	}

	// Copies the Amount of input `knob` onto an entity it creates, whose id stays the same across re-runs.
	private struct Copy {
		alias Key = ecrs.relation.Relation!1;
		alias Value = ecrs.relation.Relation!1;
		static Value compute(ref QueryEngine engine, Key key) @nogc nothrow {
			immutable knob = key.related[0];
			assert(read(engine, knob));
			auto e = createEntity(engine, knob);
			auto amount = produce!Amount(engine, e);
			assert(e != invalidEntity && amount !is null);
			amount.value = ecrs.context.getComponent!Amount(*engine.store, knob).value;
			return Value([e]);
		}
	}

	// Writes an Amount it owns through `own`, recording it twice.
	private struct Stamp {
		alias Key = ecrs.relation.Relation!1;
		alias Value = bool;
		static void strip(ref ecrs.context.Context store, EntityId e, size_t component, EntityId owner) @nogc nothrow {
			assert(ecrs.context.removeComponent!Amount(store, e));
		}
		static size_t hash(ref const ecrs.context.Context store, EntityId e, size_t component, EntityId owner) @nogc nothrow {
			return 0;
		}
		static bool compute(ref QueryEngine engine, Key key) @nogc nothrow {
			immutable e = key.related[0];
			doir.testing.addComponent!Amount(*engine.store, e).value = 9;
			assert(recordProduced(engine, doir.components.query.Produced([e], ecrs.registry.componentId!Amount(), &strip, &hash), false));
			assert(recordProduced(engine, doir.components.query.Produced([e], ecrs.registry.componentId!Amount(), &strip, &hash), false));
			return true;
		}
	}

	// Reads the Amount Copy produced, through Copy, so Copy's produced contents decide whether it re-runs.
	private struct CopiedAmount {
		alias Key = ecrs.relation.Relation!1;
		alias Value = int;
		static int compute(ref QueryEngine engine, Key key) @nogc nothrow {
			immutable knob = key.related[0];
			++runs;
			return ecrs.context.getComponent!Amount(*engine.store, query!Copy(engine, Copy.Key([knob])).related[0]).value;
		}
	}

	private __gshared int live;

	// A value owning a dynarray, counting how many are alive.
	private struct Owned {
		int* items;
		void finalize() @nogc nothrow {
			if (items is null) return;
			--live;
			fp.dynarray.free(items);
		}
	}

	// Lists the Amount of input `knob` in a value that owns memory.
	private struct Listing {
		alias Key = ecrs.relation.Relation!1;
		alias Value = Owned;
		static Owned compute(ref QueryEngine engine, Key key) @nogc nothrow {
			immutable knob = key.related[0];
			assert(read(engine, knob));
			Owned value;
			immutable pushed = fp.dynarray.pushBack(value.items, ecrs.context.getComponent!Amount(*engine.store, knob).value);
			assert(pushed);
			++live;
			return value;
		}
		static bool valueEqual(ref const Owned a, ref const Owned b) @nogc nothrow {
			return fp.dynarray.slice(a.items) == fp.dynarray.slice(b.items);
		}
	}

	// An alias chain: Resolve(n) follows n - 1 down to 0, and Resolve(-n) loops back to itself through n steps.
	private struct Resolve {
		alias Key = long;
		alias Value = long;
		static long compute(ref QueryEngine engine, long key) @nogc nothrow {
			if (key == 0) return 0;
			if (key == -1) {
				auto back = query!Resolve(engine, -3);
				return back is null ? -1 : *back;
			}
			auto next = query!Resolve(engine, key > 0 ? key - 1 : key + 1);
			return next is null ? -1 : *next;
		}
	}

	// Unsigned(k) needs its own answer: a cycle, reported with an unsigned key.
	private struct Unsigned {
		alias Key = uint;
		alias Value = bool;
		static bool compute(ref QueryEngine engine, uint key) @nogc nothrow { return query!Unsigned(engine, key) is null; }
	}

	// Creates an entity, and reports a refusal of a list of its own through `fail`.
	private struct Spawn {
		alias Key = int;
		alias Value = ecrs.relation.Relation!1;
		static Value compute(ref QueryEngine engine, int key) @nogc nothrow {
			immutable e = createEntity(engine, invalidEntity);
			int* list = null;
			scope(exit) fp.dynarray.free(list);
			if (e != invalidEntity && !fp.dynarray.pushBack(list, key)) fail(engine);
			return Value([e]);
		}
	}

	// Depth(n), demanded from outside any query at n = 0, runs in frame n and nests down to Depth(3).
	private struct Depth {
		alias Key = size_t;
		alias Value = size_t;
		static size_t compute(ref QueryEngine engine, size_t key) @nogc nothrow {
			assert(ecrs.context.getComponent!(doir.components.query.Running)(*engine.store, currentQuery(engine)).frame == key);
			return key == 3 ? key : *query!Depth(engine, key + 1);
		}
	}

	// Spin(n) demands itself: a cycle whose report names an unsigned key.
	private struct Spin {
		alias Key = uint;
		alias Value = uint;
		static uint compute(ref QueryEngine engine, uint key) @nogc nothrow {
			auto self = query!Spin(engine, key);
			return self is null ? 0 : *self;
		}
	}

	// A labelled graph: node entities carry a label and an ordered child list.
	private struct Node {
		mixin ecrs.relation.Relates!2; // the children
		int label;
		size_t count;
	}

	private struct Pair {
		mixin ecrs.relation.Relates!("a", "b");
	}

	private __gshared int equalRuns;

	// Structural equivalence over the graph, assuming a pair under comparison equal (S-Struct).
	private struct Equal {
		alias Key = Pair;
		alias Value = bool;
		static bool cycleFallback(ref QueryEngine engine, Pair key) @nogc nothrow { return true; }
		static bool compute(ref QueryEngine engine, Pair key) @nogc nothrow {
			++equalRuns;
			if (!read(engine, key.a) || !read(engine, key.b)) return false;
			auto x = ecrs.context.getComponent!Node(*engine.store, key.a), y = ecrs.context.getComponent!Node(*engine.store, key.b);
			if (x.label != y.label || x.count != y.count) return false;
			foreach (i; 0 .. x.count) {
				auto same = query!Equal(engine, Pair([x.related[i], y.related[i]]));
				if (same is null || !*same) return false;
			}
			return true;
		}
	}

	private shared int sharedRuns;

	// What every `Fan` needs: run once however many workers demand it at once, and warning once.
	private struct Shared {
		alias Key = int;
		alias Value = int;
		static int compute(ref QueryEngine engine, int key) @nogc nothrow {
			static import core.atomic;
			core.atomic.atomicOp!"+="(sharedRuns, 1);
			if (!report(engine, invalidEntity, diagnose.Kind.warning, "shared", "share less")) return 0;
			return 100;
		}
	}

	// Fan(k) is Shared(0) plus k, warning when k is a multiple of 3, so reports from many demands have an order to keep.
	private struct Fan {
		alias Key = int;
		alias Value = int;
		static int compute(ref QueryEngine engine, int key) @nogc nothrow {
			auto base = query!Shared(engine, 0);
			if (base is null) return 0;
			if (key % 3 == 0) {
				char[16] text;
				immutable n = core.stdc.stdio.snprintf(text.ptr, text.length, "fan %d", key);
				if (!report(engine, invalidEntity, diagnose.Kind.warning, text[0 .. n], "fan less")) return 0;
			}
			return *base + key;
		}
	}

	// Ring(k) needs Ring(k + 1 mod 4): demanded together, workers each start on a different part of one cycle.
	private struct Ring {
		alias Key = int;
		alias Value = int;
		static int compute(ref QueryEngine engine, int key) @nogc nothrow {
			auto next = query!Ring(engine, (key + 1) % 4);
			return next is null ? key : *next;
		}
	}

	// The inputs `Wide` reads, `wideReads` to a key, so a batch of them records more reverse edges than one thread applies alone.
	private __gshared EntityId* wideInputs;
	private enum size_t wideReads = 80;
	private shared int wideRuns;

	// Wide(k) sums the Amount of its own `wideReads` inputs.
	private struct Wide {
		alias Key = int;
		alias Value = int;
		static int compute(ref QueryEngine engine, int key) @nogc nothrow {
			static import core.atomic;
			core.atomic.atomicOp!"+="(wideRuns, 1);
			int sum = 0;
			foreach (e; wideInputs[key * wideReads .. (key + 1) * wideReads]) {
				if (!read(engine, e)) return 0;
				sum += ecrs.context.getComponent!Amount(*engine.store, e).value;
			}
			return sum;
		}
	}

	// Claim(e) writes an Amount onto `e` it records as produced, which only the engine's thread may do.
	private struct Claim {
		alias Key = ecrs.relation.Relation!1;
		alias Value = bool;
		static bool compute(ref QueryEngine engine, Key key) @nogc nothrow {
			immutable e = key.related[0];
			if (!recordProduced(engine, doir.components.query.Produced([e], ecrs.registry.componentId!Amount(), &Stamp.strip, &Stamp.hash), true)) return false;
			doir.testing.addComponent!Amount(*engine.store, e).value = 9;
			return true;
		}
	}

	// Refuse(k) meets a refusal of its own when k is 5.
	private struct Refuse {
		alias Key = int;
		alias Value = int;
		static int compute(ref QueryEngine engine, int key) @nogc nothrow {
			if (key == 5) fail(engine);
			return key;
		}
	}

	// Chain(k) needs Chain(k + 1) up to 63, each spinning a while, so workers starting along it wait on one another.
	private struct Chain {
		alias Key = int;
		alias Value = int;
		static int compute(ref QueryEngine engine, int key) @nogc nothrow {
			static import core.atomic;
			shared int spin;
			foreach (i; 0 .. 2000) core.atomic.atomicOp!"+="(spin, 1);
			if (key == 63) return 0;
			auto next = query!Chain(engine, key + 1);
			return next is null ? -1 : *next + 1;
		}
	}

	// The messages `manager` holds, joined, for comparing reports.
	private char* messagesOf(ref diagnose.Manager manager) {
		char* joined = null;
		foreach (ref d; fp.dynarray.slice(manager.diagnostics)) {
			assert(fp.string.concatenate(joined, fp.string.slice(d.message)) !is null);
			assert(fp.string.concatenate(joined, "\n") !is null);
		}
		return joined;
	}
}

unittest { // re-validation, early cutoff and replayed diagnostics
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	diagnose.Manager manager;
	scope(exit) diagnose.free(manager);
	auto engine = create(store);
	scope(exit) free(engine);
	engine.diagnostics = &manager;

	immutable e = doir.testing.addEntity(store);
	doir.testing.addComponent!Amount(store, e).value = 3;
	assert(markChanged(engine, e));

	// Sign reads IsPositive, which reads Input, which reads e.
	runs = 0;
	assert(*query!Sign(engine, Sign.Key([e])) == 1);
	assert(runs == 3);
	assert(*query!Sign(engine, Sign.Key([e])) == 1);
	assert(runs == 3);

	// Nothing changed: verification re-runs nothing.
	beginRevision(engine);
	assert(*query!Sign(engine, Sign.Key([e])) == 1);
	assert(runs == 3);

	// The input is rewritten unchanged: Input re-runs, and its equal value cuts IsPositive and Sign off.
	beginRevision(engine);
	ecrs.context.getComponent!Amount(store, e).value = 3;
	assert(markChanged(engine, e));
	assert(*query!Sign(engine, Sign.Key([e])) == 1);
	assert(runs == 4);

	// A new positive value: Input and IsPositive re-run, and IsPositive's equal value cuts Sign off.
	beginRevision(engine);
	ecrs.context.getComponent!Amount(store, e).value = 5;
	assert(markChanged(engine, e));
	assert(*query!Sign(engine, Sign.Key([e])) == 1);
	assert(runs == 6);
	assert(diagnose.count(manager) == 0);

	// The answer flips: all three re-run, and IsPositive reports a warning once per revision.
	beginRevision(engine);
	ecrs.context.getComponent!Amount(store, e).value = -1;
	assert(markChanged(engine, e));
	assert(*query!Sign(engine, Sign.Key([e])) == -1);
	assert(runs == 9);
	assert(*query!Sign(engine, Sign.Key([e])) == -1);
	assert(diagnose.count(manager) == 1);

	// A reused memo reports the same diagnostic as the run that produced it.
	beginRevision(engine);
	assert(*query!Sign(engine, Sign.Key([e])) == -1);
	assert(runs == 9);
	assert(diagnose.count(manager) == 2);
	assert(fp.string.slice(manager.diagnostics[1].message) == "negative");
	assert(manager.diagnostics[1].kind == diagnose.Kind.warning);
	assert(fp.string.slice(manager.diagnostics[1].additionalNote) == "make it positive"); // e has no location, so the hint is the note

	// Outside any query a diagnostic goes straight out, with no memo to replay it.
	assert(report(engine, e, diagnose.Kind.note, "direct", "no fix needed"));
	assert(diagnose.count(manager) == 3 && fp.string.slice(manager.diagnostics[2].message) == "direct");
	assert(fp.string.slice(manager.diagnostics[2].additionalNote) == "no fix needed");

	// A change is pushed along reverse edges: one to g reaches nothing Sign(e) reads, so Sign(e) is reused without visiting its dependencies.
	beginRevision(engine);
	ecrs.context.getComponent!Amount(store, e).value = 2;
	assert(markChanged(engine, e));
	immutable g = doir.testing.addEntity(store);
	doir.testing.addComponent!Amount(store, g).value = 1;
	assert(markChanged(engine, g));
	assert(*query!Sign(engine, Sign.Key([e])) == 1 && *query!Sign(engine, Sign.Key([g])) == 1);
	immutable input = find!Input(engine, Input.Key([e]));
	immutable verified = ecrs.context.getComponent!(doir.components.query.VerifiedAt)(store, input).revision;
	beginRevision(engine);
	ecrs.context.getComponent!Amount(store, g).value = 7;
	assert(markChanged(engine, g));
	// Settling re-runs Input(g), which IsPositive(g) reads, and IsPositive(g), whose equal answer stops the change before Sign(g).
	immutable before = runs;
	assert(settle(engine) && runs == before + 2);
	immutable settled = runs;
	assert(upToDate!Sign(engine, Sign.Key([e])) && upToDate!Sign(engine, Sign.Key([g])));
	assert(*query!Sign(engine, Sign.Key([e])) == 1 && *query!Sign(engine, Sign.Key([g])) == 1 && runs == settled);
	assert(ecrs.context.getComponent!(doir.components.query.VerifiedAt)(store, input).revision == verified);

	// Removing an entity marks what read it, since its id may be handed out again.
	beginRevision(engine);
	invalidate(engine, g);
	assert(ecrs.context.getComponent!(doir.components.query.VerifiedAt)(store, find!Input(engine, Input.Key([g]))).stale);
	assert(*query!Sign(engine, Sign.Key([g])) == 1 && runs == settled); // checked again, nothing it read having changed

	// A query that starts or stops reporting without its value changing still reaches its readers, which report what it does.
	immutable h = doir.testing.addEntity(store);
	doir.testing.addComponent!Amount(store, h).value = 2;
	assert(markChanged(engine, h));
	immutable quiet = diagnose.count(manager);
	assert(*query!Wrap(engine, Wrap.Key([h])) == 0 && diagnose.count(manager) == quiet);
	beginRevision(engine);
	ecrs.context.getComponent!Amount(store, h).value = 3;
	assert(markChanged(engine, h));
	assert(*query!Wrap(engine, Wrap.Key([h])) == 0 && diagnose.count(manager) == quiet + 1);
	assert(fp.string.slice(manager.diagnostics[quiet].message) == "odd");
	beginRevision(engine);
	ecrs.context.getComponent!Amount(store, h).value = 4;
	assert(markChanged(engine, h));
	assert(*query!Wrap(engine, Wrap.Key([h])) == 0 && diagnose.count(manager) == quiet + 1);
}

unittest { // stable created ids, provenance, ownership and eviction
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	auto engine = create(store);
	scope(exit) free(engine);

	runs = 0;
	immutable made = query!Twin(engine, 7).related[0];
	assert(ecrs.context.getComponent!Amount(store, made).value == 7);
	assert(ecrs.context.getComponent!(doir.components.query.Provenance)(store, made).origin == invalidEntity);

	// Evicting removes what the query produced and created, and the next demand re-runs it.
	evict!Twin(engine, 7);
	assert(!ecrs.context.hasComponent!Amount(store, made));
	immutable remade = query!Twin(engine, 7).related[0];
	assert(runs == 2);
	assert(ecrs.context.getComponent!Amount(store, remade).value == 7);

	// A re-run hands back the same created entity, so the value compares equal.
	beginRevision(engine);
	int key = 7;
	immutable q = find!Twin(engine, key);
	assert(ecrs.context.addComponent!(doir.components.query.InCycle)(store, q) !is null); // re-run, not re-validated
	immutable before = changedAt(engine, q);
	assert(query!Twin(engine, 7).related[0] == remade);
	assert(changedAt(engine, q) == before);

	// A re-run that writes the same contents is cut off; one with the same value but different contents is a change.
	immutable knob = doir.testing.addEntity(store);
	doir.testing.addComponent!Amount(store, knob).value = 1;
	assert(markChanged(engine, knob));
	runs = 0;
	assert(*query!CopiedAmount(engine, CopiedAmount.Key([knob])) == 1);
	immutable copy = query!Copy(engine, Copy.Key([knob])).related[0];
	assert(ecrs.context.getComponent!(doir.components.query.Provenance)(store, copy).origin == knob);
	beginRevision(engine);
	assert(markChanged(engine, knob));
	assert(*query!CopiedAmount(engine, CopiedAmount.Key([knob])) == 1);
	assert(runs == 1);
	beginRevision(engine);
	ecrs.context.getComponent!Amount(store, knob).value = 2;
	assert(markChanged(engine, knob));
	assert(*query!CopiedAmount(engine, CopiedAmount.Key([knob])) == 2);
	assert(query!Copy(engine, Copy.Key([knob])).related[0] == copy);
	assert(runs == 2);

	// A component recorded twice in one run is owned once, and stripped when the query is evicted.
	immutable stamped = doir.testing.addEntity(store);
	assert(*query!Stamp(engine, Stamp.Key([stamped])));
	assert(ecrs.context.getComponent!Amount(store, stamped).value == 9);
	immutable stamp = find!Stamp(engine, Stamp.Key([stamped]));
	assert(fp.dynarray.length(ecrs.context.getComponent!(doir.components.query.Produces)(store, stamp).items) == 1);
	evict!Stamp(engine, Stamp.Key([stamped]));
	assert(!ecrs.context.hasComponent!Amount(store, stamped));

	// A value owning memory is freed when a re-run replaces it, when a re-run's equal value is dropped, and on eviction.
	live = 0;
	immutable listed = doir.testing.addEntity(store);
	doir.testing.addComponent!Amount(store, listed).value = 3;
	assert(fp.dynarray.slice(query!Listing(engine, Listing.Key([listed])).items) == [3]);
	beginRevision(engine);
	assert(markChanged(engine, listed));
	assert(fp.dynarray.slice(query!Listing(engine, Listing.Key([listed])).items) == [3]);
	assert(live == 1);
	beginRevision(engine);
	ecrs.context.getComponent!Amount(store, listed).value = 4;
	assert(markChanged(engine, listed));
	assert(fp.dynarray.slice(query!Listing(engine, Listing.Key([listed])).items) == [4]);
	assert(live == 1);
	evict!Listing(engine, Listing.Key([listed]));
	assert(live == 0);
}

unittest { // a renumbering rewrites query entities, their keys and their dependencies
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	auto engine = create(store);
	scope(exit) free(engine);

	immutable spare = doir.testing.addEntity(store);
	immutable e = doir.testing.addEntity(store);
	doir.testing.addComponent!Amount(store, e).value = 1;
	assert(markChanged(engine, e));
	runs = 0;
	assert(*query!Sign(engine, Sign.Key([e])) == 1);
	assert(runs == 3);
	assert(ecrs.context.removeEntity(store, spare));
	assert(compact(engine));

	// Every answer is unchanged up to the permutation, and found by its rewritten key without re-running.
	immutable moved = cast(EntityId)(e - 1);
	assert(ecrs.context.getComponent!Amount(store, moved).value == 1);
	assert(*query!Sign(engine, Sign.Key([moved])) == 1);
	assert(*query!IsPositive(engine, IsPositive.Key([moved])));
	assert(runs == 3);
	beginRevision(engine);
	assert(*query!Sign(engine, Sign.Key([moved])) == 1);
	assert(runs == 3);

	// A change to the moved input still reaches its readers.
	beginRevision(engine);
	ecrs.context.getComponent!Amount(store, moved).value = -2;
	assert(markChanged(engine, moved));
	assert(*query!Sign(engine, Sign.Key([moved])) == -1);
	assert(runs == 6);

	// An explicit order rewrites a value holding an entity id, and its key still finds it without a re-run.
	runs = 0;
	immutable made = query!Twin(engine, 5).related[0];
	immutable n = fp.dynarray.length(store.indexTable);
	size_t* order = null;
	scope(exit) fp.dynarray.free(order);
	foreach (i; 0 .. n) assert(fp.dynarray.pushBack(order, i == 0 ? 0 : n - i));
	assert(renumber(engine, fp.dynarray.slice(order)));
	immutable renamed = cast(EntityId) (n - made);
	assert(query!Twin(engine, 5).related[0] == renamed && runs == 1);
	assert(ecrs.context.getComponent!Amount(store, renamed).value == 5);

	// A query entity removed before a compaction leaves a dead index entry, which the next demand at its key reuses.
	assert(*query!Resolve(engine, 0) == 0);
	assert(ecrs.context.removeEntity(store, find!Resolve(engine, 0)));
	assert(compact(engine));
	assert(find!Resolve(engine, 0) == invalidEntity);
	assert(*query!Resolve(engine, 0) == 0);
	assert(find!Resolve(engine, 0) != invalidEntity);
}

unittest { // cycles: reported chains, deep chains and the depth limit
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	diagnose.Manager manager;
	scope(exit) diagnose.free(manager);
	auto engine = create(store);
	scope(exit) free(engine);
	engine.diagnostics = &manager;

	// Resolve(-1) -> Resolve(-3) -> Resolve(-2) -> Resolve(-1) is a cycle, reported with its chain.
	assert(*query!Resolve(engine, -1) == -1);
	assert(diagnose.count(manager) == 1);
	assert(fp.string.slice(manager.diagnostics[0].message)
		== "Q-Cycle: a query needs its own answer: Resolve(-1) -> Resolve(-3) -> Resolve(-2) -> Resolve(-1)");
	assert(fp.string.slice(manager.diagnostics[0].additionalNote) == cycleHint);
	assert(ecrs.context.hasComponent!(doir.components.query.InCycle)(store, find!Resolve(engine, -1)));

	// The cycle is reported again by its memo in a later revision, which re-runs rather than re-validates.
	beginRevision(engine);
	assert(*query!Resolve(engine, -1) == -1);
	assert(diagnose.count(manager) == 2);
	assert(fp.string.slice(manager.diagnostics[1].additionalNote) == cycleHint);

	// An unsigned key is reported as one.
	assert(*query!Spin(engine, 7) == 0);
	assert(fp.string.slice(manager.diagnostics[2].message) == "Q-Cycle: a query needs its own answer: Spin(7) -> Spin(7)");
	assert(fp.string.slice(manager.diagnostics[2].additionalNote) == cycleHint);

	// Each running query is marked with its frame, and only while it runs.
	assert(*query!Depth(engine, 0) == 3);
	foreach (k; 0 .. 4) assert(ecrs.context.getComponent!(doir.components.query.Running)(store, find!Depth(engine, k)).owner == 0);

	// A chain within the depth limit resolves; one past it is reported instead of overflowing the stack.
	diagnose.clear(manager);
	assert(*query!Resolve(engine, defaultDepthLimit - 8) == 0);
	assert(diagnose.count(manager) == 0);
	assert(ecrs.context.getComponent!(doir.components.query.Running)(store, find!Resolve(engine, defaultDepthLimit - 8)).owner == 0);
	engine.depthLimit = 64;
	assert(*query!Resolve(engine, 2 * defaultDepthLimit) == -1);
	assert(diagnose.count(manager) == 1);
	enum prefix = "Q-Cycle: queries nest deeper than the limit of 64 at Resolve(";
	assert(fp.string.slice(manager.diagnostics[0].message)[0 .. prefix.length] == prefix);
	assert(fp.string.slice(manager.diagnostics[0].additionalNote) == depthHint);

	// An unsigned key is described as one.
	diagnose.clear(manager);
	assert(*query!Unsigned(engine, 3));
	assert(fp.string.slice(manager.diagnostics[0].message) == "Q-Cycle: a query needs its own answer: Unsigned(3) -> Unsigned(3)");
	assert(fp.string.slice(manager.diagnostics[0].additionalNote) == cycleHint);
}

unittest { // cycle fallbacks: coinductive equality, and reset of provisional answers
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	auto engine = create(store);
	scope(exit) free(engine);

	EntityId node(int label) {
		immutable e = doir.testing.addEntity(store);
		doir.testing.addComponent!Node(store, e).label = label;
		return e;
	}
	void link(EntityId e, EntityId a, EntityId b = invalidEntity) {
		auto n = &ecrs.context.getComponent!Node(store, e);
		n.related[0] = a;
		n.related[1] = b;
		n.count = b == invalidEntity ? 1 : 2;
	}

	// x -> x and y -> z -> y, all labelled 1: equal, as a recursive type is to its unrolling (TF-Self).
	immutable x = node(1), y = node(1), z = node(1);
	link(x, x);
	link(y, z);
	link(z, y);
	assert(*query!Equal(engine, Pair([x, y])));
	assert(!ecrs.context.hasComponent!(doir.components.query.ProvisionalOn)(store, find!Equal(engine, Pair([x, z]))));

	// A = [A, X], B = [B', Y], B' = [B, X], X != Y. Equal(A, B') answers true resting on Equal(A, B), which fails.
	immutable leafX = node(2), leafY = node(3);
	immutable a = node(1), b = node(1), b2 = node(1);
	link(leafX, leafX);
	link(leafY, leafY);
	link(a, a, leafX);
	link(b, b2, leafY);
	link(b2, b, leafX);
	assert(!*query!Equal(engine, Pair([a, b])));
	immutable provisional = find!Equal(engine, Pair([a, b2]));
	assert(ecrs.context.getComponent!(doir.components.query.VerifiedAt)(store, provisional).revision == 0); // reset, keeping no value
	equalRuns = 0;
	assert(!*query!Equal(engine, Pair([a, b2])));
	assert(equalRuns == 1);

	// Nested fallbacks: Equal(E, F) rests on Equal(C, D), which rests on Equal(A', B'), so a held fallback hands E, F down to it.
	immutable a3 = node(1), b3 = node(1), c = node(1), d = node(1), e = node(1), f = node(1);
	link(c, e, a3);
	link(d, f, b3);
	link(e, c);
	link(f, d);
	link(a3, c);
	link(b3, d);
	assert(*query!Equal(engine, Pair([a3, b3])));
	assert(*query!Equal(engine, Pair([c, d])) && *query!Equal(engine, Pair([e, f])));
	assert(!ecrs.context.hasComponent!(doir.components.query.ProvisionalOn)(store, find!Equal(engine, Pair([c, d]))));
	assert(!ecrs.context.hasComponent!(doir.components.query.ProvisionalOn)(store, find!Equal(engine, Pair([e, f]))));
}

unittest { // a refused allocation fails every running query, which memoizes nothing and runs again on its next demand
	// Each step runs with the allocator granting n allocations, for every n until one lets every step finish.
	bool finished = false;
	for (size_t n = 0; !finished; ++n) {
		assert(n < 1000);
		auto store = ecrs.context.create();
		scope(exit) ecrs.context.free(store);
		diagnose.Manager manager;
		scope(exit) diagnose.free(manager);
		auto engine = create(store);
		scope(exit) free(engine);
		engine.diagnostics = &manager;
		immutable e = doir.testing.addEntity(store);
		doir.testing.addComponent!Amount(store, e).value = -2;
		assert(markChanged(engine, e));
		bool refused = false;

		// Runs `demand`, which answers true, or false only on a refused allocation.
		bool rationed(scope bool delegate() @nogc nothrow demand) {
			auto previous = fp.testing.beginRationedAllocator(n);
			immutable answered = demand();
			fp.testing.endRationedAllocator(previous);
			assert(answered || engine.refused);
			refused |= engine.refused;
			engine.refused = false;
			return answered;
		}

		// Nested fallbacks: moving E, F down to the lower head can be refused too. It runs first, so every budget meets the same allocations.
		immutable a3 = doir.testing.addEntity(store), b3 = doir.testing.addEntity(store), c3 = doir.testing.addEntity(store);
		immutable d3 = doir.testing.addEntity(store), e3 = doir.testing.addEntity(store), f3 = doir.testing.addEntity(store);
		doir.testing.addComponent!Node(store, c3) = Node([e3, a3], 1, 2);
		doir.testing.addComponent!Node(store, d3) = Node([f3, b3], 1, 2);
		doir.testing.addComponent!Node(store, e3) = Node([c3, invalidEntity], 1, 1);
		doir.testing.addComponent!Node(store, f3) = Node([d3, invalidEntity], 1, 1);
		doir.testing.addComponent!Node(store, a3) = Node([c3, invalidEntity], 1, 1);
		doir.testing.addComponent!Node(store, b3) = Node([d3, invalidEntity], 1, 1);
		cast(void) rationed(() => query!Equal(engine, Pair([a3, b3])) !is null);
		assert(*query!Equal(engine, Pair([a3, b3])) && *query!Equal(engine, Pair([e3, f3])));

		// A null answer means the run failed, and a value means it is right; either way the next demand answers right.
		void step(int expected) {
			auto previous = fp.testing.beginRationedAllocator(n);
			auto sign = query!Sign(engine, Sign.Key([e]));
			immutable answer = sign is null ? 0 : *sign;
			fp.testing.endRationedAllocator(previous);
			assert(sign is null ? engine.refused : answer == expected);
			refused |= engine.refused;
			engine.refused = false;
			assert(*query!Sign(engine, Sign.Key([e])) == expected);
		}
		step(-1);

		// Re-validation and re-execution after an input change.
		beginRevision(engine);
		ecrs.context.getComponent!Amount(store, e).value = 5;
		assert(markChanged(engine, e));
		step(1);

		// Cycle fallbacks: a failed head discards the provisional answers resting on it.
		immutable leafX = doir.testing.addEntity(store), leafY = doir.testing.addEntity(store);
		immutable a = doir.testing.addEntity(store), b = doir.testing.addEntity(store), b2 = doir.testing.addEntity(store);
		doir.testing.addComponent!Node(store, leafX) = Node([leafX, invalidEntity], 2, 1);
		doir.testing.addComponent!Node(store, leafY) = Node([leafY, invalidEntity], 3, 1);
		doir.testing.addComponent!Node(store, a) = Node([a, leafX], 1, 2);
		doir.testing.addComponent!Node(store, b) = Node([b2, leafY], 1, 2);
		doir.testing.addComponent!Node(store, b2) = Node([b, leafX], 1, 2);
		auto previous = fp.testing.beginRationedAllocator(n);
		auto same = query!Equal(engine, Pair([a, b]));
		immutable answer = same is null || *same;
		fp.testing.endRationedAllocator(previous);
		assert(same is null ? engine.refused : !answer);
		refused |= engine.refused;
		engine.refused = false;
		assert(!*query!Equal(engine, Pair([a, b])) && !*query!Equal(engine, Pair([a, b2])));

		// Created entities, a query's own refusals (`fail`), and the reports of cycles and of the depth limit.
		cast(void) rationed(() => query!Spawn(engine, 1) !is null);
		assert(query!Spawn(engine, 1).related[0] != invalidEntity);
		cast(void) rationed(() => query!Resolve(engine, -1) !is null);
		assert(*query!Resolve(engine, -1) == -1);
		cast(void) rationed(() => query!Unsigned(engine, 3) !is null);
		assert(*query!Unsigned(engine, 3));
		engine.depthLimit = 4;
		cast(void) rationed(() => query!Resolve(engine, 8) !is null);
		assert(*query!Resolve(engine, 8) == -1);
		engine.depthLimit = defaultDepthLimit;

		// After a renumbering the index is stale; a lookup that cannot rehash it searches it instead, allocating nothing.
		immutable spare = doir.testing.addEntity(store);
		assert(ecrs.context.swapEntities(store, e, spare));
		previous = fp.testing.beginRationedAllocator(0);
		auto moved = query!Sign(engine, Sign.Key([spare]));
		fp.testing.endRationedAllocator(previous);
		assert(moved !is null && *moved == 1 && !engine.refused);
		finished = !refused;
	}
}

unittest { // a batch on workers: a shared query runs once, reports keep the serial order, and what workers may not do is handed back
	static import core.atomic;
	static import bc.threadpool;
	auto pool = bc.threadpool.create(4);
	assert(pool !is null);
	scope(exit) bc.threadpool.free(pool);
	int[64] keys;
	foreach (i, ref k; keys) k = cast(int) i;
	immutable int[4] ring = [0, 1, 2, 3];

	// The same demands on one thread, for the reports a batch must match.
	auto serialStore = ecrs.context.create();
	scope(exit) ecrs.context.free(serialStore);
	diagnose.Manager serialManager;
	scope(exit) diagnose.free(serialManager);
	auto serial = create(serialStore);
	scope(exit) free(serial);
	serial.diagnostics = &serialManager;
	foreach (k; keys) assert(query!Fan(serial, k) !is null);
	foreach (k; ring) cast(void) query!Ring(serial, k);
	auto expected = messagesOf(serialManager);
	scope(exit) fp.string.free(expected);

	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	diagnose.Manager manager;
	scope(exit) diagnose.free(manager);
	auto engine = create(store);
	scope(exit) free(engine);
	engine.diagnostics = &manager;
	engine.workers = pool;
	core.atomic.atomicStore(sharedRuns, 0);
	// Shared's query entity does not exist yet: the first round asks for it, and the second runs.
	assert(demandEach!Fan(engine, keys[]));
	assert(core.atomic.atomicLoad(sharedRuns) == 1);
	foreach (k; keys) assert(*query!Fan(engine, k) == 100 + k);
	// A cycle across workers is found by the waits it closes and settled on this thread, as it would be without workers (Q-Cycle).
	assert(demandEach!Ring(engine, ring[]));
	auto reported = messagesOf(manager);
	scope(exit) fp.string.free(reported);
	assert(fp.string.slice(reported) == fp.string.slice(expected));
	assert(diagnose.count(manager) == 1 + 22 + 1); // Shared, Fan of each multiple of 3, the cycle

	// Nothing changed: the workers re-validate, and the withheld reports come out in the same order.
	diagnose.clear(manager);
	beginRevision(engine);
	assert(demandEach!Fan(engine, keys[]) && core.atomic.atomicLoad(sharedRuns) == 1);
	assert(diagnose.count(manager) == 1 + 22);
	assert(fp.string.slice(manager.diagnostics[0].message) == "shared" && fp.string.slice(manager.diagnostics[1].message) == "fan 0");

	// Twin produces and creates, which only this thread may do, so every demand is handed back to it.
	assert(demandEach!Twin(engine, keys[0 .. 8]));
	foreach (k; keys[0 .. 8]) {
		assert(ecrs.context.getComponent!Amount(store, query!Twin(engine, k).related[0]).value == k);
		// A worker's attempt, handed back, left nothing behind: one entity, made on this thread.
		assert(fp.dynarray.length(ecrs.context.getComponent!(doir.components.query.Creates)(store, find!Twin(engine, k)).related) == 1);
	}

	// Claim produces without creating, which a worker hands back too.
	EntityId[4] claimed;
	foreach (ref e; claimed) e = doir.testing.addEntity(store);
	ecrs.relation.Relation!1[4] claims;
	foreach (i, e; claimed) claims[i] = Claim.Key([e]);
	assert(demandEach!Claim(engine, claims[]));
	foreach (e; claimed) assert(ecrs.context.getComponent!Amount(store, e).value == 9);

	// A refusal a query meets on a worker fails the batch, as it would on this thread.
	assert(!demandEach!Refuse(engine, keys[0 .. 8]) && engine.refused);
	engine.refused = false;
	assert(demandEach!Refuse(engine, keys[0 .. 5]) && *query!Refuse(engine, 4) == 4);

	// Workers starting along one chain wait on the workers ahead; past the depth limit a worker hands the demand back.
	foreach (limit; [defaultDepthLimit, 2]) {
		auto chainStore = ecrs.context.create();
		scope(exit) ecrs.context.free(chainStore);
		diagnose.Manager chainManager;
		scope(exit) diagnose.free(chainManager);
		auto chain = create(chainStore);
		scope(exit) free(chain);
		chain.workers = pool;
		chain.diagnostics = &chainManager;
		chain.depthLimit = limit;
		assert(demandEach!Chain(chain, keys[]));
		assert(limit != defaultDepthLimit || (*query!Chain(chain, 0) == 63 && diagnose.count(chainManager) == 0));
	}

	// Enough reverse edges are applied, and later built, shared among the workers; either way an edit re-runs only what read it.
	auto inputs = cast(EntityId*) null;
	scope(exit) fp.dynarray.free(inputs);
	foreach (deferred; [false, true]) {
		auto wideStore = ecrs.context.create();
		scope(exit) ecrs.context.free(wideStore);
		auto wide = create(wideStore);
		scope(exit) free(wide);
		wide.workers = pool;
		wide.edgesMissing = deferred;
		if (inputs !is null) fp.dynarray.clear(inputs);
		foreach (i; 0 .. keys.length * wideReads) {
			immutable e = doir.testing.addEntity(wideStore);
			doir.testing.addComponent!Amount(wideStore, e).value = 1;
			assert(fp.dynarray.pushBack(inputs, e));
		}
		wideInputs = inputs;
		assert(demandEach!Wide(wide, keys[]));
		assert(*query!Wide(wide, 3) == wideReads);

		// An unrelated change re-runs no Wide: with edges, none is reached; without, each finds its reads unchanged.
		immutable unrelated = doir.testing.addEntity(wideStore);
		beginRevision(wide);
		assert(markChanged(wide, unrelated));
		core.atomic.atomicStore(wideRuns, 0);
		assert(demandEach!Wide(wide, keys[]) && core.atomic.atomicLoad(wideRuns) == 0);

		// A second build replaces the edges the first made.
		foreach (build; 0 .. deferred ? 2 : 0) assert(buildDependents(wide) && !wide.edgesMissing);
		foreach (k; keys) assert(fp.dynarray.length(ecrs.context.getComponent!(doir.components.query.Dependents)(wideStore, inputs[k * wideReads]).related) == 1);
		beginRevision(wide);
		ecrs.context.getComponent!Amount(wideStore, inputs[5 * wideReads]).value = 2;
		assert(markChanged(wide, inputs[5 * wideReads]));
		assert(demandEach!Wide(wide, keys[]) && core.atomic.atomicLoad(wideRuns) == 1 && *query!Wide(wide, 5) == wideReads + 1);
	}

	// A refused allocation building the edges on workers leaves them missing; recording them on a worker, it drops them, to be built later.
	for (size_t budget = 0;; ++budget) {
		auto wideStore = ecrs.context.create();
		scope(exit) ecrs.context.free(wideStore);
		auto wide = create(wideStore);
		scope(exit) free(wide);
		wide.workers = pool;
		foreach (i; 0 .. keys.length * wideReads) {
			immutable e = doir.testing.addEntity(wideStore);
			doir.testing.addComponent!Amount(wideStore, e).value = 1;
			inputs[i] = e;
		}
		wideInputs = inputs;
		auto allocator = fp.testing.beginRationedAllocator(budget);
		immutable ran = demandEach!Wide(wide, keys[]);
		fp.testing.endRationedAllocator(allocator);
		if (!ran) wide.refused = false;
		immutable recorded = !wide.edgesMissing;
		wide.edgesMissing = true;
		assert(demandEach!Wide(wide, keys[]));
		allocator = fp.testing.beginRationedAllocator(budget);
		immutable built = buildDependents(wide);
		fp.testing.endRationedAllocator(allocator);
		assert(built != wide.edgesMissing);
		if (ran && recorded && built) break;
	}

	// A refused allocation anywhere in a batch fails it, or runs it on this thread; the next demand finishes it.
	for (size_t budget = 0;; ++budget) {
		auto rationedStore = ecrs.context.create();
		scope(exit) ecrs.context.free(rationedStore);
		auto rationed = create(rationedStore);
		scope(exit) free(rationed);
		rationed.workers = pool;
		auto allocator = fp.testing.beginRationedAllocator(budget);
		immutable ran = demandEach!Fan(rationed, keys[]);
		fp.testing.endRationedAllocator(allocator);
		if (!ran) assert(rationed.refused);
		rationed.refused = false;
		assert(demandEach!Fan(rationed, keys[]));
		foreach (k; keys) assert(*query!Fan(rationed, k) == 100 + k);
		if (ran) break;
	}
}
