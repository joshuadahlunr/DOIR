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
/// 		applyFlags(engine, t, doir.api.positions.between(engine, doir.api.positions.root, doir.api.positions.none, doir.api.positions.none), doir.api.components.Flags.Immutable);
/// 		return true;
/// 	}
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.api.query.create(store);
/// scope(exit) doir.api.query.free(engine);
/// immutable t = ecrs.context.addEntity(store);
/// assert(*doir.api.query.query!Modify(engine, Modify.Key([t])));
/// assert(flagsAt(engine, t, doir.api.positions.root) == 0);
/// assert(flagsAt(engine, t, doir.api.positions.none) == doir.api.components.Flags.Immutable);
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

/// Adds `flags` to declaration `e` at position `at` on behalf of the running query, a comptime evaluation, which owns the effect (`M-Lexical`, `C-Order`). Reads at or before `at` do not see it.
///
/// Examples:
/// ---
/// static import doir.api.query;
/// doir.api.query.QueryEngine engine;
/// assert(doir.api.query.currentQuery(engine) == invalidEntity); // applyFlags is only valid inside a query
/// ---
void applyFlags(ref doir.engine.query.QueryEngine engine, EntityId e, Position at, uint flags) {
	assert(at != doir.engine.positions.none);
	doir.engine.logs.append!(FlagsLog, uint)(engine, e, at, flags);
}

/// Adds `member` to overload set `set` at position `at` on behalf of the running query (`TF-Overload`, `C-Order`).
///
/// Examples:
/// ---
/// static import doir.api.query;
/// doir.api.query.QueryEngine engine;
/// assert(doir.api.query.currentQuery(engine) == invalidEntity); // addOverload is only valid inside a query
/// ---
void addOverload(ref doir.engine.query.QueryEngine engine, EntityId set, Position at, EntityId member) {
	assert(at != doir.engine.positions.none);
	doir.engine.logs.append!(OverloadsLog, ecrs.relation.Relation!1)(engine, set, at, ecrs.relation.Relation!1([member]));
}

/// Makes declaration `e` live on `target` from position `at` on behalf of the running query (`T-Live`, `C-Order`).
///
/// Examples:
/// ---
/// static import doir.api.query;
/// doir.api.query.QueryEngine engine;
/// assert(doir.api.query.currentQuery(engine) == invalidEntity); // liveOn is only valid inside a query
/// ---
void liveOn(ref doir.engine.query.QueryEngine engine, EntityId e, Position at, EntityId target) {
	assert(at != doir.engine.positions.none);
	doir.engine.logs.append!(OnLog, ecrs.relation.Relation!1)(engine, e, at, ecrs.relation.Relation!1([target]));
}


// --- positioned reads --------------------------------------------------------

/// The flags of declaration `e` as a read at `at` sees them: the parser's `Flags` with every modifier strictly before `at` (`M-Lexical`, `L-Freeze`); `none` sees every modifier. Inside a query, records the reads it makes; a modifier owned by a query still running is a cycle (`Q-Cycle`), reported.
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
/// doir.api.builders.addFlags(store, e, doir.api.components.Flags.Export);
/// assert(flagsAt(engine, e, doir.api.positions.none) == doir.api.components.Flags.Export);
/// ---
uint flagsAt(ref doir.engine.query.QueryEngine engine, EntityId e, Position at) {
	auto own = ecrs.context.findComponent!(doir.api.components.Flags)(*engine.store, e);
	uint out_ = own is null ? 0 : own.flags;
	doir.engine.logs.fold!(FlagsLog, uint)(engine, e, at, (ref const uint flags) { out_ |= flags; });
	return out_;
}

private void collect(L)(ref doir.engine.query.QueryEngine engine, EntityId e, Position at, ref EntityId* out_) {
	doir.engine.logs.fold!(L, ecrs.relation.Relation!1)(engine, e, at, (ref const ecrs.relation.Relation!1 effect) {
		immutable member = effect.related[0];
		foreach (existing; fp.dynarray.slice(out_))
			if (existing == member) return;
		immutable pushed = fp.dynarray.pushBack(out_, member);
		assert(pushed, "doir.effects: allocation refused");
	});
}

/// Appends to `out_` the members of overload set `set` as a read at `at` sees them, in position order, each once (`TF-Overload`, `C-Order`). Records reads as `flagsAt` does.
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
/// overloadsAt(engine, ecrs.context.addEntity(store), doir.api.positions.none, members);
/// assert(fp.dynarray.length(members) == 0);
/// ---
void overloadsAt(ref doir.engine.query.QueryEngine engine, EntityId set, Position at, ref EntityId* out_) {
	collect!OverloadsLog(engine, set, at, out_);
}

