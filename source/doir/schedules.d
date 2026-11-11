/// Schedules over the query engine, which is itself an `ecrs.schedules` owner: `demanding` makes a batch of demands a step of a schedule, and `whenChangedAt` gives a schedule the revisions a query has (`ChangedAt`, `Verification`), so it runs again only when something it watches changed since it last ran.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import ecrs.schedules;
/// static import doir.query;
/// struct Doubling {
/// 	alias Key = int;
/// 	alias Value = int;
/// 	static int compute(ref doir.query.QueryEngine engine, int key) @nogc nothrow { return 2 * key; }
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.query.create(store);
/// scope(exit) doir.query.free(engine);
/// immutable int[3] keys = [1, 2, 3];
/// assert(ecrs.schedules.sequential(engine, demanding!Doubling(keys[]), whenChangedAt(demanding!Doubling(keys[0 .. 1]), null)));
/// ---
module doir.schedules;

static import std.algorithm.sorting;

static import fp.dynarray;
version(unittest) static import fp.string;

static import ecrs.context;
static import ecrs.registry;
static import ecrs.relation;
static import ecrs.schedules;
static import ecrs.storage;

static import doir.components.query;
static import doir.query;

public import ecrs.registry : EntityId, invalidEntity;

@nogc nothrow:


// Whether `S` runs as a schedule over the engine: taking it, or the store it holds.
private enum isEngineSchedule(S) = __traits(compiles, (ref S schedule, ref doir.query.QueryEngine engine) {
	bool ran = ecrs.schedules.sequential(engine, schedule);
});


/// `doir.query.demandEach!Q` over `keys` as a schedule, from `demanding!Q(keys)`: a copyable struct callable over the engine, so a batch of demands is a step of an `ecrs.schedules` schedule.
/// `keys` must outlive it.
/// Like `demandEach`, it returns false only on a refused allocation, and reports the batch's diagnostics in the order of `keys`.
///
/// Examples:
/// ---
/// static import doir.query;
/// struct Squaring {
/// 	alias Key = int;
/// 	alias Value = int;
/// 	static int compute(ref doir.query.QueryEngine engine, int key) @nogc nothrow { return key * key; }
/// }
/// immutable int[2] keys = [3, 4];
/// Demanding!Squaring batch = demanding!Squaring(keys[]);
/// auto copy = batch;
/// ---
struct Demanding(Q) {
	private const(Q.Key)[] keys;

	@nogc nothrow:
	/// Demands the batch on `engine`.
	///
	/// Examples:
	/// ---
	/// static import doir.query;
	/// static import ecrs.context;
	/// struct Squaring {
	/// 	alias Key = int;
	/// 	alias Value = int;
	/// 	static int compute(ref doir.query.QueryEngine engine, int key) @nogc nothrow { return key * key; }
	/// }
	/// auto store = ecrs.context.create();
	/// scope(exit) ecrs.context.free(store);
	/// auto engine = doir.query.create(store);
	/// scope(exit) doir.query.free(engine);
	/// immutable int[2] keys = [3, 4];
	/// assert(demanding!Squaring(keys[])(engine) && *doir.query.query!Squaring(engine, 4) == 16);
	/// ---
	bool opCall(ref doir.query.QueryEngine engine) { return doir.query.demandEach!Q(engine, keys); }
}

/// Ditto
///
/// Examples:
/// ---
/// static import doir.query;
/// static import ecrs.context;
/// static import ecrs.schedules;
/// struct Squared {
/// 	alias Key = int;
/// 	alias Value = int;
/// 	static int compute(ref doir.query.QueryEngine engine, int key) @nogc nothrow { return key * key; }
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.query.create(store);
/// scope(exit) doir.query.free(engine);
/// immutable int[2] small = [1, 2], large = [30, 40];
/// assert(ecrs.schedules.sequential(engine, demanding!Squared(small[]), demanding!Squared(large[])));
/// ---
Demanding!Q demanding(Q)(const(Q.Key)[] keys) if (doir.query.isQuery!Q) {
	return Demanding!Q(keys);
}


