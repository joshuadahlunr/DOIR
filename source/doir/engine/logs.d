/// Owner-tagged log entries: the storage behind positioned effect logs (`C-Order`, `M-Lexical`) and behind components that several queries write parts of, such as `Lowered`.
/// Each entry names the query that wrote it, so a query's re-run or eviction strips only its own entries, and its early cutoff hashes only them.
///
/// Entries are kept in position order, an entry at a position following every entry at or before it, so a fold visits them in lexical order however demand ordered their writes (`R-Order`).
///
/// Examples:
/// ---
/// struct Marks {
/// 	mixin Log!uint;
/// }
/// Marks marks;
/// marks.finalize();
/// ---
module doir.engine.logs;

static import fp.dynarray;
static import fp.algorithms;
static import fp.lifecycle;

static import bc.spinlock;
static import bc.spinlock.striped;

static import ecrs.context;
static import ecrs.registry;
static import ecrs.relation;

static import doir.engine.positions;
static import doir.query;
static import doir.components.query;

public import ecrs.registry : EntityId, invalidEntity;

@nogc nothrow:


// --- types and layout --------------------------------------------------------

/// One effect: the query entity that wrote it, `owner`, where it applies (`doir.engine.positions.end` for an unpositioned one), and what it is.
/// An effect that names entities is an `ecrs.relation.Relation`, renumbered with the entry.
///
/// Examples:
/// ---
/// auto entry = Entry!uint([3], doir.engine.positions.root, 1);
/// assert(entry.owner == 3 && entry.effect == 1);
/// ---
struct Entry(E) {
	mixin ecrs.relation.Relates!"owner";
	doir.engine.positions.Position at; /// Where it takes effect.
	E effect; /// What it does.
}

/// The body of a log component of effects `E`: its entries in position order, with the `E-Remap`, lifetime, `equal` and `contentHash` hooks of `ecrs.relation.RelatesEach`.
/// An `E` that mixes in `ecrs.relation.Relates` is remapped too, and one that owns memory is released with its entry.
///
/// Examples:
/// ---
/// static import fp.dynarray;
/// static import ecrs.relation;
/// alias Member = ecrs.relation.Relation!1;
/// struct Members {
/// 	mixin Log!Member;
/// }
/// Members members;
/// scope(exit) members.finalize();
/// assert(fp.dynarray.pushBack(members.entries, Entry!Member([1], doir.engine.positions.end, Member([2]))));
/// immutable EntityId[3] remap = [0, 2, 1];
/// Members.remapEntities(members, remap[]);
/// assert(members.entries[0].owner == 2 && members.entries[0].effect.related[0] == 1);
/// ---
mixin template Log(E) {
	static import ecrs.relation;
	static import doir.engine.logs;

	mixin ecrs.relation.RelatesEach!(doir.engine.logs.Entry!E, "entries");
}


// --- writing -----------------------------------------------------------------

/// The `StripFunction` of log component `L`: removes `owner`'s entries, keeping the others in order.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import ecrs.registry;
/// static import fp.dynarray;
/// struct Marks {
/// 	mixin Log!uint;
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// immutable e = ecrs.context.addEntity(store);
/// auto marks = ecrs.context.addComponent!Marks(store, e);
/// assert(fp.dynarray.pushBack(marks.entries, Entry!uint([5], doir.engine.positions.end, 1)));
/// assert(fp.dynarray.pushBack(marks.entries, Entry!uint([6], doir.engine.positions.end, 2)));
/// removeOwnerEntries!Marks(store, e, ecrs.registry.componentId!Marks(), 5);
/// assert(fp.dynarray.length(marks.entries) == 1 && marks.entries[0].effect == 2);
/// ---
package(doir) void removeOwnerEntries(L)(ref ecrs.context.Context store, EntityId e, size_t component, EntityId owner) {
	auto log = ecrs.context.findForWriting!L(store, e);
	if (log is null) return;
	cast(void) fp.dynarray.retain!((ref const entry) => entry.owner != owner)(log.entries);
}

