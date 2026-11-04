/// The components a target's lowering owns (`L-Erase`, `REG-Virt`, `REG-Phys`), and the functions that write and read them.
///
/// The internal register components are indexed by target (`VirtualReg_τ`, `PhysicalReg_τ`): one libECRS component per target index, so each target's lowering owns its own and independent targets never clobber each other. A single-target build uses index 0.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// assert(findPerTarget!PhysicalReg(store, ecrs.context.addEntity(store), 0) is null);
/// ---
module doir.components.lowering;

static import std.typecons;

static import fp.pointer;
version(unittest) static import fp.testing;

static import ecrs.context;
static import ecrs.relation;
static import ecrs.registry;

static import doir.engine.logs;
static import doir.engine.positions;
static import doir.query;
static import doir.components.query;

public import ecrs.registry : EntityId, invalidEntity;

@nogc nothrow:


// --- types and layout --------------------------------------------------------

/// The targets whose lowering has retired the entity (`L-Erase`); absent means retired under none. Each target's entry is owned by that target's lowering query.
struct Lowered {
	mixin doir.engine.logs.Log!(ecrs.relation.Relation!1);
}

/// A binding's internal virtual register for one target (`REG-Virt`).
struct VirtualReg {
	uint id; /// The `VRegId`.
}

/// A binding's assigned hardware register or spill slot for one target (`REG-Phys`).
struct PhysicalReg {
	/// Which of the two the binding was given.
	enum Kind : ubyte { register, spill }

	Kind kind = Kind.register; /// A register or a spill slot.
	uint value; /// The `PRegId`, or the spill slot's offset.
}

unittest { // libECRS silently skips a holder whose hook is not `@nogc nothrow`; every holder of an entity id must pass (E-Remap)
	static assert(ecrs.registry.hasRemapEntities!Lowered);
}


// --- per-target components ---------------------------------------------------

private enum isPerTarget(C) = is(C == VirtualReg) || is(C == PhysicalReg);

/// The libECRS component id of per-target component `C` (`VirtualReg_τ` or `PhysicalReg_τ`) for target index `target`, registered on first use. Returns `fp.pointer.notFound` if the registration was refused; no entity can then have the component.
///
/// Examples:
/// ---
/// assert(perTargetComponent!VirtualReg(0) == perTargetComponent!VirtualReg(0));
/// assert(perTargetComponent!VirtualReg(0) != perTargetComponent!VirtualReg(1));
/// assert(perTargetComponent!PhysicalReg(0) != perTargetComponent!VirtualReg(0));
/// ---
size_t perTargetComponent(C)(size_t target) @trusted if (isPerTarget!C) {
	// The name is built on the stack, so a lookup of a registered id never allocates and cannot fail.
	enum prefix = ecrs.registry.componentName!C ~ "@target";
	char[20] digits = void; // a 64-bit target has at most 20
	size_t first = digits.length;
	do digits[--first] = cast(char)('0' + target % 10);
	while ((target /= 10) != 0);
	char[prefix.length + digits.length + 1] name = void;
	immutable length = prefix.length + digits.length - first;
	foreach (i, c; prefix) name[i] = c; // slice copies need druntime under -betterC
	foreach (i, c; digits[first .. $]) name[prefix.length + i] = c;
	name[length] = '\0';
	immutable existing = ecrs.registry.lookupId(name.ptr);
	if (existing != fp.pointer.notFound) return existing;
	return ecrs.registry.registerType(name[0 .. length], ecrs.registry.nextId(), C.sizeof, ecrs.registry.hooksFor!C());
}

/// `e`'s per-target component `C` (a `VirtualReg` or `PhysicalReg`) for target index `target`, or null if it has none.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// assert(findPerTarget!VirtualReg(store, ecrs.context.addEntity(store), 0) is null);
/// ---
const(C)* findPerTarget(C)(ref const ecrs.context.Context store, EntityId e, size_t target) @trusted if (isPerTarget!C) {
	immutable id = perTargetComponent!C(target);
	return id == fp.pointer.notFound ? null : cast(const(C)*) ecrs.context.findComponent(store, e, id, C.sizeof);
}

/// Gives `e` per-target component `C` for target index `target` on behalf of the running query, the target's lowering, which owns it: a virtual register, or a physical register or spill slot. `e` must not already have one for that target. Returns null on a refused allocation, which fails the running queries (`doir.query.fail`).
///
/// Examples:
/// ---
/// static import ecrs.relation;
/// static import ecrs.context;
/// static import doir.query;
/// struct Assign {
/// 	alias Key = ecrs.relation.Relation!1;
/// 	alias Value = bool;
/// 	static bool compute(ref doir.query.QueryEngine engine, Key key) @nogc nothrow {
/// 		immutable e = key.related[0];
/// 		auto reg = producePerTarget!VirtualReg(engine, e, 1);
/// 		auto slot = producePerTarget!PhysicalReg(engine, e, 0);
/// 		if (reg is null || slot is null) return false;
/// 		reg.id = 9;
/// 		*slot = PhysicalReg(PhysicalReg.Kind.spill, 16);
/// 		return true;
/// 	}
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.query.create(store);
/// scope(exit) doir.query.free(engine);
/// immutable e = ecrs.context.addEntity(store);
/// assert(*doir.query.query!Assign(engine, Assign.Key([e])));
/// assert(findPerTarget!VirtualReg(store, e, 1).id == 9 && findPerTarget!VirtualReg(store, e, 0) is null);
/// assert(findPerTarget!PhysicalReg(store, e, 0).kind == PhysicalReg.Kind.spill);
/// ---
C* producePerTarget(C)(ref doir.query.QueryEngine engine, EntityId e, size_t target) @trusted if (isPerTarget!C) {
	immutable id = perTargetComponent!C(target);
	if (id == fp.pointer.notFound) {
		doir.query.fail(engine);
		return null;
	}
	if (!doir.query.recordProduced(engine, doir.components.query.Produced([e], id, &doir.query.stripComponent, &doir.query.hashComponent!C), true)) return null;
	auto c = cast(C*) ecrs.context.addComponent(*engine.store, e, id, C.sizeof);
	if (c is null) doir.query.fail(engine);
	return c;
}

