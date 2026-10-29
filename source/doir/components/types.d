/// The components that describe a type or a symbol beyond its layout: a function's or static's ABI symbol and the pointer or array a type is (`doir.spec.md` Part II §1). Every one holding an entity id mixes in `ecrs.relation.Relates` (`E-Remap`).
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// immutable u8 = ecrs.context.addEntity(store), p = ecrs.context.addEntity(store);
/// *ecrs.context.addComponent!Pointer(store, p) = Pointer([u8], 4);
/// assert(ecrs.context.getComponent!Pointer(store, p).pointee == u8);
/// ---
module doir.components.types;

static import ecrs.context;
static import ecrs.relation;
static import ecrs.registry;

public import ecrs.registry : EntityId, invalidEntity;
public import doir.strings : StringId;

@nogc nothrow:


// --- types and layout --------------------------------------------------------

/// The ABI symbol of a function or static: the `R-Mangle` name unless `M-SymbolName` set one.
struct SymbolName {
	StringId value; /// The interned symbol.
}

/// A pointer or array type: ⟨pointee, length⟩, a length of 0 being a pointer and any other an array of that many elements.
struct Pointer {
	mixin ecrs.relation.Relates!"pointee";
	ulong length = 0; /// 0 for a pointer, the element count for an array.
}

unittest { // libECRS silently skips a holder whose hook is not `@nogc nothrow`; every holder of an entity id must pass (E-Remap)
	static assert(ecrs.registry.hasRemapEntities!Pointer);
}

version(unittest) {
	static import doir.testing;
	static import doir.query;
}

unittest { // Pointer holds an entity id, which a compaction rewrites (E-Remap)
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	auto engine = doir.query.create(store);
	scope(exit) doir.query.free(engine);

	immutable spare = doir.testing.addEntity(store);
	immutable pointee = doir.testing.addEntity(store);
	immutable ptr = doir.testing.addEntity(store);
	doir.testing.addComponent!Pointer(store, ptr) = Pointer([pointee], 0);
	assert(ecrs.context.removeEntity(store, spare));
	assert(doir.query.compact(engine));
	immutable moved = cast(EntityId) (ptr - 1);
	assert(ecrs.context.getComponent!Pointer(store, moved).pointee == pointee - 1);
	assert(ecrs.context.getComponent!Pointer(store, moved).length == 0);
}
