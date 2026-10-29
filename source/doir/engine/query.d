/// The query engine's machinery (`roadmap.md` Phase 1): the components a query entity carries, the engine's state, and demand, validation, execution and cycle handling. Programs use it through `doir.api.query`, which documents the query protocol; the `package` functions here are the entry points that module calls.
///
/// A refused allocation fails every query running at the time (`fail`): each keeps no value and returns null to its demander, so nothing computed from a partial run is memoized. `QueryEngine.refused` records that it happened. Work outside a run, such as adding a query entity or delivering a diagnostic, reports through its result and the same flag.
module doir.engine.query;

static import core.stdc.string;

static import fp.dynarray;
static import fp.fnv1a;
static import fp.hashtable;
static import fp.lifecycle;
static import fp.pointer;
static import fp.string;

static import diagnose;
static import ecrs.context;
static import ecrs.registry;
static import ecrs.relation;
static import ecrs.storage;

static import doir.engine.positions;

public import ecrs.registry : EntityId, invalidEntity;

@nogc nothrow:


// --- types and layout --------------------------------------------------------

/// A point in the engine's history. Revision 0 means "before anything was recorded".
alias Revision = ulong;

/// The revision an entity last changed in: set on inputs by `markChanged`, and on a query entity whenever a run produces a different value or different components.
struct ChangedAt {
	Revision revision;
}

/// The revision a query entity's value was last confirmed current in.
struct VerifiedAt {
	Revision revision;
}

/// The entities and query entities a query read during its last run.
struct DependsOn {
	mixin ecrs.relation.Relates;
}

/// Removes what query `owner` wrote of component `component` on `e`: the whole component, or for a shared one such as an effect log, only `owner`'s entries.
alias StripFunction = void function(ref ecrs.context.Context store, EntityId e, size_t component, EntityId owner) @nogc nothrow;

/// Hashes what query `owner` wrote of component `component` on `e`, so a re-run that writes the same thing keeps early cutoff.
alias HashFunction = size_t function(ref const ecrs.context.Context store, EntityId e, size_t component, EntityId owner) @nogc nothrow;

/// One component a query wrote to `entity`, `component` being its libECRS component id, with how to remove and hash it.
struct Produced {
	mixin ecrs.relation.Relates!"entity";
	size_t component; /// The component written.
	StripFunction strip; /// Removes it.
	HashFunction hash; /// Hashes it.
}

/// Every component a query wrote during its last run, removed before it runs again and when it is evicted, and the hash of their contents at the end of that run.
struct Produces {
	Produced* items = null; /// What was written, in order.
	size_t hash = 0; /// The contents' hash, which early cutoff compares.

	/// The `E-Remap` hook libECRS finds by name.
	///
	/// Examples:
	/// ---
	/// static import fp.dynarray;
	/// Produces list;
	/// scope(exit) list.finalize();
	/// assert(fp.dynarray.pushBack(list.items, Produced([1], 0)));
	/// immutable EntityId[3] remap = [0, 2, 1];
	/// Produces.remapEntities(list, remap[]);
	/// assert(list.items[0].entity == 2);
	/// ---
	static void remapEntities(ref Produces self, const(EntityId)[] remap) @nogc nothrow {
		foreach (ref item; fp.dynarray.slice(self.items)) Produced.remapEntities(item, remap);
	}
	/// Releases the list when the component is removed.
	///
	/// Examples:
	/// ---
	/// static import fp.dynarray;
	/// Produces list;
	/// assert(fp.dynarray.pushBack(list.items, Produced([1], 0)));
	/// list.finalize();
	/// ---
	void finalize() @nogc nothrow { fp.dynarray.free(items); }
}

/// The entities a query created, indexed by creation sequence number, so a re-run hands back the same ids.
struct Creates {
	mixin ecrs.relation.Relates;
}

/// The entity a query-created entity was derived from, so a diagnostic about it resolves to a source location.
struct Provenance {
	mixin ecrs.relation.Relates!"origin";
}

/// A diagnostic a query reported: the entity it is about, `subject`, or `invalidEntity`, how severe it is and its message. Its location is resolved from `subject` only when it is reported.
struct QueryDiagnostic {
	mixin ecrs.relation.Relates!"subject";
	diagnose.Kind kind; /// How severe it is.
	char* message = null; /// An owned fp string.
}

/// The diagnostics a query reported during its last run, reported again whenever its memo is reused in a later revision.
struct QueryDiagnostics {
	QueryDiagnostic* items = null;

