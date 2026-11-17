/// The components of source files and the declarations parsed from them that the incremental commit keeps (`roadmap.md` Phase 2): a file's text and lines, the keys the input commit matches declarations by across reparses, and the files a block imports (`I-Import`).
/// The spans, source annotations and syntax errors the parser writes are `doir.core.components.source`'s.
/// Every one holding an entity id mixes in `ecrs.relation.Relates` (`E-Remap`).
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// immutable e = ecrs.context.addEntity(store), root = ecrs.context.addEntity(store);
/// ecrs.context.addComponent!FileRoot(store, e).root = root;
/// assert(ecrs.context.getComponent!FileRoot(store, e).root == root);
/// ---
module doir.components.source;

static import fp.rope;

static import ecrs.relation;
static import ecrs.registry;

static import doir.core.strings;

public import ecrs.registry : EntityId, invalidEntity;
public import doir.engine.positions : Position;

@nogc nothrow:


// --- files -------------------------------------------------------------------

/// A source file's input entity: its path, interned.
/// The file's contents join it with the parser (`roadmap.md` Phase 2).
struct SourceFile {
	doir.core.strings.StringId path; /// The path, as the build named it.
}

/// A file's path and its text as of the last commit, owned by its input entity.
/// Every parsed entity's location is a range of it, and its lines are kept by the text itself (`fp.rope`).
struct SourceText {
	const(char)[] path; /// The path, interned, so it outlives every version of the text.
	fp.rope.Rope text; /// The version the last commit wrote; this component owns it, and releases it through the rope's own hooks.
}

/// A file's root block, which every commit of the file keeps.
struct FileRoot {
	mixin ecrs.relation.Relates!"root";
}

/// Marks a file's root block with the file, which the spans below it are relative to.
struct InFile {
	mixin ecrs.relation.Relates!"file";
}

/// The files a block's `std.import` declarations name, resolved to their input entities, in declaration order.
/// An input, written by the commit that parses them, or by evaluation once paths are comptime values.
struct Imports {
	mixin ecrs.relation.Relates;
}


// --- declarations ------------------------------------------------------------

/// A named declaration's key across reparses: its name path, each name with its occurrence index among same-named siblings (`ir-design.md` §4.2).
struct PathHash {
	ulong value; /// The hash.
}

/// The hash of a declaration's non-trivia tokens, each nested declaration a placeholder: equal hashes mean an unchanged declaration.
struct SyntaxHash {
	ulong value; /// The hash.
}

/// A declaration's lexical position, the order key that `C-Order` reads and log entries are positioned by (`M-Lexical`).
struct LexicalPosition {
	Position at; /// The key.
}

/// The entities the parse made for a declaration besides its nested declarations: its function types written in place and their parameters, parents first.
/// A rebuild reuses them in order, so their ids survive it.
struct ParsedParts {
	mixin ecrs.relation.Relates;
}


unittest { // libECRS silently skips a holder whose hook is not `@nogc nothrow`; every holder of an entity id must pass (E-Remap)
	static assert(ecrs.registry.hasRemapEntities!FileRoot && ecrs.registry.hasRemapEntities!InFile && ecrs.registry.hasRemapEntities!Imports && ecrs.registry.hasRemapEntities!ParsedParts);
}