// --- retirement --------------------------------------------------------------

/// Records that the running query, `target`'s lowering, retired `e` for `target` (`L-Erase`). The entry is its own, removed when it runs again or is evicted, so the targets of a build retire entities independently. Returns false on a refused allocation, which fails the running queries (`doir.query.fail`).
///
/// Examples:
/// ---
/// static import ecrs.relation;
/// static import ecrs.context;
/// static import doir.query;
/// struct Lower {
/// 	alias Key = ecrs.relation.Relation!1;
/// 	alias Value = bool;
/// 	static bool compute(ref doir.query.QueryEngine engine, Key key) @nogc nothrow {
/// 		immutable e = key.related[0];
/// 		return retire(engine, e, e);
/// 	}
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.query.create(store);
/// scope(exit) doir.query.free(engine);
/// immutable e = ecrs.context.addEntity(store);
/// assert(*doir.query.query!Lower(engine, Lower.Key([e])));
/// assert(retiredFor(engine, e, e).get);
/// ---
bool retire(ref doir.query.QueryEngine engine, EntityId e, EntityId target) {
	return doir.engine.logs.append!(Lowered, ecrs.relation.Relation!1)(engine, e, doir.engine.positions.none, ecrs.relation.Relation!1([target]));
}

/// Whether some lowering retired `e` for `target` (`L-Erase`). Inside a query, records the read of `e` and of the lowering that retired it. Returns null if the answer may be incomplete, where `doir.engine.logs.fold` returns false.
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
/// assert(!retiredFor(engine, e, e).get);
/// ---
std.typecons.Nullable!bool retiredFor(ref doir.query.QueryEngine engine, EntityId e, EntityId target) {
	bool retired = false;
	immutable folded = doir.engine.logs.fold!(Lowered, ecrs.relation.Relation!1)(engine, e, doir.engine.positions.none, (ref const ecrs.relation.Relation!1 t) {
		if (t.related[0] == target) retired = true;
	});
	if (!folded) return typeof(return).init;
	return typeof(return)(retired);
}


version(unittest) {
	static import doir.testing;
	static import doir.query;

	private __gshared uint registerBase;

	// Target `key.target`'s lowering of `key.entity`: its registers and its retirement entry.
	private struct LowerFor {
		struct Key {
			mixin ecrs.relation.Relates!"entity";
			size_t target;
		}
		alias Value = bool;
		static bool compute(ref doir.query.QueryEngine engine, Key key) @nogc nothrow {
			auto virtual = producePerTarget!VirtualReg(engine, key.entity, key.target);
			auto physical = producePerTarget!PhysicalReg(engine, key.entity, key.target);
			if (virtual is null || physical is null) return false;
			virtual.id = registerBase + cast(uint) key.target;
			*physical = PhysicalReg(PhysicalReg.Kind.register, cast(uint) key.target);
			return retire(engine, key.entity, cast(EntityId) (key.target + 100));
		}
	}
}

unittest { // targets own their registers and retirement independently
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	auto engine = doir.query.create(store);
	scope(exit) doir.query.free(engine);

	immutable e = doir.testing.addEntity(store);
	registerBase = 10;
	assert(*doir.query.query!LowerFor(engine, LowerFor.Key([e], 0)));
	assert(*doir.query.query!LowerFor(engine, LowerFor.Key([e], 1)));
	assert(findPerTarget!VirtualReg(store, e, 0).id == 10 && findPerTarget!VirtualReg(store, e, 1).id == 11);
	assert(findPerTarget!PhysicalReg(store, e, 1).value == 1);
	assert(retiredFor(engine, e, 100).get && retiredFor(engine, e, 101).get && !retiredFor(engine, e, 102).get);

	// Evicting one target's lowering removes only that target's parts.
	doir.query.evict!LowerFor(engine, LowerFor.Key([e], 0));
	assert(findPerTarget!VirtualReg(store, e, 0) is null && findPerTarget!PhysicalReg(store, e, 0) is null);
	assert(findPerTarget!VirtualReg(store, e, 1).id == 11);
	assert(!retiredFor(engine, e, 100).get && retiredFor(engine, e, 101).get);
	registerBase = 20;
	assert(*doir.query.query!LowerFor(engine, LowerFor.Key([e], 0)));
	assert(findPerTarget!VirtualReg(store, e, 0).id == 20 && retiredFor(engine, e, 100).get);

	// A target whose component ids cannot be registered fails its lowering; each attempt names a fresh target.
	bool refused = true;
	for (size_t n = 0; refused; ++n) {
		assert(n < 100);
		auto previous = fp.testing.beginRationedAllocator(n);
		auto lowered = doir.query.query!LowerFor(engine, LowerFor.Key([e], 1000 + n));
		fp.testing.endRationedAllocator(previous);
		assert(lowered is null ? engine.refused : *lowered);
		refused = engine.refused;
		engine.refused = false;
	}
}