/// The `HashFunction` of log component `L`: hashes `owner`'s entries, their positions and effects, in order.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import ecrs.registry;
/// struct Marks {
/// 	mixin Log!uint;
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// immutable e = ecrs.context.addEntity(store);
/// assert(ownerHash!Marks(store, e, ecrs.registry.componentId!Marks(), 5) == 0);
/// ---
package(doir) size_t ownerHash(L)(ref const ecrs.context.Context store, EntityId e, size_t component, EntityId owner) @trusted {
	auto log = ecrs.context.findComponent!L(store, e);
	if (log is null) return 0;
	size_t h = 0;
	foreach (ref entry; fp.dynarray.slice(log.entries))
		if (entry.owner == owner) {
			h = fp.algorithms.combine(h, entry.at.value);
			h = fp.algorithms.combine(h, fp.lifecycle.contentHash(entry.effect));
		}
	return h;
}

/// Adds `effect` at `at` to log component `L` on `e`, owned by the running query, after every entry at or before `at`; adds `L` to `e` if it has none.
/// The entry is stripped when the query runs again or is evicted.
/// Returns false on a refused allocation, which fails the running queries (`doir.query.fail`) and adds no entry.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import ecrs.relation;
/// struct Marks {
/// 	mixin Log!uint;
/// }
/// struct Mark {
/// 	alias Key = ecrs.relation.Relation!1;
/// 	alias Value = bool;
/// 	static bool compute(ref doir.query.QueryEngine engine, Key key) @nogc nothrow {
/// 		return append!(Marks, uint)(engine, key.related[0], doir.engine.positions.end, 4);
/// 	}
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// doir.query.QueryEngine engine;
/// engine.store = &store;
/// scope(exit) doir.query.free(engine);
/// immutable e = ecrs.context.addEntity(store);
/// assert(*doir.query.query!Mark(engine, Mark.Key([e])));
/// assert(ecrs.context.getComponent!Marks(store, e).entries[0].effect == 4);
/// ---
package(doir) bool append(L, E)(ref doir.query.QueryEngine engine, EntityId e, doir.engine.positions.Position at, E effect) {
	immutable q = doir.query.currentQuery(engine);
	assert(q != invalidEntity, "doir.logs: writing an effect outside a query");
	// Recorded first, so no entry exists that a reset of its owner would not strip.
	if (!doir.query.recordOutput(engine, doir.components.query.Output([e], ecrs.registry.componentId!L(), &removeOwnerEntries!L, &ownerHash!L), false)) return false;
	// Other threads' queries write the same log, so it is added in the exclusive section and written behind `e`'s lock.
	if (!ecrs.context.hasComponent!L(*engine.store, e)) {
		doir.query.beginExclusive(engine);
		immutable made = ecrs.context.ensureComponent!L(*engine.store, e) !is null;
		doir.query.endExclusive(engine);
		if (!made) {
			doir.query.fail(engine);
			return false;
		}
	}
	auto lock = &bc.spinlock.striped.stripeFor(engine.entityLocks, e);
	bc.spinlock.lockForWriting(*lock);
	auto log = &ecrs.context.getForWriting!L(*engine.store, e);
	size_t i = fp.dynarray.length(log.entries);
	while (i > 0 && doir.engine.positions.precedes(engine.positions, at, log.entries[i - 1].at)) --i;
	immutable inserted = fp.dynarray.insert(log.entries, i, Entry!E([q], at, effect));
	bc.spinlock.unlockForWriting(*lock);
	if (inserted) return true;
	doir.query.fail(engine);
	return false;
}


// --- reading -----------------------------------------------------------------

private bool visible(ref doir.query.QueryEngine engine, doir.engine.positions.Position entry, doir.engine.positions.Position at) {
	return at == doir.engine.positions.end || doir.engine.positions.precedes(engine.positions, entry, at);
}

