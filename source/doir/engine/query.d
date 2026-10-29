/// The query engine's machinery (`roadmap.md` Phase 1): the components a query entity carries, the engine's state, and demand, validation, execution and cycle handling. Programs use it through `doir.query`, which re-exports the public functions here.
///
/// A refused allocation fails every query running at the time (`fail`): each keeps no value and returns null to its demander, so nothing computed from a partial run is memoized. `QueryEngine.refused` records that it happened. Work outside a run, such as adding a query entity or delivering a diagnostic, reports through its result and the same flag.
module doir.engine.query;

static import core.stdc.string;
static import std.typecons;

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

static import doir.engine.locations;
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

/// Another entity a query's diagnostic involves, `target`, drawn as an annotation at it saying what part it plays.
struct QueryAnnotation {
	mixin ecrs.relation.Relates!"target";
	char* message = null; /// An owned fp string.
}

/// A diagnostic a query reported: the entity it is about, `subject`, or `invalidEntity`, how severe it is, its message, the hint saying how to fix it, and the other entities involved. Its locations are resolved from the entities only when it is reported.
struct QueryDiagnostic {
	mixin ecrs.relation.Relates!"subject";
	diagnose.Kind kind; /// How severe it is.
	char* message = null; /// An owned fp string.
	char* hint = null; /// An owned fp string, drawn as an annotation at `subject`, or as the closing note if `subject` has no location.
	QueryAnnotation* annotations = null; /// An owned fp dynarray, an annotation at each other entity involved.
}

/// Frees what `d` owns, nulling its pointers.
///
/// Examples:
/// ---
/// static import fp.string;
/// static import diagnose;
/// auto d = QueryDiagnostic([1], diagnose.Kind.error, fp.string.makeDynamic("bad"));
/// freeDiagnostic(d);
/// assert(d.message is null);
/// ---
package(doir) void freeDiagnostic(ref QueryDiagnostic d) {
	fp.string.free(d.message);
	fp.string.free(d.hint);
	foreach (ref a; fp.dynarray.slice(d.annotations)) fp.string.free(a.message);
	fp.dynarray.free(d.annotations);
	d.message = d.hint = null;
	d.annotations = null;
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
		foreach (ref d; fp.dynarray.slice(self.items)) {
			QueryDiagnostic.remapEntities(d, remap);
			foreach (ref a; fp.dynarray.slice(d.annotations)) QueryAnnotation.remapEntities(a, remap);
		}
	}
	/// Releases the diagnostics and the list.
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
		foreach (ref d; fp.dynarray.slice(items)) freeDiagnostic(d);
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
		&& ecrs.registry.hasRemapEntities!Provenance && ecrs.registry.hasRemapEntities!QueryDiagnostics && ecrs.registry.hasRemapEntities!QueryAnnotation && ecrs.registry.hasRemapEntities!ProvisionalOn);
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

/// True if `Q` follows the query protocol `doir.query` documents. A key's lifetime must be its bytes, since the index holds a bit copy of it.
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

/// The engine: the store it works on, the current revision, where diagnostics go, the order keys of lexical positions, and the stack of running queries. Renumber the store only through `doir.query.renumber` and `compact`, which require that no query is running.
struct QueryEngine {
	ecrs.context.Context* store; /// The store, which must outlive the engine.
	Revision revision = 1; /// The current revision.
	size_t depthLimit = defaultDepthLimit; /// How deep demands may nest before `Q-Cycle` is reported instead of overflowing the stack.
	diagnose.Manager* diagnostics = null; /// Where reported diagnostics go, each once per revision; null discards them, though queries still record theirs.
	bool refused = false; /// Set when an allocation was refused: every query running at the time failed, keeping no value, or a diagnostic was lost on its way to `diagnostics`. The engine never clears it.
	doir.engine.positions.Positions positions; /// The order keys of every positioned effect and read (`C-Order`), made with `doir.positions.between`.
	package(doir) Frame* stack = null;
	package(doir) size_t depth = 0;
}


