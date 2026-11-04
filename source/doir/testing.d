/// Test-only helpers shared by this repository's unittests. Compiled only under `-unittest`.
module doir.testing;

version(unittest):

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
