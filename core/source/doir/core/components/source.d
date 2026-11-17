/// The components the parser writes on what it parses, besides the bindings of `doir.core.components.ast`: every parsed entity's `SourceSpan`, relative to its parent's start, with the `SourceAnnotation` that overrides it (`AT-Source`), and the syntax errors a parse recovered from, with the fixes their hints state.
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
module doir.core.components.source;

static import fp.dynarray;
static import fp.string;

static import diagnose;

@nogc nothrow:


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
