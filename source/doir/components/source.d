/// The components of source files and the declarations parsed from them (`roadmap.md` Phase 2): a file's text and lines, the keys the input commit matches declarations by across reparses, the files a block imports (`I-Import`), and every parsed entity's `SourceSpan`, relative to its parent's start, with the `SourceAnnotation` that overrides it (`AT-Source`). Every one holding an entity id mixes in `ecrs.relation.Relates` (`E-Remap`).
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// immutable e = ecrs.context.addEntity(store);
/// *ecrs.context.addComponent!SourceSpan(store, e) = SourceSpan(6, 5);
/// assert(ecrs.context.getComponent!SourceSpan(store, e).length == 5);
/// ---
module doir.components.source;

static import fp.dynarray;
static import fp.string;

static import diagnose;
static import ecrs.relation;
static import ecrs.registry;

static import doir.strings;

public import ecrs.registry : EntityId, invalidEntity;
public import doir.engine.positions : Position;

@nogc nothrow:


// --- files -------------------------------------------------------------------

/// A source file's input entity: its path, interned. The file's contents join it with the parser (`roadmap.md` Phase 2).
struct SourceFile {
	doir.strings.StringId path; /// The path, as the build named it.
}

/// A file's text, owned by its input entity, which every parsed entity's location slices.
struct SourceText {
	char* text = null; /// An owned fp string.

	/// Releases the text when the component is removed.
	///
	/// Examples:
	/// ---
	/// static import fp.string;
	/// SourceText s = SourceText(fp.string.makeDynamic("x"));
	/// s.finalize();
	/// assert(s.text is null);
	/// ---
	void finalize() @nogc nothrow {
		fp.string.free(text);
		text = null;
	}
}

/// A file's path and current text, which the input commit sets, and the starts of its lines, computed the first time a location in it is asked for.
struct SourceLines {
	const(char)[] path; /// The path, interned, so it outlives every version of the text.
	const(char)[] text; /// The text as of the last commit, owned by the file's `SourceText`.
	size_t* starts = null; /// The byte offset of each line's start, or null until computed; an fp dynarray.

	/// Releases the line starts when the component is removed.
	///
	/// Examples:
	/// ---
	/// SourceLines lines;
	/// lines.finalize();
	/// ---
	void finalize() @nogc nothrow {
		fp.dynarray.free(starts);
		starts = null;
	}
}

/// A file's root block, which every commit of the file keeps.
struct FileRoot {
	mixin ecrs.relation.Relates!"root";
}

/// Marks a file's root block with the file, which the spans below it are relative to.
struct InFile {
	mixin ecrs.relation.Relates!"file";
}

/// The files a block's `std.import` declarations name, resolved to their input entities, in declaration order. An input, written by the commit that parses them, or by evaluation once paths are comptime values.
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

/// The entities the parse made for a declaration besides its nested declarations: its function types written in place and their parameters, parents first. A rebuild reuses them in order, so their ids survive it.
struct ParsedParts {
	mixin ecrs.relation.Relates;
}


// --- locations ---------------------------------------------------------------

/// Where a parsed entity's text is, relative to its `Parent`'s start: a declaration's to its enclosing declaration's, a parameter's to its function type's. A file's root block has the whole file.
struct SourceSpan {
	uint offset; /// Bytes from the parent's start.
	uint length; /// Bytes long.
}

/// The location a source annotation wrote on its declaration (`AT-Source`), which replaces the derived one.
struct SourceAnnotation {
	diagnose.Detailed location; /// The annotated range; its file name is interned, so it outlives the text it was parsed from.
}

unittest { // libECRS silently skips a holder whose hook is not `@nogc nothrow`; every holder of an entity id must pass (E-Remap)
	static assert(ecrs.registry.hasRemapEntities!FileRoot && ecrs.registry.hasRemapEntities!InFile && ecrs.registry.hasRemapEntities!Imports && ecrs.registry.hasRemapEntities!ParsedParts);
}
