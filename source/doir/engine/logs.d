/// Owner-tagged log entries: the storage behind positioned effect logs (`C-Order`, `M-Lexical`) and behind components that several queries write parts of, such as `Lowered`. Each entry names the query that wrote it, so a query's re-run or eviction strips only its own entries, and its early cutoff hashes only them.
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
static import fp.fnv1a;

static import ecrs.context;
static import ecrs.registry;
static import ecrs.relation;

static import doir.engine.positions;
static import doir.engine.query;

public import ecrs.registry : EntityId, invalidEntity;

@nogc nothrow:


// --- types and layout --------------------------------------------------------

/// One effect: the query entity that wrote it, `owner`, where it applies (`doir.engine.positions.none` for an unpositioned one), and what it is. An effect that names entities is an `ecrs.relation.Relation`, renumbered with the entry.
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

/// The body of a log component of effects `E`: its entries in position order, with the `E-Remap` and lifetime hooks libECRS finds by name. An `E` that mixes in `ecrs.relation.Relates` is remapped too.
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
/// assert(fp.dynarray.pushBack(members.entries, Entry!Member([1], doir.engine.positions.none, Member([2]))));
/// immutable EntityId[3] remap = [0, 2, 1];
/// Members.remapEntities(members, remap[]);
/// assert(members.entries[0].owner == 2 && members.entries[0].effect.related[0] == 1);
/// ---
mixin template Log(E) {
	@nogc nothrow:
	static import fp.dynarray;
	static import ecrs.registry;
	static import doir.engine.logs;

	doir.engine.logs.Entry!E* entries = null; /// The entries, in position order.

	// The E-Remap hook libECRS finds by name.
	static void remapEntities(ref typeof(this) self, const(EntityId)[] remap) {
		foreach (ref entry; fp.dynarray.slice(self.entries)) {
			doir.engine.logs.Entry!E.remapEntities(entry, remap);
			static if (ecrs.registry.hasRemapEntities!E) E.remapEntities(entry.effect, remap);
		}
	}

	// Releases the entries when the component is removed.
	void finalize() {
		fp.dynarray.free(entries);
		entries = null;
	}
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
/// assert(fp.dynarray.pushBack(marks.entries, Entry!uint([5], doir.engine.positions.none, 1)));
/// assert(fp.dynarray.pushBack(marks.entries, Entry!uint([6], doir.engine.positions.none, 2)));
/// strip!Marks(store, e, ecrs.registry.componentId!Marks(), 5);
/// assert(fp.dynarray.length(marks.entries) == 1 && marks.entries[0].effect == 2);
/// ---
package(doir) void strip(L)(ref ecrs.context.Context store, EntityId e, size_t component, EntityId owner) {
	auto log = ecrs.context.findComponent!L(store, e);
	if (log is null) return;
	size_t kept = 0;
	foreach (entry; fp.dynarray.slice(log.entries))
		if (entry.owner != owner) log.entries[kept++] = entry;
	fp.dynarray.popBackCount(log.entries, fp.dynarray.length(log.entries) - kept);
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
/// assert(hash!Marks(store, e, ecrs.registry.componentId!Marks(), 5) == 0);
/// ---
package(doir) size_t hash(L)(ref const ecrs.context.Context store, EntityId e, size_t component, EntityId owner) @trusted {
	auto log = ecrs.context.findComponent!L(store, e);
	if (log is null) return 0;
	size_t h = 0;
	foreach (ref entry; fp.dynarray.slice(log.entries))
		if (entry.owner == owner) {
			h = (h ^ entry.at.value) * 0x100000001b3;
			static if (__traits(hasMember, typeof(entry.effect), "contentHash")) immutable effectHash = typeof(entry.effect).contentHash(entry.effect);
			else immutable effectHash = fp.fnv1a.hash((cast(const(ubyte)*) &entry.effect)[0 .. entry.effect.sizeof]);
			h = (h ^ effectHash) * 0x100000001b3;
		}
	return h;
}

/// Adds `effect` at `at` to log component `L` on `e`, owned by the running query, after every entry at or before `at`; adds `L` to `e` if it has none. The entry is stripped when the query runs again or is evicted.
///
/// Examples:
/// ---
/// struct Marks {
/// 	mixin Log!uint;
/// }
/// doir.engine.query.QueryEngine engine;
/// assert(doir.engine.query.innermost(engine) == invalidEntity); // append is only valid inside a query
/// ---
package(doir) void append(L, E)(ref doir.engine.query.QueryEngine engine, EntityId e, doir.engine.positions.Position at, E effect) {
	immutable q = doir.engine.query.innermost(engine);
	assert(q != invalidEntity, "doir.logs: writing an effect outside a query");
	auto log = ecrs.context.getOrAddComponent!L(*engine.store, e);
	assert(log !is null, "doir.logs: allocation refused");
	size_t i = fp.dynarray.length(log.entries);
	while (i > 0 && doir.engine.positions.precedes(engine.positions, at, log.entries[i - 1].at)) --i;
	immutable inserted = fp.dynarray.insert(log.entries, i, Entry!E([q], at, effect));
	assert(inserted, "doir.logs: allocation refused");
	doir.engine.query.recordProduced(engine, doir.engine.query.Produced([e], ecrs.registry.componentId!L(), &strip!L, &hash!L), false);
}


// --- reading -----------------------------------------------------------------

private bool visible(ref doir.engine.query.QueryEngine engine, doir.engine.positions.Position entry, doir.engine.positions.Position at) {
	return at == doir.engine.positions.none || doir.engine.positions.precedes(engine.positions, entry, at);
}

/// Calls `visit` with every effect of log component `L` on `e` visible to a read at `at`: those strictly before it, or every one for `at` of `none` (`C-Order`, `L-Freeze`). Each visible entry's owner is brought up to date first, as a reader demands a producer, and the read of `e` and of each owner is recorded, so the reader re-runs when a writer's effects change. An entry owned by another query that is still running is an effect the read cannot wait for, a cycle (`Q-Cycle`): it is reported, and visited all the same.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// struct Marks {
/// 	mixin Log!uint;
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// doir.engine.query.QueryEngine engine;
/// engine.store = &store;
/// scope(exit) doir.engine.query.release(engine);
/// uint seen = 0;
/// fold!(Marks, uint)(engine, ecrs.context.addEntity(store), doir.engine.positions.none, (ref const uint effect) { seen |= effect; });
/// assert(seen == 0);
/// ---
package(doir) void fold(L, E)(ref doir.engine.query.QueryEngine engine, EntityId e, doir.engine.positions.Position at, scope void delegate(ref const E effect) @nogc nothrow visit) {
	doir.engine.query.recordRead(engine, e);
	if (!ecrs.context.hasComponent!L(*engine.store, e)) return;
	immutable reader = doir.engine.query.innermost(engine);
	// A refreshed writer may re-run, rewriting this log, so the log is re-fetched after each one.
	for (size_t i = 0;; ++i) {
		auto entries = ecrs.context.getComponent!L(*engine.store, e).entries;
		if (i >= fp.dynarray.length(entries) || !visible(engine, entries[i].at, at)) break;
		immutable owner = entries[i].owner;
		if (owner != reader && !doir.engine.query.running(engine, owner)) cast(void) doir.engine.query.refreshQuery(engine, owner);
	}
	foreach (entry; fp.dynarray.slice(ecrs.context.getComponent!L(*engine.store, e).entries)) {
		if (!visible(engine, entry.at, at)) break;
		if (entry.owner != reader) {
			if (doir.engine.query.running(engine, entry.owner)) doir.engine.query.reportRunning(engine, entry.owner);
			else doir.engine.query.recordRead(engine, entry.owner);
		}
		visit(entry.effect);
	}
}
