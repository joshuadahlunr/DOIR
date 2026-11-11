/// The demand-driven query engine over the libECRS store (`roadmap.md` Phase 1).
/// A query instance is an entity: its key, value, dependencies, outputs, diagnostics and revisions are components, so a renumbering covers them like any other (`E-Remap`).
///
/// A query type `Q` is a struct declaring `Key`, `Value` and `static Value compute(ref QueryEngine, Key) @nogc nothrow`.
/// `Key` and `Value` are compared and hashed through `fp.lifecycle.equal` and `fp.lifecycle.contentHash`, so padding never decides, unless `Q` declares `static bool keyEqual(ref const Key, ref const Key)` with `static size_t keyHash(ref const Key)`, or `static bool valueEqual(ref const Value, ref const Value)`.
/// A `Key` or `Value` that holds entity ids does so by mixing in `ecrs.relation.Relates`, or by being an `ecrs.relation.Relation`, and the engine renumbers it through that (`E-Remap`).
/// `Q` may declare `static Value cycleFallback(ref QueryEngine, Key)`, the answer a demand for it gets while it is already running, and `static bool describeKey(ref const Key, ref char*)`, which appends the key to a cycle report and returns false if the string could not grow.
///
/// Validation follows Salsa's revisions: inputs carry `ChangedAt`, query entities carry `ChangedAt` and `Verification`, and a query re-runs only when a dependency changed after it was last verified.
/// A re-run whose value and produced components are unchanged keeps its old `ChangedAt` (early cutoff).
/// Unlike Salsa, a change is also pushed: each entity lists the queries that read it (`ReadBy`), `markChanged` marks them and their dependents stale, and a query no change reached is reused without visiting its dependencies, unless reusing it reports diagnostics, which come from walking them.
/// So re-validating a tree of queries after an edit costs in proportion to what the edit reached.
/// Dependencies are on whole entities; per (entity, component type) dependencies are the refinement if the extra re-verification shows up in profiles.
///
/// A component a query produces is read through that query: a reader demands the producer first, so it depends on it, and the producer's `ChangedAt` moves when what it produced changes.
///
/// A refused allocation fails every query running at the time (`fail`): each keeps no value and its demand returns null, so nothing built on a partial run is memoized, and the next demand runs it again.
/// `QueryEngine.refused` records that it happened.
/// The calls a query makes report it through their results as well, so a `compute` can stop early; one that hits a refused allocation of its own calls `fail`.
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
static import std.algorithm.sorting;

static import fp.dynarray;
static import fp.algorithms;
static import fp.hashtable;
static import fp.lifecycle;
static import fp.pointer;
static import fp.string;
version(unittest) static import fp.testing;

static import bc.gate;
static import bc.monitor;
static import bc.platform;
static import bc.spinlock.readerlock;
static import bc.spinlock;
static import bc.spinlock.striped;
static import bc.thread;
static import bc.threadpool;
static import diagnose;
static import ecrs.context;
static import ecrs.registry;
static import ecrs.relation;
static import ecrs.schedules;
static import ecrs.storage;

static import doir.engine.locations;
static import doir.engine.positions;
static import doir.strings;
static import doir.components.query;

public import ecrs.registry : EntityId, invalidEntity;

@nogc nothrow:


// --- types and layout --------------------------------------------------------

/// A point in the engine's history.
/// Revision 0 means "before anything was recorded".
alias Revision = ulong;

/// True if `Q` follows the query protocol `doir.query` documents.
/// A key's lifetime must be its bytes, since the index holds a bit copy of it.
enum isQuery(Q) = is(Q.Key) && is(Q.Value) && fp.lifecycle.isBitMoveable!(Q.Key) && __traits(compiles, (ref QueryEngine engine, Q.Key key) @nogc nothrow {
	Q.Value value = Q.compute(engine, key);
});

private bool keysEqual(Q)(ref const Q.Key a, ref const Q.Key b) {
	static if (__traits(hasMember, Q, "keyEqual")) return Q.keyEqual(a, b);
	else return fp.lifecycle.equal(a, b);
}

private size_t keyHash(Q)(ref const Q.Key key) @trusted {
	static if (__traits(hasMember, Q, "keyEqual")) {
		static assert(__traits(hasMember, Q, "keyHash"), Q.stringof ~ " declares keyEqual without keyHash");
		return Q.keyHash(key);
	} else return fp.lifecycle.contentHash(key);
}

private bool valuesEqual(Q)(ref const Q.Value a, ref const Q.Value b) {
	static if (__traits(hasMember, Q, "valueEqual")) return Q.valueEqual(a, b);
	else return fp.lifecycle.equal(a, b);
}

private struct TableEntry(Q) {
	mixin ecrs.relation.Relates!"query";
	Q.Key key;
}

// wrapper: the key hash an `fp.hashtable` config takes, over a slot's bytes
private size_t hashTableEntry(Q)(inout(ubyte)[] bytes) @trusted {
	assert(bytes.length == TableEntry!Q.sizeof, "doir.query: hashing a table entry of the wrong size");
	return keyHash!Q((cast(const(TableEntry!Q)*) bytes.ptr).key);
}

private bool equalTableEntry(Q)(inout(ubyte)[] a, inout(ubyte)[] b) @trusted {
	assert(a.length == TableEntry!Q.sizeof && b.length == TableEntry!Q.sizeof, "doir.query: comparing table entries of the wrong size");
	immutable same = keysEqual!Q((cast(const(TableEntry!Q)*) a.ptr).key, (cast(const(TableEntry!Q)*) b.ptr).key);
	assert(!same || hashTableEntry!Q(a) == hashTableEntry!Q(b), "doir.query: equal keys that hash differently");
	return same;
}

// What a `QueryTable` keeps behind its lock.
private struct TableState(Q) {
	TableEntry!Q* table = null;
	bool stale = false; // entries were rewritten in place and may sit under their old hashes
	ecrs.relation.Relation!(ecrs.relation.dynamicArity) spareQueries; // blank query entities, made in batches in the exclusive section, that adds take
	size_t lastSpareBatch = 0; // how many the last batch made
}

/// The index from key to query entity for query type `Q`, held as a component on an entity of its own.
/// A renumbering rewrites its keys and ids in place and leaves it to be rehashed on its next use (`E-Remap`).
/// Keys that a compaction maps to the same key keep one query entity; the others are no longer found.
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
	// Read-held by finds, write-held by inserts and rehashes, so threads add query entities without the exclusive section.
	private bc.monitor.Monitor!(TableState!Q, bc.spinlock.readerlock.ReaderLock) state;

	/// The `E-Remap` hook libECRS finds by name: rewrites every entry in place and marks the table stale, since a rewritten key hashes differently.
	/// A hook cannot fail, so the rehash, which allocates, waits for the next lookup.
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
		auto state = bc.monitor.write(self.state);
		auto table = state.value.table;
		foreach (stored; fp.hashtable.occupied(table)) {
			auto entry = table + (stored - table); // the iterator yields const pointers
			TableEntry!Q.remapEntities(*entry, remap); // its key's ids too
		}
		typeof(state.value.spareQueries).remapEntities(state.value.spareQueries, remap);
		state.value.stale = true;
		assert(state.value.table is null || fp.hashtable.valid(state.value.table), "doir.query: a query table that is not a table");
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
	void finalize() @nogc nothrow {
		auto s = bc.monitor.write(state);
		fp.hashtable.free(s.value.table);
		s.value.spareQueries.finalize();
		assert(s.value.table is null && s.value.spareQueries.related is null, "doir.query: a query table left holding memory");
	}
}

private enum size_t notRunning = size_t.max;

private struct Frame {
	EntityId query;
	size_t created;
	size_t head = notRunning; // the lowest frame whose cycle fallback this run's value rests on
	bool cycle; // this run took part in a cycle
	bool usedAsHead; // a demand above got this frame's cycle fallback
	EntityId* provisional; // finished queries resting on this frame's fallback
	bool refused; // an allocation was refused during this run, so it keeps no value
	bool reportsDeferredBelow; // a query this run demanded holds diagnostics a worker withheld
	EntityId* reporting; // the queries this run demanded that hold diagnostics, or have one below them that does, in order, for `ReportingReads`
}

/// The depth of nested demands and re-validations a new engine allows before reporting it (`IL-Chain`), well inside a default 8 MiB stack, and past the chain of answers that rule requires.
enum size_t defaultDepthLimit = 4096;

/// How many threads may demand on one engine over its life: each claims the queries it runs under an owner id of its own (`doir.components.query.Claim`).
enum size_t maxThreads = 256;

// How many locks share out the lists several threads write in place: an entity's `ReadBy`, and effect logs (`doir.engine.logs`).
private enum size_t lockedShards = 64;

/// The change log `markChanged` keeps, from which systems learn what entered their domains (`changesSince`).
///
/// Examples:
/// ---
/// ChangeLog log;
/// assert(log.entries is null && log.base == 0);
/// ---
package(doir) struct ChangeLog {
	EntityId* entries = null; /// The entities recorded, oldest first.
	size_t base; /// How many entries were dropped from the front over the engine's life.
}

/// The engine: the store it works on, the current revision, where diagnostics go, the order keys of lexical positions, and how the threads demanding on it share the store.
/// Any thread may demand at once (`query`); work outside demands, an input commit, a new revision or a renumbering, needs no thread demanding.
///
/// A thread demanding holds the engine's shared section, reading the store and writing only what it owns: the queries it has claimed, or lists behind an entity's lock.
/// A change to the store's structure, adding or removing an entity or a component, waits for an exclusive section, which every other thread leaves at its next safepoint: entering a demand, or waiting on another thread's query.
struct QueryEngine {
	ecrs.context.Context* store; /// The store, which must outlive the engine.
	Revision revision = 1; /// The current revision.
	size_t depthLimit = defaultDepthLimit; /// How deep demands may nest before `IL-Chain` is reported instead of overflowing the stack.
	diagnose.Manager* diagnostics = null; /// Where reported diagnostics go, each once per revision; null discards them, though queries still record theirs.
	/// Set when an allocation was refused: every query running at the time failed, keeping no value, or a diagnostic was lost on its way to `diagnostics`.
	/// The engine never clears it.
	/// Accessed atomically while threads demand.
	bool refused = false;
	doir.engine.positions.Positions positions; /// The order keys of every positioned effect and read (`C-Order`), made with `doir.positions.between`.
	/// Threads for work shared out, such as `demandEach`'s demands and skimming a large file's chunks; null does that work on the calling thread.
	/// The engine borrows it.
	bc.threadpool.ThreadPool* workers = null;
	doir.strings.Strings* strings = null; /// The interned names its queries read, as checks read declarations' names; the engine borrows it.
	/// Set while the reverse dependency edges (`ReadBy`) are not kept: when a refused allocation lost one, or from the start for an engine that defers them, as one that never sees an edit should.
	/// Meanwhile queries record none, and no query is reused without checking its dependencies, since a change may not reach it.
	/// `buildDependents` builds them all and clears it.
	bool edgesMissing = false;
	alias context = store; /// The store under the name `ecrs.schedules` finds an owner's context by, so schedules and systems run over the engine itself.
	package(doir) bc.monitor.Monitor!(EntityId*) staleQueue; /// Stale queries `revalidateStale` has yet to bring up to date, which demanding threads and an input commit's workers append to.
	/// The length of `pending`, read without its lock to see whether there is anything to settle.
	/// Accessed atomically.
	package(doir) size_t staleQueued;
	package(doir) bc.monitor.Monitor!ChangeLog changes; /// What `markChanged` recorded, which an input commit's workers append to.
	package(doir) bool settling = false; /// `revalidateStale` is running, so diagnostics are withheld for the demands that reach them.
	package(doir) size_t engineSerial; /// Tells a thread's state for this engine from one for an engine since freed at the same address; given on the first demand.
	/// Owner ids handed out, one per thread that demanded.
	/// Accessed atomically.
	package(doir) uint ownerIdsIssued;
	/// The thread each owner id went to, by the address of its thread-local state, so a thread back from other engines takes its own id again.
	/// Accessed atomically.
	package(doir) size_t[maxThreads] ownerThreads;
	/// The query each owner waits for, if any, which `waitForRunner` follows to find waits that loop.
	/// Accessed atomically.
	package(doir) EntityId[maxThreads + 1] waitingOn;
	/// Threads in a top-level demand.
	/// Accessed atomically.
	package(doir) size_t demandingThreads;
	package(doir) bc.gate.Gate gate; /// How the threads share the store: each demanding thread shares the gate, and a structural change takes it exclusively.
	/// A thread settles, so no other may start a demand.
	/// Accessed atomically.
	package(doir) bool demandsBlocked;
	package(doir) bc.spinlock.SpinLock diagnosticsLock; /// Guards `diagnostics`.
	/// Guard lists that several demanding threads write in place on an entity, such as its `ReadBy` or an effect log, `bc.spinlock.striped.stripeFor` picking one by id.
	/// Hold one briefly, demanding nothing and taking no exclusive section meanwhile.
	package(doir) bc.spinlock.striped.Striped!(bc.spinlock.SpinLock, lockedShards) entityLocks;
}

private __gshared size_t serials; // engines given a serial

// A thread's part in demands on one engine: its owner id, its stack of running queries, and how it holds the engine.
private struct ThreadState {
	size_t serial; // the engine's, 0 for none
	uint self;
	Frame* stack;
	size_t depth;
	bool holding; // in the shared section
	bool abandoned; // its demand was given up to break waits that loop across threads (Q-Cycle)
}

// The owner ids a thread took on recent engines, so moving between a few engines takes no new ones.
private struct OwnerId {
	size_t serial;
	uint self;
}

private ThreadState local; // module scope, so one per thread
private OwnerId[4] ownerIds;
private size_t nextOwnerId; // the slot of `ownerIds` the next new id replaces
private bool deferringReports; // this thread's diagnostics wait for an ordered flush (`demandEach`)
private size_t exclusiveDepth; // nested holds of an exclusive section on this thread
private QueryEngine* exclusiveEngine; // the engine they hold, so a hold of another's is caught rather than skipped

// Makes the calling thread's state `engine`'s, taking an owner id on its first demand there.
private void attach(ref QueryEngine engine) {
	static assert(invalidEntity == 0, "doir.query: `waitingOn` starts out waiting for nothing");
	if (core.atomic.atomicLoad(bc.platform.asShared(engine.engineSerial)) == 0)
		cast(void) core.atomic.cas(&bc.platform.asShared(engine.engineSerial), size_t(0), core.atomic.atomicOp!"+="(bc.platform.asShared(serials), 1));
	immutable serial = core.atomic.atomicLoad(bc.platform.asShared(engine.engineSerial));
	if (local.serial == serial) return;
	assert(fp.dynarray.length(local.stack) == 0, "doir.query: a demand on one engine inside a query of another");
	uint self = 0;
	foreach (id; ownerIds) if (id.serial == serial) self = id.self;
	immutable cached = self != 0;
	immutable thread = cast(size_t) &local;
	if (self == 0) {
		// Only the thread itself writes its slot, so one it took before is found whatever other threads add meanwhile.
		immutable issued = core.atomic.atomicLoad(bc.platform.asShared(engine.ownerIdsIssued));
		foreach (i; 0 .. issued < maxThreads ? issued : maxThreads)
			if (core.atomic.atomicLoad(bc.platform.asShared(engine.ownerThreads[i])) == thread) self = cast(uint) (i + 1);
	}
	if (self == 0) {
		self = core.atomic.atomicOp!"+="(bc.platform.asShared(engine.ownerIdsIssued), 1u);
		// Checked in every build: past the bound, the id would index beyond `waitingOn`.
		if (self > maxThreads) assert(0, "doir.query: more threads demanded on one engine than maxThreads");
		core.atomic.atomicStore(bc.platform.asShared(engine.ownerThreads[self - 1]), thread);
	}
	if (!cached) {
		ownerIds[nextOwnerId] = OwnerId(serial, self);
		nextOwnerId = (nextOwnerId + 1) % ownerIds.length;
	}
	local = ThreadState(serial, self);
	assert(self >= 1 && self <= maxThreads, "doir.query: an owner id outside 1 .. maxThreads");
	assert(attached(engine), "doir.query: attached to an engine without matching its serial");
}