// Whether `watched` changed after `since`, query entities refreshed first (early cutoff); one that cannot be counts as changed.
private bool changedSince(ref doir.query.QueryEngine engine, doir.query.Revision since, const(EntityId)[] watched) {
	doir.query.beginReading(engine);
	scope(exit) doir.query.endReading(engine);
	foreach (e; watched) {
		if (auto info = ecrs.context.findComponent!(doir.components.query.Hooks)(*engine.store, e))
			if (!info.bringUpToDate(engine, e)) return true;
		if (doir.query.changedAt(engine, e) > since) return true;
	}
	return false;
}

/// Runs `schedule` over `engine` unless no entity of `watched` changed after `verified`, the revision in which the schedule was last confirmed current, as a query re-runs only when a dependency's `ChangedAt` passes its `Verification`.
/// A watched query entity is brought up to date first, so a re-run that keeps its value does not count (early cutoff).
/// A run that succeeds, or a check that finds nothing changed, sets `verified` to the current revision; start it at 0, which runs the schedule on the first call.
/// Returns true when it skips, and otherwise what the schedule returns, leaving `verified` as it was when that is false, so the next call runs it again.
/// The calling thread must not be running a query.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.query;
/// static size_t runs;
/// static bool count(ref doir.query.QueryEngine) @nogc nothrow { ++runs; return true; }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.query.create(store);
/// scope(exit) doir.query.free(engine);
/// immutable input = ecrs.context.addEntity(store);
/// immutable EntityId[1] watched = [input];
/// doir.query.Revision verified = 0;
/// assert(whenChangedAt(engine, &count, verified, watched[]) && whenChangedAt(engine, &count, verified, watched[]) && runs == 1);
/// doir.query.beginRevision(engine);
/// assert(doir.query.markChanged(engine, input));
/// assert(whenChangedAt(engine, &count, verified, watched[]) && runs == 2);
/// ---
bool whenChangedAt(S)(ref doir.query.QueryEngine engine, auto ref S schedule, ref doir.query.Revision verified, const(EntityId)[] watched) if (isEngineSchedule!S) {
	assert(doir.query.runsNoQuery(engine), "doir.schedules.whenChangedAt: run inside a query");
	assert(verified <= engine.revision, "doir.schedules.whenChangedAt: verified at a revision the engine has not reached; is it another engine's?");
	if (verified == engine.revision) return true;
	if (verified != 0 && !changedSince(engine, verified, watched)) {
		verified = engine.revision;
		return true;
	}
	if (!ecrs.schedules.sequential(engine, schedule)) return false;
	verified = engine.revision;
	return true;
}

/// `whenChangedAt` with its schedule and watched entities bound, from `whenChangedAt(schedule, watched)`: a copyable struct that is itself a schedule over the engine, keeping its own `Verification`, so each copy tracks changes separately.
/// `watched` must outlive it.
///
/// Examples:
/// ---
/// static import doir.query;
/// static bool succeeds(ref doir.query.QueryEngine) @nogc nothrow { return true; }
/// WhenChangedAt!(typeof(&succeeds)) step = whenChangedAt(&succeeds, null);
/// auto copy = step;
/// ---
struct WhenChangedAt(S) {
	private S schedule;
	private const(EntityId)[] watched;
	private doir.query.Revision verified = 0;

	@nogc nothrow:
	/// Runs the schedule over `engine` if what it watches changed since it was last confirmed current.
	///
	/// Examples:
	/// ---
	/// static import doir.query;
	/// static import ecrs.context;
	/// static bool succeeds(ref doir.query.QueryEngine) @nogc nothrow { return true; }
	/// auto store = ecrs.context.create();
	/// scope(exit) ecrs.context.free(store);
	/// auto engine = doir.query.create(store);
	/// scope(exit) doir.query.free(engine);
	/// auto step = whenChangedAt(&succeeds, null);
	/// assert(step(engine) && step(engine));
	/// ---
	bool opCall(ref doir.query.QueryEngine engine) { return .whenChangedAt(engine, schedule, verified, watched); }
}