/// Calls `visit` with every effect of log component `L` on `e` visible to a read at `at`: those strictly before it, or every one for `at` of `none` (`C-Order`, `L-Freeze`).
/// Each visible entry's owner is brought up to date first, as a reader demands a producer, and the read of `e` and of each owner is recorded, so the reader re-runs when a writer's effects change.
/// An entry owned by another query that is still running is an effect the read cannot wait for, a cycle (`Q-Cycle`): it is reported, and visited all the same.
/// Returns false if the fold may be incomplete: a refused allocation, which fails the running queries (`doir.query.fail`), or an owner that could not be brought up to date, such as one past the depth limit, which is reported.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// struct Marks {
/// 	mixin Log!uint;
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// doir.query.QueryEngine engine;
/// engine.store = &store;
/// scope(exit) doir.query.free(engine);
/// uint seen = 0;
/// assert(fold!(Marks, uint)(engine, ecrs.context.addEntity(store), doir.engine.positions.end, (ref const uint effect) { seen |= effect; }));
/// assert(seen == 0);
/// ---
package(doir) bool fold(L, E)(ref doir.query.QueryEngine engine, EntityId e, doir.engine.positions.Position at, scope void delegate(ref const E effect) @nogc nothrow visit) {
	bool complete = doir.query.read(engine, e);
	if (!ecrs.context.hasComponent!L(*engine.store, e)) return complete;
	immutable reader = doir.query.currentQuery(engine);
	// Other threads' queries write this log, so it is read behind `e`'s lock, which is never held across a demand.
	auto lock = &bc.spinlock.striped.stripeFor(engine.entityLocks, e);
	// A refreshed writer may re-run, rewriting this log, so the log is re-fetched after each one.
	for (size_t i = 0;; ++i) {
		bc.spinlock.lockForReading(*lock);
		auto entries = ecrs.context.getComponent!L(*engine.store, e).entries;
		immutable more = i < fp.dynarray.length(entries) && visible(engine, entries[i].at, at);
		immutable owner = more ? entries[i].owner : invalidEntity;
		bc.spinlock.unlockForReading(*lock);
		if (!more) break;
		if (owner != reader && !doir.query.running(engine, owner)) complete = ecrs.context.getComponent!(doir.components.query.Hooks)(*engine.store, owner).bringUpToDate(engine, owner) && complete;
	}
	Entry!E* visibleEntries = null;
	scope(exit) fp.dynarray.free(visibleEntries);
	bool copied = true;
	bc.spinlock.lockForReading(*lock);
	foreach (entry; fp.dynarray.slice(ecrs.context.getComponent!L(*engine.store, e).entries)) {
		if (!visible(engine, entry.at, at)) break;
		copied = fp.dynarray.pushBack(visibleEntries, entry);
		if (!copied) break;
	}
	bc.spinlock.unlockForReading(*lock);
	if (!copied) {
		doir.query.fail(engine);
		return false;
	}
	foreach (entry; fp.dynarray.slice(visibleEntries)) {
		if (entry.owner != reader) {
			if (doir.query.running(engine, entry.owner)) complete = doir.query.reportRunning(engine, entry.owner) && complete;
			else complete = doir.query.read(engine, entry.owner) && complete;
		}
		visit(entry.effect);
	}
	return complete;
}


