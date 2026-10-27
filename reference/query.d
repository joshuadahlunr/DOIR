/// A minimal demand-driven query engine over the libECRS store (`roadmap.md` Phase 1). A query instance is an entity: its key, value, dependencies, outputs and revisions are components, so a renumbering covers them like any other (`E-Remap`).
///
/// A query type `Q` is a struct declaring `Key`, `Value` and `static Value compute(ref QueryEngine, Key) @nogc nothrow`. `Key` and `Value` are plain data compared by their bytes, unless `Q` declares `static bool keyEqual(ref const Key, ref const Key)` or `static bool valueEqual(ref const Value, ref const Value)`. If they hold entity ids, `Q` declares `static void remapKey(ref Key, const(EntityId)[])` or `static void remapValue(ref Value, const(EntityId)[])`.
///
/// Validation follows Salsa's revisions: inputs carry `ChangedAt`, query entities carry `ChangedAt` and `VerifiedAt`, and a query re-runs only when a dependency changed after it was last verified. A re-run whose value is unchanged keeps its old `ChangedAt` (early cutoff). Dependencies are on whole entities; per (entity, component type) dependencies are the refinement if the extra re-verification shows up in profiles.
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

static import core.stdc.string;

static import fp.dynarray;

static import ecrs.context;
static import ecrs.registry;
static import ecrs.storage;
public import ecrs.registry : EntityId, invalidEntity;

@nogc nothrow:


// --- types and layout --------------------------------------------------------

/// A point in the engine's history. Revision 0 means "before anything was recorded".
alias Revision = ulong;

/// The revision an entity last changed in: set on inputs by `markChanged`, and on a query entity whenever a run produces a different value.
struct ChangedAt {
	Revision revision;
}

/// The revision a query entity's value was last confirmed current in.
struct VerifiedAt {
	Revision revision;
}