/// Ditto
///
/// Examples:
/// ---
/// static import doir.query;
/// static import ecrs.context;
/// static import ecrs.schedules;
/// static bool succeeds(ref doir.query.QueryEngine) @nogc nothrow { return true; }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.query.create(store);
/// scope(exit) doir.query.free(engine);
/// immutable input = ecrs.context.addEntity(store);
/// immutable EntityId[1] watched = [input];
/// auto step = ecrs.schedules.sequential(whenChangedAt(&succeeds, watched[]), &succeeds);
/// assert(step(engine));
/// ---
WhenChangedAt!S whenChangedAt(S)(S schedule, const(EntityId)[] watched) if (isEngineSchedule!S) {
	return WhenChangedAt!S(schedule, watched);
}



// --- systems -----------------------------------------------------------------

/// Whether `S` is a system the engine can run as memoized queries: a component `S.Tag` whose owners are its domain, and `static bool run(ref doir.query.QueryEngine, EntityId)`, which handles one of them as a query's body would, reading through `doir.query.read` and the queries it demands, reporting through `doir.query.report` and writing through `doir.query.produce`, and returns whether that entity passed.
/// It may also give the order its entities are visited and report in: `alias Order`, `static Order orderOf(ref doir.query.QueryEngine, EntityId)` and `static int compare(ref doir.query.QueryEngine, ref const Order, ref const Order)`; without them, they go by id.
///
/// Examples:
/// ---
/// struct Seen {
/// 	alias Tag = int;
/// 	static bool run(ref doir.query.QueryEngine engine, EntityId e) @nogc nothrow { return true; }
/// }
/// static assert(isSystem!Seen && !isSystem!int);
/// ---
enum isSystem(S) = is(S.Tag) && __traits(compiles, (ref doir.query.QueryEngine engine, EntityId e) @nogc nothrow {
	bool passed = S.run(engine, e);
});

/// The query that runs system `S` on one entity of its domain, keyed by the entity: its value is what `S.run` returned, reused until something `S.run` read changes, as any query's is.
/// A change that marks it stale is passed to the system's next run (`onStale`), which visits it without visiting the rest of the domain.
///
/// Examples:
/// ---
/// struct Memoed {
/// 	alias Tag = int;
/// 	static bool run(ref doir.query.QueryEngine engine, EntityId e) @nogc nothrow { return true; }
/// }
/// static assert(doir.query.isQuery!(Memo!Memoed));
/// ---
struct Memo(S) if (isSystem!S) {
	alias Key = ecrs.relation.Relation!1; /// The entity.
	alias Value = bool; /// What `S.run` returned.

	/// Runs `S` on the entity, having read it, so a change to the entity alone re-runs the memo.
	///
	/// Examples:
	/// ---
	/// static import ecrs.context;
	/// struct Nonzero2 {
	/// 	alias Tag = int;
	/// 	static bool run(ref doir.query.QueryEngine engine, EntityId e) @nogc nothrow { return e != invalidEntity; }
	/// }
	/// auto store = ecrs.context.create();
	/// scope(exit) ecrs.context.free(store);
	/// auto engine = doir.query.create(store);
	/// scope(exit) doir.query.free(engine);
	/// immutable e = ecrs.context.addEntity(store);
	/// assert(*doir.query.query!(Memo!Nonzero2)(engine, Memo!Nonzero2.Key([e])));
	/// ---
	static bool compute(ref doir.query.QueryEngine engine, Key key) @nogc nothrow {
		return doir.query.read(engine, key.related[0]) && S.run(engine, key.related[0]);
	}

	/// Queues the entity for the system's next run; a refusal makes that run visit the whole domain instead.
	///
	/// Examples:
	/// ---
	/// static import ecrs.context;
	/// struct Queued2 {
	/// 	alias Tag = int;
	/// 	static bool run(ref doir.query.QueryEngine engine, EntityId e) @nogc nothrow { return true; }
	/// }
	/// auto store = ecrs.context.create();
	/// scope(exit) ecrs.context.free(store);
	/// auto engine = doir.query.create(store);
	/// scope(exit) doir.query.free(engine);
	/// Memo!Queued2.onStale(engine, Memo!Queued2.Key([1])); // before the system's first run, which visits everything anyway
	/// ---
	static void onStale(ref doir.query.QueryEngine engine, Key key) @nogc nothrow {
		auto state = ecrs.context.findSingletonForWriting!(doir.components.query.SystemState!S)(*engine.store);
		if (state !is null && !fp.dynarray.pushBack(state.related, key.related[0])) state.lastRunRevision = 0;
	}
}