/// Appends to `out_` the targets `live_on` gave declaration `e` as a read at `at` sees them, each once (`T-Live`). Records reads as `flagsAt` does.
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
/// targetsAt(engine, ecrs.context.addEntity(store), doir.api.positions.none, targets);
/// assert(fp.dynarray.length(targets) == 0);
/// ---
void targetsAt(ref doir.engine.query.QueryEngine engine, EntityId e, Position at, ref EntityId* out_) {
	collect!OnLog(engine, e, at, out_);
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
/// doir.api.builders.addFlags(store, e, doir.api.components.Flags.Export);
/// assert(flags(engine, e) == doir.api.components.Flags.Export);
/// ---
uint flags(ref doir.engine.query.QueryEngine engine, EntityId e) {
	doir.api.query.read(engine, e);
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

// Writes folded `value`, taken over, as `e`'s frozen `C`. Outside a query it is an input commit, marking `e` changed if the value differs.
private void writeFrozen(C)(ref doir.engine.query.QueryEngine engine, EntityId e, ref C value) {
	immutable inside = doir.api.query.currentQuery(engine) != invalidEntity;
	bool changed = true;
	if (auto old = ecrs.context.findComponent!C(*engine.store, e)) {
		changed = !same(*old, value);
		release(*old);
		*old = value;
	} else if (inside) {
		doir.api.query.produce!C(engine, e) = value;
	} else {
		auto c = ecrs.context.addComponent!C(*engine.store, e);
		assert(c !is null, "doir.effects: allocation refused");
		*c = value;
	}
	if (changed && !inside) doir.api.query.markChanged(engine, e);
}

/// Folds every log on `e` into the plain component cross-level queries read: `FrozenFlags`, `Overloads` and `On` (`L-Freeze`). A log-less `e` gets none. Outside a query it is an input commit: call it after `beginRevision`, and it marks `e` changed when a folded value differs from the last freeze. Inside a query, such as an import (`I-Import`), the components it adds are that query's.
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
/// freezeEntity(engine, e);
/// assert(!ecrs.context.hasComponent!FrozenFlags(store, e));
/// ---
void freezeEntity(ref doir.engine.query.QueryEngine engine, EntityId e) {
	if (ecrs.context.hasComponent!FlagsLog(*engine.store, e)) {
		auto frozen = FrozenFlags(flagsAt(engine, e, doir.engine.positions.none));
		writeFrozen(engine, e, frozen);
	}
	if (ecrs.context.hasComponent!OverloadsLog(*engine.store, e)) {
		doir.api.components.Overloads members;
		overloadsAt(engine, e, doir.engine.positions.none, members.related);
		writeFrozen(engine, e, members);
	}
	if (ecrs.context.hasComponent!OnLog(*engine.store, e)) {
		doir.api.components.On targets;
		targetsAt(engine, e, doir.engine.positions.none, targets.related);
		writeFrozen(engine, e, targets);
	}
}

/// Freezes `root` and every declaration below it, its blocks' contents and function types' parameters, as `freezeEntity` does (`L-Freeze`): once a level's comptime has terminated, every other reader sees one final answer.
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
/// freezeLevel(engine, root.block);
/// ---
void freezeLevel(ref doir.engine.query.QueryEngine engine, EntityId root) {
	EntityId* pending = null;
	scope(exit) fp.dynarray.free(pending);
	immutable pushed = fp.dynarray.pushBack(pending, root);
	assert(pushed, "doir.effects: allocation refused");
	while (fp.dynarray.length(pending) > 0) {
		immutable e = *fp.dynarray.back(pending);
		cast(void) fp.dynarray.popBack(pending);
		freezeEntity(engine, e);
		if (auto block = ecrs.context.findComponent!(doir.api.components.Block)(*engine.store, e))
			foreach (child; fp.dynarray.slice(block.related)) {
				immutable ok = fp.dynarray.pushBack(pending, child);
				assert(ok, "doir.effects: allocation refused");
			}
		if (auto inputs = ecrs.context.findComponent!(doir.api.components.FunctionInputs)(*engine.store, e))
			foreach (p; fp.dynarray.slice(inputs.related)) {
				immutable ok = fp.dynarray.pushBack(pending, p);
				assert(ok, "doir.effects: allocation refused");
			}
	}
}


version(unittest) {
	static import diagnose;
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
			applyFlags(engine, key.target, key.at, modifierFlags);
			return true;
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
			return flagsAt(engine, key.target, key.at);
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
			applyFlags(engine, key.target, key.at, doir.api.components.Flags.Pure);
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
			addOverload(engine, key.set, key.at, key.member);
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
			liveOn(engine, key.declaration, key.at, key.target);
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
	doir.api.builders.addFlags(store, t, doir.api.components.Flags.Export);
	doir.api.query.markChanged(engine, t);
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
	freezeLevel(engine, root.block);
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
	freezeLevel(engine, root.block);
	assert(flags(engine, t) == (doir.api.components.Flags.Export | doir.api.components.Flags.Packed));
	modifierFlags = doir.api.components.Flags.Immutable;

	// A renumbering rewrites the logs and positioned keys with everything else (E-Remap).
	immutable spare = ecrs.context.addEntity(store);
	assert(ecrs.context.swapEntities(store, t, spare));
	assert(doir.engine.query.find!ReadFlags(engine, ReadFlags.Key([spare], py)) != invalidEntity);
	assert(*doir.api.query.query!ReadFlags(engine, ReadFlags.Key([spare], py)) == (doir.api.components.Flags.Export | doir.api.components.Flags.Packed));
	assert(flagsAt(engine, spare, px) == doir.api.components.Flags.Export);
}

unittest { // overload sets fold in position order; a read needing a running query's effect is a cycle
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	diagnose.Manager manager;
	scope(exit) diagnose.free(manager);
	auto engine = doir.api.query.create(store);
	scope(exit) doir.api.query.free(engine);
	engine.diagnostics = &manager;

	immutable set = ecrs.context.addEntity(store), f = ecrs.context.addEntity(store), g = ecrs.context.addEntity(store);
	immutable p1 = doir.api.positions.between(engine, doir.api.positions.root, doir.api.positions.none, doir.api.positions.none);
	immutable p2 = doir.api.positions.between(engine, doir.api.positions.root, p1, doir.api.positions.none);
	immutable p3 = doir.api.positions.between(engine, doir.api.positions.root, p2, doir.api.positions.none);
	assert(*doir.api.query.query!Overload(engine, Overload.Key([set, g], p2)));
	assert(*doir.api.query.query!Overload(engine, Overload.Key([set, f], p1)));
	EntityId* members = null;
	scope(exit) fp.dynarray.free(members);
	overloadsAt(engine, set, p3, members);
	assert(fp.dynarray.slice(members) == [f, g]);
	fp.dynarray.clear(members);
	overloadsAt(engine, set, p2, members);
	assert(fp.dynarray.slice(members) == [f]);
	doir.api.query.beginRevision(engine);
	freezeLevel(engine, set);
	assert(fp.dynarray.slice(ecrs.context.getComponent!(doir.api.components.Overloads)(store, set).related) == [f, g]);

	// Targets fold the same way, and freezing reaches a function type's parameters (T-Live, L-Freeze).
	auto root = doir.api.builders.createRoot(store);
	immutable ft = doir.api.builders.pushFunctionType(root, doir.strings.StringId(0), doir.strings.StringId(1));
	immutable param = doir.api.builders.pushParameter(store, ft, doir.strings.StringId(2), doir.strings.StringId(3));
	immutable cpu = ecrs.context.addEntity(store), gpu = ecrs.context.addEntity(store);
	assert(*doir.api.query.query!LiveOn(engine, LiveOn.Key([param, gpu], p2)));
	assert(*doir.api.query.query!LiveOn(engine, LiveOn.Key([param, cpu], p1)));
	EntityId* targets = null;
	scope(exit) fp.dynarray.free(targets);
	targetsAt(engine, param, p2, targets);
	assert(fp.dynarray.slice(targets) == [cpu]);
	doir.api.query.beginRevision(engine);
	freezeLevel(engine, root.block);
	assert(fp.dynarray.slice(ecrs.context.getComponent!(doir.api.components.On)(store, param).related) == [cpu, gpu]);

	// Without a frozen modifier, a cross-level read sees the parser's flags, or none.
	assert(flags(engine, param) == doir.api.components.Flags.Valueless);
	assert(flags(engine, cpu) == 0);

	// A re-freeze that folds the same members leaves the entity unchanged; one that drops a member replaces the last freeze.
	immutable frozenAt = doir.api.query.changedAt(engine, param);
	doir.api.query.beginRevision(engine);
	freezeLevel(engine, root.block);
	freezeLevel(engine, set);
	assert(doir.api.query.changedAt(engine, param) == frozenAt);
	doir.api.query.beginRevision(engine);
	doir.api.query.evict!LiveOn(engine, LiveOn.Key([param, gpu], p2));
	freezeLevel(engine, root.block);
	assert(fp.dynarray.slice(ecrs.context.getComponent!(doir.api.components.On)(store, param).related) == [cpu]);
	assert(doir.api.query.changedAt(engine, param) == engine.revision);

	immutable t = ecrs.context.addEntity(store);
	cast(void) doir.api.query.query!ModifyThenRead(engine, ModifyThenRead.Key([t], p1, p3));
	assert(diagnose.count(manager) == 1);
	enum prefix = "Q-Cycle: a read needs an effect of a query that is still running: ModifyThenRead";
	assert(fp.string.slice(manager.diagnostics[0].message)[0 .. prefix.length] == prefix);
}

version(unittest) {
	static import fp.string;
	static import doir.strings;
}
