/// Positioned effect logs (`C-Order`, `M-Lexical`, `L-Freeze`). Comptime-mutable state, a declaration's flags, an overload set's members and the targets `compile_for` gave it, is a log of ⟨position, effect⟩ entries, never overwritten in place. A read at position k folds the entries before k in position order, so demand may evaluate a forward-referenced declaration early (`R-Order`) without an earlier read seeing its effects.
///
/// `freezeLevel` folds each log once into the plain component that cross-level queries read by entity alone: `FrozenFlags`, `Overloads` and `On`. The parser's `Flags` stays as it wrote it, the base every fold starts from, so a re-freeze after an edit drops an effect whose line was removed.
///
/// Each entry is owned by the query that wrote it, a comptime evaluation keyed by ⟨entity, position⟩, so a re-run replaces only its own entries. Logs hold entity ids only through `E-Remap` hooks, so renumbering covers them.
///
/// Examples:
/// ---
/// static import ecrs.relation;
/// static import ecrs.context;
/// static import doir.query;
/// static import doir.positions;
/// static import doir.components;
/// struct Modify {
/// 	alias Key = ecrs.relation.Relation!1;
/// 	alias Value = bool;
/// 	static bool compute(ref doir.query.QueryEngine engine, Key key) @nogc nothrow {
/// 		immutable t = key.related[0];
/// 		return applyFlags(engine, t, doir.positions.between(engine.positions, doir.positions.root, doir.positions.none, doir.positions.none), doir.components.Flags.ReadOnly);
/// 	}
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.query.create(store);
/// scope(exit) doir.query.free(engine);
/// immutable t = ecrs.context.addEntity(store);
/// assert(*doir.query.query!Modify(engine, Modify.Key([t])));
/// assert(flagsAt(engine, t, doir.positions.root).get == 0);
/// assert(flagsAt(engine, t, doir.positions.none).get == doir.components.Flags.ReadOnly);
/// ---
module doir.effects;

static import std.typecons;

static import fp.dynarray;

static import ecrs.context;
static import ecrs.relation;
static import ecrs.registry;

static import doir.engine.logs;
static import doir.engine.positions;
static import doir.engine.query;
static import doir.builders;
static import doir.components;
static import doir.query;

public import ecrs.registry : EntityId, invalidEntity;
public import doir.engine.positions : Position;

@nogc nothrow:


// --- types and layout --------------------------------------------------------

/// The flag modifiers applied to a declaration, each a set of flags added at a position (`M-Lexical`, `M-Idempotent`).
struct FlagsLog {
	mixin doir.engine.logs.Log!uint;
}

/// The flags of a frozen declaration: the parser's `Flags` with every modifier of its log (`L-Freeze`). Cross-level queries read it by entity alone, through `flags`.
struct FrozenFlags {
	uint flags; /// The set, one bit per flag.
}

/// The members `std.functions.add_overload` added to an overload set, each at a position (`TF-Overload`).
struct OverloadsLog {
	mixin doir.engine.logs.Log!(ecrs.relation.Relation!1);
}

/// The targets `std.targets.compile_for` gave a declaration, each at a position (`T-Live`).
struct OnLog {
	mixin doir.engine.logs.Log!(ecrs.relation.Relation!1);
}


unittest { // libECRS silently skips a holder whose hook is not `@nogc nothrow`; every holder of an entity id must pass (E-Remap)
	static assert(ecrs.registry.hasRemapEntities!FlagsLog && ecrs.registry.hasRemapEntities!OverloadsLog && ecrs.registry.hasRemapEntities!OnLog);
}


// --- writing effects ---------------------------------------------------------