private bool attached(ref QueryEngine engine) {
	assert(local.serial == 0 || local.self >= 1, "doir.query: a thread attached with no owner id");
	return local.serial != 0 && local.serial == core.atomic.atomicLoad(bc.platform.asShared(engine.engineSerial));
}


// --- sharing the store between threads ---------------------------------------

// Whether the calling thread shares `engine`'s gate: it is attached to `engine`, not only to an engine since freed or another one, and demanding.
private bool sharing(ref QueryEngine engine) {
	assert(!local.holding || local.serial != 0, "doir.query: holding the gate of no engine");
	return attached(engine) && local.holding;
}

// A point where the calling thread, demanding, lets a thread waiting for the exclusive section have it, pausing until it is done.
private void safepoint(ref QueryEngine engine) {
	if (sharing(engine)) bc.gate.yieldToExclusive(engine.gate);
}

/// Takes the exclusive section of `engine`: every other demanding thread pauses at its next safepoint, so the caller may change the store's structure, adding or removing entities and components, until `endExclusive`.
/// Holds nest.
/// Hold it briefly, demanding nothing and taking no entity's lock meanwhile; the engine takes it for its own structural changes, and a query's own code needs it only for writes `produce` and `createEntity` do not cover.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = create(store);
/// scope(exit) free(engine);
/// beginExclusive(engine);
/// immutable e = ecrs.context.addEntity(store);
/// endExclusive(engine);
/// assert(e != invalidEntity);
/// ---
package(doir) void beginExclusive(ref QueryEngine engine) {
	assert(exclusiveDepth == 0 || exclusiveEngine is &engine, "doir.query: an exclusive section of one engine inside another's");
	if (exclusiveDepth++) return;
	exclusiveEngine = &engine;
	bc.gate.beginExclusive(engine.gate, sharing(engine));
	ecrs.context.beginExclusive(*engine.store);
	assert(ecrs.context.inExclusive(*engine.store), "doir.query: an exclusive section the store does not know of");
}

/// Ditto
package(doir) void endExclusive(ref QueryEngine engine) {
	assert(exclusiveDepth && exclusiveEngine is &engine, "doir.query: endExclusive without beginExclusive");
	if (--exclusiveDepth) return;
	exclusiveEngine = null;
	assert(ecrs.context.inExclusive(*engine.store), "doir.query: ending an exclusive section the store does not know of");
	ecrs.context.endExclusive(*engine.store);
	bc.gate.endExclusive(engine.gate, sharing(engine));
}

private bool tryRunAlone(ref QueryEngine engine) {
	if (!core.atomic.cas(&bc.platform.asShared(engine.demandsBlocked), false, true)) return false;
	if (core.atomic.atomicLoad(bc.platform.asShared(engine.demandingThreads)) == 0) return true;
	core.atomic.atomicStore(bc.platform.asShared(engine.demandsBlocked), false);
	return false;
}

private void joinDemand(ref QueryEngine engine) {
	assert(!local.holding, "doir.query: joining a demand this thread already makes");
	attach(engine);
	core.atomic.atomicOp!"+="(bc.platform.asShared(engine.demandingThreads), 1);
	bc.gate.enterShared(engine.gate);
	local.holding = true;
	local.abandoned = false;
	assert(sharing(engine), "doir.query: joined a demand without sharing the engine");
}

private void leaveDemand(ref QueryEngine engine) {
	assert(sharing(engine), "doir.query: leaving a demand this thread does not make");
	local.holding = false;
	bc.gate.leaveShared(engine.gate);
	core.atomic.atomicOp!"-="(bc.platform.asShared(engine.demandingThreads), 1);
	assert(fp.dynarray.length(local.stack) == 0, "doir.query: leaving a demand with queries still running");
	fp.dynarray.free(local.stack);
	local.stack = null;
}

// Brings stale queries up to date if no thread demands, keeping others out meanwhile.
// A failure is recorded in `edgesMissing`.
private void revalidateIfAlone(ref QueryEngine engine) {
	if (core.atomic.atomicLoad(bc.platform.asShared(engine.staleQueued)) == 0 || !tryRunAlone(engine)) return;
	joinDemand(engine);
	cast(void) revalidateStale(engine);
	leaveDemand(engine);
	core.atomic.atomicStore(bc.platform.asShared(engine.demandsBlocked), false);
}


// --- the running query -------------------------------------------------------

/// Whether the calling thread runs no query on `engine`, as the entry points that must not run inside one assert.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = create(store);
/// scope(exit) free(engine);
/// assert(runsNoQuery(engine));
/// ---
package(doir) bool runsNoQuery(ref QueryEngine engine) {
	return !attached(engine) || fp.dynarray.length(local.stack) == 0;
}

private size_t frameOf(ref QueryEngine engine, EntityId q) {
	assert(q != invalidEntity, "doir.query: the frame of no query");
	if (runsNoQuery(engine)) return notRunning;
	auto running = ecrs.context.findComponent!(doir.components.query.Claim)(*engine.store, q);
	if (running is null || core.atomic.atomicLoad(bc.platform.asShared(running.owner)) != local.self) return notRunning;
	assert(running.frame == notRunning || (running.frame < fp.dynarray.length(local.stack) && local.stack[running.frame].query == q), "doir.query: a claim naming a frame that runs another query");
	return running.frame;
}

/// Reports a refused allocation the running query met on its own, outside the engine's calls: it and every query below it fail, keeping no value, and `engine.refused` is set.
/// The whole stack fails because a query failing alone could memoize a value built on a failed demand's null.
/// Its `compute` should then return at once; the value it returns is discarded.
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
	// A null from a demand given up to break a wait cycle is no refusal, though the query seeing it may call this.
	if (!attached(engine) || !local.abandoned) core.atomic.atomicStore(bc.platform.asShared(engine.refused), true);
	if (attached(engine)) foreach (ref frame; fp.dynarray.slice(local.stack)) frame.refused = true;
}

// Gives up this thread's demand to break a wait cycle: its running queries fail without setting `engine.refused`, and it starts again.
private void abandon(ref QueryEngine engine) {
	assert(attached(engine) && local.holding, "doir.query: abandoning a demand this thread does not make");
	local.abandoned = true;
	foreach (ref frame; fp.dynarray.slice(local.stack)) frame.refused = true;
}

// Waits until no thread runs `q` (rustc's `QueryLatch`), outside the shared section; false if this thread gives up its demand to break a wait cycle.
private bool waitForRunner(ref QueryEngine engine, EntityId q) {
	assert(local.self >= 1 && local.self <= maxThreads, "doir.query: waiting with an owner id outside 1 .. maxThreads");
	assert(core.atomic.atomicLoad(bc.platform.asShared(engine.waitingOn[local.self])) == invalidEntity, "doir.query: a thread waiting on two queries at once");
	auto running = &ecrs.context.getComponent!(doir.components.query.Claim)(*engine.store, q);
	core.atomic.atomicStore(bc.platform.asShared(engine.waitingOn[local.self]), q);
	scope(exit) core.atomic.atomicStore(bc.platform.asShared(engine.waitingOn[local.self]), invalidEntity);
	for (;;) {
		uint owner = core.atomic.atomicLoad(bc.platform.asShared(running.owner));
		if (owner == 0) return true;
		uint highest = local.self;
		// Each hop is another thread, so a chain longer than the threads loops among others, who find it themselves.
		for (size_t hops = 0; owner != 0 && hops <= maxThreads; ++hops) {
			if (owner == local.self) {
				if (highest != local.self && !deferringReports) break;
				abandon(engine);
				return false;
			}
			if (owner > highest) highest = owner;
			immutable next = core.atomic.atomicLoad(bc.platform.asShared(engine.waitingOn[owner]));
			if (next == invalidEntity) break;
			owner = core.atomic.atomicLoad(bc.platform.asShared(ecrs.context.getComponent!(doir.components.query.Claim)(*engine.store, next).owner));
		}
		safepoint(engine);
		bc.thread.yield();
	}
}

/// The running query entity whose run is innermost on the calling thread, or `invalidEntity` outside any query.
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
	assert(runsNoQuery(engine) || local.holding, "doir.query: a query running on a thread that does not share the engine");
	immutable q = runsNoQuery(engine) ? invalidEntity : fp.dynarray.back(local.stack).query;
	assert(runsNoQuery(engine) || q != invalidEntity, "doir.query: a running frame for no query");
	return q;
}

// How many of a query's latest reads `read` searches for a repeat.
private enum size_t recentReads = 16;

/// Records that the running query read entity `e`, so a later change to `e` re-runs it.
/// Reads made outside any query are not recorded.
/// If `e` is a provisional answer, the running query's value rests on the same cycle fallback (`Q-Cycle`); one resting on another thread's running query is waited for, until that query keeps or discards it.
/// Do not record reads of `SourceSpan` or `ByteRange`: spans are untracked.
/// Returns false on a refused allocation, which fails the running queries (`fail`), and when the wait loops back across threads, which gives the demand up to run again.
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
	if (runsNoQuery(engine)) return true;
	auto stack = local.stack;
	immutable n = fp.dynarray.length(stack);
	assert(n > 0 && n <= engine.depthLimit + 1, "doir.query: a stack deeper than the depth limit");
	auto top = &stack[n - 1];
	if (top.query == e) return true;
	assert(e != invalidEntity, "doir.query: reading no entity");
	for (;;) {
		auto provisional = ecrs.context.findComponent!(doir.components.query.ProvisionalOn)(*engine.store, e);
		if (provisional is null) break;
		immutable h = frameOf(engine, provisional.head);
		if (h == notRunning) {
			if (!waitForRunner(engine, provisional.head)) return false;
			continue;
		}
		// A batch's worker leaves a cycle, or the depth limit, to the batch's serial pass, which meets it in key order (Q-Cycle).
		if (deferringReports) {
			abandon(engine);
			return false;
		}
		top.cycle = true;
		if (h < n - 1 && h < top.head) top.head = h;
		break;
	}
	auto deps = &ecrs.context.getForWriting!(doir.components.query.Reads)(*engine.store, top.query);
	// Only the latest reads are searched, so recording thousands stays linear; a repeat further back only costs a re-check.
	auto recorded = fp.dynarray.slice(deps.related);
	foreach (d; recorded[recorded.length > recentReads ? recorded.length - recentReads : 0 .. $])
		if (d == e) return true;
	if (fp.dynarray.pushBack(deps.related, e)) {
		assert(*fp.dynarray.back(deps.related) == e, "doir.query: a read recorded as another entity");
		return true;
	}
	fail(engine);
	return false;
}

/// Marks every query that read `e` stale, to be brought up to date before the next demand (`revalidateStale`): one whose value then changes marks its own dependents in turn, and one that keeps it stops the change there.
/// `doir.query.markChanged` calls it for each changed input, and an input commit calls it before removing an entity, whose id may be handed out again.
/// A refused allocation sets `engine.edgesMissing`.
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
/// markReadersStale(engine, input); // as an input commit does before removing it
/// assert(*query!Get(engine, Get.Key([input]))); // checked again before it is reused
/// ---
void markReadersStale(ref QueryEngine engine, EntityId e) {
	assert(e != invalidEntity, "doir.query: marking the readers of no entity");
	auto lock = &bc.spinlock.striped.stripeFor(engine.entityLocks, e);
	bc.spinlock.lockForReading(*lock);
	scope(exit) bc.spinlock.unlockForReading(*lock);
	auto dependents = ecrs.context.findComponent!(doir.components.query.ReadBy)(*engine.store, e);
	if (dependents is null) return;
	foreach (q; fp.dynarray.slice(dependents.related)) {
		auto verified = ecrs.context.findComponent!(doir.components.query.Verification)(*engine.store, q);
		// One verified in this revision read its dependencies as they are now.
		// Threads mark concurrently, so one claims each query.
		if (verified is null || core.atomic.atomicLoad(bc.platform.asShared(verified.revision)) == engine.revision || !core.atomic.cas(&bc.platform.asShared(verified.stale), false, true)) continue;
		bool queued;
		{
			auto pending = bc.monitor.write(engine.staleQueue);
			queued = fp.dynarray.pushBack(pending.value, q);
			if (queued) core.atomic.atomicOp!"+="(bc.platform.asShared(engine.staleQueued), 1);
			assert(!queued || *fp.dynarray.back(pending.value) == q, "doir.query: a stale query queued as another");
		}
		if (!queued) core.atomic.atomicStore(bc.platform.asShared(engine.edgesMissing), true);
	}
}

/// Records that the running query wrote component `item.component` on `item.entity`, to be removed by `item.strip` before the query runs again and when it is evicted, and hashed by `item.hash` for early cutoff.
/// Unless `unique`, a repeat record of the same pair in one run is ignored.
/// Use `doir.query.produce` for a whole component; this is for components that several queries write parts of, such as effect logs.
/// Returns false on a refused allocation, which fails the running queries (`fail`).
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
/// 		immutable item = doir.components.query.Output([currentQuery(engine)], ecrs.registry.componentId!int(), &strip, &hash);
/// 		if (!recordOutput(engine, item, false) || !recordOutput(engine, item, false)) return 0;
/// 		return fp.dynarray.length(ecrs.context.getComponent!(doir.components.query.Outputs)(*engine.store, currentQuery(engine)).items);
/// 	}
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// QueryEngine engine;
/// engine.store = &store;
/// scope(exit) free(engine);
/// assert(*query!Claim(engine, 1) == 1);
/// ---
bool recordOutput(ref QueryEngine engine, doir.components.query.Output item, bool unique) {
	immutable q = currentQuery(engine);
	assert(q != invalidEntity, "doir.query: writing a component outside a query");
	assert(item.entity != invalidEntity && item.strip !is null && item.hash !is null, "doir.query: an output with no entity or no hooks");
	auto produces = &ecrs.context.getForWriting!(doir.components.query.Outputs)(*engine.store, q);
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
/// removeOwnedComponent(store, e, ecrs.registry.componentId!int(), invalidEntity);
/// assert(!ecrs.context.hasComponent!int(store, e));
/// ---
package(doir) void removeOwnedComponent(ref ecrs.context.Context store, EntityId e, size_t component, EntityId owner) {
	assert(!ecrs.context.inTransaction(store), "doir.query: stripping an output inside a transaction, where removal can fail");
	if (ecrs.context.hasComponent(store, e, component)) cast(void) ecrs.context.removeComponent(store, e, component); // queries run outside transactions, where removal cannot fail
	assert(!ecrs.context.hasComponent(store, e, component), "doir.query: an output that survived being stripped");
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
		else return fp.algorithms.hashBytes((cast(const(ubyte)*) c)[0 .. C.sizeof]);
	}
}

// The running query's next created entity: the one its previous run made at that sequence number, or a fresh one.
private EntityId nextCreated(ref QueryEngine engine) {
	assert(!runsNoQuery(engine), "doir.query: creating an entity outside a query");
	auto frame = fp.dynarray.back(local.stack);
	auto creates = &ecrs.context.getForWriting!(doir.components.query.CreatedEntities)(*engine.store, frame.query);
	immutable sequence = frame.created++;
	assert(sequence <= fp.dynarray.length(creates.related), "doir.query: a created entity skipped a sequence number");
	if (sequence < fp.dynarray.length(creates.related)) return creates.related[sequence];
	beginExclusive(engine);
	immutable e = ecrs.context.addEntity(*engine.store);
	endExclusive(engine);
	if (e != invalidEntity && fp.dynarray.pushBack(creates.related, e)) {
		assert(fp.dynarray.length(creates.related) == sequence + 1, "doir.query: a created entity recorded at the wrong sequence number");
		return e;
	}
	if (e != invalidEntity) {
		beginExclusive(engine);
		cast(void) ecrs.context.removeEntity(*engine.store, e); // if refused, an orphan nothing reaches
		endExclusive(engine);
	}
	fail(engine);
	return invalidEntity;
}