// An entity a run visits, with where it goes in `S`'s order.
private struct Visit(S) {
	EntityId e;
	static if (is(S.Order)) S.Order order;
}

private bool visitsBefore(S)(ref doir.query.QueryEngine engine, ref const Visit!S a, ref const Visit!S b) {
	static if (is(S.Order)) {
		immutable c = S.compare(engine, a.order, b.order);
		if (c != 0) return c < 0;
	}
	return a.e < b.e;
}

// What a run of `S` visits from `candidates`, sorted and deduplicated; an entity that lost its `S.Tag` loses its memo instead.
// False on refusal.
private bool gatherVisits(S)(ref doir.query.QueryEngine engine, const(EntityId)[] candidates, ref Visit!S* out_) @trusted {
	foreach (e; candidates) {
		if (e == invalidEntity) continue;
		if (!ecrs.context.hasComponent!(S.Tag)(*engine.store, e)) {
			doir.query.evict!(Memo!S)(engine, Memo!S.Key([e]));
			continue;
		}
		Visit!S v = Visit!S(e);
		static if (is(S.Order)) v.order = S.orderOf(engine, e);
		if (!fp.dynarray.pushBack(out_, v)) return false;
	}
	auto all = fp.dynarray.slice(out_);
	std.algorithm.sorting.sort!((ref a, ref b) => visitsBefore!S(engine, a, b))(all);
	size_t kept = 0;
	foreach (i, ref v; all)
		if (i == 0 || v.e != all[kept - 1].e) all[kept++] = v;
	if (kept < all.length) cast(void) fp.dynarray.removeLast(out_, all.length - kept);
	foreach (i; 1 .. kept) assert(all[i - 1].e != all[i].e && !visitsBefore!S(engine, all[i], all[i - 1]), "doir.schedules: visits out of order, or repeated");
	return true;
}

