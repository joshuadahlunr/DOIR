/// The one-shot parse: a whole file's text lexed, parsed and built into the store through `doir.core.builders` in one pass, with no rope, reparse matching, order keys or revisions (`roadmap.md` Phase 4).
/// It is what an embedder hands source text to; DOIR's incremental commit builds the same entities through the same parser.
///
/// Every declaration gets its `SourceSpan`, relative to its parent's start, and the root's spans the whole text; a declaration with a source annotation gets its `SourceAnnotation` (`AT-Source`).
/// The parse recovers from syntax errors statement by statement, so a file with an error still yields its other declarations, and the errors are kept on the root as `SyntaxErrors`, each offset from the start of the text.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import fp.dynarray;
/// static import doir.core.strings;
/// static import doir.core.components.ast;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// doir.core.strings.Strings strings;
/// scope(exit) doir.core.strings.free(strings);
/// immutable parsed = parse(store, strings, "x : std.u8 = 5\nns : namespace = {\n\ty : T\n}\n").get;
/// assert(parsed.errors == 0);
/// assert(fp.dynarray.length(ecrs.context.getComponent!(doir.core.components.ast.Block)(store, parsed.root).related) == 2);
/// ---
module doir.core.parse;

static import std.typecons;

static import fp.dynarray;
static import fp.pointer;
static import fp.string;
version(unittest) static import fp.algorithms;
version(unittest) static import fp.testing;

static import ecrs.context;

static import doir.core.strings;
static import doir.core.builders;
static import doir.core.components.ast;
static import doir.core.components.source;
static import doir.core.syntax.lexer;
static import doir.core.syntax.parser;

public import ecrs.context : EntityId, invalidEntity;

@nogc nothrow:


// --- types -------------------------------------------------------------------

/// What `parse` built.
struct Parsed {
	EntityId root = invalidEntity; /// The file's root block.
	size_t errors; /// How many syntax errors the parse recovered from, kept on `root` as `SyntaxErrors`.
}

/// The longest text `parse` accepts: spans are 32-bit offsets.
enum size_t maxLength = uint.max - 1;

// A block whose records are still being built: its entity, where its text starts, and the record after its last nested one.
private struct Open {
	EntityId block;
	size_t start;
	size_t end;
}


// --- building ----------------------------------------------------------------

// Appends record `r` to `open.block` as a new declaration and builds it, with its span and annotation; returns it, or `invalidEntity` on refusal.
private EntityId buildRecord(ref ecrs.context.Context store, ref doir.core.strings.Strings strings, ref const doir.core.syntax.parser.Syntax syntax, const(char)[] source, size_t r, Open open) {
	immutable record = syntax.records[r];
	assert(record.spanStart >= open.start && record.spanEnd >= record.spanStart, "doir.core.parse: a record before its block, or ending before it starts");
	immutable name = record.name == doir.core.syntax.parser.unnamed ? doir.core.strings.unnamed : doir.core.syntax.parser.internSpelling(doir.core.syntax.lexer.text(syntax.tokens[record.name], source), strings);
	if (name == doir.core.strings.refused) return invalidEntity;
	auto block = doir.core.builders.BlockBuilder(&store, open.block);
	immutable e = doir.core.builders.pushDeclaration(block, name);
	if (e == invalidEntity) return invalidEntity;
	auto b = doir.core.syntax.parser.Builder(&store, &strings, e);
	scope(exit) fp.dynarray.free(b.parts);
	if (!doir.core.syntax.parser.build(syntax, source, r, b)) return invalidEntity;
	immutable span = doir.core.components.source.SourceSpan(cast(uint) (record.spanStart - open.start), record.spanEnd - record.spanStart);
	if (!ecrs.context.setComponent!(doir.core.components.source.SourceSpan)(store, e, span)) return invalidEntity;
	if (b.annotated && !ecrs.context.setComponent!(doir.core.components.source.SourceAnnotation)(store, e, doir.core.components.source.SourceAnnotation(b.annotation))) return invalidEntity;
	assert(ecrs.context.getComponent!(doir.core.components.ast.Parent)(store, e).parent == open.block, "doir.core.parse: a declaration under another block (WF-Par)");
	return e;
}

