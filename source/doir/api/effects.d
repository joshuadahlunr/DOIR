/// Positioned effect logs (`C-Order`, `M-Lexical`, `L-Freeze`). Comptime-mutable state, a declaration's flags, an overload set's members and the targets `live_on` gave it, is a log of ⟨position, effect⟩ entries, never overwritten in place. A read at position k folds the entries before k in position order, so demand may evaluate a forward-referenced declaration early (`R-Order`) without an earlier read seeing its effects.
///
/// `freezeLevel` folds each log once into the plain component that cross-level queries read by entity alone: `FrozenFlags`, `Overloads` and `On`. The parser's `Flags` stays as it wrote it, the base every fold starts from, so a re-freeze after an edit drops an effect whose line was removed.
///
/// Each entry is owned by the query that wrote it, a comptime evaluation keyed by ⟨entity, position⟩, so a re-run replaces only its own entries. Logs hold entity ids only through `E-Remap` hooks, so renumbering covers them.
///
/// Examples:
/// ---
/// static import ecrs.relation;
/// static import ecrs.context;
/// static import doir.api.query;
/// static import doir.api.positions;
/// static import doir.api.components;
/// struct Modify {
/// 	alias Key = ecrs.relation.Relation!1;
/// 	alias Value = bool;
/// 	static bool compute(ref doir.api.query.QueryEngine engine, Key key) @nogc nothrow {
/// 		immutable t = key.related[0];
/// 		return applyFlags(engine, t, doir.api.positions.between(engine, doir.api.positions.root, doir.api.positions.none, doir.api.positions.none), doir.api.components.Flags.Immutable);
/// 	}
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.api.query.create(store);
/// scope(exit) doir.api.query.free(engine);
/// immutable t = ecrs.context.addEntity(store);
/// assert(*doir.api.query.query!Modify(engine, Modify.Key([t])));
/// uint seen;
/// assert(flagsAt(engine, t, doir.api.positions.root, seen) && seen == 0);
/// assert(flagsAt(engine, t, doir.api.positions.none, seen) && seen == doir.api.components.Flags.Immutable);
/// ---
module doir.api.effects;

static import fp.dynarray;

static import ecrs.context;
static import ecrs.relation;
static import ecrs.registry;

static import doir.engine.logs;
static import doir.engine.positions;
static import doir.engine.query;
static import doir.api.builders;
static import doir.api.components;
static import doir.api.query;

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

/// The targets `std.targets.live_on` gave a declaration, each at a position (`T-Live`).
struct OnLog {
	mixin doir.engine.logs.Log!(ecrs.relation.Relation!1);
}


unittest { // libECRS silently skips a holder whose hook is not `@nogc nothrow`; every holder of an entity id must pass (E-Remap)
	static assert(ecrs.registry.hasRemapEntities!FlagsLog && ecrs.registry.hasRemapEntities!OverloadsLog && ecrs.registry.hasRemapEntities!OnLog);
}


// --- writing effects ---------------------------------------------------------