private void remapId(ref EntityId e, const(EntityId)[] remap) {
	if (e < remap.length) e = remap[e];
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

/// The entities and query entities a query read during its last run.
struct DependsOn {
	EntityId* entities = null;

	/// The `E-Remap` hook libECRS finds by name.
	///
	/// Examples:
	/// ---
	/// static import fp.dynarray;
	/// DependsOn list;
	/// scope(exit) list.finalize();
	/// assert(fp.dynarray.pushBack(list.entities, EntityId(1)));
	/// immutable EntityId[3] remap = [0, 2, 1];
	/// DependsOn.remapEntities(list, remap[]);
	/// assert(list.entities[0] == 2);
	/// ---
	static void remapEntities(ref DependsOn self, const(EntityId)[] remap) {
		foreach (ref e; fp.dynarray.slice(self.entities)) remapId(e, remap);
	}
	/// Releases the list when the component is removed.
	///
	/// Examples:
	/// ---
	/// static import fp.dynarray;
	/// DependsOn list;
	/// assert(fp.dynarray.pushBack(list.entities, EntityId(1)));
	/// list.finalize();
	/// ---
	void finalize() @nogc nothrow { fp.dynarray.free(entities); }
}

/// One component a query wrote: `component` is its libECRS component id.
struct Produced {
	EntityId entity;
	size_t component;
}

/// Every component a query wrote during its last run; removed before it runs again, and when it is evicted.
struct Produces {
	Produced* items = null;

	/// The `E-Remap` hook libECRS finds by name.
	///
	/// Examples:
	/// ---
	/// static import fp.dynarray;
	/// Produces list;
	/// scope(exit) list.finalize();
	/// assert(fp.dynarray.pushBack(list.items, Produced(1, 0)));
	/// immutable EntityId[3] remap = [0, 2, 1];
	/// Produces.remapEntities(list, remap[]);
	/// assert(list.items[0].entity == 2);
	/// ---
	static void remapEntities(ref Produces self, const(EntityId)[] remap) {
		foreach (ref item; fp.dynarray.slice(self.items)) remapId(item.entity, remap);
	}
	/// Releases the list when the component is removed.
	///
	/// Examples:
	/// ---
	/// static import fp.dynarray;
	/// Produces list;
	/// assert(fp.dynarray.pushBack(list.items, Produced(1, 0)));
	/// list.finalize();
	/// ---
	void finalize() @nogc nothrow { fp.dynarray.free(items); }
}

/// The entities a query created, indexed by creation sequence number, so a re-run hands back the same ids.
struct Creates {
	EntityId* entities = null;

	/// The `E-Remap` hook libECRS finds by name.
	///
	/// Examples:
	/// ---
	/// static import fp.dynarray;
	/// Creates list;
	/// scope(exit) list.finalize();
	/// assert(fp.dynarray.pushBack(list.entities, EntityId(1)));
	/// immutable EntityId[3] remap = [0, 2, 1];
	/// Creates.remapEntities(list, remap[]);
	/// assert(list.entities[0] == 2);
	/// ---
	static void remapEntities(ref Creates self, const(EntityId)[] remap) {
		foreach (ref e; fp.dynarray.slice(self.entities)) remapId(e, remap);
	}
	/// Releases the list when the component is removed.
	///
	/// Examples:
	/// ---
	/// static import fp.dynarray;
	/// Creates list;
	/// assert(fp.dynarray.pushBack(list.entities, EntityId(1)));
	/// list.finalize();
	/// ---
	void finalize() @nogc nothrow { fp.dynarray.free(entities); }
}

/// Brings query entity `q` up to date, re-running it if needed. Returns false if `q` is already running (a cycle).
alias RefreshFunction = bool function(ref QueryEngine engine, EntityId q);

/// Marks an entity as a query instance, with the type-erased entry point that lets a dependent re-validate it.
struct QueryInfo {
	RefreshFunction refresh;
}

/// True if `Q` follows the query protocol in the module documentation.
enum isQuery(Q) = is(Q.Key) && is(Q.Value) && __traits(compiles, (ref QueryEngine engine, Q.Key key) @nogc nothrow {
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

	static if (__traits(hasMember, Q, "remapKey"))
	/// The `E-Remap` hook libECRS finds by name, forwarded to `Q.remapKey`.
	///
	/// Examples:
	/// ---
	/// struct Of {
	/// 	alias Key = EntityId;
	/// 	alias Value = int;
	/// 	static int compute(ref QueryEngine engine, EntityId key) @nogc nothrow { return 0; }
	/// 	static void remapKey(ref EntityId key, const(EntityId)[] remap) @nogc nothrow { key = remap[key]; }
	/// }
	/// auto k = QueryKey!Of(1);
	/// immutable EntityId[2] remap = [0, 7];
	/// QueryKey!Of.remapEntities(k, remap[]);
	/// assert(k.key == 7);
	/// ---
	static void remapEntities(ref QueryKey self, const(EntityId)[] remap) { Q.remapKey(self.key, remap); }
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

	static if (__traits(hasMember, Q, "remapValue"))
	/// The `E-Remap` hook libECRS finds by name, forwarded to `Q.remapValue`.
	///
	/// Examples:
	/// ---
	/// struct Pick {
	/// 	alias Key = int;
	/// 	alias Value = EntityId;
	/// 	static EntityId compute(ref QueryEngine engine, int key) @nogc nothrow { return 1; }
	/// 	static void remapValue(ref EntityId value, const(EntityId)[] remap) @nogc nothrow { value = remap[value]; }
	/// }
	/// auto v = QueryValue!Pick(1);
	/// immutable EntityId[2] remap = [0, 7];
	/// QueryValue!Pick.remapEntities(v, remap[]);
	/// assert(v.value == 7);
	/// ---
	static void remapEntities(ref QueryValue self, const(EntityId)[] remap) { Q.remapValue(self.value, remap); }
}

private struct Frame {
	EntityId query;
	size_t created;
}

/// The engine: the store it works on, the current revision, and the stack of running queries. Renumber the store only while no query is running.
struct QueryEngine {
	ecrs.context.Context* store;
	Revision revision = 1;
	private Frame* stack = null;
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

/// Releases the engine's own memory. Query entities stay in the store.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = create(store);
/// free(engine);
/// ---
void free(ref QueryEngine engine) {
	assert(fp.dynarray.length(engine.stack) == 0);
	fp.dynarray.free(engine.stack);
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
	assert(fp.dynarray.length(engine.stack) == 0);
	++engine.revision;
}

/// Records that input entity `e` changed in the current revision. An input commit calls this for every entity it creates or whose components it replaces, since a freed id may be handed out again.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = create(store);
/// scope(exit) free(engine);
/// immutable e = ecrs.context.addEntity(store);
/// markChanged(engine, e);
/// assert(changedAt(engine, e) == engine.revision);
/// ---
void markChanged(ref QueryEngine engine, EntityId e) {
	assert(fp.dynarray.length(engine.stack) == 0);
	ecrs.context.getOrAddComponent!ChangedAt(*engine.store, e).revision = engine.revision;
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
	if (!ecrs.context.hasComponent!ChangedAt(*engine.store, e)) return 0;
	return ecrs.context.getComponent!ChangedAt(*engine.store, e).revision;
}


// --- inside a running query --------------------------------------------------

/// Records that the running query read entity `e`, so a later change to `e` re-runs it. Reads made outside any query are not recorded. Do not record reads of `SourceSpan` or `SourceLocation`: spans are untracked.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// struct Count {
/// 	alias Key = EntityId;
/// 	alias Value = int;
/// 	static int compute(ref QueryEngine engine, EntityId input) @nogc nothrow {
/// 		read(engine, input);
/// 		return cast(int) changedAt(engine, input);
/// 	}
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = create(store);
/// scope(exit) free(engine);
/// immutable input = ecrs.context.addEntity(store);
/// markChanged(engine, input);
/// assert(*query!Count(engine, input) == 1);
/// beginRevision(engine);
/// markChanged(engine, input);
/// assert(*query!Count(engine, input) == 2);
/// ---
void read(ref QueryEngine engine, EntityId e) {
	if (fp.dynarray.length(engine.stack) == 0) return;
	immutable q = fp.dynarray.back(engine.stack).query;
	if (q == e) return;
	auto deps = &ecrs.context.getComponent!DependsOn(*engine.store, q);
	foreach (d; fp.dynarray.slice(deps.entities))
		if (d == e) return;
	append(deps.entities, e);
}

/// Creates an entity owned by the running query. The n-th call in a run returns the entity the n-th call returned in the previous run, so values holding created ids stay equal across re-runs.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// struct Make {
/// 	alias Key = int;
/// 	alias Value = EntityId;
/// 	static EntityId compute(ref QueryEngine engine, int key) @nogc nothrow { return createEntity(engine); }
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = create(store);
/// scope(exit) free(engine);
/// assert(*query!Make(engine, 0) != invalidEntity);
/// ---
EntityId createEntity(ref QueryEngine engine) {
	assert(fp.dynarray.length(engine.stack) > 0, "doir.query: createEntity outside a query");
	auto frame = fp.dynarray.back(engine.stack);
	auto creates = &ecrs.context.getComponent!Creates(*engine.store, frame.query);
	immutable sequence = frame.created++;
	if (sequence < fp.dynarray.length(creates.entities)) return creates.entities[sequence];
	immutable e = ecrs.context.addEntity(*engine.store);
	creates = &ecrs.context.getComponent!Creates(*engine.store, frame.query);
	append(creates.entities, e);
	return e;
}

/// Adds component `C` to `e` on behalf of the running query, which owns it: it is removed before the query runs again and when the query is evicted. `e` must not already have a `C`.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// struct Size { int value; }
/// struct Annotate {
/// 	alias Key = EntityId;
/// 	alias Value = bool;
/// 	static bool compute(ref QueryEngine engine, EntityId e) @nogc nothrow {
/// 		produce!Size(engine, e).value = 4;
/// 		return true;
/// 	}
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = create(store);
/// scope(exit) free(engine);
/// immutable e = ecrs.context.addEntity(store);
/// assert(*query!Annotate(engine, e));
/// assert(ecrs.context.getComponent!Size(store, e).value == 4);
/// ---
ref C produce(C)(ref QueryEngine engine, EntityId e) {
	assert(fp.dynarray.length(engine.stack) > 0, "doir.query: produce outside a query");
	immutable q = fp.dynarray.back(engine.stack).query;
	append(ecrs.context.getComponent!Produces(*engine.store, q).items, Produced(e, ecrs.registry.componentId!C()));
	return attach!C(*engine.store, e);
}


// --- running and validating queries ------------------------------------------

private void removeProduced(ref QueryEngine engine, EntityId q) {
	auto produces = &ecrs.context.getComponent!Produces(*engine.store, q);
	foreach (item; fp.dynarray.slice(produces.items))
		if (ecrs.context.hasComponent(*engine.store, item.entity, item.component))
			ecrs.context.removeComponent(*engine.store, item.entity, item.component);
	if (produces.items !is null) fp.dynarray.clear(produces.items);
}

// Removes the created entities past `keep`, the ones the latest run no longer made.
private void removeCreated(ref QueryEngine engine, EntityId q, size_t keep) {
	auto creates = &ecrs.context.getComponent!Creates(*engine.store, q);
	immutable n = fp.dynarray.length(creates.entities);
	if (keep >= n) return;
	foreach (e; creates.entities[keep .. n]) ecrs.context.removeEntity(*engine.store, e);
	creates = &ecrs.context.getComponent!Creates(*engine.store, q);
	fp.dynarray.popBackCount(creates.entities, n - keep);
}

private bool running(ref QueryEngine engine, EntityId q) {
	foreach (frame; fp.dynarray.slice(engine.stack))
		if (frame.query == q) return true;
	return false;
}

private bool keysEqual(Q)(ref const Q.Key a, ref const Q.Key b) @trusted {
	static if (__traits(hasMember, Q, "keyEqual")) return Q.keyEqual(a, b);
	else return core.stdc.string.memcmp(&a, &b, Q.Key.sizeof) == 0;
}

private bool valuesEqual(Q)(ref const Q.Value a, ref const Q.Value b) @trusted {
	static if (__traits(hasMember, Q, "valueEqual")) return Q.valueEqual(a, b);
	else return core.stdc.string.memcmp(&a, &b, Q.Value.sizeof) == 0;
}

// A linear scan over `QueryKey!Q`; the planned engine sorts that storage into a hashtable instead.
private EntityId find(Q)(ref QueryEngine engine, ref const Q.Key key) @trusted {
	auto storage = ecrs.context.getStorage!(QueryKey!Q)(*engine.store);
	if (storage is null) return invalidEntity;
	foreach (slot; 0 .. ecrs.storage.size(*storage)) {
		immutable owner = ecrs.storage.owner(*storage, slot);
		if (owner == invalidEntity) continue;
		auto stored = cast(const(QueryKey!Q)*) ecrs.storage.get(*storage, slot);
		if (keysEqual!Q(stored.key, key)) return owner;
	}
	return invalidEntity;
}

private EntityId add(Q)(ref QueryEngine engine, Q.Key key) {
	auto store = engine.store;
	immutable q = ecrs.context.addEntity(*store);
	attach!(QueryKey!Q)(*store, q).key = key;
	attach!QueryInfo(*store, q).refresh = &refresh!Q;
	attach!ChangedAt(*store, q);
	attach!VerifiedAt(*store, q);
	attach!DependsOn(*store, q);
	attach!Produces(*store, q);
	attach!Creates(*store, q);
	return q;
}

// True if no dependency changed after `q` was verified. Dependencies that are queries are refreshed first, which is what lets early cutoff stop a change.
private bool dependenciesUnchanged(ref QueryEngine engine, EntityId q) {
	immutable verified = ecrs.context.getComponent!VerifiedAt(*engine.store, q).revision;
	immutable n = fp.dynarray.length(ecrs.context.getComponent!DependsOn(*engine.store, q).entities);
	foreach (i; 0 .. n) {
		// Re-fetched each step: a refresh may remove components, and a removal can move this one.
		immutable d = ecrs.context.getComponent!DependsOn(*engine.store, q).entities[i];
		if (ecrs.context.hasComponent!QueryInfo(*engine.store, d)
			&& !ecrs.context.getComponent!QueryInfo(*engine.store, d).refresh(engine, d))
			return false;
		if (changedAt(engine, d) > verified) return false;
	}
	return true;
}

private void execute(Q)(ref QueryEngine engine, EntityId q) {
	auto store = engine.store;
	removeProduced(engine, q);
	auto deps = &ecrs.context.getComponent!DependsOn(*store, q);
	if (deps.entities !is null) fp.dynarray.clear(deps.entities);

	append(engine.stack, Frame(q, 0));
	auto key = ecrs.context.getComponent!(QueryKey!Q)(*store, q).key;
	auto value = Q.compute(engine, key);
	immutable created = fp.dynarray.back(engine.stack).created;
	fp.dynarray.popBack(engine.stack);
	removeCreated(engine, q, created);

	if (ecrs.context.hasComponent!(QueryValue!Q)(*store, q)) {
		auto old = &ecrs.context.getComponent!(QueryValue!Q)(*store, q);
		if (!valuesEqual!Q(old.value, value)) {
			old.value = value;
			ecrs.context.getComponent!ChangedAt(*store, q).revision = engine.revision;
		}
	} else {
		attach!(QueryValue!Q)(*store, q).value = value;
		ecrs.context.getComponent!ChangedAt(*store, q).revision = engine.revision;
	}
	ecrs.context.getComponent!VerifiedAt(*store, q).revision = engine.revision;
}

private bool refresh(Q)(ref QueryEngine engine, EntityId q) {
	if (running(engine, q)) return false;
	auto store = engine.store;
	if (ecrs.context.getComponent!VerifiedAt(*store, q).revision == engine.revision
		&& ecrs.context.hasComponent!(QueryValue!Q)(*store, q))
		return true;
	if (ecrs.context.hasComponent!(QueryValue!Q)(*store, q) && dependenciesUnchanged(engine, q))
		ecrs.context.getComponent!VerifiedAt(*store, q).revision = engine.revision;
	else
		execute!Q(engine, q);
	return true;
}

/// The value of `Q` at `key`, computed on first demand and re-validated against the current revision on every later one. Records the read in the running query, if any. Returns null if `Q` at `key` is already running (a cycle), leaving the store unchanged. The pointer is valid until the next structural change to the store.
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
/// auto engine = create(store);
/// scope(exit) free(engine);
/// assert(*query!Loop(engine, 1)); // the inner demand saw the cycle
/// ---
const(Q.Value)* query(Q)(ref QueryEngine engine, Q.Key key) if (isQuery!Q) {
	auto q = find!Q(engine, key);
	if (q == invalidEntity) q = add!Q(engine, key);
	if (!refresh!Q(engine, q)) return null;
	read(engine, q);
	return &ecrs.context.getComponent!(QueryValue!Q)(*engine.store, q).value;
}

/// Frees what query entity `q` holds: its value, the components it produced and the entities it created. The entity keeps its key and `ChangedAt`, so dependents still see it, and the next demand re-runs it as changed.
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
/// auto engine = create(store);
/// scope(exit) free(engine);
/// assert(*query!Halve(engine, 2) == 1);
/// evict!Halve(engine, 2);
/// assert(*query!Halve(engine, 2) == 1);
/// ---
void evict(Q)(ref QueryEngine engine, Q.Key key) if (isQuery!Q) {
	immutable q = find!Q(engine, key);
	if (q == invalidEntity) return;
	assert(!running(engine, q));
	removeProduced(engine, q);
	removeCreated(engine, q, 0);
	if (ecrs.context.hasComponent!(QueryValue!Q)(*engine.store, q))
		ecrs.context.removeComponent!(QueryValue!Q)(*engine.store, q);
	ecrs.context.getComponent!VerifiedAt(*engine.store, q).revision = 0;
}


version(unittest) {
	private __gshared int runs;

	private struct Amount {
		int value;
	}

	private void remapKey(ref EntityId key, const(EntityId)[] remap) { remapId(key, remap); }

	private struct Input {
		alias Key = EntityId;
		alias Value = int;
		alias remapKey = .remapKey;
		static int compute(ref QueryEngine engine, EntityId e) @nogc nothrow {
			++runs;
			read(engine, e);
			return ecrs.context.getComponent!Amount(*engine.store, e).value;
		}
	}

	private struct IsPositive {
		alias Key = EntityId;
		alias Value = bool;
		alias remapKey = .remapKey;
		static bool compute(ref QueryEngine engine, EntityId e) @nogc nothrow {
			++runs;
			return *query!Input(engine, e) > 0;
		}
	}

	private struct Sign {
		alias Key = EntityId;
		alias Value = int;
		alias remapKey = .remapKey;
		static int compute(ref QueryEngine engine, EntityId e) @nogc nothrow {
			++runs;
			return *query!IsPositive(engine, e) ? 1 : -1;
		}
	}

	private struct Twin {
		alias Key = int;
		alias Value = EntityId;
		static EntityId compute(ref QueryEngine engine, int key) @nogc nothrow {
			++runs;
			auto e = createEntity(engine);
			produce!Amount(engine, e).value = key;
			return e;
		}
	}
}

unittest { // re-validation and early cutoff
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	auto engine = create(store);
	scope(exit) free(engine);

	immutable e = ecrs.context.addEntity(store);
	ecrs.context.addComponent!Amount(store, e).value = 3;
	markChanged(engine, e);

	// Sign reads IsPositive, which reads Input, which reads e.
	runs = 0;
	assert(*query!Sign(engine, e) == 1);
	assert(runs == 3);
	assert(*query!Sign(engine, e) == 1);
	assert(runs == 3);

	// Nothing changed: verification re-runs nothing.
	beginRevision(engine);
	assert(*query!Sign(engine, e) == 1);
	assert(runs == 3);

	// The input stays positive: Input and IsPositive re-run, and IsPositive's equal value cuts Sign off.
	beginRevision(engine);
	ecrs.context.getComponent!Amount(store, e).value = 5;
	markChanged(engine, e);
	assert(*query!Sign(engine, e) == 1);
	assert(runs == 5);

	// The answer flips, so all three re-run.
	beginRevision(engine);
	ecrs.context.getComponent!Amount(store, e).value = -1;
	markChanged(engine, e);
	assert(*query!Sign(engine, e) == -1);
	assert(runs == 8);
}

unittest { // stable created ids, ownership and eviction
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	auto engine = create(store);
	scope(exit) free(engine);

	runs = 0;
	immutable made = *query!Twin(engine, 7);
	assert(ecrs.context.getComponent!Amount(store, made).value == 7);

	// Evicting removes what the query produced and created, and the next demand re-runs it.
	evict!Twin(engine, 7);
	assert(!ecrs.context.hasComponent!Amount(store, made));
	immutable remade = *query!Twin(engine, 7);
	assert(runs == 2);
	assert(ecrs.context.getComponent!Amount(store, remade).value == 7);

	// A re-run hands back the same created entity, so the value compares equal.
	beginRevision(engine);
	int key = 7;
	immutable q = find!Twin(engine, key);
	ecrs.context.getComponent!VerifiedAt(store, q).revision = 0;
	immutable before = changedAt(engine, q);
	assert(*query!Twin(engine, 7) == remade);
	assert(changedAt(engine, q) == before);
}

unittest { // a renumbering rewrites query entities and their dependencies
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	auto engine = create(store);
	scope(exit) free(engine);

	immutable spare = ecrs.context.addEntity(store);
	immutable e = ecrs.context.addEntity(store);
	ecrs.context.addComponent!Amount(store, e).value = 1;
	markChanged(engine, e);
	runs = 0;
	assert(*query!IsPositive(engine, e));
	ecrs.context.removeEntity(store, spare);
	ecrs.context.compact(store);

	immutable moved = cast(EntityId)(e - 1);
	assert(ecrs.context.getComponent!Amount(store, moved).value == 1);
	assert(*query!IsPositive(engine, moved));
	assert(runs == 2);
}