// Copies `d` to `engine.diagnostics`, the hint annotating `subject`, or as the closing note if unlocated.
// Refusal drops it and sets `engine.refused` without failing any query.
private bool sendToManager(ref QueryEngine engine, ref const doir.components.query.QueryDiagnostic d) {
	if (engine.diagnostics is null) return true;
	assert(fp.string.length(d.message) > 0, "doir.query: a diagnostic with no message");
	diagnose.Diagnostic out_;
	out_.kind = d.kind;
	auto location = doir.engine.locations.locate(*engine.store, d.subject);
	if (!location.isNull) out_.location = location.get;
	auto message = fp.string.clone(fp.string.slice(d.message));
	bool ok = !message.isNull;
	if (ok) out_.message = message.get;
	if (ok && d.hint !is null) {
		auto hint = fp.string.clone(fp.string.slice(d.hint));
		if (hint.isNull) ok = false;
		else if (location.isNull) out_.note = hint.get;
		else {
			auto annotation = diagnose.Diagnostic.Annotation(diagnose.LineColumn.init, null, hint.get);
			ok = diagnose.pushAnnotationAtStart(out_, annotation);
			if (!ok) fp.string.free(annotation.message);
		}
	}
	foreach (ref a; fp.dynarray.slice(d.annotations)) {
		if (!ok || location.isNull) break;
		auto where = doir.engine.locations.locate(*engine.store, a.target);
		if (where.isNull) continue;
		auto text = fp.string.clone(fp.string.slice(a.message));
		if (text.isNull) {
			ok = false;
			break;
		}
		auto annotation = diagnose.Diagnostic.Annotation(where.get.start, where.get.file == out_.location.file ? null : where.get.file, text.get);
		ok = fp.dynarray.pushBack(out_.annotations, annotation);
		if (!ok) fp.string.free(annotation.message);
	}
	if (ok) {
		assert(location.isNull || d.hint is null || fp.dynarray.length(out_.annotations) >= 1, "doir.query: a located diagnostic that lost its hint's annotation");
		bc.spinlock.lockForWriting(engine.diagnosticsLock);
		immutable pushed = diagnose.push(*engine.diagnostics, out_) !is null;
		bc.spinlock.unlockForWriting(engine.diagnosticsLock);
		if (pushed) return true;
	}
	diagnose.free(out_);
	core.atomic.atomicStore(bc.platform.asShared(engine.refused), true);
	return false;
}

// Stores `d`, taken over, on the running query, or outside one reports and frees it.
// A refusal frees it and fails the running queries.
private bool recordDiagnostic(ref QueryEngine engine, doir.components.query.QueryDiagnostic d) {
	assert(d.message !is null, "doir.query: recording a diagnostic with no message");
	immutable q = currentQuery(engine);
	if (q == invalidEntity) {
		immutable emitted = sendToManager(engine, d);
		doir.components.query.freeDiagnostic(d);
		return emitted;
	}
	if (fp.dynarray.pushBack(ecrs.context.getForWriting!(doir.components.query.QueryDiagnostics)(*engine.store, q).items, d)) return true;
	doir.components.query.freeDiagnostic(d);
	fail(engine);
	return false;
}


// --- running and validating queries ------------------------------------------

// Adds `q` to the `ReadBy` of `from` behind its lock, or drops it; a new list waits for the exclusive section.
// False on refusal.
private bool applyEdge(ref QueryEngine engine, EntityId from, EntityId q, bool added) {
	assert(from != invalidEntity && q != invalidEntity, "doir.query: an edge to or from no entity");
	if (added && !ecrs.context.hasComponent!(doir.components.query.ReadBy)(*engine.store, from)) {
		beginExclusive(engine);
		immutable made = ecrs.context.ensureComponent!(doir.components.query.ReadBy)(*engine.store, from) !is null;
		endExclusive(engine);
		if (!made) return false;
	}
	auto lock = &bc.spinlock.striped.stripeFor(engine.entityLocks, from);
	bc.spinlock.lockForWriting(*lock);
	scope(exit) bc.spinlock.unlockForWriting(*lock);
	auto list = ecrs.context.findForWriting!(doir.components.query.ReadBy)(*engine.store, from);
	assert(!added || list !is null, "doir.query: adding an edge to a list that was not made");
	if (added) return fp.dynarray.pushBack(list.related, q);
	if (list is null) return true;
	auto items = fp.dynarray.slice(list.related);
	foreach (i, d; items)
		if (d == q) {
			items[i] = items[$ - 1];
			cast(void) fp.dynarray.removeLast(list.related);
			break;
		}
	return true;
}

// How many reverse edges are worth sharing among the workers.
private enum size_t parallelEdges = 4096;

// The reverse edges from partition `part` of `parts`: `queries` lists them, `reads` holds their reads, and no two shares touch one entity's `ReadBy`.
private struct BuildShare {
	const(EntityId)[] queries;
	const(EntityId)[][] reads;
	uint[] counts;
	doir.components.query.ReadBy*[] lists;
	size_t part, parts;
}

// Counts the share's edges per entity first, so each `ReadBy` is found and sized once rather than once per edge.
private bool buildShare(ref QueryEngine engine, ref BuildShare share) @trusted {
	assert(share.part < share.parts && share.queries.length == share.reads.length, "doir.query: a share past its partition count, or reads that miss queries");
	assert(share.counts.length == share.lists.length, "doir.query: edge counts and lists that disagree");
	// As in `recordEdges`, a read renumbered to `invalidEntity` needs no edge.
	foreach (i; 0 .. share.queries.length)
		foreach (d; share.reads[i])
			if (d != invalidEntity && d % share.parts == share.part) ++share.counts[d];
	// Each list grows to its final length here; `counts` then holds where its next edge goes.
	for (size_t d = share.part; d < share.counts.length; d += share.parts) {
		if (share.counts[d] == 0) continue;
		auto list = ecrs.context.ensureComponent!(doir.components.query.ReadBy)(*engine.store, cast(EntityId) d);
		immutable had = list is null ? 0 : fp.dynarray.length(list.related);
		if (list is null || fp.dynarray.growToSize(list.related, had + share.counts[d]) is null) return false;
		share.lists[d] = list;
		share.counts[d] = cast(uint) had;
	}
	foreach (i, q; share.queries)
		foreach (d; share.reads[i])
			if (d != invalidEntity && d % share.parts == share.part) share.lists[d].related[share.counts[d]++] = q;
	for (size_t d = share.part; d < share.counts.length; d += share.parts)
		assert(share.lists[d] is null || share.counts[d] == fp.dynarray.length(share.lists[d].related), "doir.query: an edge list not filled to the length it was sized for");
	return true;
}

/// Builds every reverse dependency edge (`ReadBy`) from what each query read in its last run, replacing any there were, and clears `engine.edgesMissing`, so a change is pushed to the queries it reaches from then on.
/// An engine that defers its edges (`edgesMissing` set from the start) calls it before the first edit it wants to cost in proportion to what the edit reaches; it shares the work among `engine.workers`.
/// No query may be running.
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
	assert(core.atomic.atomicLoad(bc.platform.asShared(engine.demandingThreads)) == 0, "doir.query: buildDependents while a query runs");
	auto store = engine.store;
	auto existing = ecrs.context.getStorage(*store, ecrs.registry.componentId!(doir.components.query.ReadBy)(), doir.components.query.ReadBy.sizeof);
	if (existing is null) return false;
	foreach (e; ecrs.storage.slotOwnersOf(*existing))
		if (e != invalidEntity) fp.dynarray.clear(ecrs.context.getComponent!(doir.components.query.ReadBy)(*store, e).related);
	// Each query's reads are gathered here, so the workers never read an index list another of them may be growing.
	EntityId* queries = null;
	const(EntityId)[]* reads = null;
	BuildShare* shares = null;
	scope(exit) {
		fp.dynarray.free(queries);
		fp.dynarray.free(reads);
		fp.dynarray.free(shares);
	}
	auto made = ecrs.context.getStorage(*store, ecrs.registry.componentId!(doir.components.query.Reads)(), doir.components.query.Reads.sizeof);
	if (made is null) return false;
	size_t total = 0, bound = 0;
	foreach (q; ecrs.storage.slotOwnersOf(*made)) {
		if (q == invalidEntity) continue;
		auto read = fp.dynarray.slice(ecrs.context.getComponent!(doir.components.query.Reads)(*store, q).related);
		if (!fp.dynarray.pushBack(queries, q) || !fp.dynarray.pushBack(reads, read)) return false;
		total += read.length;
		foreach (d; read) if (d >= bound) bound = d + 1;
	}
	auto counts = fp.pointer.allocate!uint(bound);
	auto lists = fp.pointer.allocate!(doir.components.query.ReadBy*)(bound);
	scope(exit) {
		fp.pointer.free(counts);
		fp.pointer.free(lists);
	}
	if (bound && (counts is null || lists is null)) return false;
	counts[0 .. bound] = 0;
	lists[0 .. bound] = null;
	immutable workers = engine.workers is null ? 1 : bc.threadpool.workerCount(engine.workers);
	immutable n = fp.dynarray.length(queries);
	// The shares' partitions are disjoint, so `parallel` running them inline, as it does when the pool cannot take them, builds the same edges.
	immutable reserved = total >= parallelEdges && workers >= 2 && ecrs.context.reserveConcurrentAdds!(doir.components.query.ReadBy)(*store, total);
	// Building inline after a refused share list must not take the reserved slots, which only concurrent writes count.
	if (reserved && fp.dynarray.reserve(shares, workers) is null) ecrs.context.cancelConcurrentAdds(*store);
	else if (reserved) {
		foreach (w; 0 .. workers)
			cast(void) fp.dynarray.pushBack(shares, BuildShare(queries[0 .. n], reads[0 .. n], counts[0 .. bound], lists[0 .. bound], w, workers)); // reserved
		immutable ok = ecrs.schedules.concurrentWrites(engine, ecrs.schedules.parallel!buildShare(engine.workers, fp.dynarray.slice(shares)));
		engine.edgesMissing = !ok;
		return ok;
	}
	auto one = BuildShare(queries[0 .. n], reads[0 .. n], counts[0 .. bound], lists[0 .. bound], 0, 1);
	immutable ok = buildShare(engine, one);
	engine.edgesMissing = !ok;
	return ok;
}

// Updates `q`'s reverse edges from `before`, its previous run's reads, which this sorts, to its latest.
// Refusal sets `edgesMissing`.
private void recordEdges(ref QueryEngine engine, EntityId q, EntityId[] before) @trusted {
	if (core.atomic.atomicLoad(bc.platform.asShared(engine.edgesMissing))) return; // `buildDependents` builds them from scratch
	auto now = fp.dynarray.slice(ecrs.context.getComponent!(doir.components.query.Reads)(*engine.store, q).related);
	bool ok = true;
	void edge(EntityId from, bool added) {
		// A read of an entity compaction freed was renumbered to `invalidEntity`, which never changes, so needs no edge.
		if (ok && from != invalidEntity) ok = applyEdge(engine, from, q, added);
	}
	EntityId* sorted = null;
	scope(exit) fp.dynarray.free(sorted);
	// A first run adds every edge unsorted; a repeated read past `read`'s window only costs a spare edge.
	if (before.length == 0) foreach (d; now) edge(d, true);
	else if (now.length && !fp.dynarray.concatenate(sorted, now)) ok = false;
	else {
		auto after = fp.dynarray.slice(sorted);
		std.algorithm.sorting.sort(before);
		std.algorithm.sorting.sort(after);
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
	if (!ok) core.atomic.atomicStore(bc.platform.asShared(engine.edgesMissing), true);
	foreach (i; 1 .. before.length) assert(!ok || before[i - 1] <= before[i], "doir.query: previous reads left unsorted");
}

private void removeProduced(ref QueryEngine engine, EntityId q) {
	auto produces = &ecrs.context.getForWriting!(doir.components.query.Outputs)(*engine.store, q);
	if (fp.dynarray.length(produces.items) == 0) return;
	beginExclusive(engine);
	foreach (item; fp.dynarray.slice(produces.items)) {
		assert(item.strip !is null, "doir.query: an output with no way to strip it");
		item.strip(*engine.store, item.entity, item.component, q);
	}
	endExclusive(engine);
	fp.dynarray.clear(produces.items);
	assert(fp.dynarray.length(produces.items) == 0, "doir.query: outputs left after removing them");
}

private size_t hashProduced(ref QueryEngine engine, EntityId q) {
	assert(q != invalidEntity, "doir.query: hashing the outputs of no query");
	size_t h = 0xcbf29ce484222325;
	foreach (item; fp.dynarray.slice(ecrs.context.getComponent!(doir.components.query.Outputs)(*engine.store, q).items)) {
		h = fp.algorithms.combine(h, item.entity);
		h = fp.algorithms.combine(h, item.component);
		// A component several queries write parts of, an effect log, is read behind its entity's lock.
		auto lock = &bc.spinlock.striped.stripeFor(engine.entityLocks, item.entity);
		bc.spinlock.lockForReading(*lock);
		h = fp.algorithms.combine(h, item.hash(*engine.store, item.entity, item.component, q));
		bc.spinlock.unlockForReading(*lock);
	}
	return h;
}

// Removes the entities past `keep`, which the latest run no longer created.
// One the store refuses to free stays listed for later reuse or removal.
private void removeCreated(ref QueryEngine engine, EntityId q, size_t keep) {
	auto creates = &ecrs.context.getComponent!(doir.components.query.CreatedEntities)(*engine.store, q);
	if (fp.dynarray.length(creates.related) <= keep) return;
	beginExclusive(engine);
	while (fp.dynarray.length(creates.related) > keep && ecrs.context.removeEntity(*engine.store, *fp.dynarray.back(creates.related)))
		cast(void) fp.dynarray.removeLast(creates.related);
	endExclusive(engine);
	assert(fp.dynarray.length(creates.related) >= keep, "doir.query: removed entities the latest run still created");
}

private void clearDiagnostics(ref QueryEngine engine, EntityId q) {
	assert(q != invalidEntity, "doir.query: clearing the diagnostics of no query");
	auto list = &ecrs.context.getForWriting!(doir.components.query.QueryDiagnostics)(*engine.store, q);
	foreach (ref d; fp.dynarray.slice(list.items)) doir.components.query.freeDiagnostic(d);
	if (list.items !is null) fp.dynarray.clear(list.items);
	assert(fp.dynarray.length(list.items) == 0, "doir.query: diagnostics left after clearing them");
}

// Reports `q`'s diagnostics, or while withholding marks `q` withheld if it or one below it, as `below` says, has any.
private void emitAll(ref QueryEngine engine, EntityId q, bool below) {
	assert(q != invalidEntity, "doir.query: reporting the diagnostics of no query");
	auto list = fp.dynarray.slice(ecrs.context.getComponent!(doir.components.query.QueryDiagnostics)(*engine.store, q).items);
	immutable withhold = deferringReports || engine.settling;
	core.atomic.atomicStore(bc.platform.asShared(ecrs.context.getComponent!(doir.components.query.Claim)(*engine.store, q).reportsDeferred), withhold && (below || list.length));
	if (withhold) return;
	assert(!core.atomic.atomicLoad(bc.platform.asShared(ecrs.context.getComponent!(doir.components.query.Claim)(*engine.store, q).reportsDeferred)), "doir.query: reporting diagnostics still marked withheld");
	foreach (ref d; list) cast(void) sendToManager(engine, d); // a lost diagnostic is recorded in engine.refused
}

// bounded: `engine.depthLimit`, past which no query runs, so no chain of readers is longer
// Reports in serial order what was withheld at `q` and below it; one thread takes each withheld query, so none repeats.
private void flushWithheld(ref QueryEngine engine, EntityId q) {
	auto running = ecrs.context.findComponent!(doir.components.query.Claim)(*engine.store, q);
	if (running is null || !core.atomic.cas(&bc.platform.asShared(running.reportsDeferred), true, false)) return;
	// A withheld query holds diagnostics, so its reader lists it among those it reports.
	immutable n = fp.dynarray.length(ecrs.context.getComponent!(doir.components.query.ReportingReads)(*engine.store, q).related);
	foreach (i; 0 .. n) flushWithheld(engine, ecrs.context.getComponent!(doir.components.query.ReportingReads)(*engine.store, q).related[i]);
	emitAll(engine, q, false);
}

// Rehashes a table a renumbering left stale, keeping one entry of keys it mapped together, as those naming removed entities all are.
// Returns false if the rehash was refused, leaving it stale.
private bool rehashIfStale(Q)(ref TableState!Q table) {
	if (!table.stale) return true;
	if (!fp.hashtable.rehash(table.table, 0, true)) return false;
	table.stale = false;
	assert(fp.hashtable.validate(table.table), "doir.query: a rehashed query table that breaks its invariants");
	return true;
}

/// The query entity of `Q` at `key`, or `invalidEntity` if `Q` was never demanded there.
/// It cannot fail: when a table a renumbering left stale cannot be rehashed, it is searched entry by entry.
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
	auto table = ecrs.context.findSingletonForWriting!(QueryTable!Q)(*engine.store);
	if (table is null) return invalidEntity;
	{
		auto state = bc.monitor.read(table.state);
		if (!state.value.stale) return lookup!Q(state.value, key);
	}
	// A rehash refused leaves the table to be searched.
	auto state = bc.monitor.write(table.state);
	cast(void) rehashIfStale!Q(state.value);
	immutable q = lookup!Q(state.value, key);
	assert(q == invalidEntity || ecrs.context.hasComponent!(doir.components.query.QueryKey!Q)(*engine.store, q), "doir.query: a table entry naming an entity that is not a query of its type");
	return q;
}