// Builds every record of `syntax` under `root`, in preorder, each block's entries in source order; false on refusal.
private bool buildRecords(ref ecrs.context.Context store, ref doir.core.strings.Strings strings, ref const doir.core.syntax.parser.Syntax syntax, const(char)[] source, EntityId root) {
	auto records = fp.dynarray.slice(syntax.records);
	// The skim stops nesting at `maxNesting` (IL-Nest), so no deeper stack is needed.
	enum depthLimit = doir.core.syntax.parser.maxNesting + 1;
	Open[depthLimit] open;
	size_t depth = 1;
	open[0] = Open(root, 0, records.length);
	for (size_t r = 0; r < records.length; ++r) {
		while (r >= open[depth - 1].end) --depth;
		assert(depth >= 1, "doir.core.parse: a record outside the root");
		immutable e = buildRecord(store, strings, syntax, source, r, open[depth - 1]);
		if (e == invalidEntity) return false;
		if (records[r].end > r + 1 || records[r].blockOpen != doir.core.syntax.parser.noBlock) {
			assert(records[r].end <= open[depth - 1].end, "doir.core.parse: a record whose nested records run past its block's");
			assert(depth < depthLimit, "doir.core.parse: blocks nested deeper than the skim allows (IL-Nest)");
			if (!ecrs.context.hasComponent!(doir.core.components.ast.Block)(store, e)) {
				assert(records[r].end == r + 1, "doir.core.parse: nested records under a declaration that built no block");
				continue;
			}
			open[depth++] = Open(e, records[r].spanStart, records[r].end);
		}
	}
	return true;
}

// Keeps `syntax`'s errors on `root`, offsets from the start of `source`; false on refusal.
private bool storeErrors(ref ecrs.context.Context store, ref const doir.core.syntax.parser.Syntax syntax, const(char)[] source, EntityId root) {
	if (fp.dynarray.length(syntax.errors) == 0) return true;
	doir.core.components.source.SyntaxErrors list;
	scope(exit) list.finalize();
	foreach (error; fp.dynarray.slice(syntax.errors)) {
		doir.core.components.source.StoredError stored;
		stored.at = error.at;
		immutable open = doir.core.syntax.parser.opening(syntax, error);
		if (open != fp.pointer.notFound) stored.opening = cast(uint) open;
		stored.message = doir.core.syntax.parser.describe(syntax, source, error);
		stored.hint = doir.core.syntax.parser.hint(syntax, source, error);
		stored.note = doir.core.syntax.parser.explain(syntax, source, error);
		stored.fixes = doir.core.syntax.parser.fixes(syntax, source, error);
		if (stored.message is null || stored.hint is null || stored.note is null || !fp.dynarray.pushBack(list.errors, stored)) {
			fp.string.free(stored.message);
			fp.string.free(stored.hint);
			fp.string.free(stored.note);
			return false;
		}
	}
	auto moved = list;
	list.errors = null;
	return ecrs.context.setComponent!(doir.core.components.source.SyntaxErrors)(store, root, moved);
}


// --- the parse ---------------------------------------------------------------

