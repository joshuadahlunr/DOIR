/// Source locations (`roadmap.md` Phase 2): every parsed entity's `SourceSpan`, relative to its parent's start, and the `SourceAnnotation` a declaration's `<file:line:column>` writes (`AT-Source`), which overrides it. Absolute locations are not stored: `locate` derives one on demand by adding the spans up the `Parent` chain to a file's root block, so moving text rewrites only the spans of what moved.
///
/// Spans are untracked: no query records a dependency on them, and a diagnostic names the entity it is about, its location resolved only when it is reported. None of these components but `InFile` holds an entity id, and it mixes in `ecrs.relation.Relates` (`E-Remap`).
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import diagnose;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// immutable file = ecrs.context.addEntity(store), root = ecrs.context.addEntity(store), e = ecrs.context.addEntity(store);
/// ecrs.context.addComponent!SourceLines(store, file).text = "a : T\nb : T\n";
/// ecrs.context.addComponent!InFile(store, root).file = file;
/// *ecrs.context.addComponent!SourceSpan(store, root) = SourceSpan(0, 12);
/// ecrs.context.addComponent!(doir.components.Parent)(store, e).parent = root;
/// *ecrs.context.addComponent!SourceSpan(store, e) = SourceSpan(6, 5);
/// const where = locate(store, e).get;
/// assert(where.start == diagnose.Pair(2, 1) && where.end == diagnose.Pair(2, 6));
/// ---
module doir.engine.locations;

static import std.typecons;

static import fp.dynarray;

static import diagnose;
static import ecrs.context;
static import ecrs.registry;
static import ecrs.relation;

static import doir.components;
static import doir.engine.query;

public import ecrs.registry : EntityId, invalidEntity;

@nogc nothrow:


// --- types and layout --------------------------------------------------------

/// Where a parsed entity's text is, relative to its `Parent`'s start: a declaration's to its enclosing declaration's, a parameter's to its function type's. A file's root block has the whole file.
struct SourceSpan {
	uint offset; /// Bytes from the parent's start.
	uint length; /// Bytes long.
}

/// The location a source annotation wrote on its declaration (`AT-Source`), which replaces the derived one.
struct SourceAnnotation {
	diagnose.Detailed location; /// The annotated range; its file name is interned, so it outlives the text it was parsed from.
}

/// Marks a file's root block with the file, which the spans below it are relative to.
struct InFile {
	mixin ecrs.relation.Relates!"file";
}