// The query entity at `key` in `table`, whose lock the caller holds.
private EntityId lookup(Q)(ref const TableState!Q table, ref const Q.Key key) @trusted {
	const(TableEntry!Q)* found = null;
	if (!table.stale) {
		immutable at = fp.hashtable.positionOf(table.table, TableEntry!Q([invalidEntity], key));
		if (at != fp.pointer.notFound) found = table.table + at;
	} else
		foreach (stored; fp.hashtable.occupied(table.table))
			if (stored.query != invalidEntity && keysEqual!Q(stored.key, key)) {
				found = stored;
				break;
			}
	assert(found is null || keysEqual!Q(found.key, key), "doir.query: found an entry under another key");
	return found is null ? invalidEntity : found.query;
}

private bool appendDescription(Q)(ref QueryEngine engine, EntityId q, ref char* out_) @trusted {
	assert(ecrs.context.hasComponent!(doir.components.query.QueryKey!Q)(*engine.store, q), "doir.query: describing an entity that is not a query of this type");
	immutable before = fp.string.length(out_);
	if (!fp.string.concatenate(out_, __traits(identifier, Q))) return false;
	assert(fp.string.length(out_) > before, "doir.query: a description that named nothing");
	auto key = &ecrs.context.getComponent!(doir.components.query.QueryKey!Q)(*engine.store, q).key;
	static if (__traits(hasMember, Q, "describeKey")) {
		return Q.describeKey(*key, out_);
	} else static if (__traits(isIntegral, Q.Key)) {
		static if (__traits(isUnsigned, Q.Key)) auto text = fp.string.format("(%llu)", cast(ulong) *key);
		else auto text = fp.string.format("(%lld)", cast(long) *key);
		if (text.isNull) return false;
		char* formatted = text.get;
		scope(exit) fp.string.free(formatted);
		return fp.string.concatenate(out_, fp.string.slice(formatted));
	} else return true;
}

// The table of `Q`'s query entities, made in the exclusive section on its first use.
// Null on a refused allocation.
private QueryTable!Q* tableFor(Q)(ref QueryEngine engine) @trusted {
	if (auto table = ecrs.context.findSingletonForWriting!(QueryTable!Q)(*engine.store)) return table;
	beginExclusive(engine);
	scope(exit) endExclusive(engine);
	if (auto raced = ecrs.context.findSingletonForWriting!(QueryTable!Q)(*engine.store)) return raced;
	fp.hashtable.Config config;
	config.hashFunction = &hashTableEntry!Q;
	config.equalFunction = &equalTableEntry!Q;
	auto fresh = fp.hashtable.create!(TableEntry!Q)(config);
	if (fresh is null) return null;
	auto table = ecrs.context.addSingleton!(QueryTable!Q)(*engine.store);
	if (table is null) {
		fp.hashtable.free(fresh);
		return null;
	}
	bc.monitor.write(table.state).value.table = fresh;
	assert(ecrs.context.findSingletonForWriting!(QueryTable!Q)(*engine.store) is table, "doir.query: a second table for one query type");
	return table;
}

private void noteStale(Q)(ref QueryEngine engine, EntityId q) {
	Q.onStale(engine, ecrs.context.getComponent!(doir.components.query.QueryKey!Q)(*engine.store, q).key);
}

// Makes new entity `q` a query entity of `Q` with every component, its key left for the add taking it.
// Exclusive section only; on refusal removes `q` and returns false.
private bool addSpareQuery(Q)(ref QueryEngine engine, EntityId q) {
	assert(ecrs.context.inExclusive(*engine.store), "doir.query: making spare queries outside the exclusive section");
	assert(q != invalidEntity && !ecrs.context.hasComponent!(doir.components.query.QueryKey!Q)(*engine.store, q), "doir.query: making a spare of no entity, or of a query already");
	auto store = engine.store;
	auto info = ecrs.context.addComponent!(doir.components.query.QueryKey!Q)(*store, q) is null ? null : ecrs.context.addComponent!(doir.components.query.Hooks)(*store, q);
	static if (__traits(hasMember, Q, "onStale")) enum stale = &noteStale!Q;
	else enum doir.components.query.StaleFunction stale = null;
	if (info !is null) *info = doir.components.query.Hooks(&bringUpToDate!Q, &reset!Q, &appendDescription!Q, stale);
	if (info !is null
		&& ecrs.context.addComponent!(doir.components.query.ChangedAt)(*store, q) !is null
		&& ecrs.context.addComponent!(doir.components.query.Verification)(*store, q) !is null
		&& ecrs.context.addComponent!(doir.components.query.Reads)(*store, q) !is null
		&& ecrs.context.addComponent!(doir.components.query.ReportingReads)(*store, q) !is null
		&& ecrs.context.addComponent!(doir.components.query.Outputs)(*store, q) !is null
		&& ecrs.context.addComponent!(doir.components.query.CreatedEntities)(*store, q) !is null
		&& ecrs.context.addComponent!(doir.components.query.QueryDiagnostics)(*store, q) !is null
		&& ecrs.context.addComponent!(doir.components.query.Claim)(*store, q) !is null
		&& ecrs.context.addComponent!(doir.components.query.QueryValue!Q)(*store, q) !is null)
		return true;
	cast(void) ecrs.context.removeEntity(*store, q); // if refused, an orphan nothing reaches
	return false;
}

// The most spares one batch makes; each batch doubles the last, so adding n query entities of one type takes about log n exclusive sections.
private enum size_t maxSpares = 4096;

// The query entity of `Q` at `key`, or a spare taking it, a batch of spares being made when none is left.
// `invalidEntity` on refusal.
private EntityId findOrAdd(Q)(ref QueryEngine engine, ref const Q.Key key) @trusted {
	immutable found = find!Q(engine, key);
	if (found != invalidEntity) return found;
	auto table = tableFor!Q(engine);
	if (table is null) return invalidEntity;
	for (;;) {
		size_t n;
		{
			auto state = bc.monitor.write(table.state);
			if (!rehashIfStale!Q(state.value)) return invalidEntity;
			immutable raced = lookup!Q(state.value, key);
			if (raced != invalidEntity) return raced;
			if (fp.dynarray.length(state.value.spareQueries.related) != 0) {
				immutable q = *fp.dynarray.back(state.value.spareQueries.related);
				assert(q != invalidEntity, "doir.query: a spare query that was removed");
				ecrs.context.getForWriting!(doir.components.query.QueryKey!Q)(*engine.store, q).key = key;
				// An entry whose query a renumbering removed is reused.
				if (auto dead = fp.hashtable.find(state.value.table, TableEntry!Q([invalidEntity], key))) dead.related[0] = q;
				else if (fp.hashtable.insert(state.value.table, TableEntry!Q([q], key)) is null) return invalidEntity;
				cast(void) fp.dynarray.removeLast(state.value.spareQueries.related);
				assert(lookup!Q(state.value, key) == q, "doir.query: a query added that its key does not find");
				return q;
			}
			immutable last = state.value.lastSpareBatch;
			n = last == 0 ? 1 : (2 * last < maxSpares ? 2 * last : maxSpares);
			assert(n >= 1 && n <= maxSpares, "doir.query: a spare batch outside 1 .. maxSpares");
			state.value.lastSpareBatch = n;
		}
		// The table's lock is released first: a thread waiting on it would hold the shared section, which `beginExclusive` waits for.
		beginExclusive(engine);
		// Never a freed id: one a query read as an input may still be listed in its `Reads`, and must not answer as a query.
		immutable first = ecrs.context.addEntities(*engine.store, n);
		size_t made = 0;
		for (; first != invalidEntity && made < n; ++made) {
			immutable q = cast(EntityId) (first + made);
			if (!addSpareQuery!Q(engine, q)) break;
			if (!fp.dynarray.pushBack(bc.monitor.write(table.state).value.spareQueries.related, q)) {
				cast(void) ecrs.context.removeEntity(*engine.store, q); // if refused, an orphan nothing reaches
				break;
			}
		}
		// The batch's ids past the one that failed were never made into queries.
		if (first != invalidEntity)
			foreach (unused; made + 1 .. n) cast(void) ecrs.context.removeEntity(*engine.store, cast(EntityId) (first + unused)); // if refused, an orphan nothing reaches
		endExclusive(engine);
		if (made == 0) return invalidEntity;
	}
}

/// How to fix a `Q-Cycle` chain, the closing note of its report.
package(doir) enum cycleHint = "each query in the chain needs the next; break the loop by removing one of those dependencies, such as an import that leads back to its own file";

/// How to fix demands nested past the depth limit, the closing note of its report.
package(doir) enum depthHint = "nest these declarations or imports less deeply, or raise the engine's depth limit";

// Records a `Q-Cycle` error naming the frames from `from` up and back.
// On refusal returns false, failing the running queries so none memoizes without it.
private bool reportChain(ref QueryEngine engine, const(char)[] headline, size_t from) {
	assert(from < fp.dynarray.length(local.stack), "doir.query: a chain starting past the running queries");
	assert(headline.length > 0, "doir.query: a chain with no headline");
	auto copiedHeadline = fp.string.clone(headline);
	if (copiedHeadline.isNull) {
		fail(engine);
		return false;
	}
	char* message = copiedHeadline.get;
	bool built = true;
	auto stack = local.stack;
	foreach (frame; stack[from .. fp.dynarray.length(stack)])
		built = built && ecrs.context.getComponent!(doir.components.query.Hooks)(*engine.store, frame.query).appendDescription(engine, frame.query, message)
			&& fp.string.concatenate(message, " -> ");
	immutable head = stack[from].query;
	built = built && ecrs.context.getComponent!(doir.components.query.Hooks)(*engine.store, head).appendDescription(engine, head, message);
	auto copiedHint = built ? fp.string.clone(cycleHint) : typeof(copiedHeadline).init;
	char* hint = copiedHint.isNull ? null : copiedHint.get;
	if (hint !is null) return recordDiagnostic(engine, doir.components.query.QueryDiagnostic([invalidEntity], diagnose.Kind.error, message, hint));
	fp.string.free(message);
	fail(engine);
	return false;
}

// Records an `IL-Chain` error for demands nested past the depth limit at `q`, failing the running queries on a refused allocation as `reportChain` does.
private void reportDepth(ref QueryEngine engine, EntityId q) {
	assert(fp.dynarray.length(local.stack) >= engine.depthLimit, "doir.query: reporting the depth limit before it was reached");
	assert(q != invalidEntity, "doir.query: the depth limit reached at no query");
	auto copiedMessage = fp.string.format("IL-Chain: queries nest deeper than the limit of %llu at ", cast(ulong) engine.depthLimit);
	if (copiedMessage.isNull) {
		fail(engine);
		return;
	}
	char* message = copiedMessage.get;
	bool built = ecrs.context.getComponent!(doir.components.query.Hooks)(*engine.store, q).appendDescription(engine, q, message);
	auto copiedHint = built ? fp.string.clone(depthHint) : typeof(copiedMessage).init;
	char* hint = copiedHint.isNull ? null : copiedHint.get;
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
	return frameOf(engine, q) != notRunning;
}

/// Reports, on the innermost query, that it needs an effect of running query `q` (`Q-Cycle`), naming the chain from `q` up, and marks that chain as part of a cycle.
/// Returns false on a refused allocation, which fails the running queries (`fail`) rather than lose the report.
///
/// Examples:
/// ---
/// static import fp.dynarray;
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
/// assert(fp.dynarray.length(manager.diagnostics) == 1);
/// ---
package(doir) bool reportRunning(ref QueryEngine engine, EntityId q) {
	immutable h = frameOf(engine, q);
	assert(h != notRunning, "doir.query: reporting a cycle through a query this thread does not run");
	assert(h < fp.dynarray.length(local.stack), "doir.query: a cycle's frame past the running queries");
	if (deferringReports) {
		abandon(engine);
		return false;
	}
	foreach (ref frame; local.stack[h .. fp.dynarray.length(local.stack)]) frame.cycle = true;
	return reportChain(engine, "Q-Cycle: a read needs an effect of a query that is still running: ", h);
}

// True if no dependency changed since `q` was verified, refreshing dependencies first (early cutoff); sets `withheld` and appends deferred diagnostics to `reporting`.
// False on refusal.
private bool dependenciesUnchanged(ref QueryEngine engine, EntityId q, ref bool withheld, ref EntityId* reporting) {
	immutable verified = ecrs.context.getComponent!(doir.components.query.Verification)(*engine.store, q).revision;
	assert(verified != 0 && verified <= engine.revision, "doir.query: checking the dependencies of a query never verified, or verified in the future");
	immutable n = fp.dynarray.length(ecrs.context.getComponent!(doir.components.query.Reads)(*engine.store, q).related);
	foreach (i; 0 .. n) {
		immutable d = ecrs.context.getComponent!(doir.components.query.Reads)(*engine.store, q).related[i];
		auto info = ecrs.context.findComponent!(doir.components.query.Hooks)(*engine.store, d);
		if (info !is null) {
			if (!info.bringUpToDate(engine, d)) return false;
			withheld = withheld || ecrs.context.getComponent!(doir.components.query.Claim)(*engine.store, d).reportsDeferred;
			if (core.atomic.atomicLoad(bc.platform.asShared(ecrs.context.getComponent!(doir.components.query.Verification)(*engine.store, d).reports)) && !fp.dynarray.pushBack(reporting, d)) return false;
		}
		auto changed = ecrs.context.findComponent!(doir.components.query.ChangedAt)(*engine.store, d);
		if (changed !is null && core.atomic.atomicLoad(bc.platform.asShared(changed.revision)) > verified) return false;
		assert(changed is null || core.atomic.atomicLoad(bc.platform.asShared(changed.revision)) <= engine.revision, "doir.query: an entity changed in a revision not yet begun");
	}
	return true;
}