/// Adds `flags` to declaration `e` at position `at` on behalf of the running query, a comptime evaluation, which owns the effect (`M-Lexical`, `C-Order`). Reads at or before `at` do not see it. Returns false on a refused allocation, which fails the running queries (`doir.query.fail`).
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import ecrs.relation;
/// static import doir.query;
/// static import doir.positions;
/// static import doir.components;
/// struct Pure {
/// 	alias Key = ecrs.relation.Relation!1;
/// 	alias Value = bool;
/// 	static bool compute(ref doir.query.QueryEngine engine, Key key) @nogc nothrow {
/// 		return applyFlags(engine, key.related[0], doir.positions.between(engine.positions, doir.positions.root, doir.positions.none, doir.positions.none), doir.components.Flags.Pure);
/// 	}
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.query.create(store);
/// scope(exit) doir.query.free(engine);
/// immutable e = ecrs.context.addEntity(store);
/// assert(*doir.query.query!Pure(engine, Pure.Key([e])));
/// assert(flagsAt(engine, e, doir.positions.none).get == doir.components.Flags.Pure);
/// ---
bool applyFlags(ref doir.engine.query.QueryEngine engine, EntityId e, Position at, uint flags) {
	assert(at != doir.engine.positions.none);
	return doir.engine.logs.append!(FlagsLog, uint)(engine, e, at, flags);
}

/// Adds `member` to overload set `set` at position `at` on behalf of the running query (`TF-Overload`, `C-Order`). Returns false on a refused allocation, as `applyFlags` does.
///
/// Examples:
/// ---
/// static import fp.dynarray;
/// static import ecrs.context;
/// static import ecrs.relation;
/// static import doir.query;
/// static import doir.positions;
/// struct Add {
/// 	alias Key = ecrs.relation.Relation!2;
/// 	alias Value = bool;
/// 	static bool compute(ref doir.query.QueryEngine engine, Key key) @nogc nothrow {
/// 		return addOverload(engine, key.related[0], doir.positions.between(engine.positions, doir.positions.root, doir.positions.none, doir.positions.none), key.related[1]);
/// 	}
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.query.create(store);
/// scope(exit) doir.query.free(engine);
/// immutable set = ecrs.context.addEntity(store), f = ecrs.context.addEntity(store);
/// assert(*doir.query.query!Add(engine, Add.Key([set, f])));
/// EntityId* members = null;
/// scope(exit) fp.dynarray.free(members);
/// assert(entitiesAt!OverloadsLog(engine, set, doir.positions.none, members));
/// assert(fp.dynarray.slice(members) == [f]);
/// ---
bool addOverload(ref doir.engine.query.QueryEngine engine, EntityId set, Position at, EntityId member) {
	assert(at != doir.engine.positions.none);
	return doir.engine.logs.append!(OverloadsLog, ecrs.relation.Relation!1)(engine, set, at, ecrs.relation.Relation!1([member]));
}

/// Makes declaration `e` live on `target` from position `at` on behalf of the running query (`T-Live`, `C-Order`). Returns false on a refused allocation, as `applyFlags` does.
///
/// Examples:
/// ---
/// static import fp.dynarray;
/// static import ecrs.context;
/// static import ecrs.relation;
/// static import doir.query;
/// static import doir.positions;
/// struct Live {
/// 	alias Key = ecrs.relation.Relation!2;
/// 	alias Value = bool;
/// 	static bool compute(ref doir.query.QueryEngine engine, Key key) @nogc nothrow {
/// 		return liveOn(engine, key.related[0], doir.positions.between(engine.positions, doir.positions.root, doir.positions.none, doir.positions.none), key.related[1]);
/// 	}
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.query.create(store);
/// scope(exit) doir.query.free(engine);
/// immutable e = ecrs.context.addEntity(store), gpu = ecrs.context.addEntity(store);
/// assert(*doir.query.query!Live(engine, Live.Key([e, gpu])));
/// EntityId* targets = null;
/// scope(exit) fp.dynarray.free(targets);
/// assert(entitiesAt!OnLog(engine, e, doir.positions.none, targets));
/// assert(fp.dynarray.slice(targets) == [gpu]);
/// ---
bool liveOn(ref doir.engine.query.QueryEngine engine, EntityId e, Position at, EntityId target) {
	assert(at != doir.engine.positions.none);
	return doir.engine.logs.append!(OnLog, ecrs.relation.Relation!1)(engine, e, at, ecrs.relation.Relation!1([target]));
}


// --- positioned reads --------------------------------------------------------