// --- entry points re-exported by doir.query -----------------------------

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
/// free(engine);
/// ---
package(doir) bool idle(ref QueryEngine engine) {
	return fp.dynarray.length(engine.stack) == 0;
}

private size_t frameOf(ref QueryEngine engine, EntityId q) {
	if (idle(engine)) return noFrame;
	auto running = ecrs.context.findComponent!Running(*engine.store, q);
	return running is null ? noFrame : running.frame;
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
	engine.refused = true;
	foreach (ref frame; fp.dynarray.slice(engine.stack)) frame.refused = true;
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
	doir.engine.positions.free(engine.positions);
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
	return idle(engine) ? invalidEntity : fp.dynarray.back(engine.stack).query;
}

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

/// Records that the running query wrote component `item.component` on `item.entity`, to be removed by `item.strip` before the query runs again and when it is evicted, and hashed by `item.hash` for early cutoff. Unless `unique`, a repeat record of the same pair in one run is ignored. Use `doir.query.produce` for a whole component; this is for components that several queries write parts of, such as effect logs. Returns false on a refused allocation, which fails the running queries (`fail`).
///
/// Examples:
/// ---
/// static import fp.dynarray;
/// static import ecrs.context;
/// static import ecrs.registry;
/// static void strip(ref ecrs.context.Context store, EntityId e, size_t c, EntityId owner) @nogc nothrow {}
/// static size_t hash(ref const ecrs.context.Context store, EntityId e, size_t c, EntityId owner) @nogc nothrow { return 0; }
/// struct Claim {
/// 	alias Key = int;
/// 	alias Value = size_t;
/// 	static size_t compute(ref QueryEngine engine, int key) @nogc nothrow {
/// 		immutable item = Produced([currentQuery(engine)], ecrs.registry.componentId!int(), &strip, &hash);
/// 		if (!recordProduced(engine, item, false) || !recordProduced(engine, item, false)) return 0;
/// 		return fp.dynarray.length(ecrs.context.getComponent!Produces(*engine.store, currentQuery(engine)).items);
/// 	}
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// QueryEngine engine;
/// engine.store = &store;
/// scope(exit) free(engine);
/// assert(*query!Claim(engine, 1) == 1);
/// ---
bool recordProduced(ref QueryEngine engine, Produced item, bool unique) {
	immutable q = currentQuery(engine);
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
/// scope(exit) free(engine);
/// immutable made = query!Spawn(engine, 1).related[0];
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

// A copy of the fp string `message`, a null `char*` for a null `message`. Null if refused.
private std.typecons.Nullable!(char*) copyText(const(char)* message) {
	auto copy = fp.string.makeDynamic(fp.string.slice(message));
	if (copy is null && message !is null) return typeof(return).init;
	return typeof(return)(copy);
}

// Copies `d` to `engine.diagnostics`, the hint annotating `subject`, or as the closing note if unlocated. Refusal drops it and sets `engine.refused` without failing any query.
private bool emit(ref QueryEngine engine, ref const QueryDiagnostic d) {
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

/// Stores `d`, whose strings and annotations it takes over, on the running query, or outside any query reports it to `engine.diagnostics` and frees it. Returns false on a refused allocation, which frees them and fails the running queries (`fail`).
///
/// Examples:
/// ---
/// QueryEngine engine;
/// assert(recordDiagnostic(engine, QueryDiagnostic.init));
/// ---
package(doir) bool recordDiagnostic(ref QueryEngine engine, QueryDiagnostic d) {
	immutable q = currentQuery(engine);
	if (q == invalidEntity) {
		immutable emitted = emit(engine, d);
		freeDiagnostic(d);
		return emitted;
	}
	if (fp.dynarray.pushBack(ecrs.context.getComponent!QueryDiagnostics(*engine.store, q).items, d)) return true;
	freeDiagnostic(d);
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
	foreach (ref d; fp.dynarray.slice(list.items)) freeDiagnostic(d);
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

/// How to fix a `Q-Cycle` chain, the closing note of its report.
package(doir) enum cycleHint = "each query in the chain needs the next; break the loop by removing one of those dependencies, such as an import that leads back to its own file";

/// How to fix demands nested past the depth limit, the closing note of its report.
package(doir) enum depthHint = "nest these declarations or imports less deeply, or raise the engine's depth limit";

// Records a `Q-Cycle` error naming the frames from `from` up and back. On refusal returns false, failing the running queries so none memoizes without it.
private bool reportChain(ref QueryEngine engine, const(char)[] headline, size_t from) {
	char* message = fp.string.makeDynamic(headline);
	bool built = message !is null;
	foreach (frame; engine.stack[from .. fp.dynarray.length(engine.stack)])
		built = built && ecrs.context.getComponent!QueryInfo(*engine.store, frame.query).describe(engine, frame.query, message)
			&& fp.string.concatenate(message, " -> ") !is null;
	immutable head = engine.stack[from].query;
	built = built && ecrs.context.getComponent!QueryInfo(*engine.store, head).describe(engine, head, message);
	char* hint = built ? fp.string.makeDynamic(cycleHint) : null;
	if (hint !is null) return recordDiagnostic(engine, QueryDiagnostic([invalidEntity], diagnose.Kind.error, message, hint));
	fp.string.free(message);
	fail(engine);
	return false;
}

// Records a `Q-Cycle` error for demands nested past the depth limit at `q`, failing the running queries on a refused allocation as `reportChain` does.
private void reportDepth(ref QueryEngine engine, EntityId q) {
	char* message = fp.string.format("Q-Cycle: queries nest deeper than the limit of %llu at ", cast(ulong) engine.depthLimit);
	char* hint = message !is null && ecrs.context.getComponent!QueryInfo(*engine.store, q).describe(engine, q, message) ? fp.string.makeDynamic(depthHint) : null;
	if (hint !is null) cast(void) recordDiagnostic(engine, QueryDiagnostic([invalidEntity], diagnose.Kind.error, message, hint)); // fails the running queries itself
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
	if (ecrs.context.hasComponent!ProvisionalOn(*engine.store, p)) cast(void) ecrs.context.removeComponent!ProvisionalOn(*engine.store, p);
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
	if (!self.cycle && tagged) cast(void) ecrs.context.removeComponent!InCycle(*engine.store, q);
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
		if (running !is null) cast(void) ecrs.context.removeComponent!Running(*store, q);
		fail(engine);
		reset!Q(engine, q);
		return false;
	}
	running.frame = fp.dynarray.length(engine.stack) - 1;
	auto key = ecrs.context.getComponent!(QueryKey!Q)(*store, q).key;
	auto value = Q.compute(engine, key);
	auto frame = *fp.dynarray.back(engine.stack);
	cast(void) fp.dynarray.popBack(engine.stack);
	cast(void) ecrs.context.removeComponent!Running(*store, q);
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
		cast(void) ecrs.context.removeComponent!(QueryValue!Q)(*engine.store, q);
	ecrs.context.getComponent!VerifiedAt(*engine.store, q).revision = 0;
}

// A demand for `q`, which is running in frame `h`: every frame from `h` up is part of the cycle.
private const(Q.Value)* cycle(Q)(ref QueryEngine engine, EntityId q, size_t h) {
	immutable top = fp.dynarray.length(engine.stack) - 1;
	foreach (ref frame; engine.stack[h .. top + 1]) frame.cycle = true;
	if (!read(engine, q)) return null;
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
	auto q = find!Q(engine, key);
	if (q == invalidEntity && (q = add!Q(engine, key)) == invalidEntity) {
		fail(engine);
		return null;
	}
	immutable h = frameOf(engine, q);
	if (h != noFrame) return cycle!Q(engine, q, h);
	if (!refresh!Q(engine, q) || !read(engine, q)) return null;
	return &ecrs.context.getComponent!(QueryValue!Q)(*engine.store, q).value;
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