/// Lexes, parses and builds `source`, the whole text of one file, under a new root block in `store`, interning names and string literals in `strings`.
/// Syntax errors do not fail the parse: they are counted in the result and kept on the root (`roadmap.md` Phase 2, statement-level recovery).
///
/// Returns null if `source` is longer than `maxLength` or an allocation is refused, leaving `store` as it was; strings interned before the refusal stay interned.
/// `store` must have no transaction open, since the parse runs in one.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.core.strings;
/// static import doir.core.components.source;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// doir.core.strings.Strings strings;
/// scope(exit) doir.core.strings.free(strings);
/// immutable parsed = parse(store, strings, "x : T = \ny : T\n").get;
/// assert(parsed.errors == 1);
/// assert(ecrs.context.getComponent!(doir.core.components.source.SourceSpan)(store, parsed.root).length == 15);
/// ---
std.typecons.Nullable!Parsed parse(ref ecrs.context.Context store, ref doir.core.strings.Strings strings, const(char)[] source) {
	if (source.length > maxLength) return typeof(return).init;
	doir.core.syntax.parser.Syntax syntax;
	scope(exit) doir.core.syntax.parser.free(syntax);
	if (!doir.core.syntax.parser.skim(source, syntax)) return typeof(return).init;

	immutable before = ecrs.context.entityCount(store);
	ecrs.context.beginTransaction(store);
	auto root = doir.core.builders.createRoot(store);
	immutable built = root.block != invalidEntity
		&& ecrs.context.setComponent!(doir.core.components.source.SourceSpan)(store, root.block, doir.core.components.source.SourceSpan(0, cast(uint) source.length))
		&& buildRecords(store, strings, syntax, source, root.block)
		&& storeErrors(store, syntax, source, root.block);
	if (!built) {
		ecrs.context.rollbackTransaction(store);
		assert(ecrs.context.entityCount(store) == before, "doir.core.parse: a refused parse left entities behind");
		return typeof(return).init;
	}
	ecrs.context.commitTransaction(store);
	return typeof(return)(Parsed(root.block, fp.dynarray.length(syntax.errors)));
}


// --- tests -------------------------------------------------------------------

version(unittest) {
	// Checks `e`'s subtree against `source`: every entry names `e` as its `Parent`, and every span slices its declaration's text, relative to `start`.
	// bounded: the nesting the skim allows (IL-Nest)
	private size_t checkTree(ref ecrs.context.Context store, EntityId e, const(char)[] source, size_t start, size_t depth = 0) {
		assert(depth <= doir.core.syntax.parser.maxNesting + 1, "doir.core.parse: a tree deeper than the skim allows (IL-Nest)");
		size_t count = 1;
		auto block = ecrs.context.findComponent!(doir.core.components.ast.Block)(store, e);
		if (block is null) return count;
		foreach (child; fp.dynarray.slice(block.related)) {
			assert(ecrs.context.getComponent!(doir.core.components.ast.Parent)(store, child).parent == e);
			immutable span = ecrs.context.getComponent!(doir.core.components.source.SourceSpan)(store, child);
			assert(start + span.offset + span.length <= source.length);
			count += checkTree(store, child, source, start + span.offset, depth + 1);
		}
		return count;
	}
}

unittest { // the tree: blocks, parents, spans, names and annotations
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	doir.core.strings.Strings strings;
	scope(exit) doir.core.strings.free(strings);
	immutable source = "x : std.u8 = 5\nns : namespace = {\n\ty : T\n\tinner : namespace = { z : T = 1; }\n}\n_ : _ = std.return(x) <f:1:2>\nf : (a: T) -> U\n";
	immutable parsed = parse(store, strings, source).get;
	assert(parsed.errors == 0 && !ecrs.context.hasComponent!(doir.core.components.source.SyntaxErrors)(store, parsed.root));
	assert(checkTree(store, parsed.root, source, 0) == 8);

	auto entries = fp.dynarray.slice(ecrs.context.getComponent!(doir.core.components.ast.Block)(store, parsed.root).related);
	assert(entries.length == 4);
	immutable x = ecrs.context.getComponent!(doir.core.components.source.SourceSpan)(store, entries[0]);
	assert(source[x.offset .. x.offset + x.length] == "x : std.u8 = 5");
	assert(doir.core.strings.text(strings, ecrs.context.getComponent!(doir.core.components.ast.Name)(store, entries[0]).value) == "x");
	immutable ns = ecrs.context.getComponent!(doir.core.components.source.SourceSpan)(store, entries[1]);
	auto inside = fp.dynarray.slice(ecrs.context.getComponent!(doir.core.components.ast.Block)(store, entries[1]).related);
	assert(inside.length == 2);
	immutable y = ecrs.context.getComponent!(doir.core.components.source.SourceSpan)(store, inside[0]);
	assert(source[ns.offset + y.offset .. ns.offset + y.offset + y.length] == "y : T");
	assert(!ecrs.context.hasComponent!(doir.core.components.ast.Name)(store, entries[2]));
	assert(ecrs.context.getComponent!(doir.core.components.source.SourceAnnotation)(store, entries[2]).location.start.line == 1);
	assert(ecrs.context.hasComponent!(doir.core.components.ast.TypeOf)(store, entries[3]), "a function type written in place is a part, not a lookup");
}