	/// The `E-Remap` hook libECRS finds by name.
	///
	/// Examples:
	/// ---
	/// static import fp.dynarray;
	/// QueryDiagnostics list;
	/// scope(exit) list.finalize();
	/// assert(fp.dynarray.pushBack(list.items, QueryDiagnostic([1])));
	/// immutable EntityId[2] remap = [0, 3];
	/// QueryDiagnostics.remapEntities(list, remap[]);
	/// assert(list.items[0].subject == 3);
	/// ---
	static void remapEntities(ref QueryDiagnostics self, const(EntityId)[] remap) @nogc nothrow {
		foreach (ref d; fp.dynarray.slice(self.items)) QueryDiagnostic.remapEntities(d, remap);
	}
	/// Releases the messages and the list.
	///
	/// Examples:
	/// ---
	/// static import fp.dynarray;
	/// QueryDiagnostics list;
	/// assert(fp.dynarray.pushBack(list.items, QueryDiagnostic([1])));
	/// list.finalize();
	/// assert(list.items is null);
	/// ---
	void finalize() @nogc nothrow {
		foreach (ref d; fp.dynarray.slice(items)) fp.string.free(d.message);
		fp.dynarray.free(items);
		items = null;
	}
}

/// Marks a finished query whose value rests on a running query's cycle fallback, until that query, `head`, finishes and confirms or discards it.
struct ProvisionalOn {
	mixin ecrs.relation.Relates!"head";
}

/// Tags a query whose last run took part in a cycle (`Q-Cycle`). It is re-run, not re-validated, in a later revision, since its dependencies loop back to it.
struct InCycle {
	enum isTag = true;
}

/// Marks a running query with the index of its frame on the engine's stack, so finding it never scans the stack. Present only while the query runs.
struct Running {
	size_t frame; /// Its index in the engine's stack.
}

unittest { // libECRS silently skips a holder whose hook is not `@nogc nothrow`; every holder of an entity id must pass (E-Remap)
	static assert(ecrs.registry.hasRemapEntities!DependsOn && ecrs.registry.hasRemapEntities!Produces && ecrs.registry.hasRemapEntities!Creates
		&& ecrs.registry.hasRemapEntities!Provenance && ecrs.registry.hasRemapEntities!QueryDiagnostics && ecrs.registry.hasRemapEntities!ProvisionalOn);
}

/// Brings query entity `q` up to date, re-running it if needed. Returns false if it cannot: `q` is already running, the depth limit is reached, or its run failed on a refused allocation.
alias RefreshFunction = bool function(ref QueryEngine engine, EntityId q) @nogc nothrow;

/// Discards query entity `q`'s value and what it produced and created, so the next demand runs it.
alias ResetFunction = void function(ref QueryEngine engine, EntityId q) @nogc nothrow;

/// Appends a description of query entity `q`, such as `Layout(12)`, to an fp string. Returns false if the string could not grow, leaving it holding a prefix of the description.
alias DescribeFunction = bool function(ref QueryEngine engine, EntityId q, ref char* out_) @nogc nothrow;

/// Marks an entity as a query instance, with the type-erased entry points that let a dependent re-validate it and a cycle report name it.
struct QueryInfo {
	RefreshFunction refresh; /// Re-validates or re-runs it.
	ResetFunction reset; /// Discards its value.
	DescribeFunction describe; /// Names it.
}

/// True if `Q` follows the query protocol `doir.api.query` documents. A key's lifetime must be its bytes, since the index holds a bit copy of it.
enum isQuery(Q) = is(Q.Key) && is(Q.Value) && fp.lifecycle.isBitMoveable!(Q.Key) && __traits(compiles, (ref QueryEngine engine, Q.Key key) @nogc nothrow {
	Q.Value value = Q.compute(engine, key);
});

/// The key of a query entity of type `Q`.
///
/// Examples:
/// ---
/// struct Identity {
/// 	alias Key = int;
/// 	alias Value = int;
/// 	static int compute(ref QueryEngine engine, int key) @nogc nothrow { return key; }
/// }
/// QueryKey!Identity k;
/// k.key = 3;
/// assert(k.key == 3);
/// ---
struct QueryKey(Q) {
	Q.Key key;

	static if (ecrs.registry.hasRemapEntities!(Q.Key))
	/// The `E-Remap` hook libECRS finds by name, forwarded to the key's own, which it has by mixing in `ecrs.relation.Relates`.
	///
	/// Examples:
	/// ---
	/// static import ecrs.relation;
	/// struct Of {
	/// 	alias Key = ecrs.relation.Relation!1;
	/// 	alias Value = int;
	/// 	static int compute(ref QueryEngine engine, Key key) @nogc nothrow { return 0; }
	/// }
	/// auto k = QueryKey!Of(Of.Key([1]));
	/// immutable EntityId[2] remap = [0, 7];
	/// QueryKey!Of.remapEntities(k, remap[]);
	/// assert(k.key.related[0] == 7);
	/// ---
	static void remapEntities(ref QueryKey self, const(EntityId)[] remap) @nogc nothrow { Q.Key.remapEntities(self.key, remap); }
}