// Whether `q` is current without checking dependencies: run before, not stale, no edge missing, not in a cycle; reuse still walks its diagnostics (`ReportingReads`).
private bool reusableUnchecked(ref QueryEngine engine, EntityId q) {
	assert(q != invalidEntity, "doir.query: reusing no query");
	auto verified = &ecrs.context.getComponent!(doir.components.query.Verification)(*engine.store, q);
	return core.atomic.atomicLoad(bc.platform.asShared(verified.revision)) != 0 && !core.atomic.atomicLoad(bc.platform.asShared(verified.stale))
		&& !core.atomic.atomicLoad(bc.platform.asShared(engine.edgesMissing)) && !ecrs.context.hasComponent!(doir.components.query.InCycle)(*engine.store, q);
}

// Whether `q` is current and no query below it holds diagnostics, so reusing it visits nothing.
private bool reusableSilently(ref QueryEngine engine, EntityId q) {
	return reusableUnchecked(engine, q) && !core.atomic.atomicLoad(bc.platform.asShared(ecrs.context.getComponent!(doir.components.query.Verification)(*engine.store, q).reportsBelow));
}

// Records `q` current in this revision with `reporting` as its `ReportingReads`; the caller frees the list it replaced.
// The revision is released last.
private void markVerified(ref QueryEngine engine, EntityId q, ref EntityId* reporting) {
	assert(engine.revision != 0, "doir.query: verifying in revision 0, which reads as never verified");
	auto verified = &ecrs.context.getComponent!(doir.components.query.Verification)(*engine.store, q);
	auto list = &ecrs.context.getForWriting!(doir.components.query.ReportingReads)(*engine.store, q).related;
	auto old = *list;
	*list = reporting;
	reporting = old;
	immutable below = fp.dynarray.length(*list) != 0;
	immutable reports = below || fp.dynarray.length(ecrs.context.getComponent!(doir.components.query.QueryDiagnostics)(*engine.store, q).items);
	// Whether it reports is not part of its value, so its readers, which may be reused without walking to it, are told when that changes.
	immutable flipped = reports != core.atomic.atomicLoad(bc.platform.asShared(verified.reports));
	core.atomic.atomicStore(bc.platform.asShared(verified.reportsBelow), below);
	core.atomic.atomicStore(bc.platform.asShared(verified.reports), reports);
	if (flipped) markReadersStale(engine, q);
	core.atomic.atomicStore(bc.platform.asShared(verified.stale), false);
	core.atomic.atomicStore(bc.platform.asShared(verified.revision), engine.revision);
	assert(core.atomic.atomicLoad(bc.platform.asShared(verified.reports)) == reports, "doir.query: whether a query reports changed under its verification");
}

private void clearProvisional(ref QueryEngine engine, EntityId p) {
	if (!ecrs.context.hasComponent!(doir.components.query.ProvisionalOn)(*engine.store, p)) return;
	beginExclusive(engine);
	cast(void) ecrs.context.removeComponent!(doir.components.query.ProvisionalOn)(*engine.store, p);
	endExclusive(engine);
	assert(!ecrs.context.hasComponent!(doir.components.query.ProvisionalOn)(*engine.store, p), "doir.query: a provisional mark that survived clearing");
}

// Settles queries resting on `self`'s fallback, moving those a lower fallback still holds up.
// Returns false on refusal, discarding any it could not move.
private bool settleProvisional(ref QueryEngine engine, ref Frame self, size_t index, bool fallbackHeld) {
	if (!self.usedAsHead) return true;
	assert(self.head == notRunning || self.head <= index, "doir.query: a frame whose head is above it");
	bool moved = true;
	immutable lower = self.head < index;
	foreach (p; fp.dynarray.slice(self.provisional)) {
		if (fallbackHeld && lower && moved) {
			ecrs.context.getForWriting!(doir.components.query.ProvisionalOn)(*engine.store, p).head = local.stack[self.head].query;
			if (fp.dynarray.pushBack(local.stack[self.head].provisional, p)) continue;
			moved = false;
		}
		clearProvisional(engine, p);
		if (!fallbackHeld || lower) ecrs.context.getComponent!(doir.components.query.Hooks)(*engine.store, p).reset(engine, p);
	}
	fp.dynarray.free(self.provisional);
	return moved;
}

// Marks `q` provisional if it rests on a lower frame's fallback, and tags it if its run joined a cycle.
// Returns false on refusal.
private bool markCycle(ref QueryEngine engine, EntityId q, ref Frame self, size_t index) {
	assert(self.query == q, "doir.query: marking a cycle on a frame of another query");
	if (self.head < index) {
		auto head = &local.stack[self.head];
		beginExclusive(engine);
		auto mark = ecrs.context.ensureComponent!(doir.components.query.ProvisionalOn)(*engine.store, q);
		endExclusive(engine);
		if (mark is null) return false;
		mark.head = head.query;
		if (!fp.dynarray.pushBack(head.provisional, q)) {
			clearProvisional(engine, q);
			return false;
		}
	}
	immutable tagged = ecrs.context.hasComponent!(doir.components.query.InCycle)(*engine.store, q);
	if (self.cycle == tagged) return true;
	beginExclusive(engine);
	scope(exit) endExclusive(engine);
	if (self.cycle) return ecrs.context.addComponent!(doir.components.query.InCycle)(*engine.store, q) !is null;
	cast(void) ecrs.context.removeComponent!(doir.components.query.InCycle)(*engine.store, q);
	return true;
}

// Stores `value`, taken over, as `q`'s; if it or what `q` produced changed (early cutoff), records the revision and marks `q`'s readers stale.
private void storeValue(Q)(ref QueryEngine engine, EntityId q, ref Q.Value value, bool fresh) {
	auto store = engine.store;
	auto stored = &ecrs.context.getForWriting!(doir.components.query.QueryValue!Q)(*store, q);
	immutable hash = hashProduced(engine, q);
	auto produces = &ecrs.context.getForWriting!(doir.components.query.Outputs)(*store, q);
	bool changed = fresh || produces.hash != hash;
	produces.hash = hash;
	if (fresh || !valuesEqual!Q(stored.value, value)) {
		fp.lifecycle.moveInto(stored.value, value);
		changed = true;
	} else fp.lifecycle.endLifetime(value);
	if (!changed) return;
	core.atomic.atomicStore(bc.platform.asShared(ecrs.context.getForWriting!(doir.components.query.ChangedAt)(*store, q).revision), engine.revision);
	markReadersStale(engine, q);
}

// Runs `q`, claimed by this thread, and stores its value.
// False, leaving `q` reset, if a refused allocation failed the run.
private bool execute(Q)(ref QueryEngine engine, EntityId q) {
	auto store = engine.store;
	assert(frameOf(engine, q) == notRunning, "doir.query: running a query that is already running");
	assert(core.atomic.atomicLoad(bc.platform.asShared(ecrs.context.getComponent!(doir.components.query.Claim)(*store, q).owner)) == local.self, "doir.query: running a query this thread has not claimed");
	removeProduced(engine, q);
	clearDiagnostics(engine, q);
	clearProvisional(engine, q);
	// What it read before is kept to update its reverse edges against.
	auto deps = &ecrs.context.getForWriting!(doir.components.query.Reads)(*store, q);
	EntityId* before = deps.related;
	deps.related = null;
	scope(exit) fp.dynarray.free(before);
	immutable fresh = ecrs.context.getComponent!(doir.components.query.Verification)(*store, q).revision == 0;

	if (!fp.dynarray.pushBack(local.stack, Frame(q, 0))) {
		deps.related = before;
		before = null;
		fail(engine);
		reset!Q(engine, q);
		return false;
	}
	auto running = &ecrs.context.getForWriting!(doir.components.query.Claim)(*store, q);
	immutable ownFrame = fp.dynarray.length(local.stack) - 1;
	running.frame = ownFrame;
	auto key = ecrs.context.getComponent!(doir.components.query.QueryKey!Q)(*store, q).key;
	auto value = Q.compute(engine, key);
	assert(fp.dynarray.length(local.stack) == ownFrame + 1 && fp.dynarray.back(local.stack).query == q, "doir.query: a query's frame was not on top when it returned");
	auto frame = *fp.dynarray.back(local.stack);
	scope(exit) fp.dynarray.free(frame.reporting); // or the list `markVerified` replaced with it
	cast(void) fp.dynarray.removeLast(local.stack);
	running = &ecrs.context.getForWriting!(doir.components.query.Claim)(*store, q);
	running.frame = notRunning;
	immutable index = fp.dynarray.length(local.stack);

	if (frame.refused) {
		// It keeps what it read before, which its reverse edges still list.
		deps = &ecrs.context.getForWriting!(doir.components.query.Reads)(*store, q);
		fp.dynarray.free(deps.related);
		deps.related = before;
		before = null;
		fp.lifecycle.endLifetime(value);
		cast(void) settleProvisional(engine, frame, index, false);
		reset!Q(engine, q);
		return false;
	}
	assert(frame.query == q && index == ownFrame, "doir.query: a frame popped for another query, or at another depth");
	removeCreated(engine, q, frame.created);
	recordEdges(engine, q, fp.dynarray.slice(before));
	storeValue!Q(engine, q, value, fresh);
	markVerified(engine, q, frame.reporting);
	assert(core.atomic.atomicLoad(bc.platform.asShared(ecrs.context.getComponent!(doir.components.query.Verification)(*store, q).revision)) == engine.revision, "doir.query: a run that left its query unverified");

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
	emitAll(engine, q, frame.reportsDeferredBelow);
	assert(!ecrs.context.hasComponent!(doir.components.query.ProvisionalOn)(*store, q) || frame.head < index, "doir.query: a query marked provisional that rests on no lower fallback");
	return true;
}

// A query verified in this revision is reused; one withholding nothing reports what other threads withheld below it.
private bool flushReusedReports(ref QueryEngine engine, EntityId q) {
	assert(core.atomic.atomicLoad(bc.platform.asShared(ecrs.context.getComponent!(doir.components.query.Verification)(*engine.store, q).revision)) == engine.revision, "doir.query: reusing a query not verified in this revision");
	if (!deferringReports && !engine.settling) flushWithheld(engine, q);
	return true;
}

// Brings `q` up to date, claiming it or waiting for its runner.
// False if this thread runs it, past the depth limit, or failing.
private bool bringUpToDate(Q)(ref QueryEngine engine, EntityId q) {
	if (frameOf(engine, q) != notRunning) return false;
	auto store = engine.store;
	if (core.atomic.atomicLoad(bc.platform.asShared(ecrs.context.getComponent!(doir.components.query.Verification)(*engine.store, q).revision)) == engine.revision) return flushReusedReports(engine, q);
	// Nothing runs an unchanged query, so confirming one with no diagnostics to report needs no claim.
	if (reusableSilently(engine, q) && !core.atomic.atomicLoad(bc.platform.asShared(ecrs.context.getComponent!(doir.components.query.Verification)(*store, q).reports))) {
		core.atomic.atomicStore(bc.platform.asShared(ecrs.context.getComponent!(doir.components.query.Verification)(*store, q).revision), engine.revision);
		return true;
	}
	auto running = &ecrs.context.getComponent!(doir.components.query.Claim)(*store, q);
	bool claimed = false;
	for (;;) {
		if (core.atomic.atomicLoad(bc.platform.asShared(ecrs.context.getComponent!(doir.components.query.Verification)(*engine.store, q).revision)) == engine.revision) return flushReusedReports(engine, q);
		// Met again while this thread validates it: as one thread alone would, the recursion stops at the depth limit.
		if (core.atomic.atomicLoad(bc.platform.asShared(running.owner)) == local.self) break;
		if (core.atomic.cas(&bc.platform.asShared(running.owner), 0u, local.self)) {
			claimed = true;
			break;
		}
		if (!waitForRunner(engine, q)) return false;
	}
	scope(exit) if (claimed) core.atomic.atomicStore(bc.platform.asShared(running.owner), 0u);
	if (core.atomic.atomicLoad(bc.platform.asShared(ecrs.context.getComponent!(doir.components.query.Verification)(*engine.store, q).revision)) == engine.revision) return flushReusedReports(engine, q);
	if (reusableSilently(engine, q)) {
		emitAll(engine, q, false);
		core.atomic.atomicStore(bc.platform.asShared(ecrs.context.getComponent!(doir.components.query.Verification)(*store, q).revision), engine.revision);
		return true;
	}
	if (local.depth >= engine.depthLimit) {
		if (deferringReports) {
			abandon(engine);
			return false;
		}
		reportDepth(engine, q);
		return false;
	}
	assert(local.depth < engine.depthLimit, "doir.query: validating past the depth limit");
	++local.depth;
	scope(exit) --local.depth;
	// Current, so nothing it read changed: only the queries below it holding diagnostics are visited, to report them in order.
	if (reusableUnchecked(engine, q)) {
		core.atomic.atomicStore(bc.platform.asShared(ecrs.context.getComponent!(doir.components.query.Verification)(*store, q).revision), engine.revision);
		bool withheld = false;
		for (size_t i = 0; i < fp.dynarray.length(ecrs.context.getComponent!(doir.components.query.ReportingReads)(*store, q).related); ++i) {
			immutable d = ecrs.context.getComponent!(doir.components.query.ReportingReads)(*store, q).related[i];
			if (!ecrs.context.getComponent!(doir.components.query.Hooks)(*store, d).bringUpToDate(engine, d)) return false;
			withheld = withheld || core.atomic.atomicLoad(bc.platform.asShared(ecrs.context.getComponent!(doir.components.query.Claim)(*store, d).reportsDeferred));
		}
		emitAll(engine, q, withheld);
		return true;
	}
	bool withheld = false;
	EntityId* reporting = null;
	scope(exit) fp.dynarray.free(reporting);
	if (ecrs.context.getComponent!(doir.components.query.Verification)(*store, q).revision == 0 || ecrs.context.hasComponent!(doir.components.query.InCycle)(*store, q)
		|| !dependenciesUnchanged(engine, q, withheld, reporting))
		return execute!Q(engine, q);
	assert(claimed || core.atomic.atomicLoad(bc.platform.asShared(running.owner)) == local.self, "doir.query: verifying a query this thread does not hold");
	emitAll(engine, q, withheld);
	markVerified(engine, q, reporting);
	return true;
}

private void reset(Q)(ref QueryEngine engine, EntityId q) {
	assert(frameOf(engine, q) == notRunning, "doir.query: resetting a query that is running");
	assert(ecrs.context.hasComponent!(doir.components.query.QueryValue!Q)(*engine.store, q), "doir.query: resetting an entity that is not a query of this type");
	removeProduced(engine, q);
	removeCreated(engine, q, 0);
	clearDiagnostics(engine, q);
	clearProvisional(engine, q);
	// The value stays as a component, emptied, so re-running `q` never adds one.
	auto stored = &ecrs.context.getForWriting!(doir.components.query.QueryValue!Q)(*engine.store, q);
	fp.lifecycle.endLifetime(stored.value);
	stored.value = Q.Value.init;
	core.atomic.atomicStore(bc.platform.asShared(ecrs.context.getComponent!(doir.components.query.Verification)(*engine.store, q).revision), Revision(0));
	// Its next run may answer differently.
	markReadersStale(engine, q);
	assert(fp.dynarray.length(ecrs.context.getComponent!(doir.components.query.Outputs)(*engine.store, q).items) == 0, "doir.query: a reset query that kept its outputs");
}

