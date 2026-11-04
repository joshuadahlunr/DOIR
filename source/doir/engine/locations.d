/// Source locations (`roadmap.md` Phase 2): every parsed entity's `SourceSpan`, relative to its parent's start, and the `SourceAnnotation` a declaration's `<file:line:column>` writes (`AT-Source`), which overrides it. Absolute locations are not stored: `locate` derives one on demand by adding the spans up the `Parent` chain to a file's root block, so moving text rewrites only the spans of what moved.
///
/// Spans are untracked: no query records a dependency on them, and a diagnostic names the entity it is about, its location resolved only when it is reported. The components are in `doir.components.source`.
///
/// Examples:
/// ---
/// static import doir.components.ast;
/// static import doir.components.source;
/// static import ecrs.context;
/// static import fp.rope;
/// static import diagnose;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// immutable file = ecrs.context.addEntity(store), root = ecrs.context.addEntity(store), e = ecrs.context.addEntity(store);
/// assert(ecrs.context.setComponent!(doir.components.source.SourceText)(store, file, doir.components.source.SourceText("f.doir", fp.rope.create("a : T\nb : T\n").get)));
/// ecrs.context.addComponent!(doir.components.source.InFile)(store, root).file = file;
/// *ecrs.context.addComponent!(doir.components.source.SourceSpan)(store, root) = doir.components.source.SourceSpan(0, 12);
/// ecrs.context.addComponent!(doir.components.ast.Parent)(store, e).parent = root;
/// *ecrs.context.addComponent!(doir.components.source.SourceSpan)(store, e) = doir.components.source.SourceSpan(6, 5);
/// const where = locate(store, e).get;
/// assert(where.start == diagnose.Pair(2, 1) && where.end == diagnose.Pair(2, 6));
/// ---
module doir.engine.locations;

static import std.typecons;

static import fp.rope;

static import diagnose;
static import ecrs.context;
static import ecrs.relation;

static import doir.components.ast;
static import doir.components.query;
static import doir.components.source;

public import ecrs.registry : EntityId, invalidEntity;

@nogc nothrow:


// --- queries -----------------------------------------------------------------

private enum size_t maxHops = 64;

/// The line and column of byte `at` in `file`'s text, found through the lines the text keeps (`fp.rope`). `at` may be the text's length.
///
/// Returns null if `file` has no text.
///
/// Examples:
/// ---
/// static import doir.components.source;
/// static import fp.rope;
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// immutable file = ecrs.context.addEntity(store);
/// assert(ecrs.context.setComponent!(doir.components.source.SourceText)(store, file, doir.components.source.SourceText("f.doir", fp.rope.create("a\nbc\n").get)));
/// assert(pairAt(store, file, 3).get == imported!"diagnose".Pair(2, 2));
/// ---
std.typecons.Nullable!(diagnose.Pair) pairAt(ref ecrs.context.Context store, EntityId file, size_t at) {
	auto source = ecrs.context.findComponent!(doir.components.source.SourceText)(store, file);
	if (source is null) return typeof(return).init;
	immutable line = fp.rope.lineOf(source.text, at);
	return typeof(return)(diagnose.Pair(line + 1, at - fp.rope.lineStart(source.text, line) + 1));
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
	auto own = ecrs.context.findComponent!(doir.components.source.SourceSpan)(store, e);
	if (own is null) return typeof(return).init;
	size_t start = own.offset;
	for (EntityId at = e;;) {
		if (auto root = ecrs.context.findComponent!(doir.components.source.InFile)(store, at)) {
			auto source = ecrs.context.findComponent!(doir.components.source.SourceText)(store, root.file);
			if (source is null) return typeof(return).init;
			FileBytes out_;
			out_.file = root.file;
			out_.bytes = diagnose.SourceLocation(source.path, start, start + own.length);
			return typeof(return)(out_);
		}
		auto parent = ecrs.context.findComponent!(doir.components.ast.Parent)(store, at);
		if (parent is null) return typeof(return).init;
		at = parent.parent;
		auto span = ecrs.context.findComponent!(doir.components.source.SourceSpan)(store, at);
		if (span is null) return typeof(return).init;
		start += span.offset;
	}
}

