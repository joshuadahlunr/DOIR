/// The components a query entity carries (`roadmap.md` Phase 1): its key and value, revisions, dependencies, what it produced and created, and the diagnostics it reported. `doir.query` reads and writes them. Every one holding an entity id mixes in `ecrs.relation.Relates` or forwards to one that does (`E-Remap`).
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// immutable from = ecrs.context.addEntity(store), made = ecrs.context.addEntity(store);
/// ecrs.context.addComponent!Provenance(store, made).origin = from;
/// assert(ecrs.context.getComponent!Provenance(store, made).origin == from);
/// ---
module doir.components.query;

static import fp.dynarray;
static import fp.lifecycle;
static import fp.string;

static import diagnose;
static import ecrs.context;
static import ecrs.registry;
static import ecrs.relation;

static import doir.query;

public import ecrs.registry : EntityId, invalidEntity;

@nogc nothrow:


// --- revisions and dependencies ----------------------------------------------

/// The revision an entity last changed in: set on inputs by `markChanged`, and on a query entity whenever a run produces a different value or different components.
struct ChangedAt {
	doir.query.Revision revision;
}

/// The revision a query entity's value was last confirmed current in, and whether that confirmation still holds without checking its dependencies.
struct VerifiedAt {
	doir.query.Revision revision;
	bool stale; /// Something it depends on changed since, as `doir.query.markChanged` pushes along `Dependents`. Accessed atomically.
	bool reports; /// It or a query below it holds diagnostics, which reusing it reports. Accessed atomically.
	bool reportsBelow; /// A query below it holds diagnostics, so reusing it walks its dependencies to report them, even when it is not stale. Accessed atomically.
}

/// The entities and query entities a query read during its last run.
struct DependsOn {
	mixin ecrs.relation.Relates;
}

/// The queries a query depends on that hold diagnostics, or have one below them that does, in the order it read them: what reusing it walks to, to report them again, instead of every dependency. Every query entity has one, so a worker confirming a query only writes it.
struct ReportingBelow {
	mixin ecrs.relation.Relates;
}

/// The query entities that read an entity, so a change to it marks them stale. It may still list a query that no longer reads it, which costs that query one re-validation.
struct Dependents {
	mixin ecrs.relation.Relates;
}


// --- outputs -----------------------------------------------------------------

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


// --- diagnostics -------------------------------------------------------------

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


// --- running state -----------------------------------------------------------

/// Marks a finished query whose value rests on a running query's cycle fallback, until that query, `head`, finishes and confirms or discards it.
struct ProvisionalOn {
	mixin ecrs.relation.Relates!"head";
}

/// Tags a query whose last run took part in a cycle (`Q-Cycle`). It is re-run, not re-validated, in a later revision, since its dependencies loop back to it.
struct InCycle {
	enum isTag = true;
}

/// Which thread runs a query, if any, and where, so finding it never scans a stack; every query entity has one. A worker claims a query by setting `owner` atomically, and a demand from another worker waits until it is 0 again (`doir.query.demandEach`).
struct Running {
	uint owner; /// 0 if no thread runs it; 1 for the engine's own thread; 2 on for a batch's workers. Accessed atomically.
	size_t frame = size_t.max; /// Its index in its owner's stack while it runs, `size_t.max` otherwise, as while a worker validates it.
	bool withheld; /// A worker brought it up to date, and it or a query below it has diagnostics not yet reported, which the engine's thread reports in order.
}


// --- query entities ----------------------------------------------------------

/// Brings query entity `q` up to date, re-running it if needed. Returns false if it cannot: `q` is already running, the depth limit is reached, or its run failed on a refused allocation.
alias RefreshFunction = bool function(ref doir.query.QueryEngine engine, EntityId q) @nogc nothrow;

/// Discards query entity `q`'s value and what it produced and created, so the next demand runs it.
alias ResetFunction = void function(ref doir.query.QueryEngine engine, EntityId q) @nogc nothrow;

/// Appends a description of query entity `q`, such as `Layout(12)`, to an fp string. Returns false if the string could not grow, leaving it holding a prefix of the description.
alias DescribeFunction = bool function(ref doir.query.QueryEngine engine, EntityId q, ref char* out_) @nogc nothrow;

/// Marks an entity as a query instance, with the type-erased entry points that let a dependent re-validate it and a cycle report name it.
struct QueryInfo {
	RefreshFunction refresh; /// Re-validates or re-runs it.
	ResetFunction reset; /// Discards its value.
	DescribeFunction describe; /// Names it.
}

/// The key of a query entity of type `Q`.
///
/// Examples:
/// ---
/// struct Identity {
/// 	alias Key = int;
/// 	alias Value = int;
/// 	static int compute(ref doir.query.QueryEngine engine, int key) @nogc nothrow { return key; }
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
	/// 	static int compute(ref doir.query.QueryEngine engine, Key key) @nogc nothrow { return 0; }
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
/// 	static int compute(ref doir.query.QueryEngine engine, int key) @nogc nothrow { return 1; }
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
	/// 	static Value compute(ref doir.query.QueryEngine engine, int key) @nogc nothrow { return Value([1]); }
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
	/// 	static Owning compute(ref doir.query.QueryEngine engine, int key) @nogc nothrow { return Owning.init; }
	/// 	static bool valueEqual(ref const Owning a, ref const Owning b) @nogc nothrow { return true; }
	/// }
	/// QueryValue!Listed v;
	/// v.finalize();
	/// ---
	void finalize() @nogc nothrow { fp.lifecycle.endLifetime(value); }
}

unittest { // libECRS silently skips a holder whose hook is not `@nogc nothrow`; every holder of an entity id must pass (E-Remap)
	static assert(ecrs.registry.hasRemapEntities!DependsOn && ecrs.registry.hasRemapEntities!ReportingBelow && ecrs.registry.hasRemapEntities!Produces && ecrs.registry.hasRemapEntities!Creates && ecrs.registry.hasRemapEntities!Provenance && ecrs.registry.hasRemapEntities!QueryDiagnostics && ecrs.registry.hasRemapEntities!QueryAnnotation && ecrs.registry.hasRemapEntities!ProvisionalOn);
}