// A demand for `q`, which is running in frame `h`: every frame from `h` up is part of the cycle.
private const(Q.Value)* cycle(Q)(ref QueryEngine engine, EntityId q, size_t h) {
	assert(fp.dynarray.length(local.stack) > 0 && h < fp.dynarray.length(local.stack), "doir.query: a cycle through a frame past the running queries");
	assert(local.stack[h].query == q, "doir.query: a cycle's frame runs another query");
	immutable top = fp.dynarray.length(local.stack) - 1;
	foreach (ref frame; local.stack[h .. top + 1]) frame.cycle = true;
	if (!read(engine, q)) return null;
	static if (__traits(hasMember, Q, "cycleFallback")) {
		static Q.Value fallback; // one per thread
		fp.lifecycle.endLifetime(fallback);
		fallback = Q.cycleFallback(engine, ecrs.context.getComponent!(doir.components.query.QueryKey!Q)(*engine.store, q).key);
		local.stack[h].usedAsHead = true;
		if (h < top && h < local.stack[top].head) local.stack[top].head = h;
		return &fallback;
	} else {
		cast(void) reportChain(engine, "Q-Cycle: a query needs its own answer: ", h); // the demand returns null either way
		return null;
	}
}

// `query` once the calling thread holds the shared section.
private const(Q.Value)* demand(Q)(ref QueryEngine engine, ref const Q.Key key) {
	immutable q = findOrAdd!Q(engine, key);
	if (q == invalidEntity) {
		fail(engine);
		return null;
	}
	immutable h = frameOf(engine, q);
	if (h != notRunning) {
		if (!deferringReports) return cycle!Q(engine, q, h);
		abandon(engine);
		return null;
	}
	if (!bringUpToDate!Q(engine, q) || !read(engine, q)) return null;
	if (!runsNoQuery(engine) && core.atomic.atomicLoad(bc.platform.asShared(ecrs.context.getComponent!(doir.components.query.Verification)(*engine.store, q).reports))) {
		auto top = fp.dynarray.back(local.stack);
		immutable n = fp.dynarray.length(top.reporting);
		if ((n == 0 || top.reporting[n - 1] != q) && !fp.dynarray.pushBack(top.reporting, q)) {
			fail(engine);
			return null;
		}
	}
	if ((deferringReports || engine.settling) && !runsNoQuery(engine) && core.atomic.atomicLoad(bc.platform.asShared(ecrs.context.getComponent!(doir.components.query.Claim)(*engine.store, q).reportsDeferred)))
		fp.dynarray.back(local.stack).reportsDeferredBelow = true;
	return &ecrs.context.getComponent!(doir.components.query.QueryValue!Q)(*engine.store, q).value;
}

/// The value of `Q` at `key`, computed on first demand and re-validated against the current revision on every later one.
/// Records the read in the running query, if any.
///
/// Any thread may demand at once.
/// A query two threads need runs once, the second waiting for the first, as rustc's `QueryLatch` does; waits that loop across threads are a cycle (`Q-Cycle`), which the thread with the highest owner id in the loop breaks by giving its demand up and making it again once the others have gone on, so it meets the cycle on one thread as a single-threaded engine would.
/// A top-level demand first settles stale queries (`revalidateStale`) if no other thread demands; concurrent demands are as independent of each other as a `demandEach` batch's.
/// Diagnostics are reported as each demand finds them, so concurrent demands' interleave; `demandEach` keeps the order of its keys.
///
/// A demand for a query that is already running is a cycle (`Q-Cycle`).
/// If `Q` declares `cycleFallback`, the demand gets that value, and every query whose value rests on it stays provisional until the running one finishes: if its answer equals the fallback they are kept, and otherwise they are reset, to run again on their next demand.
/// This suits a fallback that assumes the coinductive answer, as structural equivalence assumes a pair under comparison equal (`S-Struct`, `TF-Self`).
/// Without a fallback, the cycle is reported as an error naming the chain of queries that closes it, and the demand returns null.
/// A demand nested deeper than `engine.depthLimit` is reported and returns null too, rather than overflowing the stack.
/// So does a demand whose run, or any run below it, met a refused allocation (`fail`); then `engine.refused` is set.
///
/// The pointer is valid while the query entity exists, holding the value of its latest run in this revision, or for a fallback, until the calling thread's next fallback of `Q`.
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
	assert(engine.store !is null, "doir.query: demanding on an engine with no store");
	if (!runsNoQuery(engine)) {
		safepoint(engine);
		return demand!Q(engine, key);
	}
	// A demand given up to break a wait cycle starts again, once the threads it waited on have gone on.
	immutable reading = sharing(engine);
	for (;;) {
		if (reading) safepoint(engine);
		else beginReading(engine);
		local.abandoned = false;
		auto value = demand!Q(engine, key);
		immutable abandoned = local.abandoned;
		if (!reading) endReading(engine);
		assert(reading == sharing(engine), "doir.query: a demand that changed whether this thread shares the engine");
		if (!abandoned || deferringReports) return value;
		bc.thread.yield();
	}
}

/// Joins the shared section of `engine` outside any demand, until `endReading`, so the calling thread may read the store while other threads demand, as a system's function reading components between its demands must.
/// Demands made meanwhile nest in it.
/// It counts as demanding: no input commit, new revision or renumbering happens until it ends.
/// The calling thread must not be running a query or already reading.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = create(store);
/// scope(exit) free(engine);
/// immutable e = ecrs.context.addEntity(store);
/// beginReading(engine);
/// assert(!ecrs.context.hasComponent!int(store, e));
/// endReading(engine);
/// ---
void beginReading(ref QueryEngine engine) {
	assert(runsNoQuery(engine) && !sharing(engine), "doir.query: reading inside a query or another reading");
	// A top-level demand starts here too, settling first if no other thread demands.
	for (;;) {
		revalidateIfAlone(engine);
		joinDemand(engine);
		if (!core.atomic.atomicLoad(bc.platform.asShared(engine.demandsBlocked))) {
			assert(sharing(engine), "doir.query: reading without sharing the engine");
			return;
		}
		leaveDemand(engine);
		while (core.atomic.atomicLoad(bc.platform.asShared(engine.demandsBlocked))) bc.thread.yield();
	}
}

/// Ditto
void endReading(ref QueryEngine engine) {
	assert(sharing(engine) && runsNoQuery(engine), "doir.query: endReading without beginReading");
	leaveDemand(engine);
	assert(!sharing(engine), "doir.query: still sharing the engine after endReading");
}

/// Brings every stale query that another query reads up to date (`markReadersStale`), so that afterwards a query that is not stale is current and is reused without visiting its dependencies.
/// One nothing reads stays stale until it is demanded, as everything not reached by a change stays unrun.
/// One whose value changes marks its dependents stale in turn; one that keeps its value stops the change there (early cutoff).
/// Their diagnostics are withheld until a demand reaches them, to be reported in the order that demand would report them.
/// Each stale query of a type declaring `static void onStale(ref QueryEngine, Key)` is passed to it as it is taken, whether or not anything reads it, as a system learns which of its memos to visit (`doir.schedules.runSystem`); it runs on the settling thread alone, and may write the store but not change its structure.
/// A top-level demand calls it first when no other thread demands, keeping any from starting until it is done.
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
/// assert(revalidateStale(engine));
/// ---
package(doir) bool revalidateStale(ref QueryEngine engine) {
	assert(runsNoQuery(engine), "doir.query: settling inside a query");
	if (!attached(engine) || !local.holding) {
		revalidateIfAlone(engine);
		return !core.atomic.atomicLoad(bc.platform.asShared(engine.edgesMissing));
	}
	assert(core.atomic.atomicLoad(bc.platform.asShared(engine.demandsBlocked)), "doir.query: settling while other threads may demand");
	if (fp.dynarray.length(bc.monitor.read(engine.staleQueue).value) == 0) return true;
	engine.settling = true;
	scope(exit) engine.settling = false;
	for (;;) {
		EntityId q;
		// Popped under a brief hold: refreshing `q` below may queue more.
		{
			auto pending = bc.monitor.write(engine.staleQueue);
			if (fp.dynarray.length(pending.value) == 0) break;
			q = *fp.dynarray.back(pending.value);
			cast(void) fp.dynarray.removeLast(pending.value);
		}
		assert(core.atomic.atomicLoad(bc.platform.asShared(engine.staleQueued)) > 0, "doir.query: more stale queries popped than were queued");
		core.atomic.atomicOp!"-="(bc.platform.asShared(engine.staleQueued), 1);
		auto verified = ecrs.context.findComponent!(doir.components.query.Verification)(*engine.store, q);
		auto info = ecrs.context.findComponent!(doir.components.query.Hooks)(*engine.store, q);
		if (info !is null && info.stale !is null) info.stale(engine, q);
		// One never run or reset since runs when demanded, and one nothing reads cannot pass a change on, so it waits for its demand too.
		auto readers = ecrs.context.findComponent!(doir.components.query.ReadBy)(*engine.store, q);
		if (verified is null || info is null || verified.revision == 0 || !verified.stale || readers is null || fp.dynarray.length(readers.related) == 0) continue;
		if (!info.bringUpToDate(engine, q)) {
			engine.edgesMissing = true;
			fp.dynarray.clear(bc.monitor.write(engine.staleQueue).value);
			core.atomic.atomicStore(bc.platform.asShared(engine.staleQueued), size_t(0));
			return false;
		}
	}
	return true;
}

/// Frees what the query entity of `Q` at `key` holds: its value, diagnostics, the components it produced and the entities it created.
/// The entity keeps its key and `ChangedAt`, so dependents still see it, and the next demand re-runs it.
/// Does nothing if `Q` was never demanded at `key`.
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
	assert(core.atomic.atomicLoad(bc.platform.asShared(engine.demandingThreads)) == 0, "doir.query: evicting while threads demand");
	immutable q = find!Q(engine, key);
	if (q == invalidEntity) return;
	reset!Q(engine, q);
	assert(!reusableUnchecked(engine, q), "doir.query: an evicted query still reusable");
}

/// Whether `Q` at `key` holds a value a demand would reuse without running anything or checking its dependencies: nothing it depends on changed since it was last verified.
/// A demand still walks to the queries below it that hold diagnostics, to report them, visiting only those (`ReportingReads`).
/// A walk over many queries can skip those, and batch the rest with `demandEach`.
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
	revalidateIfAlone(engine);
	immutable q = find!Q(engine, key);
	return q != invalidEntity && reusableUnchecked(engine, q);
}

// A run of a batch's keys one worker demands in turn, and which of them it gave up.
private struct Share(Q) {
	const(Q.Key)[] keys;
	bool[] gaveUp;
}

// A batch's share on a worker: its diagnostics withheld for the batch's order, its cycles left to the serial pass.
private bool demandShare(Q)(ref QueryEngine engine, ref Share!Q share) {
	assert(share.keys.length == share.gaveUp.length, "doir.query: a share whose keys and outcomes disagree");
	immutable outer = deferringReports;
	deferringReports = true;
	scope(exit) deferringReports = outer;
	// One section for the share, so its demands nest in it rather than each joining the engine.
	beginReading(engine);
	scope(exit) endReading(engine);
	foreach (i, ref key; share.keys) {
		cast(void) query!Q(engine, key);
		share.gaveUp[i] = local.abandoned;
	}
	return !core.atomic.atomicLoad(bc.platform.asShared(engine.refused));
}

// Shares per worker, so one finishing early takes another; each share is a pool job, dearer than a reused demand.
private enum size_t sharesPerWorker = 8;

/// Demands `Q` at each of `keys`, as calling `query` on each in turn would, its diagnostics reported in that order, but on `engine.workers` when it has two or more, through `ecrs.schedules.parallel`: each worker takes demands as it frees up, withholding their diagnostics, and a query two of them need runs once while the other waits for it.
/// A worker meeting a cycle (`Q-Cycle`) or the depth limit gives its demand up.
/// The calling thread then demands each key in order, finishing what workers gave up and reporting what they withheld, so a batch reports what one thread would, in the same order.
/// Values are read afterwards with `query`, which finds them up to date.
/// The calling thread must not be running a query.
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
	assert(runsNoQuery(engine), "doir.query: a batch of demands inside a query");
	revalidateIfAlone(engine);
	immutable workers = engine.workers is null ? 1 : bc.threadpool.workerCount(engine.workers);
	bool serially() {
		foreach (key; keys)
			if (query!Q(engine, key) is null && core.atomic.atomicLoad(bc.platform.asShared(engine.refused))) return false;
		return !core.atomic.atomicLoad(bc.platform.asShared(engine.refused));
	}
	if (workers < 2 || keys.length < 2) return serially();
	immutable count = keys.length < workers * sharesPerWorker ? keys.length : workers * sharesPerWorker;
	mixin fp.pointer.allocateOnStack!(Share!Q, "shares", "count"); // at most `sharesPerWorker` per worker
	bool* gaveUp = fp.dynarray.create!bool(keys.length);
	scope(exit) fp.dynarray.free(gaveUp);
	if (gaveUp is null) return serially();
	foreach (i; 0 .. count) {
		immutable from = keys.length * i / count, to = keys.length * (i + 1) / count;
		assert(from <= to && to <= keys.length, "doir.query: a share past the batch");
		shares[i] = Share!Q(keys[from .. to], gaveUp[from .. to]);
	}
	assert(count >= 1 && count <= workers * sharesPerWorker, "doir.query: more shares than the workers take");
	gaveUp[0 .. keys.length] = true; // a share the pool never ran gave up every demand
	cast(void) ecrs.schedules.parallel!(demandShare!Q)(engine, engine.workers, shares[0 .. count]);
	// Each demand given up runs here, and every other reports what the workers withheld below it, in order.
	foreach (i, ref key; keys) {
		if (gaveUp[i]) {
			if (query!Q(engine, key) is null && core.atomic.atomicLoad(bc.platform.asShared(engine.refused))) return false;
		} else {
			immutable q = find!Q(engine, key);
			if (q != invalidEntity) flushWithheld(engine, q);
		}
	}
	return !core.atomic.atomicLoad(bc.platform.asShared(engine.refused));
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
	assert(out_.revision >= 1 && out_.depthLimit == defaultDepthLimit, "doir.query: an engine that starts in revision 0, or with another depth limit");
	return out_;
}

/// Releases the engine's own memory and its positions.
/// Query entities stay in the store.
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
	assert(core.atomic.atomicLoad(bc.platform.asShared(engine.demandingThreads)) == 0, "doir.query: freeing an engine while threads demand");
	assert(!attached(engine) || !local.holding, "doir.query: freeing an engine this thread still reads");
	fp.dynarray.free(bc.monitor.write(engine.staleQueue).value);
	fp.dynarray.free(bc.monitor.write(engine.changes).value.entries);
	doir.engine.positions.free(engine.positions);
}


// --- inputs ------------------------------------------------------------------

// Empties the change log, so unread systems visit their whole domain next; with `lost`, read ones too.
// Takes the log's hold itself.
private void dropChanges(ref QueryEngine engine, bool lost) {
	auto log = bc.monitor.write(engine.changes);
	immutable base = log.value.base;
	log.value.base += fp.dynarray.length(log.value.entries) + lost;
	fp.dynarray.clear(log.value.entries);
	assert(log.value.base >= base, "doir.query: the change log's base wrapped");
}

/// Starts a new revision.
/// Call once per batch of input changes (one input commit), before `markChanged`, while no thread demands.
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
	assert(core.atomic.atomicLoad(bc.platform.asShared(engine.demandingThreads)) == 0, "doir.query: a new revision while threads demand");
	immutable before = engine.revision;
	++engine.revision;
	assert(engine.revision > before, "doir.query: revisions wrapped");
	// Past one entry per entity, reading the log costs a system more than visiting its whole domain does.
	immutable logged = fp.dynarray.length(bc.monitor.read(engine.changes).value.entries);
	if (logged > ecrs.context.entityCount(*engine.store)) dropChanges(engine, false);
	assert(fp.dynarray.length(bc.monitor.read(engine.changes).value.entries) <= ecrs.context.entityCount(*engine.store), "doir.query: a change log longer than the store");
}

