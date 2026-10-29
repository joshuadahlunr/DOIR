/// The demand-driven query engine over the libECRS store (`roadmap.md` Phase 1). A query instance is an entity: its key, value, dependencies, outputs, diagnostics and revisions are components, so a renumbering covers them like any other (`E-Remap`).
///
/// A query type `Q` is a struct declaring `Key`, `Value` and `static Value compute(ref QueryEngine, Key) @nogc nothrow`. `Key` and `Value` are plain data compared by their bytes, unless `Q` declares `static bool keyEqual(ref const Key, ref const Key)` with `static size_t keyHash(ref const Key)`, or `static bool valueEqual(ref const Value, ref const Value)`. A `Key` or `Value` that holds entity ids does so by mixing in `ecrs.relation.Relates`, or by being an `ecrs.relation.Relation`, and the engine renumbers it through that (`E-Remap`). `Q` may declare `static Value cycleFallback(ref QueryEngine, Key)`, the answer a demand for it gets while it is already running, and `static bool describeKey(ref const Key, ref char*)`, which appends the key to a cycle report and returns false if the string could not grow.
///
/// Validation follows Salsa's revisions: inputs carry `ChangedAt`, query entities carry `ChangedAt` and `VerifiedAt`, and a query re-runs only when a dependency changed after it was last verified. A re-run whose value and produced components are unchanged keeps its old `ChangedAt` (early cutoff). Dependencies are on whole entities; per (entity, component type) dependencies are the refinement if the extra re-verification shows up in profiles.
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

static import fp.dynarray;
static import fp.string;

static import diagnose;
static import ecrs.context;
static import ecrs.relation;
static import ecrs.registry;

static import doir.engine.query;

public import doir.engine.query : EntityId, invalidEntity, Revision, ChangedAt, VerifiedAt, Provenance, QueryDiagnostic, Produced, StripFunction, HashFunction, QueryEngine, defaultDepthLimit, isQuery, free, currentQuery, read, recordProduced, fail, query, evict;

@nogc nothrow:


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
	assert(doir.engine.query.idle(engine));
	++engine.revision;
}

/// Records that input entity `e` changed in the current revision. An input commit calls this for every entity it creates or whose components it replaces, since a freed id may be handed out again. Returns false if the store refused the record, leaving `e` as it was.
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
	assert(doir.engine.query.idle(engine));
	// Set rather than written in place, so a transaction around an input commit can undo it.
	return ecrs.context.setComponent!ChangedAt(*engine.store, e, ChangedAt(engine.revision));
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
	auto changed = ecrs.context.findComponent!ChangedAt(*engine.store, e);
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
	if (!doir.engine.query.recordProduced(engine, Produced([e], id, &doir.engine.query.stripComponent, &doir.engine.query.hashComponent!C), true)) return null;
	auto component = ecrs.context.addComponent!C(*engine.store, e);
	if (component is null) doir.engine.query.fail(engine);
	return component;
}