/// The value of a query entity of type `Q`, present once it has run and until it is evicted.
///
/// Examples:
/// ---
/// struct Constant {
/// 	alias Key = int;
/// 	alias Value = int;
/// 	static int compute(ref QueryEngine engine, int key) @nogc nothrow { return 1; }
/// }
/// QueryValue!Constant v;
/// v.value = 1;
/// assert(v.value == 1);
/// ---
struct QueryValue(Q) {
	Q.Value value;

	static if (ecrs.registry.hasRemapEntities!(Q.Value))
	/// The `E-Remap` hook libECRS finds by name, forwarded to the value's own, which it has by mixing in `ecrs.relation.Relates`.
	///
	/// Examples:
	/// ---
	/// static import ecrs.relation;
	/// struct Pick {
	/// 	alias Key = int;
	/// 	alias Value = ecrs.relation.Relation!1;
	/// 	static Value compute(ref QueryEngine engine, int key) @nogc nothrow { return Value([1]); }
	/// }
	/// auto v = QueryValue!Pick(Pick.Value([1]));
	/// immutable EntityId[2] remap = [0, 7];
	/// QueryValue!Pick.remapEntities(v, remap[]);
	/// assert(v.value.related[0] == 7);
	/// ---
	static void remapEntities(ref QueryValue self, const(EntityId)[] remap) @nogc nothrow { Q.Value.remapEntities(self.value, remap); }

	static if (!fp.lifecycle.isBitMoveable!(Q.Value))
	/// Ends the value's lifetime when the component is removed, so a value owning memory is freed on eviction.
	///
	/// Examples:
	/// ---
	/// static import fp.dynarray;
	/// struct Owning {
	/// 	int* items;
	/// 	void finalize() @nogc nothrow { fp.dynarray.free(items); }
	/// }
	/// struct Listed {
	/// 	alias Key = int;
	/// 	alias Value = Owning;
	/// 	static Owning compute(ref QueryEngine engine, int key) @nogc nothrow { return Owning.init; }
	/// 	static bool valueEqual(ref const Owning a, ref const Owning b) @nogc nothrow { return true; }
	/// }
	/// QueryValue!Listed v;
	/// v.finalize();
	/// ---
	void finalize() @nogc nothrow { fp.lifecycle.endLifetime(value); }
}

private bool keysEqual(Q)(ref const Q.Key a, ref const Q.Key b) @trusted {
	static if (__traits(hasMember, Q, "keyEqual")) return Q.keyEqual(a, b);
	else return core.stdc.string.memcmp(&a, &b, Q.Key.sizeof) == 0;
}

private size_t keyHash(Q)(ref const Q.Key key) @trusted {
	static if (__traits(hasMember, Q, "keyEqual")) {
		static assert(__traits(hasMember, Q, "keyHash"), Q.stringof ~ " declares keyEqual without keyHash");
		return Q.keyHash(key);
	} else return fp.fnv1a.hash((cast(const(ubyte)*) &key)[0 .. Q.Key.sizeof]);
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
}

/// The depth of nested demands and re-validations a new engine allows before reporting `Q-Cycle`, well inside a default 8 MiB stack.
enum size_t defaultDepthLimit = 4096;

/// The engine: the store it works on, the current revision, where diagnostics go, the order keys of lexical positions, and the stack of running queries. Renumber the store only through `doir.api.query.renumber` and `compact`, which require that no query is running.
struct QueryEngine {
	ecrs.context.Context* store; /// The store, which must outlive the engine.
	Revision revision = 1; /// The current revision.
	size_t depthLimit = defaultDepthLimit; /// How deep demands may nest before `Q-Cycle` is reported instead of overflowing the stack.
	diagnose.Manager* diagnostics = null; /// Where reported diagnostics go, each once per revision; null discards them, though queries still record theirs.
	bool refused = false; /// Set when an allocation was refused: every query running at the time failed, keeping no value, or a diagnostic was lost on its way to `diagnostics`. The engine never clears it.
	package(doir) doir.engine.positions.Positions positions; // the order keys of every positioned effect and read (C-Order)
	package(doir) Frame* stack = null;
	package(doir) size_t depth = 0;
}


// --- entry points for doir.api ----------------------------------------------

/// Whether no query is running, as entering a revision, an input commit and a renumbering require.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// QueryEngine engine;
/// engine.store = &store;
/// assert(idle(engine));
/// release(engine);
/// ---
package(doir) bool idle(ref QueryEngine engine) {
	return fp.dynarray.length(engine.stack) == 0;
}