/// The flags of declaration `e` as a read at `at` sees them: the parser's `Flags` with every modifier strictly before `at` (`M-Lexical`, `L-Freeze`); `none` sees every modifier. Inside a query, records the reads it makes; a modifier owned by a query still running is a cycle (`Q-Cycle`), reported. Returns null if the answer may be incomplete: a refused allocation, which fails the running queries (`doir.query.fail`), or a modifier's query that could not be brought up to date, which is reported.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.query;
/// static import doir.positions;
/// static import doir.builders;
/// static import doir.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.query.create(store);
/// scope(exit) doir.query.free(engine);
/// immutable e = ecrs.context.addEntity(store);
/// assert(doir.builders.addFlags(store, e, doir.components.Flags.Export));
/// assert(flagsAt(engine, e, doir.positions.none).get == doir.components.Flags.Export);
/// ---
std.typecons.Nullable!uint flagsAt(ref doir.engine.query.QueryEngine engine, EntityId e, Position at) {
	auto own = ecrs.context.findComponent!(doir.components.Flags)(*engine.store, e);
	uint out_ = own is null ? 0 : own.flags;
	if (!doir.engine.logs.fold!(FlagsLog, uint)(engine, e, at, (ref const uint flags) { out_ |= flags; })) return typeof(return).init;
	return typeof(return)(out_);
}

/// Appends to `out_` the entities log `L` holds for `e` as a read at `at` sees them, in position order, each once: the members of overload set `e` for `OverloadsLog` (`TF-Overload`), or the targets `compile_for` gave declaration `e` for `OnLog` (`T-Live`) (`C-Order`). Records reads as `flagsAt` does, and returns false where it returns null or an append is refused.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import fp.dynarray;
/// static import doir.query;
/// static import doir.positions;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.query.create(store);
/// scope(exit) doir.query.free(engine);
/// EntityId* members = null;
/// scope(exit) fp.dynarray.free(members);
/// assert(entitiesAt!OverloadsLog(engine, ecrs.context.addEntity(store), doir.positions.none, members));
/// assert(fp.dynarray.length(members) == 0);
/// ---
bool entitiesAt(L)(ref doir.engine.query.QueryEngine engine, EntityId e, Position at, ref EntityId* out_) if (is(L == OverloadsLog) || is(L == OnLog)) {
	bool appended = true;
	immutable folded = doir.engine.logs.fold!(L, ecrs.relation.Relation!1)(engine, e, at, (ref const ecrs.relation.Relation!1 effect) {
		immutable member = effect.related[0];
		foreach (existing; fp.dynarray.slice(out_))
			if (existing == member) return;
		if (fp.dynarray.pushBack(out_, member)) return;
		if (appended) doir.engine.query.fail(engine);
		appended = false;
	});
	return folded && appended;
}


// --- freezing ----------------------------------------------------------------

/// The flags of a frozen declaration, read by entity alone (`L-Freeze`): its `FrozenFlags`, or the parser's `Flags` if no freeze has folded a modifier into it. Records the read of `e`.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.query;
/// static import doir.builders;
/// static import doir.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.query.create(store);
/// scope(exit) doir.query.free(engine);
/// immutable e = ecrs.context.addEntity(store);
/// assert(doir.builders.addFlags(store, e, doir.components.Flags.Export));
/// assert(flags(engine, e) == doir.components.Flags.Export);
/// ---
uint flags(ref doir.engine.query.QueryEngine engine, EntityId e) {
	cast(void) doir.query.read(engine, e); // a refusal fails the running queries, discarding this answer
	if (auto frozen = ecrs.context.findComponent!FrozenFlags(*engine.store, e)) return frozen.flags;
	if (auto own = ecrs.context.findComponent!(doir.components.Flags)(*engine.store, e)) return own.flags;
	return 0;
}

private bool same(C)(ref const C a, ref const C b) {
	static if (__traits(hasMember, C, "equal")) return C.equal(a, b);
	else return a == b;
}

private void release(C)(ref C value) {
	static if (__traits(hasMember, C, "finalize")) value.finalize();
}

