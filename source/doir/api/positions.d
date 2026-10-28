/// Lexical positions (`C-Order`, `M-Lexical`, `L-Freeze`): order keys that totally order a file's declarations in preorder, a block's contents after the block and before its next sibling. A key can always be made between two neighbours, so an inserted declaration gets one without renumbering any other, and a declaration kept across a reparse keeps its own.
///
/// Positions are interned by the engine, so equal keys are equal `Position`s and a position compares and hashes as a number inside a query key (⟨entity, position⟩).
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.query;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.api.query.create(store);
/// scope(exit) doir.api.query.free(engine);
/// immutable a = between(engine, root, none, none);
/// immutable b = between(engine, root, a, none);
/// immutable inA = between(engine, a, none, none);
/// assert(precedes(engine, a, inA) && precedes(engine, inA, b));
/// ---
module doir.api.positions;

static import doir.engine.positions;
static import doir.engine.query;

public import doir.engine.positions : Position, root, none;

@nogc nothrow:


/// A new position for a child of `parent`, after sibling `previous` and before sibling `next`; pass `none` for either to leave that side open. `previous` must come before `next`, and both must be children of `parent`. The same arguments give the same position.
///
/// Returns `none` if allocation fails, leaving the engine's positions as they were.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.query;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.api.query.create(store);
/// scope(exit) doir.api.query.free(engine);
/// immutable first = between(engine, root, none, none);
/// immutable earlier = between(engine, root, none, first);
/// assert(precedes(engine, earlier, first));
/// ---
Position between(ref doir.engine.query.QueryEngine engine, Position parent, Position previous, Position next) {
	return doir.engine.positions.between(engine.positions, parent, previous, next);
}

/// Orders `a` and `b`: negative if `a` comes first, zero if they are the same position, positive otherwise. `none` comes after every other position.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.query;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.api.query.create(store);
/// scope(exit) doir.api.query.free(engine);
/// immutable a = between(engine, root, none, none);
/// assert(compare(engine, root, a) < 0 && compare(engine, a, a) == 0 && compare(engine, none, a) > 0);
/// ---
int compare(ref doir.engine.query.QueryEngine engine, Position a, Position b) {
	return doir.engine.positions.compare(engine.positions, a, b);
}

/// Whether `a` comes strictly before `b`: whether an effect at `a` is visible to a read at `b` (`C-Order`, `L-Freeze`).
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.query;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.api.query.create(store);
/// scope(exit) doir.api.query.free(engine);
/// immutable a = between(engine, root, none, none);
/// assert(precedes(engine, a, none) && !precedes(engine, a, a));
/// ---
bool precedes(ref doir.engine.query.QueryEngine engine, Position a, Position b) {
	return doir.engine.positions.precedes(engine.positions, a, b);
}


unittest { // the engine's positions order as the keys they intern
	static import ecrs.context;
	static import doir.api.query;
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	auto engine = doir.api.query.create(store);
	scope(exit) doir.api.query.free(engine);
	immutable a = between(engine, root, none, none);
	immutable b = between(engine, root, a, none);
	immutable inA = between(engine, a, none, none);
	assert(compare(engine, a, b) < 0 && compare(engine, b, a) > 0 && compare(engine, inA, inA) == 0);
	assert(precedes(engine, a, inA) && precedes(engine, inA, b) && !precedes(engine, b, inA));
	assert(between(engine, root, a, none) == b);
}