/// Records that input entity `e` changed in the current revision, and marks every query that depends on it stale (`markReadersStale`), so the next demand of one checks it again; a query no change reaches is reused without visiting its dependencies.
/// An input commit calls this for every entity it creates or whose components it replaces, since a freed id may be handed out again.
/// It logs `e` too, so systems learn what entered their domains (`changesSince`).
/// Returns false if the store refused the record, leaving `e` as it was.
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
	assert(core.atomic.atomicLoad(bc.platform.asShared(engine.demandingThreads)) == 0, "doir.query: an input changed while threads demand");
	// Set rather than written in place, so a transaction around an input commit can undo it; a stale mark it leaves only costs a check.
	assert(e != invalidEntity, "doir.query: marking no entity changed");
	if (!ecrs.context.setComponent!(doir.components.query.ChangedAt)(*engine.store, e, doir.components.query.ChangedAt(engine.revision))) return false;
	assert(changedAt(engine, e) == engine.revision, "doir.query: a change not recorded in this revision");
	markReadersStale(engine, e);
	immutable logged = fp.dynarray.pushBack(bc.monitor.write(engine.changes).value.entries, e);
	if (!logged) dropChanges(engine, true); // the systems reading it visit everything instead
	return true;
}

/// Where a system's next read of the change log starts, and what it read: `entities`, recorded by `markChanged` from `cursor` on, unless `complete` is false, when the log has dropped some of them since and the reader must visit every entity it would have learned of.
package(doir) struct Changes {
	const(EntityId)[] entities; /// What changed, oldest first; valid until the next `markChanged`, `beginRevision` or renumbering.
	size_t next; /// The cursor past them, for the next read.
	bool complete; /// Whether `entities` holds every change since `cursor`.
}

/// The entities `markChanged` recorded since `cursor`, a `Changes.next` from an earlier read, or 0 for every one still logged; incomplete when the log has dropped some of them since, as it does when it outgrows the store, a record is refused, or the store is renumbered.
/// No thread may be committing.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = create(store);
/// scope(exit) free(engine);
/// immutable e = ecrs.context.addEntity(store);
/// immutable before = changesSince(engine, 0).next;
/// assert(markChanged(engine, e));
/// auto read = changesSince(engine, before);
/// assert(read.complete && read.entities == [e] && changesSince(engine, read.next).entities.length == 0);
/// ---
package(doir) Changes changesSince(ref QueryEngine engine, size_t cursor) {
	auto log = bc.monitor.read(engine.changes);
	auto entries = fp.dynarray.slice(log.value.entries);
	immutable base = log.value.base, end = base + entries.length;
	assert(end >= base, "doir.query: a change log whose end wrapped");
	if (cursor < base || cursor > end) return Changes(null, end, false);
	auto changes = Changes(entries[cursor - base .. $], end, true);
	assert(changes.entities.length == end - cursor, "doir.query: changes that do not reach the cursor");
	return changes;
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

/// Adds component `C` to `e` on behalf of the running query, which owns it: it is removed before the query runs again and when the query is evicted.
/// `e` must not already have a `C`.
/// Its contents count toward early cutoff, hashed by `C.contentHash(ref const C)` if `C` declares one and by their bytes otherwise, so a component holding pointers should declare one.
/// Returns null on a refused allocation, which fails the running queries (`fail`).
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
	assert(e != invalidEntity, "doir.query: producing a component on no entity");
	immutable id = ecrs.registry.componentId!C();
	assert(id != fp.pointer.notFound, "doir.query: producing a component the registry refused");
	if (!recordOutput(engine, doir.components.query.Output([e], id, &removeOwnedComponent, &hashComponent!C), true)) return null;
	beginExclusive(engine);
	auto component = ecrs.context.addComponent!C(*engine.store, e);
	endExclusive(engine);
	if (component is null) fail(engine);
	return component;
}

/// Creates an entity owned by the running query, with a `Provenance` naming `origin`, the entity it is derived from.
/// The n-th call in a run returns the entity the n-th call returned in the previous run, so values holding created ids stay equal across re-runs (as rustc's `create_def` does).
/// Returns `invalidEntity` on a refused allocation, which fails the running queries (`fail`).
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
	assert(ecrs.context.getComponent!(doir.components.query.Provenance)(*engine.store, e).origin == origin, "doir.query: a created entity that forgot its origin");
	return e;
}

/// Another entity a reported diagnostic involves, `target`, with what part it plays, such as "first made visible here".
struct Related {
	mixin ecrs.relation.Relates!"target";
	const(char)[] message; /// What part it plays.
}

/// Reports a diagnostic about `subject` (`invalidEntity` for none), with `hint` saying how to fix it, drawn as an annotation at `subject`, and an annotation at each of the `related` entities.
/// A `subject` without a location gets the hint as its closing note instead (`AGENTS.md`, Diagnostics).
/// Inside a query it is stored on the running query entity and reported again whenever that memo is reused in a later revision, so a cached answer reports what a fresh one does; outside any query it goes straight to `engine.diagnostics`.
/// Returns false on a refused allocation, which loses the diagnostic and fails the running queries (`fail`).
///
/// Examples:
/// ---
/// static import fp.dynarray;
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
/// assert(fp.dynarray.length(manager.diagnostics) == 1 && fp.string.slice(manager.diagnostics[0].note) == "be less careless");
/// ---
bool report(ref QueryEngine engine, EntityId subject, diagnose.Kind kind, const(char)[] message, const(char)[] hint, const(Related)[] related = null) {
	assert(hint.length, "every diagnostic says how to fix it");
	assert(message.length, "doir.query.report: a diagnostic with no message");
	foreach (r; related) assert(r.message.length && r.target != invalidEntity, "doir.query.report: a related item with no message or no target");
	auto copiedMessage = fp.string.clone(message);
	auto copiedHint = fp.string.clone(hint);
	if (copiedMessage.isNull || copiedHint.isNull) {
		if (!copiedMessage.isNull) fp.string.free(copiedMessage.get);
		if (!copiedHint.isNull) fp.string.free(copiedHint.get);
		fail(engine);
		return false;
	}
	auto d = doir.components.query.QueryDiagnostic([subject], kind, copiedMessage.get, copiedHint.get);
	bool ok = related.length == 0 || fp.dynarray.reserve(d.annotations, related.length) !is null;
	foreach (r; related) {
		if (!ok) break;
		auto copied = fp.string.clone(r.message);
		if (copied.isNull) {
			ok = false;
			break;
		}
		auto a = doir.components.query.QueryAnnotation([r.target], copied.get);
		ok = fp.dynarray.pushBack(d.annotations, a); // reserved above
		if (!ok) fp.string.free(a.message);
	}
	if (ok) return recordDiagnostic(engine, d);
	doir.components.query.freeDiagnostic(d);
	fail(engine);
	return false;
}


// --- renumbering -------------------------------------------------------------

/// Renumbers the store's entities, `order[i]` being the entity that becomes `i`, as `ecrs.context.reorderEntities` does: every entity-valued component, query keys, values, dependencies, tables and effect logs included, in one step (`E-Remap`).
/// Only between levels or edits: no thread may be demanding.
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
	assert(core.atomic.atomicLoad(bc.platform.asShared(engine.demandingThreads)) == 0, "doir.query: renumbering while threads demand (E-Remap)");
	// Pending stale queries are held by id, so they are brought up to date first.
	cast(void) revalidateStale(engine); // a failure is recorded in `edgesMissing`
	// The change log holds ids too, and dropping it makes each system visit its whole domain (E-Remap).
	dropChanges(engine, false);
	assert(fp.dynarray.length(bc.monitor.read(engine.changes).value.entries) == 0, "doir.query: change log ids kept across a renumbering");
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
	assert(core.atomic.atomicLoad(bc.platform.asShared(engine.demandingThreads)) == 0, "doir.query: renumbering while threads demand (E-Remap)");
	// Pending stale queries are held by id, so they are brought up to date first.
	cast(void) revalidateStale(engine); // a failure is recorded in `edgesMissing`
	dropChanges(engine, false); // its ids, as `renumber` drops them (E-Remap)
	assert(fp.dynarray.length(bc.monitor.read(engine.changes).value.entries) == 0, "doir.query: change log ids kept across a compaction");
	return ecrs.context.compact(*engine.store);
}


