/// Lexical positions (`C-Order`, `M-Lexical`, `L-Freeze`): order keys that totally order a file's declarations in preorder, a block's contents after the block and before its next sibling. A key can always be made between two neighbours, so an inserted declaration gets one without renumbering any other, and a declaration kept across a reparse keeps its own.
///
/// Positions are interned by the engine, so equal keys are equal `Position`s and a position compares and hashes as a number inside a query key (⟨entity, position⟩).
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.query;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.query.create(store);
/// scope(exit) doir.query.free(engine);
/// immutable a = between(engine.positions, root, none, none);
/// immutable b = between(engine.positions, root, a, none);
/// immutable inA = between(engine.positions, a, none, none);
/// assert(precedes(engine.positions, a, inA) && precedes(engine.positions, inA, b));
/// ---
module doir.positions;

public import doir.engine.positions : Position, root, none, between, compare, precedes;