/// Adds `flags` to declaration `e` at position `at` on behalf of the running query, a comptime evaluation, which owns the effect (`M-Lexical`, `C-Order`). Reads at or before `at` do not see it. Returns false on a refused allocation, which fails the running queries (`doir.api.query.fail`).
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import ecrs.relation;
/// static import doir.api.query;
/// static import doir.api.positions;
/// static import doir.api.components;
/// struct Pure {
/// 	alias Key = ecrs.relation.Relation!1;
/// 	alias Value = bool;
/// 	static bool compute(ref doir.api.query.QueryEngine engine, Key key) @nogc nothrow {
/// 		return applyFlags(engine, key.related[0], doir.api.positions.between(engine, doir.api.positions.root, doir.api.positions.none, doir.api.positions.none), doir.api.components.Flags.Pure);
/// 	}
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.api.query.create(store);
/// scope(exit) doir.api.query.free(engine);
/// immutable e = ecrs.context.addEntity(store);
/// assert(*doir.api.query.query!Pure(engine, Pure.Key([e])));
/// uint seen;
/// assert(flagsAt(engine, e, doir.api.positions.none, seen) && seen == doir.api.components.Flags.Pure);
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
/// static import doir.api.query;
/// static import doir.api.positions;
/// struct Add {
/// 	alias Key = ecrs.relation.Relation!2;
/// 	alias Value = bool;
/// 	static bool compute(ref doir.api.query.QueryEngine engine, Key key) @nogc nothrow {
/// 		return addOverload(engine, key.related[0], doir.api.positions.between(engine, doir.api.positions.root, doir.api.positions.none, doir.api.positions.none), key.related[1]);
/// 	}
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.api.query.create(store);
/// scope(exit) doir.api.query.free(engine);
/// immutable set = ecrs.context.addEntity(store), f = ecrs.context.addEntity(store);
/// assert(*doir.api.query.query!Add(engine, Add.Key([set, f])));
/// EntityId* members = null;
/// scope(exit) fp.dynarray.free(members);
/// assert(overloadsAt(engine, set, doir.api.positions.none, members));
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
/// static import doir.api.query;
/// static import doir.api.positions;
/// struct Live {
/// 	alias Key = ecrs.relation.Relation!2;
/// 	alias Value = bool;
/// 	static bool compute(ref doir.api.query.QueryEngine engine, Key key) @nogc nothrow {
/// 		return liveOn(engine, key.related[0], doir.api.positions.between(engine, doir.api.positions.root, doir.api.positions.none, doir.api.positions.none), key.related[1]);
/// 	}
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.api.query.create(store);
/// scope(exit) doir.api.query.free(engine);
/// immutable e = ecrs.context.addEntity(store), gpu = ecrs.context.addEntity(store);
/// assert(*doir.api.query.query!Live(engine, Live.Key([e, gpu])));
/// EntityId* targets = null;
/// scope(exit) fp.dynarray.free(targets);
/// assert(targetsAt(engine, e, doir.api.positions.none, targets));
/// assert(fp.dynarray.slice(targets) == [gpu]);
/// ---
bool liveOn(ref doir.engine.query.QueryEngine engine, EntityId e, Position at, EntityId target) {
	assert(at != doir.engine.positions.none);
	return doir.engine.logs.append!(OnLog, ecrs.relation.Relation!1)(engine, e, at, ecrs.relation.Relation!1([target]));
}


// --- positioned reads --------------------------------------------------------

/// The flags of declaration `e` as a read at `at` sees them: the parser's `Flags` with every modifier strictly before `at` (`M-Lexical`, `L-Freeze`); `none` sees every modifier. Inside a query, records the reads it makes; a modifier owned by a query still running is a cycle (`Q-Cycle`), reported. Returns false if the answer may be incomplete: a refused allocation, which fails the running queries (`doir.api.query.fail`), or a modifier's query that could not be brought up to date, which is reported.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.query;
/// static import doir.api.positions;
/// static import doir.api.builders;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.api.query.create(store);
/// scope(exit) doir.api.query.free(engine);
/// immutable e = ecrs.context.addEntity(store);
/// assert(doir.api.builders.addFlags(store, e, doir.api.components.Flags.Export));
/// uint flags;
/// assert(flagsAt(engine, e, doir.api.positions.none, flags) && flags == doir.api.components.Flags.Export);
/// ---
bool flagsAt(ref doir.engine.query.QueryEngine engine, EntityId e, Position at, out uint out_) {
	auto own = ecrs.context.findComponent!(doir.api.components.Flags)(*engine.store, e);
	out_ = own is null ? 0 : own.flags;
	return doir.engine.logs.fold!(FlagsLog, uint)(engine, e, at, (ref const uint flags) { out_ |= flags; });
}