/// Creates an entity owned by the running query, with a `Provenance` naming `origin`, the entity it is derived from. The n-th call in a run returns the entity the n-th call returned in the previous run, so values holding created ids stay equal across re-runs (as rustc's `create_def` does). Returns `invalidEntity` on a refused allocation, which fails the running queries (`fail`).
///
/// Examples:
/// ---
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
/// assert(ecrs.context.getComponent!Provenance(store, made).origin == from);
/// ---
EntityId createEntity(ref QueryEngine engine, EntityId origin) {
	immutable e = doir.engine.query.nextCreated(engine);
	if (e == invalidEntity) return invalidEntity;
	auto provenance = produce!Provenance(engine, e);
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
	auto d = QueryDiagnostic([subject], kind, fp.string.makeDynamic(message), fp.string.makeDynamic(hint));
	bool ok = (d.message !is null || message.length == 0) && d.hint !is null
		&& (related.length == 0 || fp.dynarray.reserve(d.annotations, related.length) !is null);
	foreach (r; related) {
		if (!ok) break;
		auto a = doir.engine.query.QueryAnnotation([r.target], fp.string.makeDynamic(r.message));
		ok = (a.message !is null || r.message.length == 0) && fp.dynarray.pushBack(d.annotations, a); // reserved above
		if (!ok) fp.string.free(a.message);
	}
	if (ok) return doir.engine.query.recordDiagnostic(engine, d);
	doir.engine.query.freeDiagnostic(d);
	doir.engine.query.fail(engine);
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
	assert(doir.engine.query.idle(engine), "doir.query: renumbering while a query runs (E-Remap)");
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
	assert(doir.engine.query.idle(engine), "doir.query: renumbering while a query runs (E-Remap)");
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

	private struct Twin {
		alias Key = int;
		alias Value = ecrs.relation.Relation!1;
		static Value compute(ref QueryEngine engine, int key) @nogc nothrow {
			++runs;
			auto e = createEntity(engine, invalidEntity);
			auto amount = produce!Amount(engine, e);
			assert(e != invalidEntity && amount !is null);
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
			assert(recordProduced(engine, Produced([e], ecrs.registry.componentId!Amount(), &strip, &hash), false));
			assert(recordProduced(engine, Produced([e], ecrs.registry.componentId!Amount(), &strip, &hash), false));
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
			assert(ecrs.context.getComponent!(doir.engine.query.Running)(*engine.store, currentQuery(engine)).frame == key);
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
}

unittest { // stable created ids, provenance, ownership and eviction
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	auto engine = create(store);
	scope(exit) free(engine);

	runs = 0;
	immutable made = query!Twin(engine, 7).related[0];
	assert(ecrs.context.getComponent!Amount(store, made).value == 7);
	assert(ecrs.context.getComponent!Provenance(store, made).origin == invalidEntity);

	// Evicting removes what the query produced and created, and the next demand re-runs it.
	evict!Twin(engine, 7);
	assert(!ecrs.context.hasComponent!Amount(store, made));
	immutable remade = query!Twin(engine, 7).related[0];
	assert(runs == 2);
	assert(ecrs.context.getComponent!Amount(store, remade).value == 7);

	// A re-run hands back the same created entity, so the value compares equal.
	beginRevision(engine);
	int key = 7;
	immutable q = doir.engine.query.find!Twin(engine, key);
	ecrs.context.getComponent!VerifiedAt(store, q).revision = 0;
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
	assert(ecrs.context.getComponent!Provenance(store, copy).origin == knob);
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
	immutable stamp = doir.engine.query.find!Stamp(engine, Stamp.Key([stamped]));
	assert(fp.dynarray.length(ecrs.context.getComponent!(doir.engine.query.Produces)(store, stamp).items) == 1);
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
	assert(ecrs.context.removeEntity(store, doir.engine.query.find!Resolve(engine, 0)));
	assert(compact(engine));
	assert(doir.engine.query.find!Resolve(engine, 0) == invalidEntity);
	assert(*query!Resolve(engine, 0) == 0);
	assert(doir.engine.query.find!Resolve(engine, 0) != invalidEntity);
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
	assert(fp.string.slice(manager.diagnostics[0].additionalNote) == doir.engine.query.cycleHint);
	assert(ecrs.context.hasComponent!(doir.engine.query.InCycle)(store, doir.engine.query.find!Resolve(engine, -1)));

	// The cycle is reported again by its memo in a later revision, which re-runs rather than re-validates.
	beginRevision(engine);
	assert(*query!Resolve(engine, -1) == -1);
	assert(diagnose.count(manager) == 2);
	assert(fp.string.slice(manager.diagnostics[1].additionalNote) == doir.engine.query.cycleHint);

	// An unsigned key is reported as one.
	assert(*query!Spin(engine, 7) == 0);
	assert(fp.string.slice(manager.diagnostics[2].message) == "Q-Cycle: a query needs its own answer: Spin(7) -> Spin(7)");
	assert(fp.string.slice(manager.diagnostics[2].additionalNote) == doir.engine.query.cycleHint);

	// Each running query is marked with its frame, and only while it runs.
	assert(*query!Depth(engine, 0) == 3);
	foreach (k; 0 .. 4) assert(!ecrs.context.hasComponent!(doir.engine.query.Running)(store, doir.engine.query.find!Depth(engine, k)));

	// A chain within the depth limit resolves; one past it is reported instead of overflowing the stack.
	diagnose.clear(manager);
	assert(*query!Resolve(engine, defaultDepthLimit - 8) == 0);
	assert(diagnose.count(manager) == 0);
	assert(!ecrs.context.hasComponent!(doir.engine.query.Running)(store, doir.engine.query.find!Resolve(engine, defaultDepthLimit - 8)));
	engine.depthLimit = 64;
	assert(*query!Resolve(engine, 2 * defaultDepthLimit) == -1);
	assert(diagnose.count(manager) == 1);
	enum prefix = "Q-Cycle: queries nest deeper than the limit of 64 at Resolve(";
	assert(fp.string.slice(manager.diagnostics[0].message)[0 .. prefix.length] == prefix);
	assert(fp.string.slice(manager.diagnostics[0].additionalNote) == doir.engine.query.depthHint);

	// An unsigned key is described as one.
	diagnose.clear(manager);
	assert(*query!Unsigned(engine, 3));
	assert(fp.string.slice(manager.diagnostics[0].message) == "Q-Cycle: a query needs its own answer: Unsigned(3) -> Unsigned(3)");
	assert(fp.string.slice(manager.diagnostics[0].additionalNote) == doir.engine.query.cycleHint);
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
	assert(!ecrs.context.hasComponent!(doir.engine.query.ProvisionalOn)(store, doir.engine.query.find!Equal(engine, Pair([x, z]))));

	// A = [A, X], B = [B', Y], B' = [B, X], X != Y. Equal(A, B') answers true resting on Equal(A, B), which fails.
	immutable leafX = node(2), leafY = node(3);
	immutable a = node(1), b = node(1), b2 = node(1);
	link(leafX, leafX);
	link(leafY, leafY);
	link(a, a, leafX);
	link(b, b2, leafY);
	link(b2, b, leafX);
	assert(!*query!Equal(engine, Pair([a, b])));
	immutable provisional = doir.engine.query.find!Equal(engine, Pair([a, b2]));
	assert(!ecrs.context.hasComponent!(doir.engine.query.QueryValue!Equal)(store, provisional));
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
	assert(!ecrs.context.hasComponent!(doir.engine.query.ProvisionalOn)(store, doir.engine.query.find!Equal(engine, Pair([c, d]))));
	assert(!ecrs.context.hasComponent!(doir.engine.query.ProvisionalOn)(store, doir.engine.query.find!Equal(engine, Pair([e, f]))));
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
			auto previous = doir.testing.beginRationedAllocator(n);
			immutable answered = demand();
			fp.pointer.allocFunction = previous;
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
			auto previous = doir.testing.beginRationedAllocator(n);
			auto sign = query!Sign(engine, Sign.Key([e]));
			immutable answer = sign is null ? 0 : *sign;
			fp.pointer.allocFunction = previous;
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
		auto previous = doir.testing.beginRationedAllocator(n);
		auto same = query!Equal(engine, Pair([a, b]));
		immutable answer = same is null || *same;
		fp.pointer.allocFunction = previous;
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
		previous = doir.testing.beginRationedAllocator(0);
		auto moved = query!Sign(engine, Sign.Key([spare]));
		fp.pointer.allocFunction = previous;
		assert(moved !is null && *moved == 1 && !engine.refused);
		finished = !refused;
	}
}