// Takes over folded `value` as `e`'s frozen `C`; outside a query, an input commit marking a differing value changed. Returns false on refusal, releasing `value`.
private bool writeFrozen(C)(ref doir.engine.query.QueryEngine engine, EntityId e, ref C value) {
	immutable inside = doir.query.currentQuery(engine) != invalidEntity;
	bool changed = true;
	auto slot = ecrs.context.findComponent!C(*engine.store, e);
	if (slot !is null) {
		changed = !same(*slot, value);
		release(*slot);
	} else slot = inside ? doir.query.produce!C(engine, e) : ecrs.context.addComponent!C(*engine.store, e);
	if (slot is null) {
		if (!inside) doir.engine.query.fail(engine);
		release(value);
		return false;
	}
	*slot = value;
	return !changed || inside || doir.query.markChanged(engine, e);
}

/// Folds every log on `e` into the plain component cross-level queries read: `FrozenFlags`, `Overloads` and `On` (`L-Freeze`). A log-less `e` gets none. Outside a query it is an input commit: call it after `beginRevision`, and it marks `e` changed when a folded value differs from the last freeze. Inside a query, such as an import (`I-Import`), the components it adds are that query's. Returns false if a fold was incomplete or an allocation was refused, which fails the running queries (see `flagsAt`); `e` may then hold some of its frozen components, from this freeze or the last.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.query;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.query.create(store);
/// scope(exit) doir.query.free(engine);
/// immutable e = ecrs.context.addEntity(store);
/// assert(freezeEntity(engine, e));
/// assert(!ecrs.context.hasComponent!FrozenFlags(store, e));
/// ---
bool freezeEntity(ref doir.engine.query.QueryEngine engine, EntityId e) {
	if (ecrs.context.hasComponent!FlagsLog(*engine.store, e)) {
		immutable flags = flagsAt(engine, e, doir.engine.positions.none);
		if (flags.isNull) return false;
		auto frozen = FrozenFlags(flags.get);
		if (!writeFrozen(engine, e, frozen)) return false;
	}
	if (ecrs.context.hasComponent!OverloadsLog(*engine.store, e)) {
		doir.components.Overloads members;
		if (!entitiesAt!OverloadsLog(engine, e, doir.engine.positions.none, members.related)) {
			release(members);
			return false;
		}
		if (!writeFrozen(engine, e, members)) return false;
	}
	if (ecrs.context.hasComponent!OnLog(*engine.store, e)) {
		doir.components.On targets;
		if (!entitiesAt!OnLog(engine, e, doir.engine.positions.none, targets.related)) {
			release(targets);
			return false;
		}
		if (!writeFrozen(engine, e, targets)) return false;
	}
	return true;
}

/// Freezes `root` and every declaration below it, its blocks' contents and function types' parameters, as `freezeEntity` does (`L-Freeze`): once a level's comptime has terminated, every other reader sees one final answer. Returns false on the first entity `freezeEntity` fails on, or on a refused allocation of its own, which fails the running queries (`doir.query.fail`); the entities before it stay frozen.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.query;
/// static import doir.builders;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.query.create(store);
/// scope(exit) doir.query.free(engine);
/// auto root = doir.builders.createRoot(store);
/// assert(freezeLevel(engine, root.block));
/// ---
bool freezeLevel(ref doir.engine.query.QueryEngine engine, EntityId root) {
	EntityId* pending = null;
	scope(exit) fp.dynarray.free(pending);
	bool grew = fp.dynarray.pushBack(pending, root);
	while (grew && fp.dynarray.length(pending) > 0) {
		immutable e = *fp.dynarray.back(pending);
		cast(void) fp.dynarray.popBack(pending);
		if (!freezeEntity(engine, e)) return false;
		if (auto block = ecrs.context.findComponent!(doir.components.Block)(*engine.store, e))
			grew = fp.dynarray.concatenate(pending, fp.dynarray.slice(block.related));
		if (auto inputs = ecrs.context.findComponent!(doir.components.FunctionInputs)(*engine.store, e))
			grew = grew && fp.dynarray.concatenate(pending, fp.dynarray.slice(inputs.related));
	}
	if (!grew) doir.engine.query.fail(engine);
	return grew;
}