private bool collect(L)(ref doir.engine.query.QueryEngine engine, EntityId e, Position at, ref EntityId* out_) {
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

/// Appends to `out_` the members of overload set `set` as a read at `at` sees them, in position order, each once (`TF-Overload`, `C-Order`). Records reads and reports failure as `flagsAt` does, a refused append included.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import fp.dynarray;
/// static import doir.api.query;
/// static import doir.api.positions;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.api.query.create(store);
/// scope(exit) doir.api.query.free(engine);
/// EntityId* members = null;
/// scope(exit) fp.dynarray.free(members);
/// assert(overloadsAt(engine, ecrs.context.addEntity(store), doir.api.positions.none, members));
/// assert(fp.dynarray.length(members) == 0);
/// ---
bool overloadsAt(ref doir.engine.query.QueryEngine engine, EntityId set, Position at, ref EntityId* out_) {
	return collect!OverloadsLog(engine, set, at, out_);
}

/// Appends to `out_` the targets `live_on` gave declaration `e` as a read at `at` sees them, each once (`T-Live`). Records reads and reports failure as `flagsAt` does, a refused append included.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import fp.dynarray;
/// static import doir.api.query;
/// static import doir.api.positions;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.api.query.create(store);
/// scope(exit) doir.api.query.free(engine);
/// EntityId* targets = null;
/// scope(exit) fp.dynarray.free(targets);
/// assert(targetsAt(engine, ecrs.context.addEntity(store), doir.api.positions.none, targets));
/// assert(fp.dynarray.length(targets) == 0);
/// ---
bool targetsAt(ref doir.engine.query.QueryEngine engine, EntityId e, Position at, ref EntityId* out_) {
	return collect!OnLog(engine, e, at, out_);
}


// --- freezing ----------------------------------------------------------------

/// The flags of a frozen declaration, read by entity alone (`L-Freeze`): its `FrozenFlags`, or the parser's `Flags` if no freeze has folded a modifier into it. Records the read of `e`.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.query;
/// static import doir.api.builders;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.api.query.create(store);
/// scope(exit) doir.api.query.free(engine);
/// immutable e = ecrs.context.addEntity(store);
/// assert(doir.api.builders.addFlags(store, e, doir.api.components.Flags.Export));
/// assert(flags(engine, e) == doir.api.components.Flags.Export);
/// ---
uint flags(ref doir.engine.query.QueryEngine engine, EntityId e) {
	cast(void) doir.api.query.read(engine, e); // a refusal fails the running queries, discarding this answer
	if (auto frozen = ecrs.context.findComponent!FrozenFlags(*engine.store, e)) return frozen.flags;
	if (auto own = ecrs.context.findComponent!(doir.api.components.Flags)(*engine.store, e)) return own.flags;
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
	immutable inside = doir.api.query.currentQuery(engine) != invalidEntity;
	bool changed = true;
	auto slot = ecrs.context.findComponent!C(*engine.store, e);
	if (slot !is null) {
		changed = !same(*slot, value);
		release(*slot);
	} else slot = inside ? doir.api.query.produce!C(engine, e) : ecrs.context.addComponent!C(*engine.store, e);
	if (slot is null) {
		if (!inside) doir.engine.query.fail(engine);
		release(value);
		return false;
	}
	*slot = value;
	return !changed || inside || doir.api.query.markChanged(engine, e);
}

/// Folds every log on `e` into the plain component cross-level queries read: `FrozenFlags`, `Overloads` and `On` (`L-Freeze`). A log-less `e` gets none. Outside a query it is an input commit: call it after `beginRevision`, and it marks `e` changed when a folded value differs from the last freeze. Inside a query, such as an import (`I-Import`), the components it adds are that query's. Returns false if a fold was incomplete or an allocation was refused, which fails the running queries (see `flagsAt`); `e` may then hold some of its frozen components, from this freeze or the last.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.query;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.api.query.create(store);
/// scope(exit) doir.api.query.free(engine);
/// immutable e = ecrs.context.addEntity(store);
/// assert(freezeEntity(engine, e));
/// assert(!ecrs.context.hasComponent!FrozenFlags(store, e));
/// ---
bool freezeEntity(ref doir.engine.query.QueryEngine engine, EntityId e) {
	if (ecrs.context.hasComponent!FlagsLog(*engine.store, e)) {
		FrozenFlags frozen;
		if (!flagsAt(engine, e, doir.engine.positions.none, frozen.flags) || !writeFrozen(engine, e, frozen)) return false;
	}
	if (ecrs.context.hasComponent!OverloadsLog(*engine.store, e)) {
		doir.api.components.Overloads members;
		if (!overloadsAt(engine, e, doir.engine.positions.none, members.related)) {
			release(members);
			return false;
		}
		if (!writeFrozen(engine, e, members)) return false;
	}
	if (ecrs.context.hasComponent!OnLog(*engine.store, e)) {
		doir.api.components.On targets;
		if (!targetsAt(engine, e, doir.engine.positions.none, targets.related)) {
			release(targets);
			return false;
		}
		if (!writeFrozen(engine, e, targets)) return false;
	}
	return true;
}

/// Freezes `root` and every declaration below it, its blocks' contents and function types' parameters, as `freezeEntity` does (`L-Freeze`): once a level's comptime has terminated, every other reader sees one final answer. Returns false on the first entity `freezeEntity` fails on, or on a refused allocation of its own, which fails the running queries (`doir.api.query.fail`); the entities before it stay frozen.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.query;
/// static import doir.api.builders;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.api.query.create(store);
/// scope(exit) doir.api.query.free(engine);
/// auto root = doir.api.builders.createRoot(store);
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
		if (auto block = ecrs.context.findComponent!(doir.api.components.Block)(*engine.store, e))
			grew = fp.dynarray.concatenate(pending, fp.dynarray.slice(block.related));
		if (auto inputs = ecrs.context.findComponent!(doir.api.components.FunctionInputs)(*engine.store, e))
			grew = grew && fp.dynarray.concatenate(pending, fp.dynarray.slice(inputs.related));
	}
	if (!grew) doir.engine.query.fail(engine);
	return grew;
}