private size_t frameOf(ref QueryEngine engine, EntityId q) {
	if (idle(engine)) return noFrame;
	auto running = ecrs.context.findComponent!Running(*engine.store, q);
	return running is null ? noFrame : running.frame;
}

/// Records a refused allocation: sets `engine.refused` and fails every running query, each of which then keeps no value and returns null to its demander. A query failing alone could memoize a value built on a failed demand's null, so the whole stack fails.
///
/// Examples:
/// ---
/// QueryEngine engine;
/// fail(engine);
/// assert(engine.refused);
/// ---
package(doir) void fail(ref QueryEngine engine) {
	engine.refused = true;
	foreach (ref frame; fp.dynarray.slice(engine.stack)) frame.refused = true;
}

/// Releases the engine's own memory: its stack and its positions.
///
/// Examples:
/// ---
/// QueryEngine engine;
/// release(engine);
/// ---
package(doir) void release(ref QueryEngine engine) {
	assert(idle(engine));
	fp.dynarray.free(engine.stack);
	doir.engine.positions.free(engine.positions);
}

/// The innermost running query entity, or `invalidEntity` outside any query.
///
/// Examples:
/// ---
/// QueryEngine engine;
/// assert(innermost(engine) == invalidEntity);
/// ---
package(doir) EntityId innermost(ref QueryEngine engine) {
	return idle(engine) ? invalidEntity : fp.dynarray.back(engine.stack).query;
}

/// Records that the running query read `e`, and if `e` is a provisional answer, that its value rests on the same cycle fallback. Does nothing outside a query. Returns false on a refused allocation, which fails the running queries (`fail`).
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// QueryEngine engine;
/// engine.store = &store;
/// assert(recordRead(engine, ecrs.context.addEntity(store)));
/// ---
package(doir) bool recordRead(ref QueryEngine engine, EntityId e) {
	immutable n = fp.dynarray.length(engine.stack);
	if (n == 0) return true;
	auto top = &engine.stack[n - 1];
	if (top.query == e) return true;
	if (auto provisional = ecrs.context.findComponent!ProvisionalOn(*engine.store, e)) {
		immutable h = frameOf(engine, provisional.head);
		assert(h != noFrame);
		top.cycle = true;
		if (h < n - 1 && h < top.head) top.head = h;
	}
	auto deps = &ecrs.context.getComponent!DependsOn(*engine.store, top.query);
	foreach (d; fp.dynarray.slice(deps.related))
		if (d == e) return true;
	if (fp.dynarray.pushBack(deps.related, e)) return true;
	fail(engine);
	return false;
}

/// Adds `item` to the running query's `Produces` list, unless `unique` is false and the list already has its (entity, component) pair. Returns false on a refused allocation, which fails the running queries (`fail`).
///
/// Examples:
/// ---
/// static import fp.dynarray;
/// static import ecrs.context;
/// static import ecrs.registry;
/// struct Claim {
/// 	alias Key = int;
/// 	alias Value = int;
/// 	static int compute(ref QueryEngine engine, int key) @nogc nothrow {
/// 		immutable item = Produced([innermost(engine)], ecrs.registry.componentId!int(), &stripComponent, &hashComponent!int);
/// 		assert(recordProduced(engine, item, false) && recordProduced(engine, item, false));
/// 		return key;
/// 	}
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// QueryEngine engine;
/// engine.store = &store;
/// scope(exit) release(engine);
/// assert(*demand!Claim(engine, 1) == 1);
/// assert(fp.dynarray.length(ecrs.context.getComponent!Produces(store, find!Claim(engine, 1)).items) == 1);
/// ---
package(doir) bool recordProduced(ref QueryEngine engine, Produced item, bool unique) {
	immutable q = innermost(engine);
	assert(q != invalidEntity, "doir.query: writing a component outside a query");
	auto produces = &ecrs.context.getComponent!Produces(*engine.store, q);
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
	if (ecrs.context.hasComponent(store, e, component)) ecrs.context.removeComponent(store, e, component);
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
		else return fp.fnv1a.hash((cast(const(ubyte)*) c)[0 .. C.sizeof]);
	}
}