unittest { // syntax errors: recovery, and the errors kept on the root with their hints
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	doir.core.strings.Strings strings;
	scope(exit) doir.core.strings.free(strings);
	immutable source = "a : T = 1\nb : T = \nc : T = 3\nns : namespace = {\n";
	immutable parsed = parse(store, strings, source).get;
	assert(parsed.errors == 2);
	auto errors = fp.dynarray.slice(ecrs.context.getComponent!(doir.core.components.source.SyntaxErrors)(store, parsed.root).errors);
	assert(errors.length == 2 && errors[0].at < errors[1].at);
	foreach (error; errors) assert(error.at <= source.length && fp.string.slice(error.message).length && fp.string.slice(error.hint).length);
	assert(errors[1].opening != doir.core.components.source.noOpening, "a missing `}` points at the brace it would close");
	auto entries = fp.dynarray.slice(ecrs.context.getComponent!(doir.core.components.ast.Block)(store, parsed.root).related);
	assert(entries.length >= 2, "the declarations around an error are still built");
	assert(doir.core.strings.text(strings, ecrs.context.getComponent!(doir.core.components.ast.Name)(store, entries[0]).value) == "a");
}

unittest { // a refused allocation leaves the store as it was, and some budget always suffices (seeded)
	static immutable string[3] sources = [
		"x : std.u8 = 5\nns : namespace = {\n\ty : T\n}\n",
		"f : (a: T, b: U = 2) -> V = {\n\t_ : _ = std.return(a)\n}\ns : std.byte_pointer = \"hi\\n\"\n",
		"a : T = \nb : T = 2\n",
	];
	auto random = fp.algorithms.createRandom(0xD01C0);
	foreach (source; sources) {
		auto whole = ecrs.context.create();
		scope(exit) ecrs.context.free(whole);
		doir.core.strings.Strings wholeStrings;
		scope(exit) doir.core.strings.free(wholeStrings);
		immutable expected = parse(whole, wholeStrings, source).get;
		immutable entities = checkTree(whole, expected.root, source, 0);

		auto store = ecrs.context.create();
		scope(exit) ecrs.context.free(store);
		doir.core.strings.Strings strings;
		scope(exit) doir.core.strings.free(strings);
		immutable spare = ecrs.context.addEntity(store);
		assert(spare != invalidEntity);
		for (size_t budget = 0;; budget += 1 + fp.algorithms.randomBelow(random, 3)) {
			immutable before = ecrs.context.entityCount(store);
			auto allocator = fp.testing.limitAllocations(budget);
			auto parsed = parse(store, strings, source);
			fp.testing.restoreAllocator(allocator);
			if (parsed.isNull) {
				assert(ecrs.context.entityCount(store) == before, "a refused parse left entities behind");
				continue;
			}
			assert(parsed.get.errors == expected.errors);
			assert(checkTree(store, parsed.get.root, source, 0) == entities);
			break;
		}
	}
}