/// Runs system `S` over its domain as one `Memo!S` per entity, a `doir.query.demandEach` batch, so on `engine.workers` when it has them, reporting the memos' diagnostics, fresh or remembered, to `engine.diagnostics` in `S`'s order (`L-Sema`: a check is a query per entity, run in no order).
/// The first run visits every entity with an `S.Tag`.
/// A later one visits only the entities whose memos a change marked stale (`Memo.onStale`), those `doir.query.markChanged` recorded since that have an `S.Tag`, and those whose memos hold diagnostics, to report them again, so what it costs follows the edit, not the domain.
/// It visits the whole domain again when it cannot tell what changed: when the engine keeps no reverse edges (`engine.edgesMissing`), or its change log dropped entries the system had not read (`doir.query.changesSince`).
/// An entity that lost its `S.Tag` has its memo evicted.
/// Only an input commit's changes enter the domain: a query producing an `S.Tag` is not seen until the domain is visited whole.
/// No thread may be demanding.
///
/// A memo reports once per revision, so a second run in the same revision reports nothing; begin a revision (`doir.query.beginRevision`) to report again.
/// Returns false if an allocation was refused, which loses some diagnostics, sets `engine.refused`, and makes the next run visit the whole domain.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// struct Positive {
/// 	alias Tag = int;
/// 	static bool run(ref doir.query.QueryEngine engine, EntityId e) @nogc nothrow {
/// 		return ecrs.context.getComponent!int(*engine.store, e) > 0;
/// 	}
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.query.create(store);
/// scope(exit) doir.query.free(engine);
/// immutable e = ecrs.context.addEntity(store);
/// *ecrs.context.addComponent!int(store, e) = 1;
/// assert(runSystem!Positive(engine) && *doir.query.query!(Memo!Positive)(engine, Memo!Positive.Key([e])));
/// ---
bool runSystem(S)(ref doir.query.QueryEngine engine) @trusted if (isSystem!S) {
	cast(void) doir.query.revalidateStale(engine); // a failure sets `edgesMissing`, which makes this run visit everything
	auto state = ecrs.context.findSingletonForWriting!(doir.components.query.SystemState!S)(*engine.store);
	if (state is null) state = ecrs.context.addSingleton!(doir.components.query.SystemState!S)(*engine.store);
	if (state is null) {
		engine.refused = true;
		return false;
	}
	assert(state.lastRunRevision <= engine.revision, "doir.schedules: a system ran in a revision ahead of the engine's");
	auto changes = doir.query.changesSince(engine, state.cursor);
	immutable whole = state.lastRunRevision == 0 || !changes.complete || engine.edgesMissing;
	// Memos going stale during the batch queue themselves on a fresh list, for the next run.
	EntityId* queued = state.related;
	state.related = null;
	scope(exit) fp.dynarray.free(queued);
	Visit!S* visits = null;
	Memo!S.Key* keys = null;
	scope(exit) {
		fp.dynarray.free(visits);
		fp.dynarray.free(keys);
	}
	bool gathered;
	if (whole) {
		auto storage = ecrs.context.getStorage(*cast(const(ecrs.context.Context)*) engine.store, ecrs.registry.componentId!(S.Tag)());
		gathered = gatherVisits!S(engine, storage is null ? null : ecrs.storage.slotOwnersOf(*storage), visits);
	} else gathered = gatherVisits!S(engine, fp.dynarray.slice(queued), visits) && gatherVisits!S(engine, changes.entities, visits);
	if (gathered && fp.dynarray.length(visits) && fp.dynarray.reserve(keys, fp.dynarray.length(visits)) is null) gathered = false;
	foreach (ref v; fp.dynarray.slice(visits)) {
		if (!gathered) break;
		cast(void) fp.dynarray.pushBack(keys, Memo!S.Key([v.e])); // reserved
	}
	bool ran = gathered && doir.query.demandEach!(Memo!S)(engine, fp.dynarray.slice(keys));
	state = ecrs.context.findSingletonForWriting!(doir.components.query.SystemState!S)(*engine.store);
	if (ran)
		foreach (ref key; fp.dynarray.slice(keys)) {
			immutable q = doir.query.find!(Memo!S)(engine, key);
			if (q == invalidEntity || fp.dynarray.length(ecrs.context.getComponent!(doir.components.query.QueryDiagnostics)(*engine.store, q).items) == 0) continue;
			if (!fp.dynarray.pushBack(state.related, key.related[0])) {
				ran = false;
				break;
			}
		}
	if (!ran) {
		state.lastRunRevision = 0;
		engine.refused = true;
		return false;
	}
	assert(changes.next >= state.cursor || !changes.complete, "doir.schedules: the change cursor moved back");
	state.lastRunRevision = engine.revision;
	state.cursor = changes.next;
	return true;
}

/// `runSystem!S` as a schedule over the engine, so a system is a step of an `ecrs.schedules` schedule.
///
/// Examples:
/// ---
/// struct Nonzero {
/// 	alias Tag = int;
/// 	static bool run(ref doir.query.QueryEngine engine, EntityId e) @nogc nothrow { return true; }
/// }
/// System!Nonzero step;
/// auto copy = step;
/// ---
struct System(S) if (isSystem!S) {
	@nogc nothrow:
	/// Runs the system over `engine`.
	///
	/// Examples:
	/// ---
	/// static import ecrs.context;
	/// struct Swept2 {
	/// 	alias Tag = int;
	/// 	static bool run(ref doir.query.QueryEngine engine, EntityId e) @nogc nothrow { return true; }
	/// }
	/// auto store = ecrs.context.create();
	/// scope(exit) ecrs.context.free(store);
	/// auto engine = doir.query.create(store);
	/// scope(exit) doir.query.free(engine);
	/// assert(System!Swept2()(engine));
	/// ---
	bool opCall(ref doir.query.QueryEngine engine) { return runSystem!S(engine); }
}