/// The running query's next created entity: the one its previous run created at the same sequence number, or a fresh one. Returns `invalidEntity` on a refused allocation, which fails the running queries (`fail`).
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import ecrs.relation;
/// struct Spawn {
/// 	alias Key = int;
/// 	alias Value = ecrs.relation.Relation!1;
/// 	static Value compute(ref QueryEngine engine, int key) @nogc nothrow { return Value([nextCreated(engine)]); }
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// QueryEngine engine;
/// engine.store = &store;
/// scope(exit) release(engine);
/// immutable made = demand!Spawn(engine, 1).related[0];
/// assert(ecrs.context.getComponent!Creates(store, find!Spawn(engine, 1)).related[0] == made);
/// ---
package(doir) EntityId nextCreated(ref QueryEngine engine) {
	assert(!idle(engine), "doir.query: creating an entity outside a query");
	auto frame = fp.dynarray.back(engine.stack);
	auto creates = &ecrs.context.getComponent!Creates(*engine.store, frame.query);
	immutable sequence = frame.created++;
	if (sequence < fp.dynarray.length(creates.related)) return creates.related[sequence];
	immutable e = ecrs.context.addEntity(*engine.store);
	if (e != invalidEntity && fp.dynarray.pushBack(creates.related, e)) return e;
	if (e != invalidEntity) cast(void) ecrs.context.removeEntity(*engine.store, e); // if refused, an orphan nothing reaches
	fail(engine);
	return invalidEntity;
}

// Hands a copy of `d` to `engine.diagnostics`. A refused allocation loses it, setting `engine.refused` but failing no query, whose value is still right.
private bool emit(ref QueryEngine engine, ref const QueryDiagnostic d) {
	if (engine.diagnostics is null) return true;
	diagnose.Diagnostic out_;
	out_.kind = d.kind;
	out_.message = fp.string.makeDynamic(fp.string.slice(d.message));
	if ((out_.message !is null || d.message is null) && diagnose.push(*engine.diagnostics, out_) !is null) return true;
	fp.string.free(out_.message);
	engine.refused = true;
	return false;
}

/// Stores `d`, whose message it takes over, on the running query, or outside any query reports it to `engine.diagnostics` and frees it. Returns false on a refused allocation, which frees the message and fails the running queries (`fail`).
///
/// Examples:
/// ---
/// QueryEngine engine;
/// assert(recordDiagnostic(engine, QueryDiagnostic.init));
/// ---
package(doir) bool recordDiagnostic(ref QueryEngine engine, QueryDiagnostic d) {
	immutable q = innermost(engine);
	if (q == invalidEntity) {
		immutable emitted = emit(engine, d);
		fp.string.free(d.message);
		return emitted;
	}
	if (fp.dynarray.pushBack(ecrs.context.getComponent!QueryDiagnostics(*engine.store, q).items, d)) return true;
	fp.string.free(d.message);
	fail(engine);
	return false;
}


// --- running and validating queries ------------------------------------------

private void removeProduced(ref QueryEngine engine, EntityId q) {
	auto produces = &ecrs.context.getComponent!Produces(*engine.store, q);
	foreach (item; fp.dynarray.slice(produces.items)) item.strip(*engine.store, item.entity, item.component, q);
	if (produces.items !is null) fp.dynarray.clear(produces.items);
}

private size_t mix(size_t h, size_t value) {
	return (h ^ value) * 0x100000001b3;
}

private size_t hashProduced(ref QueryEngine engine, EntityId q) {
	size_t h = 0xcbf29ce484222325;
	foreach (item; fp.dynarray.slice(ecrs.context.getComponent!Produces(*engine.store, q).items)) {
		h = mix(h, item.entity);
		h = mix(h, item.component);
		h = mix(h, item.hash(*engine.store, item.entity, item.component, q));
	}
	return h;
}

// Removes the entities past `keep`, which the latest run no longer created. One the store refuses to free stays listed for later reuse or removal.
private void removeCreated(ref QueryEngine engine, EntityId q, size_t keep) {
	auto creates = &ecrs.context.getComponent!Creates(*engine.store, q);
	while (fp.dynarray.length(creates.related) > keep && ecrs.context.removeEntity(*engine.store, *fp.dynarray.back(creates.related)))
		cast(void) fp.dynarray.popBack(creates.related);
}

private void clearDiagnostics(ref QueryEngine engine, EntityId q) {
	auto list = &ecrs.context.getComponent!QueryDiagnostics(*engine.store, q);
	foreach (ref d; fp.dynarray.slice(list.items)) fp.string.free(d.message);
	if (list.items !is null) fp.dynarray.clear(list.items);
}

private void emitAll(ref QueryEngine engine, EntityId q) {
	foreach (ref d; fp.dynarray.slice(ecrs.context.getComponent!QueryDiagnostics(*engine.store, q).items))
		cast(void) emit(engine, d); // a lost diagnostic is recorded in engine.refused
}