version(unittest) {
	static import fp.dynarray;

	static import fp.pointer;
	static import doir.testing;

	private shared int runs; // bumped by queries some tests run on several threads

	private struct Amount {
		int value;
	}


	private struct Input {
		alias Key = ecrs.relation.Relation!1;
		alias Value = int;
		static int compute(ref QueryEngine engine, Key key) @nogc nothrow {
			immutable e = key.related[0];
			core.atomic.atomicOp!"+="(runs, 1);
			if (!read(engine, e)) return 0;
			return ecrs.context.getComponent!Amount(*engine.store, e).value;
		}
	}

	private struct IsPositive {
		alias Key = ecrs.relation.Relation!1;
		alias Value = bool;
		static bool compute(ref QueryEngine engine, Key key) @nogc nothrow {
			immutable e = key.related[0];
			core.atomic.atomicOp!"+="(runs, 1);
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
			core.atomic.atomicOp!"+="(runs, 1);
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
			core.atomic.atomicOp!"+="(runs, 1);
			auto e = createEntity(engine, invalidEntity);
			if (e == invalidEntity) return Value.init; // refused, or given up to break a wait cycle
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
			assert(recordOutput(engine, doir.components.query.Output([e], ecrs.registry.componentId!Amount(), &strip, &hash), false));
			assert(recordOutput(engine, doir.components.query.Output([e], ecrs.registry.componentId!Amount(), &strip, &hash), false));
			return true;
		}
	}

	// Reads the Amount Copy produced, through Copy, so Copy's produced contents decide whether it re-runs.
	private struct CopiedAmount {
		alias Key = ecrs.relation.Relation!1;
		alias Value = int;
		static int compute(ref QueryEngine engine, Key key) @nogc nothrow {
			immutable knob = key.related[0];
			core.atomic.atomicOp!"+="(runs, 1);
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
			assert(ecrs.context.getComponent!(doir.components.query.Claim)(*engine.store, currentQuery(engine)).frame == key);
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

	private shared int equalRuns;

	// Structural equivalence over the graph, assuming a pair under comparison equal (S-Struct).
	private struct Equal {
		alias Key = Pair;
		alias Value = bool;
		static bool cycleFallback(ref QueryEngine engine, Pair key) @nogc nothrow { return true; }
		static bool compute(ref QueryEngine engine, Pair key) @nogc nothrow {
			core.atomic.atomicOp!"+="(equalRuns, 1);
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
				auto text = fp.string.joined("fan ", key);
				if (text.isNull) return 0;
				scope(exit) fp.string.free(text.get);
				if (!report(engine, invalidEntity, diagnose.Kind.warning, fp.string.slice(text.get), "fan less")) return 0;
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
			if (!recordOutput(engine, doir.components.query.Output([e], ecrs.registry.componentId!Amount(), &Stamp.strip, &Stamp.hash), true)) return false;
			// Not through `produce`, so it takes the exclusive section itself, as a query adding a component on its own must.
			beginExclusive(engine);
			doir.testing.addComponent!Amount(*engine.store, e).value = 9;
			endExclusive(engine);
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
			assert(fp.string.concatenate(joined, fp.string.slice(d.message)));
			assert(fp.string.concatenate(joined, "\n"));
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
	ecrs.context.getForWriting!Amount(store, e).value = 3;
	assert(markChanged(engine, e));
	assert(*query!Sign(engine, Sign.Key([e])) == 1);
	assert(runs == 4);

	// A new positive value: Input and IsPositive re-run, and IsPositive's equal value cuts Sign off.
	beginRevision(engine);
	ecrs.context.getForWriting!Amount(store, e).value = 5;
	assert(markChanged(engine, e));
	assert(*query!Sign(engine, Sign.Key([e])) == 1);
	assert(runs == 6);
	assert(fp.dynarray.length(manager.diagnostics) == 0);

	// The answer flips: all three re-run, and IsPositive reports a warning once per revision.
	beginRevision(engine);
	ecrs.context.getForWriting!Amount(store, e).value = -1;
	assert(markChanged(engine, e));
	assert(*query!Sign(engine, Sign.Key([e])) == -1);
	assert(runs == 9);
	assert(*query!Sign(engine, Sign.Key([e])) == -1);
	assert(fp.dynarray.length(manager.diagnostics) == 1);

	// A reused memo reports the same diagnostic as the run that produced it.
	beginRevision(engine);
	assert(*query!Sign(engine, Sign.Key([e])) == -1);
	assert(runs == 9);
	assert(fp.dynarray.length(manager.diagnostics) == 2);
	assert(fp.string.slice(manager.diagnostics[1].message) == "negative");
	assert(manager.diagnostics[1].kind == diagnose.Kind.warning);
	assert(fp.string.slice(manager.diagnostics[1].note) == "make it positive"); // e has no location, so the hint is the note

	// Outside any query a diagnostic goes straight out, with no memo to replay it.
	assert(report(engine, e, diagnose.Kind.note, "direct", "no fix needed"));
	assert(fp.dynarray.length(manager.diagnostics) == 3 && fp.string.slice(manager.diagnostics[2].message) == "direct");
	assert(fp.string.slice(manager.diagnostics[2].note) == "no fix needed");

	// A change is pushed along reverse edges: one to g reaches nothing Sign(e) reads, so Sign(e) is reused without visiting its dependencies.
	beginRevision(engine);
	ecrs.context.getForWriting!Amount(store, e).value = 2;
	assert(markChanged(engine, e));
	immutable g = doir.testing.addEntity(store);
	doir.testing.addComponent!Amount(store, g).value = 1;
	assert(markChanged(engine, g));
	assert(*query!Sign(engine, Sign.Key([e])) == 1 && *query!Sign(engine, Sign.Key([g])) == 1);
	immutable input = find!Input(engine, Input.Key([e]));
	immutable verified = ecrs.context.getComponent!(doir.components.query.Verification)(store, input).revision;
	beginRevision(engine);
	ecrs.context.getForWriting!Amount(store, g).value = 7;
	assert(markChanged(engine, g));
	// Settling re-runs Input(g), which IsPositive(g) reads, and IsPositive(g), whose equal answer stops the change before Sign(g).
	immutable before = runs;
	assert(revalidateStale(engine) && runs == before + 2);
	immutable settled = runs;
	assert(upToDate!Sign(engine, Sign.Key([e])) && upToDate!Sign(engine, Sign.Key([g])));
	assert(*query!Sign(engine, Sign.Key([e])) == 1 && *query!Sign(engine, Sign.Key([g])) == 1 && runs == settled);
	assert(ecrs.context.getComponent!(doir.components.query.Verification)(store, input).revision == verified);

	// Removing an entity marks what read it, since its id may be handed out again.
	beginRevision(engine);
	markReadersStale(engine, g);
	assert(ecrs.context.getComponent!(doir.components.query.Verification)(store, find!Input(engine, Input.Key([g]))).stale);
	assert(*query!Sign(engine, Sign.Key([g])) == 1 && runs == settled); // checked again, nothing it read having changed

	// A query that starts or stops reporting without its value changing still reaches its readers, which report what it does.
	immutable h = doir.testing.addEntity(store);
	doir.testing.addComponent!Amount(store, h).value = 2;
	assert(markChanged(engine, h));
	immutable quiet = fp.dynarray.length(manager.diagnostics);
	assert(*query!Wrap(engine, Wrap.Key([h])) == 0 && fp.dynarray.length(manager.diagnostics) == quiet);
	beginRevision(engine);
	ecrs.context.getForWriting!Amount(store, h).value = 3;
	assert(markChanged(engine, h));
	assert(*query!Wrap(engine, Wrap.Key([h])) == 0 && fp.dynarray.length(manager.diagnostics) == quiet + 1);
	assert(fp.string.slice(manager.diagnostics[quiet].message) == "odd");
	beginRevision(engine);
	ecrs.context.getForWriting!Amount(store, h).value = 4;
	assert(markChanged(engine, h));
	assert(*query!Wrap(engine, Wrap.Key([h])) == 0 && fp.dynarray.length(manager.diagnostics) == quiet + 1);
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
	ecrs.context.getForWriting!Amount(store, knob).value = 2;
	assert(markChanged(engine, knob));
	assert(*query!CopiedAmount(engine, CopiedAmount.Key([knob])) == 2);
	assert(query!Copy(engine, Copy.Key([knob])).related[0] == copy);
	assert(runs == 2);

	// A component recorded twice in one run is owned once, and stripped when the query is evicted.
	immutable stamped = doir.testing.addEntity(store);
	assert(*query!Stamp(engine, Stamp.Key([stamped])));
	assert(ecrs.context.getComponent!Amount(store, stamped).value == 9);
	immutable stamp = find!Stamp(engine, Stamp.Key([stamped]));
	assert(fp.dynarray.length(ecrs.context.getComponent!(doir.components.query.Outputs)(store, stamp).items) == 1);
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
	ecrs.context.getForWriting!Amount(store, listed).value = 4;
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
	ecrs.context.getForWriting!Amount(store, moved).value = -2;
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

	// A read of an entity a compaction freed becomes `invalidEntity`, which neither path that builds reverse edges gives a reader.
	immutable doomed = doir.testing.addEntity(store);
	doir.testing.addComponent!Amount(store, doomed).value = 3;
	assert(markChanged(engine, doomed));
	assert(*query!Sign(engine, Sign.Key([doomed])) == 1);
	assert(ecrs.context.removeEntity(store, doomed));
	assert(compact(engine));
	assert(buildDependents(engine));
	assert(!ecrs.context.hasComponent!(doir.components.query.ReadBy)(store, invalidEntity));

	// A query entity removed before a compaction leaves a dead index entry, which the next demand at its key reuses.
	assert(*query!Resolve(engine, 0) == 0);
	assert(ecrs.context.removeEntity(store, find!Resolve(engine, 0)));
	assert(compact(engine));
	assert(find!Resolve(engine, 0) == invalidEntity);
	assert(*query!Resolve(engine, 0) == 0);
	assert(find!Resolve(engine, 0) != invalidEntity);

	{
		// A query entity never takes a removed input's id: a query that read the input still lists it, and checking that query would run whatever holds the id now.
		auto other = ecrs.context.create();
		scope(exit) ecrs.context.free(other);
		auto engine2 = create(other);
		scope(exit) free(engine2);
		immutable input = doir.testing.addEntity(other);
		doir.testing.addComponent!Amount(other, input).value = 1;
		assert(markChanged(engine2, input));
		assert(*query!Input(engine2, Input.Key([input])) == 1 && *query!Resolve(engine2, 0) == 0);
		assert(ecrs.context.removeEntity(other, input));
		assert(*query!Resolve(engine2, 1) == 0);
		assert(!ecrs.context.hasComponent!(doir.components.query.Hooks)(other, input));
	}
}

unittest { // a thread moving among more engines than it remembers takes its own owner id again on each, never running out
	enum size_t engines = 6;
	ecrs.context.Context[engines] stores;
	QueryEngine[engines] each;
	foreach (i; 0 .. engines) {
		stores[i] = ecrs.context.create();
		each[i] = create(stores[i]);
	}
	scope(exit) foreach (i; 0 .. engines) {
		free(each[i]);
		ecrs.context.free(stores[i]);
	}
	foreach (round; 0 .. 2 * maxThreads)
		foreach (i; 0 .. engines) assert(*query!Resolve(each[i], 0) == 0);
	foreach (i; 0 .. engines) assert(each[i].ownerIdsIssued == 1);
}

unittest { // cycles: reported chains, deep chains and the depth limit
	static assert(defaultDepthLimit >= 1024, "IL-Chain: an implementation follows a chain of at least 1024 answers");
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	diagnose.Manager manager;
	scope(exit) diagnose.free(manager);
	auto engine = create(store);
	scope(exit) free(engine);
	engine.diagnostics = &manager;

	// Resolve(-1) -> Resolve(-3) -> Resolve(-2) -> Resolve(-1) is a cycle, reported with its chain.
	assert(*query!Resolve(engine, -1) == -1);
	assert(fp.dynarray.length(manager.diagnostics) == 1);
	assert(fp.string.slice(manager.diagnostics[0].message)
		== "Q-Cycle: a query needs its own answer: Resolve(-1) -> Resolve(-3) -> Resolve(-2) -> Resolve(-1)");
	assert(fp.string.slice(manager.diagnostics[0].note) == cycleHint);
	assert(ecrs.context.hasComponent!(doir.components.query.InCycle)(store, find!Resolve(engine, -1)));

	// The cycle is reported again by its memo in a later revision, which re-runs rather than re-validates.
	beginRevision(engine);
	assert(*query!Resolve(engine, -1) == -1);
	assert(fp.dynarray.length(manager.diagnostics) == 2);
	assert(fp.string.slice(manager.diagnostics[1].note) == cycleHint);

	// An unsigned key is reported as one.
	assert(*query!Spin(engine, 7) == 0);
	assert(fp.string.slice(manager.diagnostics[2].message) == "Q-Cycle: a query needs its own answer: Spin(7) -> Spin(7)");
	assert(fp.string.slice(manager.diagnostics[2].note) == cycleHint);

	// Each running query is marked with its frame, and only while it runs.
	assert(*query!Depth(engine, 0) == 3);
	foreach (k; 0 .. 4) assert(ecrs.context.getComponent!(doir.components.query.Claim)(store, find!Depth(engine, k)).owner == 0);

	// A chain within the depth limit resolves; one past it is reported instead of overflowing the stack.
	diagnose.clear(manager);
	assert(*query!Resolve(engine, defaultDepthLimit - 8) == 0);
	assert(fp.dynarray.length(manager.diagnostics) == 0);
	assert(ecrs.context.getComponent!(doir.components.query.Claim)(store, find!Resolve(engine, defaultDepthLimit - 8)).owner == 0);
	engine.depthLimit = 64;
	assert(*query!Resolve(engine, 2 * defaultDepthLimit) == -1);
	assert(fp.dynarray.length(manager.diagnostics) == 1);
	enum prefix = "IL-Chain: queries nest deeper than the limit of 64 at Resolve(";
	assert(fp.string.slice(manager.diagnostics[0].message)[0 .. prefix.length] == prefix);
	assert(fp.string.slice(manager.diagnostics[0].note) == depthHint);

	// An unsigned key is described as one.
	diagnose.clear(manager);
	assert(*query!Unsigned(engine, 3));
	assert(fp.string.slice(manager.diagnostics[0].message) == "Q-Cycle: a query needs its own answer: Unsigned(3) -> Unsigned(3)");
	assert(fp.string.slice(manager.diagnostics[0].note) == cycleHint);
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
		auto n = &ecrs.context.getForWriting!Node(store, e);
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
	assert(ecrs.context.getComponent!(doir.components.query.Verification)(store, provisional).revision == 0); // reset, keeping no value
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
			auto previous = fp.testing.limitAllocations(n);
			immutable answered = demand();
			fp.testing.restoreAllocator(previous);
			assert(answered || engine.refused);
			refused |= engine.refused;
			engine.refused = false;
			return answered;
		}

		// Nested fallbacks: moving E, F down to the lower head can be refused too.
		// It runs first, so every budget meets the same allocations.
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
			auto previous = fp.testing.limitAllocations(n);
			auto sign = query!Sign(engine, Sign.Key([e]));
			immutable answer = sign is null ? 0 : *sign;
			fp.testing.restoreAllocator(previous);
			assert(sign is null ? engine.refused : answer == expected);
			refused |= engine.refused;
			engine.refused = false;
			assert(*query!Sign(engine, Sign.Key([e])) == expected);
		}
		step(-1);

		// Re-validation and re-execution after an input change.
		beginRevision(engine);
		ecrs.context.getForWriting!Amount(store, e).value = 5;
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
		auto previous = fp.testing.limitAllocations(n);
		auto same = query!Equal(engine, Pair([a, b]));
		immutable answer = same is null || *same;
		fp.testing.restoreAllocator(previous);
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
		previous = fp.testing.limitAllocations(0);
		auto moved = query!Sign(engine, Sign.Key([spare]));
		fp.testing.restoreAllocator(previous);
		assert(moved !is null && *moved == 1 && !engine.refused);
		finished = !refused;
	}
}

unittest { // demands on many threads: a shared query runs once, reports keep serial order, any thread may add, produce and create, and cycles resolve
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
	// Shared's query entity does not exist yet: the first worker to need it adds it.
	assert(demandEach!Fan(engine, keys[]));
	assert(core.atomic.atomicLoad(sharedRuns) == 1);
	foreach (k; keys) assert(*query!Fan(engine, k) == 100 + k);
	// A cycle across workers is found by the waits it closes and left to the serial pass, which reports it as one thread would (Q-Cycle).
	assert(demandEach!Ring(engine, ring[]));
	auto reported = messagesOf(manager);
	scope(exit) fp.string.free(reported);
	assert(fp.string.slice(reported) == fp.string.slice(expected));
	assert(fp.dynarray.length(manager.diagnostics) == 1 + 22 + 1); // Shared, Fan of each multiple of 3, the cycle

	// Nothing changed: the workers re-validate, and the withheld reports come out in the same order.
	diagnose.clear(manager);
	beginRevision(engine);
	assert(demandEach!Fan(engine, keys[]) && core.atomic.atomicLoad(sharedRuns) == 1);
	assert(fp.dynarray.length(manager.diagnostics) == 1 + 22);
	assert(fp.string.slice(manager.diagnostics[0].message) == "shared" && fp.string.slice(manager.diagnostics[1].message) == "fan 0");

	// Twin produces and creates, which workers do in the exclusive section.
	assert(demandEach!Twin(engine, keys[0 .. 8]));
	foreach (k; keys[0 .. 8]) {
		assert(ecrs.context.getComponent!Amount(store, query!Twin(engine, k).related[0]).value == k);
		assert(fp.dynarray.length(ecrs.context.getComponent!(doir.components.query.CreatedEntities)(store, find!Twin(engine, k)).related) == 1);
	}

	// Claim produces without creating, adding its component itself.
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

	// Workers starting along one chain wait on the workers ahead; past the depth limit a worker leaves the demand to the serial pass.
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
		assert(limit != defaultDepthLimit || (*query!Chain(chain, 0) == 63 && fp.dynarray.length(chainManager.diagnostics) == 0));
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
		foreach (k; keys) assert(fp.dynarray.length(ecrs.context.getComponent!(doir.components.query.ReadBy)(wideStore, inputs[k * wideReads]).related) == 1);
		beginRevision(wide);
		ecrs.context.getForWriting!Amount(wideStore, inputs[5 * wideReads]).value = 2;
		assert(markChanged(wide, inputs[5 * wideReads]));
		assert(demandEach!Wide(wide, keys[]) && core.atomic.atomicLoad(wideRuns) == 1 && *query!Wide(wide, 5) == wideReads + 1);
	}

	// A refused allocation building the edges on workers leaves them missing; one recording them on a worker drops them, to be built later.
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
		auto allocator = fp.testing.limitAllocations(budget);
		immutable ran = demandEach!Wide(wide, keys[]);
		fp.testing.restoreAllocator(allocator);
		if (!ran) wide.refused = false;
		immutable recorded = !wide.edgesMissing;
		wide.edgesMissing = true;
		assert(demandEach!Wide(wide, keys[]));
		allocator = fp.testing.limitAllocations(budget);
		immutable built = buildDependents(wide);
		fp.testing.restoreAllocator(allocator);
		assert(built != wide.edgesMissing);
		if (ran && recorded && built) break;
	}

	// A refused allocation anywhere in a batch fails it; the next demand finishes it.
	for (size_t budget = 0;; ++budget) {
		auto rationedStore = ecrs.context.create();
		scope(exit) ecrs.context.free(rationedStore);
		auto rationed = create(rationedStore);
		scope(exit) free(rationed);
		rationed.workers = pool;
		auto allocator = fp.testing.limitAllocations(budget);
		immutable ran = demandEach!Fan(rationed, keys[]);
		fp.testing.restoreAllocator(allocator);
		if (!ran) assert(rationed.refused);
		rationed.refused = false;
		assert(demandEach!Fan(rationed, keys[]));
		foreach (k; keys) assert(*query!Fan(rationed, k) == 100 + k);
		if (ran) break;
	}

	// Any thread may demand: an `ecrs.schedules` pass's jobs demand on the engine, their owner, repeatedly so races can show.
	// Reading the store between demands while other threads demand needs the shared section.
	static bool twin(ref QueryEngine engine, ref int key) @nogc nothrow {
		beginReading(engine);
		scope(exit) endReading(engine);
		auto made = query!Twin(engine, key);
		return made !is null && ecrs.context.getComponent!Amount(*engine.store, made.related[0]).value == key;
	}
	static bool enterRing(ref QueryEngine engine, ref int key) @nogc nothrow {
		return query!Ring(engine, key) !is null;
	}
	static bool equal(ref QueryEngine engine, ref Pair key) @nogc nothrow {
		auto same = query!Equal(engine, key);
		return same !is null && *same;
	}
	foreach (attempt; 0 .. 16) {
		auto anyStore = ecrs.context.create();
		scope(exit) ecrs.context.free(anyStore);
		diagnose.Manager anyManager;
		scope(exit) diagnose.free(anyManager);
		auto any = create(anyStore);
		scope(exit) free(any);
		any.diagnostics = &anyManager;

		// Every thread adds query entities, and produces and creates in the exclusive section; each query still runs once.
		assert(ecrs.schedules.parallel!twin(any, pool, keys[]) && !any.refused);
		foreach (k; keys) assert(fp.dynarray.length(ecrs.context.getComponent!(doir.components.query.CreatedEntities)(anyStore, find!Twin(any, k)).related) == 1);

		// Four threads entering a ring at four places wait in a loop; one gives up, and the ring is reported once (Q-Cycle).
		int[4] entries = [0, 1, 2, 3];
		assert(ecrs.schedules.parallel!enterRing(any, pool, entries[]) && !any.refused);
		assert(fp.dynarray.length(anyManager.diagnostics) == 1);
		foreach (k; entries) assert(*query!Ring(any, k) == *query!Ring(any, 0));

		// Coinductive comparisons from several threads, whose provisional answers rest on other threads' running queries (S-Struct).
		EntityId[6] n;
		foreach (ref e; n) e = doir.testing.addEntity(anyStore);
		doir.testing.addComponent!Node(anyStore, n[2]) = Node([n[4], n[0]], 1, 2);
		doir.testing.addComponent!Node(anyStore, n[3]) = Node([n[5], n[1]], 1, 2);
		doir.testing.addComponent!Node(anyStore, n[4]) = Node([n[2], invalidEntity], 1, 1);
		doir.testing.addComponent!Node(anyStore, n[5]) = Node([n[3], invalidEntity], 1, 1);
		doir.testing.addComponent!Node(anyStore, n[0]) = Node([n[2], invalidEntity], 1, 1);
		doir.testing.addComponent!Node(anyStore, n[1]) = Node([n[3], invalidEntity], 1, 1);
		Pair[6] pairs = [Pair([n[0], n[1]]), Pair([n[2], n[3]]), Pair([n[4], n[5]]), Pair([n[1], n[0]]), Pair([n[3], n[2]]), Pair([n[5], n[4]])];
		assert(ecrs.schedules.parallel!equal(any, pool, pairs[]) && !any.refused);
	}
}