version(unittest) {
	static import ecrs.relation;
	static import doir.testing;

	private struct Gauge {
		int value;
	}

	// Polarity(e) is the sign of e's Gauge, so changing the amount without changing its sign keeps Polarity's value (early cutoff).
	private struct Polarity {
		alias Key = ecrs.relation.Relation!1;
		alias Value = int;
		static int compute(ref doir.query.QueryEngine engine, Key key) @nogc nothrow {
			if (!doir.query.read(engine, key.related[0])) return 0;
			immutable v = ecrs.context.getComponent!Gauge(*engine.store, key.related[0]).value;
			return v < 0 ? -1 : v > 0;
		}
	}

	// The domain of `Levels`: an entity's level, which it reports when it is negative.
	private struct Level {
		int value;
	}

	// The entity whose Polarity a Levels entity adds to its own level.
	private struct Watch {
		mixin ecrs.relation.Relates!"other";
	}

	private shared size_t levelRuns;

	// A system over Level reporting each negative level, visited in descending id order through its Order hook.
	private struct Levels {
		alias Tag = Level;
		alias Order = long;
		static long orderOf(ref doir.query.QueryEngine, EntityId e) @nogc nothrow { return -cast(long) e; }
		static int compare(ref doir.query.QueryEngine, ref const long a, ref const long b) @nogc nothrow { return a < b ? -1 : a > b; }
		static bool run(ref doir.query.QueryEngine engine, EntityId e) @nogc nothrow {
			static import core.atomic;
			static import diagnose;
			core.atomic.atomicOp!"+="(levelRuns, 1);
			long v = ecrs.context.getComponent!Level(*engine.store, e).value;
			if (auto w = ecrs.context.findComponent!Watch(*engine.store, e)) {
				auto sign = doir.query.query!Polarity(engine, Polarity.Key([w.other]));
				if (sign is null) return false;
				v += *sign;
			}
			if (v >= 0) return true;
			// The level, not the entity: workers may number entities differently, as they make spare query entities in batches of their own.
			auto message = fp.string.joined("negative ", v);
			if (message.isNull) return false;
			scope(exit) fp.string.free(message.get);
			return doir.query.report(engine, e, diagnose.Kind.error, fp.string.slice(message.get), "make it positive") && false;
		}
	}

	private size_t stepRuns;
	private bool stepSucceeds = true;
	private bool step(ref doir.query.QueryEngine) {
		++stepRuns;
		return stepSucceeds;
	}

}

unittest { // demanding: batches as steps of a schedule, on workers or not
	static import bc.threadpool;
	auto pool = bc.threadpool.create(4);
	assert(pool !is null);
	scope(exit) bc.threadpool.free(pool);
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	auto engine = doir.query.create(store);
	scope(exit) doir.query.free(engine);
	engine.workers = pool;
	Polarity.Key[32] keys;
	foreach (i, ref k; keys) {
		immutable e = doir.testing.addEntity(store);
		doir.testing.addComponent!Gauge(store, e).value = cast(int) i - 16;
		k = Polarity.Key([e]);
	}
	assert(ecrs.schedules.sequential(engine, demanding!Polarity(keys[0 .. 16]), ecrs.schedules.parallel(null, demanding!Polarity(keys[16 .. $]))));
	foreach (i, k; keys) assert(*doir.query.query!Polarity(engine, k) == (i < 16 ? -1 : i > 16));
}

