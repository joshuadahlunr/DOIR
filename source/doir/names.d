/// A block's named entries indexed by name (`WF-Unique`, `R-Unqual`), so finding the entry a name reaches costs a binary search instead of a scan of the block.
/// The index is a query keyed by the block (`EntriesByName`): it re-runs when the block's entries change, and keeps its old `ChangedAt` when they change without changing which entity each name reaches (early cutoff), so a lookup through it is not re-run by an edit that adds or replaces only `_` entries.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.query;
/// static import doir.source;
/// static import doir.strings;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.query.create(store);
/// scope(exit) doir.query.free(engine);
/// doir.strings.Strings strings;
/// scope(exit) doir.strings.free(strings);
/// engine.strings = &strings;
/// immutable file = doir.source.addFile(engine, strings, "a.doir");
/// assert(doir.source.commit(engine, strings, file, "x : T = 1\ny : T = 2\n") == 0);
/// immutable root = doir.source.rootOf(engine, file);
/// assert(entryNamed(engine, root, doir.strings.intern(strings, "y")) != invalidEntity);
/// ---
module doir.names;

static import std.algorithm.sorting;

static import fp.dynarray;

static import ecrs.context;
static import ecrs.relation;

static import doir.components.ast;
static import doir.query;
static import doir.strings;

public import ecrs.registry : EntityId, invalidEntity;

@nogc nothrow:


// --- types and layout --------------------------------------------------------

/// A block's named entries, sorted by name, one per name: the last, as `doir_check` keeps it, if a block breaks `WF-Unique`.
struct Entries {
	mixin ecrs.relation.Relates;
}

// A named entry and where it stands in its block, for sorting.
private struct Named {
	doir.strings.StringId name;
	uint index;
	EntityId e;
}

// The name of `e`, or `unnamed` for `_`. Reparse matches a named entry by name, so its name never changes in place.
private doir.strings.StringId nameOf(ref doir.query.QueryEngine engine, EntityId e) {
	auto n = ecrs.context.findComponent!(doir.components.ast.Name)(*engine.store, e);
	return n is null ? doir.strings.unnamed : n.value;
}


// --- queries -----------------------------------------------------------------

/// The query of a block's `Entries`, keyed by the block.
/// It reads the block but none of its entries, since an entry's name never changes in place.
struct EntriesByName {
	alias Key = ecrs.relation.Relation!1; /// The block: a file's root, a block-valued declaration or a namespace.
	alias Value = Entries; /// Its named entries, sorted by name.

	/// Whether two indexes reach the same entity by every name.
	///
	/// Examples:
	/// ---
	/// Entries a, b;
	/// assert(EntriesByName.valueEqual(a, b));
	/// ---
	static bool valueEqual(ref const Entries a, ref const Entries b) @nogc nothrow {
		return Entries.equal(a, b);
	}

	/// Builds it; a refused allocation fails the query, as `doir.query.fail` does.
	///
	/// Examples:
	/// ---
	/// static import ecrs.context;
	/// static import fp.dynarray;
	/// static import doir.query;
	/// static import doir.source;
	/// static import doir.strings;
	/// auto store = ecrs.context.create();
	/// scope(exit) ecrs.context.free(store);
	/// auto engine = doir.query.create(store);
	/// scope(exit) doir.query.free(engine);
	/// doir.strings.Strings strings;
	/// scope(exit) doir.strings.free(strings);
	/// engine.strings = &strings;
	/// immutable file = doir.source.addFile(engine, strings, "a.doir");
	/// assert(doir.source.commit(engine, strings, file, "x : T = 1\n_ : T = 2\n") == 0);
	/// auto entries = doir.query.query!EntriesByName(engine, EntriesByName.Key([doir.source.rootOf(engine, file)]));
	/// assert(fp.dynarray.length(entries.related) == 1); // `_` has no name
	/// ---
	static Entries compute(ref doir.query.QueryEngine engine, Key key) @nogc nothrow @trusted {
		immutable block = key.related[0];
		Entries out_;
		if (!doir.query.read(engine, block)) return out_;
		auto b = ecrs.context.findComponent!(doir.components.ast.Block)(*engine.store, block);
		if (b is null) return out_;
		Named* named = null;
		scope(exit) fp.dynarray.free(named);
		foreach (i, e; fp.dynarray.slice(b.related)) {
			immutable name = nameOf(engine, e);
			if (name != doir.strings.unnamed && !fp.dynarray.pushBack(named, Named(name, cast(uint) i, e))) {
				doir.query.fail(engine);
				return out_;
			}
		}
		immutable n = fp.dynarray.length(named);
		if (n == 0) return out_;
		std.algorithm.sorting.sort!((ref a, ref b) => a.name.value != b.name.value ? a.name.value < b.name.value : a.index < b.index)(named[0 .. n]);
		if (fp.dynarray.reserve(out_.related, n) is null) {
			doir.query.fail(engine);
			return out_;
		}
		foreach (i, ref entry; fp.dynarray.slice(named))
			if (i + 1 == n || named[i + 1].name != entry.name) cast(void) fp.dynarray.pushBack(out_.related, entry.e); // reserved
		return out_;
	}
}