/// The location a diagnostic about `e` reports: its `SourceAnnotation`, else its span's lines and columns, else, for an entity without a span, that of the entity it was derived from (`Provenance`) or of its `Parent`. Returns null if none is found.
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
		if (auto annotation = ecrs.context.findComponent!(doir.components.source.SourceAnnotation)(store, e)) return typeof(return)(annotation.location);
		if (ecrs.context.hasComponent!(doir.components.source.SourceSpan)(store, e)) {
			auto found = bytesOf(store, e);
			if (found.isNull) return typeof(return).init;
			auto start = pairAt(store, found.get.file, found.get.bytes.startByte);
			if (start.isNull) return typeof(return).init;
			auto end = pairAt(store, found.get.file, found.get.bytes.endByte);
			if (end.isNull) return typeof(return).init;
			return typeof(return)(diagnose.Detailed(found.get.bytes.file, start.get, end.get));
		}
		if (auto provenance = ecrs.context.findComponent!(doir.components.query.Provenance)(store, e)) e = provenance.origin;
		else if (auto parent = ecrs.context.findComponent!(doir.components.ast.Parent)(store, e)) e = parent.parent;
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
	assert(ecrs.context.setComponent!(doir.components.source.SourceText)(store, file, doir.components.source.SourceText("a.doir", fp.rope.create(text).get)));
	ecrs.context.addComponent!(doir.components.source.InFile)(store, root).file = file;
	*ecrs.context.addComponent!(doir.components.source.SourceSpan)(store, root) = doir.components.source.SourceSpan(0, cast(uint) text.length);
	void place(EntityId e, EntityId parent, uint offset, uint length) {
		ecrs.context.addComponent!(doir.components.ast.Parent)(store, e).parent = parent;
		*ecrs.context.addComponent!(doir.components.source.SourceSpan)(store, e) = doir.components.source.SourceSpan(offset, length);
	}
	place(ns, root, 0, cast(uint) text.length - 1);
	place(declared, ns, 20, 9);
	place(annotated, ns, 31, 9);
	ecrs.context.addComponent!(doir.components.source.SourceAnnotation)(store, annotated).location = diagnose.Detailed("gen", diagnose.Pair(9, 2), diagnose.Pair(9, 2));
	ecrs.context.addComponent!(doir.components.query.Provenance)(store, derived).origin = declared;
	ecrs.context.addComponent!(doir.components.ast.Parent)(store, part).parent = annotated;

	const found = bytesOf(store, declared).get;
	assert(text[found.bytes.startByte .. found.bytes.endByte] == "x : T = 1" && found.bytes.file == "a.doir" && found.file == file);
	assert(locate(store, declared).get.start == diagnose.Pair(2, 2) && locate(store, declared).get.end == diagnose.Pair(2, 11));
	assert(locate(store, annotated).get.file == "gen" && locate(store, annotated).get.start.line == 9);
	assert(locate(store, derived).get.start.line == 2);
	assert(locate(store, part).get.file == "gen");
	assert(locate(store, invalidEntity).isNull);

	// A loop of origins with no location gives up after `maxHops` rather than spinning.
	immutable loopA = ecrs.context.addEntity(store), loopB = ecrs.context.addEntity(store);
	ecrs.context.addComponent!(doir.components.query.Provenance)(store, loopA).origin = loopB;
	ecrs.context.addComponent!(doir.components.query.Provenance)(store, loopB).origin = loopA;
	assert(locate(store, loopA).isNull);

	// New text brings its own lines.
	static immutable moved = "\n\n" ~ text;
	assert(ecrs.context.setComponent!(doir.components.source.SourceText)(store, file, doir.components.source.SourceText("a.doir", fp.rope.create(moved).get)));
	ecrs.context.getComponent!(doir.components.source.SourceSpan)(store, root) = doir.components.source.SourceSpan(0, cast(uint) moved.length);
	ecrs.context.getComponent!(doir.components.source.SourceSpan)(store, ns).offset = 2;
	assert(locate(store, declared).get.start == diagnose.Pair(4, 2));
}