unittest { // whenChangedAt: runs on a newer ChangedAt, follows early cutoff through a watched query, and retries after failing
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	auto engine = doir.query.create(store);
	scope(exit) doir.query.free(engine);
	immutable input = doir.testing.addEntity(store), other = doir.testing.addEntity(store);
	doir.testing.addComponent!Gauge(store, input).value = 1;
	assert(*doir.query.query!Polarity(engine, Polarity.Key([input])) == 1);
	immutable polarity = doir.query.find!Polarity(engine, Polarity.Key([input]));
	immutable EntityId[1] watchInput = [input], watchPolarity = [polarity];

	stepRuns = 0;
	doir.query.Revision verified = 0;
	assert(whenChangedAt(engine, &step, verified, watchInput[]) && stepRuns == 1 && verified == engine.revision);
	assert(whenChangedAt(engine, &step, verified, watchInput[]) && stepRuns == 1);

	// A change to an entity it does not watch leaves it alone; one to its input runs it.
	doir.query.beginRevision(engine);
	assert(doir.query.markChanged(engine, other));
	assert(whenChangedAt(engine, &step, verified, watchInput[]) && stepRuns == 1 && verified == engine.revision);
	doir.query.beginRevision(engine);
	assert(doir.query.markChanged(engine, input));
	assert(whenChangedAt(engine, &step, verified, watchInput[]) && stepRuns == 2);

	// Watching the query: an amount that keeps its sign re-runs Polarity to the same value, which does not count; one that flips it does.
	verified = 0;
	auto bound = whenChangedAt(&step, watchPolarity[]);
	assert(bound(engine) && stepRuns == 3);
	doir.query.beginRevision(engine);
	ecrs.context.getForWriting!Gauge(store, input).value = 7;
	assert(doir.query.markChanged(engine, input));
	assert(bound(engine) && stepRuns == 3);
	doir.query.beginRevision(engine);
	ecrs.context.getForWriting!Gauge(store, input).value = -7;
	assert(doir.query.markChanged(engine, input));
	assert(bound(engine) && stepRuns == 4 && *doir.query.query!Polarity(engine, Polarity.Key([input])) == -1);

	// A failed run keeps its old VerifiedAt, so the next call runs it again.
	doir.query.beginRevision(engine);
	assert(doir.query.markChanged(engine, input));
	stepSucceeds = false;
	immutable before = verified;
	assert(!whenChangedAt(engine, &step, verified, watchInput[]) && verified == before && stepRuns == 5);
	stepSucceeds = true;
	assert(whenChangedAt(engine, &step, verified, watchInput[]) && stepRuns == 6);
}


