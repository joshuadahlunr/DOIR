/// The query engine's machinery (`roadmap.md` Phase 1): the components a query entity carries, the engine's state, and demand, validation, execution and cycle handling. Programs use it through `doir.api.query`, which documents the query protocol; the `package` functions here are the entry points that module calls.
///
/// Allocation failure is a fatal assert: a query that runs out of memory leaves no state worth keeping.
module doir.engine.query;

static import core.stdc.string;

static import fp.dynarray;
static import fp.fnv1a;
static import fp.hashtable;
static import fp.lifecycle;
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

private void append(T)(ref T* list, T value) {
	immutable pushed = fp.dynarray.pushBack(list, value);
	assert(pushed, "doir.query: allocation refused");
}

private ref C attach(C)(ref ecrs.context.Context store, EntityId e) {
	auto component = ecrs.context.addComponent!C(store, e);
	assert(component !is null, "doir.query: allocation refused");
	return *component;
}

private size_t mix(size_t h, size_t value) {
	return (h ^ value) * 0x100000001b3;
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

unittest { // libECRS silently skips a holder whose hook is not `@nogc nothrow`; every holder of an entity id must pass (E-Remap)
	static assert(ecrs.registry.hasRemapEntities!DependsOn && ecrs.registry.hasRemapEntities!Produces && ecrs.registry.hasRemapEntities!Creates
		&& ecrs.registry.hasRemapEntities!Provenance && ecrs.registry.hasRemapEntities!QueryDiagnostics && ecrs.registry.hasRemapEntities!ProvisionalOn);
}

/// Brings query entity `q` up to date, re-running it if needed. Returns false if it cannot: `q` is already running, or the depth limit is reached.
alias RefreshFunction = bool function(ref QueryEngine engine, EntityId q) @nogc nothrow;

/// Discards query entity `q`'s value and what it produced and created, so the next demand runs it.
alias ResetFunction = void function(ref QueryEngine engine, EntityId q) @nogc nothrow;

/// Appends a description of query entity `q`, such as `Layout(12)`, to an fp string.
alias DescribeFunction = void function(ref QueryEngine engine, EntityId q, ref char* out_) @nogc nothrow;

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

private TableEntry!Q* createTable(Q)() {
	fp.hashtable.Config config;
	config.hashFunction = &hashTableEntry!Q;
	config.equalFunction = &equalTableEntry!Q;
	auto table = fp.hashtable.create!(TableEntry!Q)(config);
	assert(table !is null, "doir.query: allocation refused");
	return table;
}

/// The index from key to query entity for query type `Q`, held as a component on an entity of its own. A renumbering rewrites its keys and ids and rehashes it (`E-Remap`). Keys that a compaction maps to the same key keep one query entity; the others are no longer found.
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

	/// The `E-Remap` hook libECRS finds by name: rewrites every entry and rebuilds the table, since a rewritten key hashes differently.
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
		auto fresh = createTable!Q();
		foreach (stored; fp.hashtable.occupied(self.table)) {
			TableEntry!Q entry = *stored;
			static if (ecrs.registry.hasRemapEntities!(Q.Key)) Q.Key.remapEntities(entry.key, remap);
			TableEntry!Q.remapEntities(entry, remap);
			if (entry.query == invalidEntity) continue;
			immutable inserted = fp.hashtable.insert(fresh, entry) !is null;
			assert(inserted, "doir.query: allocation refused");
		}
		fp.hashtable.free(self.table);
		self.table = fresh;
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
}

/// The depth of nested demands and re-validations a new engine allows before reporting `Q-Cycle`, well inside a default 8 MiB stack.
enum size_t defaultDepthLimit = 4096;

/// The engine: the store it works on, the current revision, where diagnostics go, the order keys of lexical positions, and the stack of running queries. Renumber the store only through `doir.api.query.renumber` and `compact`, which require that no query is running.
struct QueryEngine {
	ecrs.context.Context* store; /// The store, which must outlive the engine.
	Revision revision = 1; /// The current revision.
	size_t depthLimit = defaultDepthLimit; /// How deep demands may nest before `Q-Cycle` is reported instead of overflowing the stack.
	diagnose.Manager* diagnostics = null; /// Where reported diagnostics go, each once per revision; null discards them, though queries still record theirs.
	package(doir) doir.engine.positions.Positions positions; // the order keys of every positioned effect and read (C-Order)
	package(doir) Frame* stack = null;
	package(doir) size_t depth = 0;
}


