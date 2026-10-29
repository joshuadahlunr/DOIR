/// The components a level of the tower carries (`L-Tower`): its rank, and how it evaluates the files it imports (`I-Import`).
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// immutable level = ecrs.context.addEntity(store);
/// ecrs.context.addComponent!Rank(store, level).value = 2;
/// assert(ecrs.context.getComponent!Rank(store, level).value == 2);
/// ---
module doir.components.levels;

static import doir.query;

public import ecrs.registry : EntityId, invalidEntity;

@nogc nothrow:


// --- types and layout --------------------------------------------------------

/// The rank of the entity's level in the tower (`L-Tower`).
struct Rank {
	ushort value; /// The rank.
}

/// Builds the entities of `file` for `level` through `createEntity` and `produce`, and runs its comptime, inside the import query. Returns its root block, or `invalidEntity` if it cannot be evaluated, having reported why.
alias EvaluateFunction = EntityId function(ref doir.query.QueryEngine engine, EntityId file, EntityId level) @nogc nothrow;

/// How a level evaluates a file it imports: its parse and its comptime. An input on the level entity, set when the tower is built.
struct LevelEvaluator {
	EvaluateFunction evaluate; /// The evaluator.
}