version(unittest) {
	private struct TestMarks {
		mixin Log!uint;
	}

	private struct TestMark {
		alias Key = ecrs.relation.Relation!1;
		alias Value = bool;
		static bool compute(ref doir.query.QueryEngine engine, Key key) @nogc nothrow {
			return append!(TestMarks, uint)(engine, key.related[0], doir.engine.positions.end, 4);
		}
	}

	// TestMarkAs(e, k) marks `e` with bit k of a 64-bit word, so many queries write one log.
	private struct TestMarkAs {
		mixin ecrs.relation.Relates!"target";
		uint bit;
	}

	private struct TestMarkOne {
		alias Key = TestMarkAs;
		alias Value = bool;
		static bool compute(ref doir.query.QueryEngine engine, Key key) @nogc nothrow {
			return append!(TestMarks, uint)(engine, key.target, doir.engine.positions.end, key.bit);
		}
	}

	// TestFold(e) folds every bit marked on `e`.
	private struct TestFold {
		alias Key = ecrs.relation.Relation!1;
		alias Value = ulong;
		static ulong compute(ref doir.query.QueryEngine engine, Key key) @nogc nothrow {
			ulong bits = 0;
			if (!fold!(TestMarks, uint)(engine, key.related[0], doir.engine.positions.end, (ref const uint bit) { bits |= 1UL << bit; })) return 0;
			return bits;
		}
	}
}

unittest { // a refused append adds no entry and fails the query; the next demand appends it once
	static import fp.testing;
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	doir.query.QueryEngine engine;
	engine.store = &store;
	scope(exit) doir.query.free(engine);
	bool reachedCompute = false;
	for (size_t budget = 0;; ++budget) {
		immutable e = ecrs.context.addEntity(store);
		auto allocator = fp.testing.limitAllocations(budget);
		auto appended = doir.query.query!TestMark(engine, TestMark.Key([e]));
		fp.testing.restoreAllocator(allocator);
		if (appended !is null && *appended) break;
		assert(engine.refused);
		auto log = ecrs.context.findComponent!TestMarks(store, e);
		reachedCompute |= doir.query.find!TestMark(engine, TestMark.Key([e])) != invalidEntity;
		assert(log is null || fp.dynarray.length(log.entries) == 0);
		engine.refused = false;
		doir.query.beginRevision(engine);
		assert(*doir.query.query!TestMark(engine, TestMark.Key([e])));
		assert(fp.dynarray.length(ecrs.context.getComponent!TestMarks(store, e).entries) == 1);
	}
	assert(reachedCompute);

	// A renumbering rewrites each entry's owner with its query (E-Remap).
	immutable marked = ecrs.context.addEntity(store), spare = ecrs.context.addEntity(store);
	assert(*doir.query.query!TestMark(engine, TestMark.Key([marked])));
	immutable owner = doir.query.find!TestMark(engine, TestMark.Key([marked]));
	assert(ecrs.context.swapEntities(store, owner, spare));
	assert(ecrs.context.getComponent!TestMarks(store, marked).entries[0].owner == spare);
}

unittest { // queries on many threads write one log at once, and a fold sees each entry once
	static import bc.threadpool;
	static import ecrs.schedules;
	auto pool = bc.threadpool.create(4);
	assert(pool !is null);
	scope(exit) bc.threadpool.free(pool);
	static bool mark(ref doir.query.QueryEngine engine, ref TestMarkAs key) @nogc nothrow {
		auto marked = doir.query.query!TestMarkOne(engine, key);
		return marked !is null && *marked;
	}
	static bool foldAll(ref doir.query.QueryEngine engine, ref TestFold.Key key) @nogc nothrow {
		auto bits = doir.query.query!TestFold(engine, key);
		return bits !is null && *bits == ulong.max;
	}
	foreach (attempt; 0 .. 16) {
		auto store = ecrs.context.create();
		scope(exit) ecrs.context.free(store);
		auto engine = doir.query.create(store);
		scope(exit) doir.query.free(engine);
		immutable target = ecrs.context.addEntity(store);
		TestMarkAs[64] marks;
		foreach (i, ref m; marks) m = TestMarkAs([target], cast(uint) i);
		assert(ecrs.schedules.parallel!mark(engine, pool, marks[]) && !engine.refused);
		assert(fp.dynarray.length(ecrs.context.getComponent!TestMarks(store, target).entries) == marks.length);
		// Several folds read the log at once, each bringing its writers up to date first.
		TestFold.Key[8] folds = TestFold.Key([target]);
		assert(ecrs.schedules.parallel!foldAll(engine, pool, folds[]) && !engine.refused);
	}
}