private QueryTable!Q* tableOf(Q)(ref QueryEngine engine) @trusted {
	auto storage = ecrs.context.getStorage!(QueryTable!Q)(*engine.store);
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
	if (rehashIfStale(*table)) found = fp.hashtable.find(table.table, TableEntry!Q([invalidEntity], key));
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
	auto key = &ecrs.context.getComponent!(QueryKey!Q)(*engine.store, q).key;
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
	auto k = ecrs.context.addComponent!(QueryKey!Q)(*store, q);
	if (k !is null) k.key = key;
	auto info = k is null ? null : ecrs.context.addComponent!QueryInfo(*store, q);
	if (info !is null) *info = QueryInfo(&refresh!Q, &reset!Q, &describe!Q);
	if (info !is null
		&& ecrs.context.addComponent!ChangedAt(*store, q) !is null
		&& ecrs.context.addComponent!VerifiedAt(*store, q) !is null
		&& ecrs.context.addComponent!DependsOn(*store, q) !is null
		&& ecrs.context.addComponent!Produces(*store, q) !is null
		&& ecrs.context.addComponent!Creates(*store, q) !is null
		&& ecrs.context.addComponent!QueryDiagnostics(*store, q) !is null
		&& index!Q(engine, key, q))
		return q;
	cast(void) ecrs.context.removeEntity(*store, q); // if refused, an orphan no index reaches
	return invalidEntity;
}

// Records a `Q-Cycle` error naming the frames from `from` up and back. On refusal returns false, failing the running queries so none memoizes without it.
private bool reportChain(ref QueryEngine engine, const(char)[] headline, size_t from) {
	char* message = fp.string.makeDynamic(headline);
	bool built = message !is null;
	foreach (frame; engine.stack[from .. fp.dynarray.length(engine.stack)])
		built = built && ecrs.context.getComponent!QueryInfo(*engine.store, frame.query).describe(engine, frame.query, message)
			&& fp.string.concatenate(message, " -> ") !is null;
	immutable head = engine.stack[from].query;
	built = built && ecrs.context.getComponent!QueryInfo(*engine.store, head).describe(engine, head, message);
	if (built) return recordDiagnostic(engine, QueryDiagnostic([invalidEntity], diagnose.Kind.error, message));
	fp.string.free(message);
	fail(engine);
	return false;
}

