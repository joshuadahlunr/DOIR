/// Test-only helpers shared by this repository's unittests. Compiled only under `-unittest`.
module doir.testing;

version(unittest):

static import fp.pointer;

static import ecrs.context;

public import ecrs.registry : EntityId, invalidEntity;

@nogc nothrow:


// --- store setup -------------------------------------------------------------

/// Adds an entity to `store`, as `ecrs.context.addEntity` does, for tests: a refused allocation fails the test with an assert instead of returning `invalidEntity`.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// assert(addEntity(store) != addEntity(store));
/// ---
package(doir) EntityId addEntity(ref ecrs.context.Context store) {
	immutable e = ecrs.context.addEntity(store);
	assert(e != invalidEntity, "doir.testing: allocation refused");
	return e;
}

/// Adds component `C` to `e`, as `ecrs.context.addComponent` does, for tests: a refused allocation fails the test with an assert instead of returning null.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// immutable e = addEntity(store);
/// addComponent!int(store, e) = 4;
/// assert(ecrs.context.getComponent!int(store, e) == 4);
/// ---
package(doir) ref C addComponent(C)(ref ecrs.context.Context store, EntityId e) {
	auto component = ecrs.context.addComponent!C(store, e);
	assert(component !is null, "doir.testing: allocation refused");
	return *component;
}


// --- refused allocations -----------------------------------------------------

private __gshared fp.pointer.AllocFunction rationedUnderlying;
private __gshared size_t rationedRemaining;

private void* rationedAlloc(void* p, size_t size) {
	// Frees are always forwarded, or a test could not clean up after itself.
	if (size == 0) return rationedUnderlying(p, 0);
	if (rationedRemaining == 0) return null;
	--rationedRemaining;
	return rationedUnderlying(p, size);
}

/// For tests of refused allocations, as libfp's own: `beginRationedAllocator` makes `fp.pointer.allocFunction` grant only the next `n` allocations and refuse the rest, while still freeing; `endRationedAllocator` restores the allocator it returned.
///
/// Examples:
/// ---
/// static import fp.dynarray;
/// int* list = null;
/// auto previous = beginRationedAllocator(0);
/// assert(!fp.dynarray.pushBack(list, 1));
/// endRationedAllocator(previous);
/// assert(fp.dynarray.pushBack(list, 1));
/// fp.dynarray.free(list);
/// ---
package(doir) fp.pointer.AllocFunction beginRationedAllocator(size_t n) {
	fp.pointer.AllocFunction previous = fp.pointer.allocFunction;
	rationedUnderlying = previous;
	rationedRemaining = n;
	fp.pointer.allocFunction = &rationedAlloc;
	return previous;
}

/// Ditto
package(doir) void endRationedAllocator(fp.pointer.AllocFunction previous) {
	fp.pointer.allocFunction = previous;
}