version(unittest) {
	static import fp.string;

	static import diagnose;

	static import doir.strings;
	static import doir.testing;
	static import doir.api.positions;

	private __gshared int modifierRuns, readRuns;
	private __gshared uint modifierFlags = doir.api.components.Flags.Immutable;

	// The modifier line `std.types.immutable(t)` at position `at`, a comptime evaluation keyed by ⟨entity, position⟩.
	private struct Modifier {
		struct Key {
			mixin ecrs.relation.Relates!"target";
			Position at;
		}
		alias Value = bool;
		static bool compute(ref doir.api.query.QueryEngine engine, Key key) @nogc nothrow {
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
		static uint compute(ref doir.api.query.QueryEngine engine, Key key) @nogc nothrow {
			++readRuns;
			uint seen;
			return flagsAt(engine, key.target, key.at, seen) ? seen : 0;
		}
	}

	// A modifier at `at` that first demands a read further down, which sees its effect: a cycle.
	private struct ModifyThenRead {
		struct Key {
			mixin ecrs.relation.Relates!"target";
			Position at, later;
		}
		alias Value = uint;
		static uint compute(ref doir.api.query.QueryEngine engine, Key key) @nogc nothrow {
			assert(applyFlags(engine, key.target, key.at, doir.api.components.Flags.Pure));
			return *doir.api.query.query!ReadFlags(engine, ReadFlags.Key([key.target], key.later));
		}
	}

	private struct Overload {
		struct Key {
			mixin ecrs.relation.Relates!("set", "member");
			Position at;
		}
		alias Value = bool;
		static bool compute(ref doir.api.query.QueryEngine engine, Key key) @nogc nothrow {
			assert(addOverload(engine, key.set, key.at, key.member));
			return true;
		}
	}

	// The line `std.targets.live_on(e, target)` at position `at`.
	private struct LiveOn {
		struct Key {
			mixin ecrs.relation.Relates!("declaration", "target");
			Position at;
		}
		alias Value = bool;
		static bool compute(ref doir.api.query.QueryEngine engine, Key key) @nogc nothrow {
			assert(liveOn(engine, key.declaration, key.at, key.target));
			return true;
		}
	}
}

unittest { // a read before a modifier's position sees the type unmodified, even when demand evaluated the modifier first
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	auto engine = doir.api.query.create(store);
	scope(exit) doir.api.query.free(engine);

	// t : type = {} ; x : _ = read(t) ; _ : _ = std.types.immutable(t) ; y : _ = read(t)
	auto root = doir.api.builders.createRoot(store);
	immutable t = doir.api.builders.pushAggregate(root, doir.strings.StringId(0), doir.strings.StringId(1)).block;
	assert(doir.api.builders.addFlags(store, t, doir.api.components.Flags.Export));
	assert(doir.api.query.markChanged(engine, t));
	immutable pt = doir.api.positions.between(engine, doir.api.positions.root, doir.api.positions.none, doir.api.positions.none);
	immutable px = doir.api.positions.between(engine, doir.api.positions.root, pt, doir.api.positions.none);
	immutable pm = doir.api.positions.between(engine, doir.api.positions.root, px, doir.api.positions.none);
	immutable py = doir.api.positions.between(engine, doir.api.positions.root, pm, doir.api.positions.none);

	// Demand runs the modifier on line 3 before the read on line 2.
	modifierRuns = readRuns = 0;
	assert(*doir.api.query.query!Modifier(engine, Modifier.Key([t], pm)));
	assert(*doir.api.query.query!ReadFlags(engine, ReadFlags.Key([t], px)) == doir.api.components.Flags.Export);
	assert(*doir.api.query.query!ReadFlags(engine, ReadFlags.Key([t], py)) == (doir.api.components.Flags.Export | doir.api.components.Flags.Immutable));
	assert(*doir.api.query.query!ReadFlags(engine, ReadFlags.Key([t], pm)) == doir.api.components.Flags.Export);

	// Freezing folds the log once; cross-level reads by entity alone see every modifier.
	doir.api.query.beginRevision(engine);
	assert(freezeLevel(engine, root.block));
	assert(ecrs.context.getComponent!FrozenFlags(store, t).flags == (doir.api.components.Flags.Export | doir.api.components.Flags.Immutable));
	assert(flags(engine, t) == (doir.api.components.Flags.Export | doir.api.components.Flags.Immutable));
	assert(ecrs.context.getComponent!(doir.api.components.Flags)(store, t).flags == doir.api.components.Flags.Export);

	// Freezing marked `t` changed, so its in-level reads re-validate here, cut off by their equal values.
	assert(*doir.api.query.query!ReadFlags(engine, ReadFlags.Key([t], py)) == (doir.api.components.Flags.Export | doir.api.components.Flags.Immutable));
	assert(*doir.api.query.query!ReadFlags(engine, ReadFlags.Key([t], px)) == doir.api.components.Flags.Export);

	// The modifier re-runs with a different effect: the read after it re-runs, the one before it does not, and a re-freeze drops the old bit.
	doir.api.query.beginRevision(engine);
	modifierFlags = doir.api.components.Flags.Packed;
	doir.api.query.evict!Modifier(engine, Modifier.Key([t], pm));
	readRuns = 0;
	assert(*doir.api.query.query!ReadFlags(engine, ReadFlags.Key([t], py)) == (doir.api.components.Flags.Export | doir.api.components.Flags.Packed));
	assert(*doir.api.query.query!ReadFlags(engine, ReadFlags.Key([t], px)) == doir.api.components.Flags.Export);
	assert(readRuns == 1);
	doir.api.query.beginRevision(engine);
	assert(freezeLevel(engine, root.block));
	assert(flags(engine, t) == (doir.api.components.Flags.Export | doir.api.components.Flags.Packed));
	modifierFlags = doir.api.components.Flags.Immutable;

	// A renumbering rewrites the logs and positioned keys with everything else (E-Remap).
	immutable spare = doir.testing.addEntity(store);
	assert(ecrs.context.swapEntities(store, t, spare));
	assert(doir.engine.query.find!ReadFlags(engine, ReadFlags.Key([spare], py)) != invalidEntity);
	assert(*doir.api.query.query!ReadFlags(engine, ReadFlags.Key([spare], py)) == (doir.api.components.Flags.Export | doir.api.components.Flags.Packed));
	uint seen;
	assert(flagsAt(engine, spare, px, seen) && seen == doir.api.components.Flags.Export);

	// A modifier whose allocation is refused fails, leaving no entry its re-run would not strip; the next demand applies it once.
	size_t n = 0;
	for (bool refused = true; refused;) {
		immutable fresh = doir.testing.addEntity(store);
		assert(doir.api.builders.addFlags(store, fresh, doir.api.components.Flags.Export));
		assert(doir.api.query.markChanged(engine, fresh));
		auto previous = doir.testing.beginRationedAllocator(n++);
		auto applied = doir.api.query.query!Modifier(engine, Modifier.Key([fresh], pm));
		doir.testing.endRationedAllocator(previous);
		assert(applied is null ? engine.refused : *applied);
		refused = engine.refused;
		engine.refused = false;
		assert(*doir.api.query.query!Modifier(engine, Modifier.Key([fresh], pm)));
		assert(fp.dynarray.length(ecrs.context.getComponent!FlagsLog(store, fresh).entries) == 1);
		assert(flagsAt(engine, fresh, py, seen) && seen == (doir.api.components.Flags.Export | doir.api.components.Flags.Immutable));
	}
}

unittest { // overload sets fold in position order; a read needing a running query's effect is a cycle
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	diagnose.Manager manager;
	scope(exit) diagnose.free(manager);
	auto engine = doir.api.query.create(store);
	scope(exit) doir.api.query.free(engine);
	engine.diagnostics = &manager;

	immutable set = doir.testing.addEntity(store), f = doir.testing.addEntity(store), g = doir.testing.addEntity(store);
	immutable p1 = doir.api.positions.between(engine, doir.api.positions.root, doir.api.positions.none, doir.api.positions.none);
	immutable p2 = doir.api.positions.between(engine, doir.api.positions.root, p1, doir.api.positions.none);
	immutable p3 = doir.api.positions.between(engine, doir.api.positions.root, p2, doir.api.positions.none);
	assert(*doir.api.query.query!Overload(engine, Overload.Key([set, g], p2)));
	assert(*doir.api.query.query!Overload(engine, Overload.Key([set, f], p1)));
	EntityId* members = null;
	scope(exit) fp.dynarray.free(members);
	assert(overloadsAt(engine, set, p3, members));
	assert(fp.dynarray.slice(members) == [f, g]);
	fp.dynarray.clear(members);
	assert(overloadsAt(engine, set, p2, members));
	assert(fp.dynarray.slice(members) == [f]);
	doir.api.query.beginRevision(engine);
	assert(freezeLevel(engine, set));
	assert(fp.dynarray.slice(ecrs.context.getComponent!(doir.api.components.Overloads)(store, set).related) == [f, g]);

	// Targets fold the same way, and freezing reaches a function type's parameters (T-Live, L-Freeze).
	auto root = doir.api.builders.createRoot(store);
	immutable ft = doir.api.builders.pushFunctionType(root, doir.strings.StringId(0), doir.strings.StringId(1));
	immutable param = doir.api.builders.pushParameter(store, ft, doir.strings.StringId(2), doir.strings.StringId(3));
	immutable cpu = doir.testing.addEntity(store), gpu = doir.testing.addEntity(store);
	assert(*doir.api.query.query!LiveOn(engine, LiveOn.Key([param, gpu], p2)));
	assert(*doir.api.query.query!LiveOn(engine, LiveOn.Key([param, cpu], p1)));
	EntityId* targets = null;
	scope(exit) fp.dynarray.free(targets);
	assert(targetsAt(engine, param, p2, targets));
	assert(fp.dynarray.slice(targets) == [cpu]);
	doir.api.query.beginRevision(engine);
	assert(freezeLevel(engine, root.block));
	assert(fp.dynarray.slice(ecrs.context.getComponent!(doir.api.components.On)(store, param).related) == [cpu, gpu]);

	// Without a frozen modifier, a cross-level read sees the parser's flags, or none.
	assert(flags(engine, param) == doir.api.components.Flags.Valueless);
	assert(flags(engine, cpu) == 0);

	// A re-freeze that folds the same members leaves the entity unchanged; one that drops a member replaces the last freeze.
	immutable frozenAt = doir.api.query.changedAt(engine, param);
	doir.api.query.beginRevision(engine);
	assert(freezeLevel(engine, root.block));
	assert(freezeLevel(engine, set));
	assert(doir.api.query.changedAt(engine, param) == frozenAt);
	doir.api.query.beginRevision(engine);
	doir.api.query.evict!LiveOn(engine, LiveOn.Key([param, gpu], p2));
	assert(freezeLevel(engine, root.block));
	assert(fp.dynarray.slice(ecrs.context.getComponent!(doir.api.components.On)(store, param).related) == [cpu]);
	assert(doir.api.query.changedAt(engine, param) == engine.revision);

	immutable t = doir.testing.addEntity(store);
	cast(void) doir.api.query.query!ModifyThenRead(engine, ModifyThenRead.Key([t], p1, p3));
	assert(diagnose.count(manager) == 1);
	enum prefix = "Q-Cycle: a read needs an effect of a query that is still running: ModifyThenRead";
	assert(fp.string.slice(manager.diagnostics[0].message)[0 .. prefix.length] == prefix);

	// A freeze refused at any allocation fails, and the next one folds every log.
	bool refused = true;
	for (size_t n = 0; refused; ++n) {
		assert(n < 100);
		immutable x = doir.testing.addEntity(store);
		assert(*doir.api.query.query!Modifier(engine, Modifier.Key([x], p1)));
		assert(*doir.api.query.query!Overload(engine, Overload.Key([x, f], p1)));
		assert(*doir.api.query.query!LiveOn(engine, LiveOn.Key([x, cpu], p1)));
		doir.api.query.beginRevision(engine);
		auto previous = doir.testing.beginRationedAllocator(n);
		immutable frozen = freezeEntity(engine, x);
		doir.testing.endRationedAllocator(previous);
		assert(frozen || engine.refused);
		refused = engine.refused;
		engine.refused = false;
		assert(freezeEntity(engine, x));
		assert(flags(engine, x) == modifierFlags);
		assert(fp.dynarray.slice(ecrs.context.getComponent!(doir.api.components.Overloads)(store, x).related) == [f]);
		assert(fp.dynarray.slice(ecrs.context.getComponent!(doir.api.components.On)(store, x).related) == [cpu]);
	}
}