/// The entry of `block` named `name`, found through the block's `EntriesByName`, so the running query depends on the index rather than on the block.
/// `invalidEntity` if none is, or if the index could not be built, which fails the running queries (`doir.query.fail`).
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.query;
/// static import doir.source;
/// static import doir.strings;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.query.create(store);
/// scope(exit) doir.query.free(engine);
/// doir.strings.Strings strings;
/// scope(exit) doir.strings.free(strings);
/// engine.strings = &strings;
/// immutable file = doir.source.addFile(engine, strings, "a.doir");
/// assert(doir.source.commit(engine, strings, file, "x : T = 1\n") == 0);
/// assert(entryNamed(engine, doir.source.rootOf(engine, file), doir.strings.intern(strings, "z")) == invalidEntity);
/// ---
EntityId entryNamed(ref doir.query.QueryEngine engine, EntityId block, doir.strings.StringId name) {
	if (name == doir.strings.unnamed) return invalidEntity;
	auto entries = doir.query.query!EntriesByName(engine, EntriesByName.Key([block]));
	if (entries is null) return invalidEntity;
	auto sorted = fp.dynarray.slice(entries.related);
	size_t low = 0, high = sorted.length;
	while (low < high) {
		immutable middle = (low + high) / 2;
		if (nameOf(engine, sorted[middle]).value < name.value) low = middle + 1;
		else high = middle;
	}
	return low < sorted.length && nameOf(engine, sorted[low]) == name ? sorted[low] : invalidEntity;
}


unittest { // the last entry of a name wins; an edit that replaces only `_` entries leaves the index's ChangedAt alone
	static import doir.components.query;
	static import doir.query;
	static import doir.source;
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	auto engine = doir.query.create(store);
	scope(exit) doir.query.free(engine);
	doir.strings.Strings strings;
	scope(exit) doir.strings.free(strings);
	engine.strings = &strings;
	immutable file = doir.source.addFile(engine, strings, "a.doir");
	assert(doir.source.commit(engine, strings, file, "b : T = 1\n_ : T = 2\na : T = 3\nb : T = 4\n") == 0);
	immutable root = doir.source.rootOf(engine, file);
	auto entries = ecrs.context.getComponent!(doir.components.ast.Block)(store, root).related;
	assert(entryNamed(engine, root, doir.strings.intern(strings, "a")) == entries[2]);
	assert(entryNamed(engine, root, doir.strings.intern(strings, "b")) == entries[3]);
	assert(entryNamed(engine, root, doir.strings.intern(strings, "c")) == invalidEntity);
	assert(entryNamed(engine, root, doir.strings.unnamed) == invalidEntity);
	immutable index = doir.query.find!EntriesByName(engine, EntriesByName.Key([root]));
	immutable changed = ecrs.context.getComponent!(doir.components.query.ChangedAt)(store, index).revision;
	assert(doir.source.commit(engine, strings, file, "b : T = 1\n_ : T = 5\na : T = 3\nb : T = 4\n") == 0);
	assert(entryNamed(engine, root, doir.strings.intern(strings, "a")) == entries[2]);
	assert(ecrs.context.getComponent!(doir.components.query.ChangedAt)(store, index).revision == changed);
	assert(doir.source.commit(engine, strings, file, "b : T = 1\n_ : T = 5\nc : T = 3\nb : T = 4\n") == 0);
	assert(entryNamed(engine, root, doir.strings.intern(strings, "a")) == invalidEntity);
	assert(entryNamed(engine, root, doir.strings.intern(strings, "c")) != invalidEntity);
	assert(ecrs.context.getComponent!(doir.components.query.ChangedAt)(store, index).revision != changed);

	// A refused allocation fails the index, which the next demand builds.
	static import fp.testing;
	for (size_t budget = 0;; ++budget) {
		auto rationedStore = ecrs.context.create();
		scope(exit) ecrs.context.free(rationedStore);
		auto rationed = doir.query.create(rationedStore);
		scope(exit) doir.query.free(rationed);
		rationed.strings = &strings;
		immutable rationedFile = doir.source.addFile(rationed, strings, "r.doir");
		assert(doir.source.commit(rationed, strings, rationedFile, "b : T = 1\n_ : T = 2\na : T = 3\nb : T = 4\nc : T = 5\nd : T = 6\ne : T = 7\nf : T = 8\ng : T = 9\n") == 0);
		immutable rationedRoot = doir.source.rootOf(rationed, rationedFile);
		auto allocator = fp.testing.limitAllocations(budget);
		auto built = doir.query.query!EntriesByName(rationed, EntriesByName.Key([rationedRoot]));
		fp.testing.restoreAllocator(allocator);
		if (built is null) {
			assert(rationed.refused);
			rationed.refused = false;
			assert(entryNamed(rationed, rationedRoot, doir.strings.intern(strings, "g")) != invalidEntity);
			continue;
		}
		assert(fp.dynarray.length(built.related) == 7);
		break;
	}
}