// Records a `Q-Cycle` error for demands nested past the depth limit at `q`, failing the running queries on a refused allocation as `reportChain` does.
private void reportDepth(ref QueryEngine engine, EntityId q) {
	char* message = fp.string.format("Q-Cycle: queries nest deeper than the limit of %llu at ", cast(ulong) engine.depthLimit);
	if (message !is null && ecrs.context.getComponent!QueryInfo(*engine.store, q).describe(engine, q, message))
		cast(void) recordDiagnostic(engine, QueryDiagnostic([invalidEntity], diagnose.Kind.error, message)); // fails the running queries itself
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

/// Brings query entity `q` up to date through its type-erased entry point, re-validating or re-running it. Returns false if it cannot: it is running, or the depth limit is reached.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// struct Seven {
/// 	alias Key = int;
/// 	alias Value = int;
/// 	static int compute(ref QueryEngine engine, int key) @nogc nothrow { return 7; }
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// QueryEngine engine;
/// engine.store = &store;
/// scope(exit) release(engine);
/// assert(*demand!Seven(engine, 0) == 7);
/// immutable q = find!Seven(engine, 0);
/// ++engine.revision;
/// assert(refreshQuery(engine, q));
/// assert(ecrs.context.getComponent!VerifiedAt(store, q).revision == engine.revision);
/// ---
package(doir) bool refreshQuery(ref QueryEngine engine, EntityId q) {
	return ecrs.context.getComponent!QueryInfo(*engine.store, q).refresh(engine, q);
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
/// 		assert(reportRunning(engine, innermost(engine)));
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
/// scope(exit) release(engine);
/// assert(*demand!Waits(engine, 0) == 0);
/// assert(diagnose.count(manager) == 1);
/// ---
package(doir) bool reportRunning(ref QueryEngine engine, EntityId q) {
	immutable h = frameOf(engine, q);
	assert(h != noFrame);
	foreach (ref frame; engine.stack[h .. fp.dynarray.length(engine.stack)]) frame.cycle = true;
	return reportChain(engine, "Q-Cycle: a read needs an effect of a query that is still running: ", h);
}

// True if no dependency changed after `q` was verified. Dependencies that are queries are refreshed first, which is what lets early cutoff stop a change.
private bool dependenciesUnchanged(ref QueryEngine engine, EntityId q) {
	immutable verified = ecrs.context.getComponent!VerifiedAt(*engine.store, q).revision;
	immutable n = fp.dynarray.length(ecrs.context.getComponent!DependsOn(*engine.store, q).related);
	foreach (i; 0 .. n) {
		immutable d = ecrs.context.getComponent!DependsOn(*engine.store, q).related[i];
		auto info = ecrs.context.findComponent!QueryInfo(*engine.store, d);
		if (info !is null && !info.refresh(engine, d)) return false;
		auto changed = ecrs.context.findComponent!ChangedAt(*engine.store, d);
		if (changed !is null && changed.revision > verified) return false;
	}
	return true;
}

private void clearProvisional(ref QueryEngine engine, EntityId p) {
	if (ecrs.context.hasComponent!ProvisionalOn(*engine.store, p)) ecrs.context.removeComponent!ProvisionalOn(*engine.store, p);
}

// Settles queries resting on `self`'s fallback, moving those a lower fallback still holds up. Returns false on refusal, discarding any it could not move.
private bool settleProvisional(ref QueryEngine engine, ref Frame self, size_t index, bool fallbackHeld) {
	if (!self.usedAsHead) return true;
	bool moved = true;
	immutable lower = self.head < index;
	foreach (p; fp.dynarray.slice(self.provisional)) {
		if (fallbackHeld && lower && moved) {
			ecrs.context.getComponent!ProvisionalOn(*engine.store, p).head = engine.stack[self.head].query;
			if (fp.dynarray.pushBack(engine.stack[self.head].provisional, p)) continue;
			moved = false;
		}
		clearProvisional(engine, p);
		if (!fallbackHeld || lower) ecrs.context.getComponent!QueryInfo(*engine.store, p).reset(engine, p);
	}
	fp.dynarray.free(self.provisional);
	return moved;
}

// Marks `q` provisional if it rests on a lower frame's fallback, and tags it if its run joined a cycle. Returns false on refusal.
private bool markCycle(ref QueryEngine engine, EntityId q, ref Frame self, size_t index) {
	if (self.head < index) {
		auto head = &engine.stack[self.head];
		auto mark = ecrs.context.getOrAddComponent!ProvisionalOn(*engine.store, q);
		if (mark is null) return false;
		mark.head = head.query;
		if (!fp.dynarray.pushBack(head.provisional, q)) {
			clearProvisional(engine, q);
			return false;
		}
	}
	immutable tagged = ecrs.context.hasComponent!InCycle(*engine.store, q);
	if (self.cycle && !tagged) return ecrs.context.addComponent!InCycle(*engine.store, q) !is null;
	if (!self.cycle && tagged) ecrs.context.removeComponent!InCycle(*engine.store, q);
	return true;
}

// Runs `q` and stores its value. Returns false, leaving `q` reset, if a refused allocation failed the run here or in a query it demanded.
private bool execute(Q)(ref QueryEngine engine, EntityId q) {
	auto store = engine.store;
	removeProduced(engine, q);
	clearDiagnostics(engine, q);
	clearProvisional(engine, q);
	auto deps = &ecrs.context.getComponent!DependsOn(*store, q);
	if (deps.related !is null) fp.dynarray.clear(deps.related);

	auto running = ecrs.context.addComponent!Running(*store, q);
	if (running is null || !fp.dynarray.pushBack(engine.stack, Frame(q, 0))) {
		if (running !is null) ecrs.context.removeComponent!Running(*store, q);
		fail(engine);
		reset!Q(engine, q);
		return false;
	}
	running.frame = fp.dynarray.length(engine.stack) - 1;
	auto key = ecrs.context.getComponent!(QueryKey!Q)(*store, q).key;
	auto value = Q.compute(engine, key);
	auto frame = *fp.dynarray.back(engine.stack);
	cast(void) fp.dynarray.popBack(engine.stack);
	ecrs.context.removeComponent!Running(*store, q);
	immutable index = fp.dynarray.length(engine.stack);

	QueryValue!Q* stored = null;
	bool fresh = false;
	if (!frame.refused) {
		removeCreated(engine, q, frame.created);
		stored = ecrs.context.findComponent!(QueryValue!Q)(*store, q);
		fresh = stored is null;
		if (fresh && (stored = ecrs.context.addComponent!(QueryValue!Q)(*store, q)) is null) fail(engine);
	}
	if (stored is null) {
		fp.lifecycle.endLifetime(value);
		cast(void) settleProvisional(engine, frame, index, false);
		reset!Q(engine, q);
		return false;
	}

	immutable hash = hashProduced(engine, q);
	auto produces = &ecrs.context.getComponent!Produces(*store, q);
	bool changed = fresh || produces.hash != hash;
	produces.hash = hash;
	if (fresh || !valuesEqual!Q(stored.value, value)) {
		fp.lifecycle.moveInto(stored.value, value);
		changed = true;
	} else fp.lifecycle.endLifetime(value);
	if (changed) ecrs.context.getComponent!ChangedAt(*store, q).revision = engine.revision;
	ecrs.context.getComponent!VerifiedAt(*store, q).revision = engine.revision;

	bool fallbackHeld = true;
	static if (__traits(hasMember, Q, "cycleFallback"))
		if (frame.usedAsHead) {
			auto assumed = Q.cycleFallback(engine, key);
			fallbackHeld = valuesEqual!Q(ecrs.context.getComponent!(QueryValue!Q)(*store, q).value, assumed);
			fp.lifecycle.endLifetime(assumed);
		}
	if (!settleProvisional(engine, frame, index, fallbackHeld) || !markCycle(engine, q, frame, index)) {
		fail(engine);
		reset!Q(engine, q);
		return false;
	}
	emitAll(engine, q);
	return true;
}

private bool refresh(Q)(ref QueryEngine engine, EntityId q) {
	if (frameOf(engine, q) != noFrame) return false;
	auto store = engine.store;
	immutable hasValue = ecrs.context.hasComponent!(QueryValue!Q)(*store, q);
	if (hasValue && ecrs.context.getComponent!VerifiedAt(*store, q).revision == engine.revision) return true;
	if (engine.depth >= engine.depthLimit) {
		reportDepth(engine, q);
		return false;
	}
	++engine.depth;
	scope(exit) --engine.depth;
	if (!hasValue || ecrs.context.hasComponent!InCycle(*store, q) || !dependenciesUnchanged(engine, q)) return execute!Q(engine, q);
	ecrs.context.getComponent!VerifiedAt(*store, q).revision = engine.revision;
	emitAll(engine, q);
	return true;
}

private void reset(Q)(ref QueryEngine engine, EntityId q) {
	assert(frameOf(engine, q) == noFrame);
	removeProduced(engine, q);
	removeCreated(engine, q, 0);
	clearDiagnostics(engine, q);
	clearProvisional(engine, q);
	if (ecrs.context.hasComponent!(QueryValue!Q)(*engine.store, q))
		ecrs.context.removeComponent!(QueryValue!Q)(*engine.store, q);
	ecrs.context.getComponent!VerifiedAt(*engine.store, q).revision = 0;
}

// A demand for `q`, which is running in frame `h`: every frame from `h` up is part of the cycle.
private const(Q.Value)* cycle(Q)(ref QueryEngine engine, EntityId q, size_t h) {
	immutable top = fp.dynarray.length(engine.stack) - 1;
	foreach (ref frame; engine.stack[h .. top + 1]) frame.cycle = true;
	if (!recordRead(engine, q)) return null;
	static if (__traits(hasMember, Q, "cycleFallback")) {
		static Q.Value fallback;
		fp.lifecycle.endLifetime(fallback);
		fallback = Q.cycleFallback(engine, ecrs.context.getComponent!(QueryKey!Q)(*engine.store, q).key);
		engine.stack[h].usedAsHead = true;
		if (h < top && h < engine.stack[top].head) engine.stack[top].head = h;
		return &fallback;
	} else {
		cast(void) reportChain(engine, "Q-Cycle: a query needs its own answer: ", h); // the demand returns null either way
		return null;
	}
}

/// The value of `Q` at `key`, as `doir.api.query.query` documents: found or added, refreshed, and recorded as read, or on a cycle, the fallback or null. A refused allocation returns null and fails the running queries (`fail`).
///
/// Examples:
/// ---
/// static import ecrs.context;
/// struct Triple {
/// 	alias Key = int;
/// 	alias Value = int;
/// 	static int compute(ref QueryEngine engine, int key) @nogc nothrow { return 3 * key; }
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// QueryEngine engine;
/// engine.store = &store;
/// scope(exit) release(engine);
/// assert(*demand!Triple(engine, 2) == 6);
/// ---
package(doir) const(Q.Value)* demand(Q)(ref QueryEngine engine, Q.Key key) if (isQuery!Q) {
	auto q = find!Q(engine, key);
	if (q == invalidEntity && (q = add!Q(engine, key)) == invalidEntity) {
		fail(engine);
		return null;
	}
	immutable h = frameOf(engine, q);
	if (h != noFrame) return cycle!Q(engine, q, h);
	if (!refresh!Q(engine, q) || !recordRead(engine, q)) return null;
	return &ecrs.context.getComponent!(QueryValue!Q)(*engine.store, q).value;
}

/// Discards the value of `Q` at `key` and what it produced and created, as `doir.api.query.evict` documents.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// struct Once {
/// 	alias Key = int;
/// 	alias Value = int;
/// 	static int compute(ref QueryEngine engine, int key) @nogc nothrow { return key; }
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// QueryEngine engine;
/// engine.store = &store;
/// scope(exit) release(engine);
/// assert(*demand!Once(engine, 4) == 4);
/// discard!Once(engine, 4);
/// ---
package(doir) void discard(Q)(ref QueryEngine engine, Q.Key key) if (isQuery!Q) {
	immutable q = find!Q(engine, key);
	if (q == invalidEntity) return;
	reset!Q(engine, q);
}
