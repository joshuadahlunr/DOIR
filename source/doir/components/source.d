/// The components of source files and the declarations parsed from them (`roadmap.md` Phase 2): a file's text and lines, the syntax errors in each block, the keys the input commit matches declarations by across reparses, the files a block imports (`I-Import`), and every parsed entity's `SourceSpan`, relative to its parent's start, with the `SourceAnnotation` that overrides it (`AT-Source`).
/// Every one holding an entity id mixes in `ecrs.relation.Relates` (`E-Remap`).
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
static import fp.rope;
static import fp.string;

static import diagnose;
static import ecrs.relation;
static import ecrs.registry;

static import doir.strings;

public import ecrs.registry : EntityId, invalidEntity;
public import doir.engine.positions : Position;

@nogc nothrow:


// --- files -------------------------------------------------------------------

/// A source file's input entity: its path, interned.
/// The file's contents join it with the parser (`roadmap.md` Phase 2).
struct SourceFile {
	doir.strings.StringId path; /// The path, as the build named it.
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


// --- locations ---------------------------------------------------------------

/// Where a parsed entity's text is, relative to its `Parent`'s start: a declaration's to its enclosing declaration's, a parameter's to its function type's.
/// A file's root block has the whole file.
struct SourceSpan {
	uint offset; /// Bytes from the parent's start.
	uint length; /// Bytes long.
}

/// The location a source annotation wrote on its declaration (`AT-Source`), which replaces the derived one.
struct SourceAnnotation {
	diagnose.LineColumnRange location; /// The annotated range; its file name is interned, so it outlives the text it was parsed from.
}


// --- syntax errors -----------------------------------------------------------

/// An edit a syntax error's hint states exactly: `text`, with a space before and after it where `spaceBefore` and `spaceAfter` say, written over the bytes from `from` to `to`, counted from where the error is reported, so it moves with the error.
struct SyntaxFix {
	int from; /// Where the replaced bytes start, from where the error is reported; negative before it.
	int to; /// Where the replaced bytes end, from where the error is reported; equal to `from` for an insertion.
	string text; /// What is written there, without the spaces; a view of the parser's tables, so it needs no freeing.
	bool spaceBefore; /// Whether a space goes before `text`, as in `x : T = {`.
	bool spaceAfter; /// Whether a space goes after `text`.
}

/// The most fixes one syntax error offers: one per token its hint lists.
enum maxSyntaxFixes = 9;

/// The fixes a syntax error offers, in the order its hint names them.
struct SyntaxFixes {
	SyntaxFix[maxSyntaxFixes] items; /// The first `length` are the fixes.
	size_t length; /// How many there are.
}

/// A syntax error the parse recovered from, as `SyntaxErrors` keeps it.
struct StoredError {
	uint at; /// Bytes from its holder's start to where it is reported.
	uint opening = noOpening; /// Bytes from its holder's start to the bracket a missing closer would close, or `noOpening`.
	char* message = null; /// What went wrong; an owned fp string.
	char* hint = null; /// How to fix it; an owned fp string.
	char* note = null; /// What DOIR expects there, for someone new to it; an owned fp string.
	SyntaxFixes fixes; /// The edits its hint states exactly, for an editor to offer.
}

/// `StoredError.opening` when no bracket is left open.
enum uint noOpening = uint.max;

/// The syntax errors found directly in a block when it was last parsed: held by the innermost block-valued declaration enclosing them, or by the file's root block, with offsets from its start, so they move with its span.
/// A commit replaces them whenever it reparses the block and leaves them alone when it skips it as unchanged.
struct SyntaxErrors {
	StoredError* errors = null; /// In source order; an owned fp dynarray.

	/// Releases the errors and their strings when the component is removed.
	///
	/// Examples:
	/// ---
	/// SyntaxErrors s;
	/// s.finalize();
	/// assert(s.errors is null);
	/// ---
	void finalize() @nogc nothrow {
		foreach (ref error; fp.dynarray.slice(errors)) {
			fp.string.free(error.message);
			fp.string.free(error.hint);
			fp.string.free(error.note);
		}
		fp.dynarray.free(errors);
	}
}

unittest { // libECRS silently skips a holder whose hook is not `@nogc nothrow`; every holder of an entity id must pass (E-Remap)
	static assert(ecrs.registry.hasRemapEntities!FileRoot && ecrs.registry.hasRemapEntities!InFile && ecrs.registry.hasRemapEntities!Imports && ecrs.registry.hasRemapEntities!ParsedParts);
}