// --- entry points for doir.api ----------------------------------------------

private size_t frameOf(ref QueryEngine engine, EntityId q) {
	foreach (i, frame; fp.dynarray.slice(engine.stack))
		if (frame.query == q) return i;
	return noFrame;
}

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

/// Records that the running query read `e`, and if `e` is a provisional answer, that its value rests on the same cycle fallback. Does nothing outside a query.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// QueryEngine engine;
/// engine.store = &store;
/// recordRead(engine, ecrs.context.addEntity(store));
/// ---
package(doir) void recordRead(ref QueryEngine engine, EntityId e) {
	immutable n = fp.dynarray.length(engine.stack);
	if (n == 0) return;
	auto top = &engine.stack[n - 1];
	if (top.query == e) return;
	if (auto provisional = ecrs.context.findComponent!ProvisionalOn(*engine.store, e)) {
		immutable h = frameOf(engine, provisional.head);
		assert(h != noFrame);
		top.cycle = true;
		if (h < n - 1 && h < top.head) top.head = h;
	}
	auto deps = &ecrs.context.getComponent!DependsOn(*engine.store, top.query);
	foreach (d; fp.dynarray.slice(deps.related))
		if (d == e) return;
	append(deps.related, e);
}

/// Adds `item` to the running query's `Produces` list, unless `unique` is false and the list already has its (entity, component) pair.
///
/// Examples:
/// ---
/// QueryEngine engine;
/// assert(innermost(engine) == invalidEntity); // recordProduced is only valid inside a query
/// ---
package(doir) void recordProduced(ref QueryEngine engine, Produced item, bool unique) {
	immutable q = innermost(engine);
	assert(q != invalidEntity, "doir.query: writing a component outside a query");
	auto produces = &ecrs.context.getComponent!Produces(*engine.store, q);
	if (!unique)
		foreach (existing; fp.dynarray.slice(produces.items))
			if (existing.entity == item.entity && existing.component == item.component) return;
	append(produces.items, item);
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

/// The running query's next created entity: the one its previous run created at the same sequence number, or a fresh one.
///
/// Examples:
/// ---
/// QueryEngine engine;
/// assert(innermost(engine) == invalidEntity); // nextCreated is only valid inside a query
/// ---
package(doir) EntityId nextCreated(ref QueryEngine engine) {
	assert(!idle(engine), "doir.query: creating an entity outside a query");
	auto frame = fp.dynarray.back(engine.stack);
	auto creates = &ecrs.context.getComponent!Creates(*engine.store, frame.query);
	immutable sequence = frame.created++;
	if (sequence < fp.dynarray.length(creates.related)) return creates.related[sequence];
	immutable e = ecrs.context.addEntity(*engine.store);
	assert(e != invalidEntity, "doir.query: allocation refused");
	append(ecrs.context.getComponent!Creates(*engine.store, frame.query).related, e);
	return e;
}

private void emit(ref QueryEngine engine, ref const QueryDiagnostic d) {
	if (engine.diagnostics is null) return;
	diagnose.Diagnostic out_;
	out_.kind = d.kind;
	out_.message = fp.string.makeDynamic(fp.string.slice(d.message));
	immutable pushed = diagnose.push(*engine.diagnostics, out_) !is null;
	assert(pushed, "doir.query: allocation refused");
}

/// Stores `d`, whose message it takes over, on the running query, or outside any query reports it to `engine.diagnostics` and frees it.
///
/// Examples:
/// ---
/// QueryEngine engine;
/// recordDiagnostic(engine, QueryDiagnostic.init);
/// ---
package(doir) void recordDiagnostic(ref QueryEngine engine, QueryDiagnostic d) {
	immutable q = innermost(engine);
	if (q == invalidEntity) {
		emit(engine, d);
		fp.string.free(d.message);
		return;
	}
	append(ecrs.context.getComponent!QueryDiagnostics(*engine.store, q).items, d);
}


// --- running and validating queries ------------------------------------------

private void removeProduced(ref QueryEngine engine, EntityId q) {
	auto produces = &ecrs.context.getComponent!Produces(*engine.store, q);
	foreach (item; fp.dynarray.slice(produces.items)) item.strip(*engine.store, item.entity, item.component, q);
	if (produces.items !is null) fp.dynarray.clear(produces.items);
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

// Removes the created entities past `keep`, the ones the latest run no longer made.
private void removeCreated(ref QueryEngine engine, EntityId q, size_t keep) {
	auto creates = &ecrs.context.getComponent!Creates(*engine.store, q);
	immutable n = fp.dynarray.length(creates.related);
	if (keep >= n) return;
	foreach (e; creates.related[keep .. n]) {
		immutable removed = ecrs.context.removeEntity(*engine.store, e);
		assert(removed, "doir.query: allocation refused");
	}
	fp.dynarray.popBackCount(creates.related, n - keep);
}

private void clearDiagnostics(ref QueryEngine engine, EntityId q) {
	auto list = &ecrs.context.getComponent!QueryDiagnostics(*engine.store, q);
	foreach (ref d; fp.dynarray.slice(list.items)) fp.string.free(d.message);
	if (list.items !is null) fp.dynarray.clear(list.items);
}

private void emitAll(ref QueryEngine engine, EntityId q) {
	foreach (ref d; fp.dynarray.slice(ecrs.context.getComponent!QueryDiagnostics(*engine.store, q).items)) 
		emit(engine, d);
}

/// The query entity of `Q` at `key`, or `invalidEntity` if `Q` was never demanded there.
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
	auto storage = ecrs.context.getStorage!(QueryTable!Q)(*engine.store);
	if (storage is null) return invalidEntity;
	foreach (slot; 0 .. ecrs.storage.size(*storage)) {
		if (ecrs.storage.owner(*storage, slot) == invalidEntity) continue;
		auto found = fp.hashtable.find(ecrs.storage.get!(QueryTable!Q)(*storage, slot).table, TableEntry!Q([invalidEntity], key));
		return found is null ? invalidEntity : found.query;
	}
	return invalidEntity;
}

private void index(Q)(ref QueryEngine engine, ref const Q.Key key, EntityId q) @trusted {
	auto storage = ecrs.context.getStorage!(QueryTable!Q)(*engine.store);
	QueryTable!Q* table = null;
	if (storage !is null)
		foreach (slot; 0 .. ecrs.storage.size(*storage))
			if (ecrs.storage.owner(*storage, slot) != invalidEntity) {
				table = &ecrs.storage.get!(QueryTable!Q)(*storage, slot);
				break;
			}
	if (table is null) {
		immutable holder = ecrs.context.addEntity(*engine.store);
		assert(holder != invalidEntity, "doir.query: allocation refused");
		table = &attach!(QueryTable!Q)(*engine.store, holder);
		table.table = createTable!Q();
	}
	immutable inserted = fp.hashtable.insert(table.table, TableEntry!Q([q], key)) !is null;
	assert(inserted, "doir.query: allocation refused");
}

private void describe(Q)(ref QueryEngine engine, EntityId q, ref char* out_) @trusted {
	immutable named = fp.string.concatenate(out_, __traits(identifier, Q)) !is null;
	assert(named, "doir.query: allocation refused");
	auto key = &ecrs.context.getComponent!(QueryKey!Q)(*engine.store, q).key;
	static if (__traits(hasMember, Q, "describeKey")) {
		Q.describeKey(*key, out_);
	} else static if (__traits(isIntegral, Q.Key)) {
		static if (__traits(isUnsigned, Q.Key)) auto text = fp.string.format("(%llu)", cast(ulong) *key);
		else auto text = fp.string.format("(%lld)", cast(long) *key);
		assert(text !is null, "doir.query: allocation refused");
		scope(exit) fp.string.free(text);
		immutable keyed = fp.string.concatenate(out_, fp.string.slice(text)) !is null;
		assert(keyed, "doir.query: allocation refused");
	}
}

private EntityId add(Q)(ref QueryEngine engine, ref const Q.Key key) {
	auto store = engine.store;
	immutable q = ecrs.context.addEntity(*store);
	assert(q != invalidEntity, "doir.query: allocation refused");
	attach!(QueryKey!Q)(*store, q).key = key;
	attach!QueryInfo(*store, q) = QueryInfo(&refresh!Q, &reset!Q, &describe!Q);
	attach!ChangedAt(*store, q);
	attach!VerifiedAt(*store, q);
	attach!DependsOn(*store, q);
	attach!Produces(*store, q);
	attach!Creates(*store, q);
	attach!QueryDiagnostics(*store, q);
	index!Q(engine, key, q);
	return q;
}

private void reportChain(ref QueryEngine engine, const(char)[] headline, size_t from) {
	char* message = fp.string.makeDynamic(headline);
	assert(message !is null, "doir.query: allocation refused");
	scope(exit) fp.string.free(message);
	foreach (frame; engine.stack[from .. fp.dynarray.length(engine.stack)]) {
		ecrs.context.getComponent!QueryInfo(*engine.store, frame.query).describe(engine, frame.query, message);
		immutable arrow = fp.string.concatenate(message, " -> ") !is null;
		assert(arrow, "doir.query: allocation refused");
	}
	immutable head = engine.stack[from].query;
	ecrs.context.getComponent!QueryInfo(*engine.store, head).describe(engine, head, message);
	auto copy = fp.string.makeDynamic(fp.string.slice(message));
	assert(copy !is null, "doir.query: allocation refused");
	recordDiagnostic(engine, QueryDiagnostic([invalidEntity], diagnose.Kind.error, copy));
}

private void reportDepth(ref QueryEngine engine, EntityId q) {
	char* message = fp.string.format("Q-Cycle: queries nest deeper than the limit of %llu at ", cast(ulong) engine.depthLimit);
	assert(message !is null, "doir.query: allocation refused");
	scope(exit) fp.string.free(message);
	ecrs.context.getComponent!QueryInfo(*engine.store, q).describe(engine, q, message);
	auto copy = fp.string.makeDynamic(fp.string.slice(message));
	assert(copy !is null, "doir.query: allocation refused");
	recordDiagnostic(engine, QueryDiagnostic([invalidEntity], diagnose.Kind.error, copy));
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
/// QueryEngine engine;
/// assert(!running(engine, 1)); // refreshQuery needs a query entity
/// ---
package(doir) bool refreshQuery(ref QueryEngine engine, EntityId q) {
	return ecrs.context.getComponent!QueryInfo(*engine.store, q).refresh(engine, q);
}

/// Reports, on the innermost query, that it needs an effect of running query `q` (`Q-Cycle`), naming the chain from `q` up, and marks that chain as part of a cycle.
///
/// Examples:
/// ---
/// QueryEngine engine;
/// assert(!running(engine, 1)); // reportRunning needs `q` on the stack
/// ---
package(doir) void reportRunning(ref QueryEngine engine, EntityId q) {
	immutable h = frameOf(engine, q);
	assert(h != noFrame);
	foreach (ref frame; engine.stack[h .. fp.dynarray.length(engine.stack)]) frame.cycle = true;
	reportChain(engine, "Q-Cycle: a read needs an effect of a query that is still running: ", h);
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

// Confirms or discards the queries resting on frame `self`'s fallback, then marks `q` provisional if its own value rests on a lower frame's.
private void settle(ref QueryEngine engine, EntityId q, ref Frame self, size_t index, bool fallbackHeld) {
	if (self.usedAsHead) {
		immutable lower = self.head < index;
		foreach (p; fp.dynarray.slice(self.provisional)) {
			if (!fallbackHeld) {
				clearProvisional(engine, p);
				ecrs.context.getComponent!QueryInfo(*engine.store, p).reset(engine, p);
			} else if (lower) {
				ecrs.context.getComponent!ProvisionalOn(*engine.store, p).head = engine.stack[self.head].query;
				append(engine.stack[self.head].provisional, p);
			} else clearProvisional(engine, p);
		}
		fp.dynarray.free(self.provisional);
	}
	if (self.head < index) {
		auto head = &engine.stack[self.head];
		auto mark = ecrs.context.getOrAddComponent!ProvisionalOn(*engine.store, q);
		assert(mark !is null, "doir.query: allocation refused");
		mark.head = head.query;
		append(head.provisional, q);
	}
	immutable tagged = ecrs.context.hasComponent!InCycle(*engine.store, q);
	if (self.cycle && !tagged) cast(void) attach!InCycle(*engine.store, q);
	else if (!self.cycle && tagged) ecrs.context.removeComponent!InCycle(*engine.store, q);
}

private void execute(Q)(ref QueryEngine engine, EntityId q) {
	auto store = engine.store;
	removeProduced(engine, q);
	clearDiagnostics(engine, q);
	clearProvisional(engine, q);
	auto deps = &ecrs.context.getComponent!DependsOn(*store, q);
	if (deps.related !is null) fp.dynarray.clear(deps.related);

	append(engine.stack, Frame(q, 0));
	auto key = ecrs.context.getComponent!(QueryKey!Q)(*store, q).key;
	auto value = Q.compute(engine, key);
	auto frame = *fp.dynarray.back(engine.stack);
	fp.dynarray.popBack(engine.stack);
	removeCreated(engine, q, frame.created);

	immutable hash = hashProduced(engine, q);
	auto produces = &ecrs.context.getComponent!Produces(*store, q);
	bool changed = produces.hash != hash;
	produces.hash = hash;
	if (auto old = ecrs.context.findComponent!(QueryValue!Q)(*store, q)) {
		if (!valuesEqual!Q(old.value, value)) {
			fp.lifecycle.moveInto(old.value, value);
			changed = true;
		} else fp.lifecycle.endLifetime(value);
	} else {
		fp.lifecycle.moveInto(attach!(QueryValue!Q)(*store, q).value, value);
		changed = true;
	}
	if (changed) ecrs.context.getComponent!ChangedAt(*store, q).revision = engine.revision;
	ecrs.context.getComponent!VerifiedAt(*store, q).revision = engine.revision;

	bool fallbackHeld = true;
	static if (__traits(hasMember, Q, "cycleFallback"))
		if (frame.usedAsHead) {
			auto assumed = Q.cycleFallback(engine, key);
			fallbackHeld = valuesEqual!Q(ecrs.context.getComponent!(QueryValue!Q)(*store, q).value, assumed);
			fp.lifecycle.endLifetime(assumed);
		}
	settle(engine, q, frame, fp.dynarray.length(engine.stack), fallbackHeld);
	emitAll(engine, q);
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
	if (hasValue && !ecrs.context.hasComponent!InCycle(*store, q) && dependenciesUnchanged(engine, q)) {
		ecrs.context.getComponent!VerifiedAt(*store, q).revision = engine.revision;
		emitAll(engine, q);
	} else
		execute!Q(engine, q);
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
	recordRead(engine, q);
	static if (__traits(hasMember, Q, "cycleFallback")) {
		static Q.Value fallback;
		fp.lifecycle.endLifetime(fallback);
		fallback = Q.cycleFallback(engine, ecrs.context.getComponent!(QueryKey!Q)(*engine.store, q).key);
		engine.stack[h].usedAsHead = true;
		if (h < top && h < engine.stack[top].head) engine.stack[top].head = h;
		return &fallback;
	} else {
		reportChain(engine, "Q-Cycle: a query needs its own answer: ", h);
		return null;
	}
}

/// The value of `Q` at `key`, as `doir.api.query.query` documents: found or added, refreshed, and recorded as read, or on a cycle, the fallback or null.
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
	if (q == invalidEntity) q = add!Q(engine, key);
	immutable h = frameOf(engine, q);
	if (h != noFrame) return cycle!Q(engine, q, h);
	if (!refresh!Q(engine, q)) return null;
	recordRead(engine, q);
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