/// A file's path and current text, which the input commit sets, and the starts of its lines, computed the first time a location in it is asked for.
struct SourceLines {
	const(char)[] path; /// The path, interned, so it outlives every version of the text.
	const(char)[] text; /// The text as of the last commit, owned by the file's `doir.source.SourceText`.
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

unittest { // libECRS silently skips a holder whose hook is not `@nogc nothrow`; every holder of an entity id must pass (E-Remap)
	static assert(ecrs.registry.hasRemapEntities!InFile);
}


// --- queries -----------------------------------------------------------------

private enum size_t maxHops = 64;

/// The line and column of byte `at` in `file`'s text, computing its line starts on first use.
///
/// Returns null if computing them is refused, leaving them to be computed on the next call.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// immutable file = ecrs.context.addEntity(store);
/// assert(ecrs.context.setComponent!SourceLines(store, file, SourceLines("f.doir", "a\nbc\n")));
/// assert(pairAt(store, file, 3).get == imported!"diagnose".Pair(2, 2));
/// ---
std.typecons.Nullable!(diagnose.Pair) pairAt(ref ecrs.context.Context store, EntityId file, size_t at) {
	auto lines = &ecrs.context.getComponent!SourceLines(store, file);
	if (lines.starts is null) {
		bool computed = fp.dynarray.pushBack(lines.starts, size_t(0));
		foreach (i, c; lines.text)
			if (computed && c == '\n') computed = fp.dynarray.pushBack(lines.starts, i + 1);
		if (!computed) {
			lines.finalize();
			return typeof(return).init;
		}
	}
	size_t lo = 0, hi = fp.dynarray.length(lines.starts);
	while (hi - lo > 1) {
		immutable mid = (lo + hi) / 2;
		if (lines.starts[mid] <= at) lo = mid;
		else hi = mid;
	}
	return typeof(return)(diagnose.Pair(lo + 1, at - lines.starts[lo] + 1));
}

/// A byte range of a file, as `bytesOf` finds it.
struct FileBytes {
	mixin ecrs.relation.Relates!"file";
	diagnose.SourceLocation bytes; /// The range, the file named by its path.
}

/// The file and byte range of `e`'s own span, its spans added up the `Parent` chain to its file's root block. Returns null if `e` has no span or its chain reaches no file.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// assert(bytesOf(store, ecrs.context.addEntity(store)).isNull);
/// ---
std.typecons.Nullable!FileBytes bytesOf(ref ecrs.context.Context store, EntityId e) {
	auto own = ecrs.context.findComponent!SourceSpan(store, e);
	if (own is null) return typeof(return).init;
	size_t start = own.offset;
	for (EntityId at = e;;) {
		if (auto root = ecrs.context.findComponent!InFile(store, at)) {
			auto lines = ecrs.context.findComponent!SourceLines(store, root.file);
			if (lines is null) return typeof(return).init;
			FileBytes out_;
			out_.file = root.file;
			out_.bytes = diagnose.SourceLocation(lines.path, start, start + own.length);
			return typeof(return)(out_);
		}
		auto parent = ecrs.context.findComponent!(doir.components.Parent)(store, at);
		if (parent is null) return typeof(return).init;
		at = parent.parent;
		auto span = ecrs.context.findComponent!SourceSpan(store, at);
		if (span is null) return typeof(return).init;
		start += span.offset;
	}
}

/// The location a diagnostic about `e` reports: its `SourceAnnotation`, else its span's lines and columns, else, for an entity without a span, that of the entity it was derived from (`Provenance`) or of its `Parent`. Returns null if none is found, or if computing its lines is refused.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import diagnose;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// assert(locate(store, ecrs.context.addEntity(store)).isNull);
/// ---
std.typecons.Nullable!(diagnose.Detailed) locate(ref ecrs.context.Context store, EntityId e) {
	foreach (hop; 0 .. maxHops) {
		if (e == invalidEntity) return typeof(return).init;
		if (auto annotation = ecrs.context.findComponent!SourceAnnotation(store, e)) return typeof(return)(annotation.location);
		if (ecrs.context.hasComponent!SourceSpan(store, e)) {
			auto found = bytesOf(store, e);
			if (found.isNull) return typeof(return).init;
			auto start = pairAt(store, found.get.file, found.get.bytes.startByte);
			if (start.isNull) return typeof(return).init;
			auto end = pairAt(store, found.get.file, found.get.bytes.endByte);
			if (end.isNull) return typeof(return).init;
			return typeof(return)(diagnose.Detailed(found.get.bytes.file, start.get, end.get));
		}
		if (auto provenance = ecrs.context.findComponent!(doir.engine.query.Provenance)(store, e)) e = provenance.origin;
		else if (auto parent = ecrs.context.findComponent!(doir.components.Parent)(store, e)) e = parent.parent;
		else return typeof(return).init;
	}
	return typeof(return).init;
}


unittest { // spans add up to the file; annotations win; derived entities and parts report where they came from
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	immutable file = ecrs.context.addEntity(store), root = ecrs.context.addEntity(store);
	immutable ns = ecrs.context.addEntity(store), declared = ecrs.context.addEntity(store), annotated = ecrs.context.addEntity(store);
	immutable derived = ecrs.context.addEntity(store), part = ecrs.context.addEntity(store);
	static immutable text = "ns : namespace = {\n\tx : T = 1\n\ty : T = 2\n}\n";
	assert(ecrs.context.setComponent!SourceLines(store, file, SourceLines("a.doir", text)));
	ecrs.context.addComponent!InFile(store, root).file = file;
	*ecrs.context.addComponent!SourceSpan(store, root) = SourceSpan(0, cast(uint) text.length);
	void place(EntityId e, EntityId parent, uint offset, uint length) {
		ecrs.context.addComponent!(doir.components.Parent)(store, e).parent = parent;
		*ecrs.context.addComponent!SourceSpan(store, e) = SourceSpan(offset, length);
	}
	place(ns, root, 0, cast(uint) text.length - 1);
	place(declared, ns, 20, 9);
	place(annotated, ns, 31, 9);
	ecrs.context.addComponent!SourceAnnotation(store, annotated).location = diagnose.Detailed("gen", diagnose.Pair(9, 2), diagnose.Pair(9, 2));
	ecrs.context.addComponent!(doir.engine.query.Provenance)(store, derived).origin = declared;
	ecrs.context.addComponent!(doir.components.Parent)(store, part).parent = annotated;

	const found = bytesOf(store, declared).get;
	assert(text[found.bytes.startByte .. found.bytes.endByte] == "x : T = 1" && found.bytes.file == "a.doir" && found.file == file);
	assert(locate(store, declared).get.start == diagnose.Pair(2, 2) && locate(store, declared).get.end == diagnose.Pair(2, 11));
	assert(locate(store, annotated).get.file == "gen" && locate(store, annotated).get.start.line == 9);
	assert(locate(store, derived).get.start.line == 2);
	assert(locate(store, part).get.file == "gen");
	assert(locate(store, invalidEntity).isNull);

	// A loop of origins with no location gives up after `maxHops` rather than spinning.
	immutable loopA = ecrs.context.addEntity(store), loopB = ecrs.context.addEntity(store);
	ecrs.context.addComponent!(doir.engine.query.Provenance)(store, loopA).origin = loopB;
	ecrs.context.addComponent!(doir.engine.query.Provenance)(store, loopB).origin = loopA;
	assert(locate(store, loopA).isNull);

	// New text drops the line starts, which are computed again from it.
	static immutable moved = "\n\n" ~ text;
	assert(ecrs.context.setComponent!SourceLines(store, file, SourceLines("a.doir", moved)));
	ecrs.context.getComponent!SourceSpan(store, root) = SourceSpan(0, cast(uint) moved.length);
	ecrs.context.getComponent!SourceSpan(store, ns).offset = 2;
	assert(locate(store, declared).get.start == diagnose.Pair(4, 2));
}