unittest { // runSystem: visits the domain whole, then what changes reach, entering, leaving and reporting in its order, on one thread or on workers
	static import core.atomic;
	static import fp.string;
	static import bc.threadpool;
	static import diagnose;
	static assert(ecrs.registry.hasRemapEntities!(doir.components.query.SystemState!Levels));
	auto pool = bc.threadpool.create(4);
	assert(pool !is null);
	scope(exit) bc.threadpool.free(pool);
	char*[2] reports;
	scope(exit) foreach (r; reports) fp.string.free(r);
	foreach (run, workers; [null, pool]) {
		auto store = ecrs.context.create();
		scope(exit) ecrs.context.free(store);
		auto engine = doir.query.create(store);
		scope(exit) doir.query.free(engine);
		engine.workers = workers;
		diagnose.Manager manager;
		scope(exit) diagnose.free(manager);
		engine.diagnostics = &manager;
		// Levels: -2, -1, 0, 1, ... so entities 1 and 2 report.
		EntityId[8] es;
		foreach (i, ref e; es) {
			e = doir.testing.addEntity(store);
			doir.testing.addComponent!Level(store, e).value = cast(int) i - 2;
		}
		immutable outsider = doir.testing.addEntity(store); // no Level, so never visited
		immutable gauge = doir.testing.addEntity(store);
		doir.testing.addComponent!Gauge(store, gauge).value = 1;
		doir.testing.addComponent!Watch(store, es[2]) = Watch([gauge]); // level 0, plus the gauge's sign
		alias M = Memo!Levels;
		void record() {
			foreach (ref d; fp.dynarray.slice(manager.diagnostics)) {
				assert(fp.string.concatenate(reports[run], fp.string.slice(d.message)));
				assert(fp.string.concatenate(reports[run], "\n"));
				// Each points at its entity's hint.
				assert(fp.string.slice(d.note) == "make it positive");
			}
			diagnose.clear(manager);
		}
		doir.query.Revision verifiedOf(EntityId e) {
			immutable q = doir.query.find!M(engine, M.Key([e]));
			return q == invalidEntity ? 0 : ecrs.context.getComponent!(doir.components.query.Verification)(store, q).revision;
		}

		// The first run visits every Level, in descending id order.
		immutable before = core.atomic.atomicLoad(levelRuns);
		assert(runSystem!Levels(engine));
		assert(core.atomic.atomicLoad(levelRuns) == before + 8 && doir.query.find!M(engine, M.Key([outsider])) == invalidEntity);
		assert(fp.dynarray.length(manager.diagnostics) == 2 && fp.string.slice(manager.diagnostics[0].message) == "negative -1" && fp.string.slice(manager.diagnostics[1].message) == "negative -2");
		record();

		// Nothing changed: the memos that report are reported again, and the rest are not visited.
		doir.query.beginRevision(engine);
		immutable quiet = verifiedOf(es[5]);
		assert(System!Levels()(engine) && core.atomic.atomicLoad(levelRuns) == before + 8 && fp.dynarray.length(manager.diagnostics) == 2);
		assert(verifiedOf(es[5]) == quiet && verifiedOf(es[0]) == engine.revision);
		record();

		// One level changes: only it runs.
		doir.query.beginRevision(engine);
		ecrs.context.getForWriting!Level(store, es[6]).value = -6;
		assert(doir.query.markChanged(engine, es[6]));
		assert(runSystem!Levels(engine) && core.atomic.atomicLoad(levelRuns) == before + 9 && fp.dynarray.length(manager.diagnostics) == 3);
		assert(verifiedOf(es[5]) == quiet);
		record();

		// One enters, as a commit marks a new entity, and one leaves, its report going with it.
		doir.query.beginRevision(engine);
		immutable entered = doir.testing.addEntity(store);
		doir.testing.addComponent!Level(store, entered).value = -9;
		assert(doir.query.markChanged(engine, entered));
		assert(ecrs.context.removeComponent!Level(store, es[0]));
		assert(doir.query.markChanged(engine, es[0]));
		assert(runSystem!Levels(engine) && core.atomic.atomicLoad(levelRuns) == before + 10 && fp.dynarray.length(manager.diagnostics) == 3);
		assert(verifiedOf(es[0]) == 0); // evicted
		record();

		// A change reaching a memo through a query: one that keeps the query's value stops there (early cutoff), one that changes it runs the memo.
		doir.query.beginRevision(engine);
		ecrs.context.getForWriting!Gauge(store, gauge).value = 5;
		assert(doir.query.markChanged(engine, gauge));
		assert(runSystem!Levels(engine) && core.atomic.atomicLoad(levelRuns) == before + 10);
		record();
		doir.query.beginRevision(engine);
		ecrs.context.getForWriting!Gauge(store, gauge).value = -5;
		assert(doir.query.markChanged(engine, gauge));
		assert(runSystem!Levels(engine) && core.atomic.atomicLoad(levelRuns) == before + 11 && fp.dynarray.length(manager.diagnostics) == 4);
		record();

		// Without reverse edges, or with changes the log dropped unread, it visits the whole domain, and still sees what entered.
		doir.query.beginRevision(engine);
		engine.edgesMissing = true;
		assert(runSystem!Levels(engine) && verifiedOf(es[5]) == engine.revision);
		assert(doir.query.buildDependents(engine));
		record();
		doir.query.beginRevision(engine);
		immutable late = doir.testing.addEntity(store);
		doir.testing.addComponent!Level(store, late).value = -1;
		foreach (_; 0 .. 2 * ecrs.context.entityCount(store)) assert(doir.query.markChanged(engine, late));
		doir.query.beginRevision(engine);
		assert(!doir.query.changesSince(engine, ecrs.context.findSingletonForWriting!(doir.components.query.SystemState!Levels)(*engine.store).cursor).complete);
		assert(runSystem!Levels(engine) && verifiedOf(es[5]) == engine.revision && verifiedOf(late) == engine.revision && fp.dynarray.length(manager.diagnostics) == 5);
		record();
	}
	// Workers report what one thread does, in the same order.
	assert(fp.string.slice(reports[0]) == fp.string.slice(reports[1]));
}
