/// The positioned effect logs of comptime-mutable state (`C-Order`, `M-Lexical`), and the plain components `doir.effects.freezeLevel` folds each into (`L-Freeze`).
/// Logs hold entity ids only through `E-Remap` hooks, so renumbering covers them.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// immutable e = ecrs.context.addEntity(store);
/// ecrs.context.addComponent!FrozenFlags(store, e).flags = 1;
/// assert(ecrs.context.getComponent!FrozenFlags(store, e).flags == 1);
/// ---
module doir.components.effects;

static import ecrs.relation;
static import ecrs.registry;

static import doir.engine.logs;

public import ecrs.registry : EntityId, invalidEntity;

@nogc nothrow:


// --- logs --------------------------------------------------------------------

/// The flag modifiers applied to a declaration, each a set of flags added at a position (`M-Lexical`, `M-Idempotent`).
struct FlagsLog {
	mixin doir.engine.logs.Log!uint;
}

/// The flags of a frozen declaration: the parser's `Flags` with every modifier of its log (`L-Freeze`).
/// Cross-level queries read it by entity alone, through `flags`.
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


// --- frozen ------------------------------------------------------------------

/// The targets `std.targets.compile_for` gave a declaration, folded from its positioned log at freeze (`T-Live`); absent means live wherever its parent is.
struct On {
	mixin ecrs.relation.Relates;
}

/// The member functions of an overload set, folded from its positioned log at freeze (`TF-Overload`).
struct Overloads {
	mixin ecrs.relation.Relates;
}

unittest { // libECRS silently skips a holder whose hook is not `@nogc nothrow`; every holder of an entity id must pass (E-Remap)
	static assert(ecrs.registry.hasRemapEntities!FlagsLog && ecrs.registry.hasRemapEntities!OverloadsLog && ecrs.registry.hasRemapEntities!OnLog && ecrs.registry.hasRemapEntities!On && ecrs.registry.hasRemapEntities!Overloads);
}