version(unittest) {
	static import fp.string;

	static import diagnose;

	static import doir.strings;
	static import fp.pointer;
	static import doir.testing;
	static import doir.positions;

	private __gshared int modifierRuns, readRuns;
	private __gshared uint modifierFlags = doir.components.Flags.ReadOnly;

	// The modifier line `std.pointers.read_only(t)` at position `at`, a comptime evaluation keyed by ⟨entity, position⟩.
	private struct Modifier {
		struct Key {
			mixin ecrs.relation.Relates!"target";
			Position at;
		}
		alias Value = bool;
		static bool compute(ref doir.query.QueryEngine engine, Key key) @nogc nothrow {
			++modifierRuns;
			return applyFlags(engine, key.target, key.at, modifierFlags);
		}
	}

	// A comptime read of `t`'s flags at position `at`, as the declaration at `at` evaluates it.
	private struct ReadFlags {
		struct Key {
			mixin ecrs.relation.Relates!"target";
			Position at;
		}
		alias Value = uint;
		static uint compute(ref doir.query.QueryEngine engine, Key key) @nogc nothrow {
			++readRuns;
			return flagsAt(engine, key.target, key.at).get(0);
		}
	}

	// A modifier at `at` that first demands a read further down, which sees its effect: a cycle.
	private struct ModifyThenRead {
		struct Key {
			mixin ecrs.relation.Relates!"target";
			Position at, later;
		}
		alias Value = uint;
		static uint compute(ref doir.query.QueryEngine engine, Key key) @nogc nothrow {
			assert(applyFlags(engine, key.target, key.at, doir.components.Flags.Pure));
			return *doir.query.query!ReadFlags(engine, ReadFlags.Key([key.target], key.later));
		}
	}

	private struct Overload {
		struct Key {
			mixin ecrs.relation.Relates!("set", "member");
			Position at;
		}
		alias Value = bool;
		static bool compute(ref doir.query.QueryEngine engine, Key key) @nogc nothrow {
			assert(addOverload(engine, key.set, key.at, key.member));
			return true;
		}
	}

	// The line `std.targets.compile_for(e, target)` at position `at`.
	private struct LiveOn {
		struct Key {
			mixin ecrs.relation.Relates!("declaration", "target");
			Position at;
		}
		alias Value = bool;
		static bool compute(ref doir.query.QueryEngine engine, Key key) @nogc nothrow {
			assert(liveOn(engine, key.declaration, key.at, key.target));
			return true;
		}
	}
}

unittest { // a read before a modifier's position sees the type unmodified, even when demand evaluated the modifier first
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	auto engine = doir.query.create(store);
	scope(exit) doir.query.free(engine);

	// t : type = {} ; x : _ = read(t) ; _ : _ = std.pointers.read_only(t) ; y : _ = read(t)
	auto root = doir.builders.createRoot(store);
	immutable t = doir.builders.pushAggregate(root, doir.strings.StringId(0), doir.strings.StringId(1)).block;
	assert(doir.builders.addFlags(store, t, doir.components.Flags.Export));
	assert(doir.query.markChanged(engine, t));
	immutable pt = doir.positions.between(engine.positions, doir.positions.root, doir.positions.none, doir.positions.none);
	immutable px = doir.positions.between(engine.positions, doir.positions.root, pt, doir.positions.none);
	immutable pm = doir.positions.between(engine.positions, doir.positions.root, px, doir.positions.none);
	immutable py = doir.positions.between(engine.positions, doir.positions.root, pm, doir.positions.none);

	// Demand runs the modifier on line 3 before the read on line 2.
	modifierRuns = readRuns = 0;
	assert(*doir.query.query!Modifier(engine, Modifier.Key([t], pm)));
	assert(*doir.query.query!ReadFlags(engine, ReadFlags.Key([t], px)) == doir.components.Flags.Export);
	assert(*doir.query.query!ReadFlags(engine, ReadFlags.Key([t], py)) == (doir.components.Flags.Export | doir.components.Flags.ReadOnly));
	assert(*doir.query.query!ReadFlags(engine, ReadFlags.Key([t], pm)) == doir.components.Flags.Export);

	// Freezing folds the log once; cross-level reads by entity alone see every modifier.
	doir.query.beginRevision(engine);
	assert(freezeLevel(engine, root.block));
	assert(ecrs.context.getComponent!FrozenFlags(store, t).flags == (doir.components.Flags.Export | doir.components.Flags.ReadOnly));
	assert(flags(engine, t) == (doir.components.Flags.Export | doir.components.Flags.ReadOnly));
	assert(ecrs.context.getComponent!(doir.components.Flags)(store, t).flags == doir.components.Flags.Export);

	// Freezing marked `t` changed, so its in-level reads re-validate here, cut off by their equal values.
	assert(*doir.query.query!ReadFlags(engine, ReadFlags.Key([t], py)) == (doir.components.Flags.Export | doir.components.Flags.ReadOnly));
	assert(*doir.query.query!ReadFlags(engine, ReadFlags.Key([t], px)) == doir.components.Flags.Export);

	// The modifier re-runs with a different effect: the read after it re-runs, the one before it does not, and a re-freeze drops the old bit.
	doir.query.beginRevision(engine);
	modifierFlags = doir.components.Flags.Packed;
	doir.query.evict!Modifier(engine, Modifier.Key([t], pm));
	readRuns = 0;
	assert(*doir.query.query!ReadFlags(engine, ReadFlags.Key([t], py)) == (doir.components.Flags.Export | doir.components.Flags.Packed));
	assert(*doir.query.query!ReadFlags(engine, ReadFlags.Key([t], px)) == doir.components.Flags.Export);
	assert(readRuns == 1);
	doir.query.beginRevision(engine);
	assert(freezeLevel(engine, root.block));
	assert(flags(engine, t) == (doir.components.Flags.Export | doir.components.Flags.Packed));
	modifierFlags = doir.components.Flags.ReadOnly;

	// A renumbering rewrites the logs and positioned keys with everything else (E-Remap).
	immutable spare = doir.testing.addEntity(store);
	assert(ecrs.context.swapEntities(store, t, spare));
	assert(doir.engine.query.find!ReadFlags(engine, ReadFlags.Key([spare], py)) != invalidEntity);
	assert(*doir.query.query!ReadFlags(engine, ReadFlags.Key([spare], py)) == (doir.components.Flags.Export | doir.components.Flags.Packed));
	assert(flagsAt(engine, spare, px).get == doir.components.Flags.Export);

	// A modifier whose allocation is refused fails, leaving no entry its re-run would not strip; the next demand applies it once.
	size_t n = 0;
	for (bool refused = true; refused;) {
		immutable fresh = doir.testing.addEntity(store);
		assert(doir.builders.addFlags(store, fresh, doir.components.Flags.Export));
		assert(doir.query.markChanged(engine, fresh));
		auto previous = doir.testing.beginRationedAllocator(n++);
		auto applied = doir.query.query!Modifier(engine, Modifier.Key([fresh], pm));
		fp.pointer.allocFunction = previous;
		assert(applied is null ? engine.refused : *applied);
		refused = engine.refused;
		engine.refused = false;
		assert(*doir.query.query!Modifier(engine, Modifier.Key([fresh], pm)));
		assert(fp.dynarray.length(ecrs.context.getComponent!FlagsLog(store, fresh).entries) == 1);
		assert(flagsAt(engine, fresh, py).get == (doir.components.Flags.Export | doir.components.Flags.ReadOnly));
	}
}

unittest { // overload sets fold in position order; a read needing a running query's effect is a cycle
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	diagnose.Manager manager;
	scope(exit) diagnose.free(manager);
	auto engine = doir.query.create(store);
	scope(exit) doir.query.free(engine);
	engine.diagnostics = &manager;

	immutable set = doir.testing.addEntity(store), f = doir.testing.addEntity(store), g = doir.testing.addEntity(store);
	immutable p1 = doir.positions.between(engine.positions, doir.positions.root, doir.positions.none, doir.positions.none);
	immutable p2 = doir.positions.between(engine.positions, doir.positions.root, p1, doir.positions.none);
	immutable p3 = doir.positions.between(engine.positions, doir.positions.root, p2, doir.positions.none);
	assert(*doir.query.query!Overload(engine, Overload.Key([set, g], p2)));
	assert(*doir.query.query!Overload(engine, Overload.Key([set, f], p1)));
	EntityId* members = null;
	scope(exit) fp.dynarray.free(members);
	assert(entitiesAt!OverloadsLog(engine, set, p3, members));
	assert(fp.dynarray.slice(members) == [f, g]);
	fp.dynarray.clear(members);
	assert(entitiesAt!OverloadsLog(engine, set, p2, members));
	assert(fp.dynarray.slice(members) == [f]);
	doir.query.beginRevision(engine);
	assert(freezeLevel(engine, set));
	assert(fp.dynarray.slice(ecrs.context.getComponent!(doir.components.Overloads)(store, set).related) == [f, g]);

	// Targets fold the same way, and freezing reaches a function type's parameters (T-Live, L-Freeze).
	auto root = doir.builders.createRoot(store);
	immutable ft = doir.builders.pushFunctionType(root, doir.strings.StringId(0), doir.strings.StringId(1));
	immutable param = doir.builders.pushParameter(store, ft, doir.strings.StringId(2), doir.strings.StringId(3));
	immutable cpu = doir.testing.addEntity(store), gpu = doir.testing.addEntity(store);
	assert(*doir.query.query!LiveOn(engine, LiveOn.Key([param, gpu], p2)));
	assert(*doir.query.query!LiveOn(engine, LiveOn.Key([param, cpu], p1)));
	EntityId* targets = null;
	scope(exit) fp.dynarray.free(targets);
	assert(entitiesAt!OnLog(engine, param, p2, targets));
	assert(fp.dynarray.slice(targets) == [cpu]);
	doir.query.beginRevision(engine);
	assert(freezeLevel(engine, root.block));
	assert(fp.dynarray.slice(ecrs.context.getComponent!(doir.components.On)(store, param).related) == [cpu, gpu]);

	// Without a frozen modifier, a cross-level read sees the parser's flags, or none.
	assert(flags(engine, param) == doir.components.Flags.Valueless);
	assert(flags(engine, cpu) == 0);

	// A re-freeze that folds the same members leaves the entity unchanged; one that drops a member replaces the last freeze.
	immutable frozenAt = doir.query.changedAt(engine, param);
	doir.query.beginRevision(engine);
	assert(freezeLevel(engine, root.block));
	assert(freezeLevel(engine, set));
	assert(doir.query.changedAt(engine, param) == frozenAt);
	doir.query.beginRevision(engine);
	doir.query.evict!LiveOn(engine, LiveOn.Key([param, gpu], p2));
	assert(freezeLevel(engine, root.block));
	assert(fp.dynarray.slice(ecrs.context.getComponent!(doir.components.On)(store, param).related) == [cpu]);
	assert(doir.query.changedAt(engine, param) == engine.revision);

	immutable t = doir.testing.addEntity(store);
	cast(void) doir.query.query!ModifyThenRead(engine, ModifyThenRead.Key([t], p1, p3));
	assert(diagnose.count(manager) == 1);
	enum prefix = "Q-Cycle: a read needs an effect of a query that is still running: ModifyThenRead";
	assert(fp.string.slice(manager.diagnostics[0].message)[0 .. prefix.length] == prefix);

	// A freeze refused at any allocation fails, and the next one folds every log.
	bool refused = true;
	for (size_t n = 0; refused; ++n) {
		assert(n < 100);
		immutable x = doir.testing.addEntity(store);
		assert(*doir.query.query!Modifier(engine, Modifier.Key([x], p1)));
		assert(*doir.query.query!Overload(engine, Overload.Key([x, f], p1)));
		assert(*doir.query.query!LiveOn(engine, LiveOn.Key([x, cpu], p1)));
		doir.query.beginRevision(engine);
		auto previous = doir.testing.beginRationedAllocator(n);
		immutable frozen = freezeEntity(engine, x);
		fp.pointer.allocFunction = previous;
		assert(frozen || engine.refused);
		refused = engine.refused;
		engine.refused = false;
		assert(freezeEntity(engine, x));
		assert(flags(engine, x) == modifierFlags);
		assert(fp.dynarray.slice(ecrs.context.getComponent!(doir.components.Overloads)(store, x).related) == [f]);
		assert(fp.dynarray.slice(ecrs.context.getComponent!(doir.components.On)(store, x).related) == [cpu]);
	}
}
