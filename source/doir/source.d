/// Source files and the input commit (`roadmap.md` Phase 2): parsing is not a memoized query but an input, as a Salsa input or a rustc `eval_always` query is. `commit` reparses a file, matches its declarations against the previous parse, builds only those that are new or changed, and sets `ChangedAt` on what changed. Parsed entities belong to no query's `Produces` list, so no re-run removes them.
///
/// Matching keeps entity ids, so memos keyed by unchanged declarations stay valid. A named declaration's key is its name path with its occurrence index among same-named siblings (`R-Merge` reopens a namespace that way), stored as a `PathHash`; unnamed `_` declarations are aligned by their hashes, which leave out trivia and nested declarations. A declaration whose key and hash match keeps its entity and components; one whose key matches but whose hash differs keeps its entity, is rebuilt, and is marked changed; an unmatched one is new, and old ones left unmatched are removed. A block that gains, loses or reorders an entry is marked changed too, so lookups through it re-run (`R-Shadow`). Because matched declarations are written into their old entities, no renumbering is needed (`E-Remap`).
///
/// Each declaration gets its lexical position, an order key: a matched one keeps its key where the keys stay in order, and any other gets a key between its neighbours (`C-Order`, `M-Lexical`). Spans and locations are untracked: moving text rewrites them and marks nothing changed but the file, whose text only `AT-Source` reads depend on.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.strings;
/// static import doir.query;
/// static import doir.components.ast;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.query.create(store);
/// scope(exit) doir.query.free(engine);
/// doir.strings.Strings strings;
/// scope(exit) doir.strings.free(strings);
/// immutable file = addFile(engine, strings, "a.doir");
/// assert(commit(engine, strings, file, "x : std.u8 = 5\n") == 0);
/// immutable x = ecrs.context.getComponent!(doir.components.ast.Block)(store, rootOf(engine, file)).related[0];
/// assert(commit(engine, strings, file, "// moved\nx : std.u8 = 5\n") == 0);
/// assert(ecrs.context.getComponent!(doir.components.ast.Block)(store, rootOf(engine, file)).related[0] == x);
/// ---
module doir.source;

static import core.stdc.stdlib;
static import std.typecons;

static import fp.dynarray;
static import fp.hash;
static import fp.hashtable;
static import fp.pointer;
static import fp.rope;
static import fp.string;
version(unittest) static import fp.file;
version(unittest) static import fp.testing;

static import bc.threadpool;
static import diagnose;
static import ecrs.context;
static import ecrs.registry;
static import ecrs.relation;
static import ecrs.storage;

static import doir.strings;
static import doir.components.ast;
static import doir.components.query;
static import doir.components.source;
static import doir.engine.positions;
static import doir.query;
static import doir.engine.locations;
static import doir.syntax.lexer;
static import doir.syntax.parser;

public import ecrs.registry : EntityId, invalidEntity;
public import doir.engine.positions : Position;

@nogc nothrow:


// --- files -------------------------------------------------------------------

/// A new input entity for the file at `path`, with no text until its first `commit`.
///
/// Returns `invalidEntity` if allocation fails, leaving the store as it was. No store transaction may be open: it runs in one of its own.
///
/// Examples:
/// ---
/// static import doir.components.source;
/// static import ecrs.context;
/// static import doir.strings;
/// static import doir.query;
/// static import doir.imports;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.query.create(store);
/// scope(exit) doir.query.free(engine);
/// doir.strings.Strings strings;
/// scope(exit) doir.strings.free(strings);
/// immutable file = addFile(engine, strings, "a.doir");
/// assert(doir.strings.text(strings, ecrs.context.getComponent!(doir.components.source.SourceFile)(store, file).path) == "a.doir");
/// ---
EntityId addFile(ref doir.query.QueryEngine engine, ref doir.strings.Strings strings, const(char)[] path) {
	// Index lists run to an entity's highest component id, so what most parsed entities hold, `Dependents` included, takes the lowest ids; refused registration repeats later.
	static foreach (C; imported!"std.meta".AliasSeq!(doir.components.query.ChangedAt, doir.components.query.Dependents, doir.components.source.SourceSpan, doir.components.ast.Parent, doir.components.ast.LookupTypeOf, doir.components.ast.Name, doir.components.source.LexicalPosition, doir.components.source.SyntaxHash, doir.components.ast.Flags, doir.components.source.PathHash, doir.components.ast.LookupCall, doir.components.ast.LookupFunctionInputs, doir.components.ast.TypeDefinition, doir.components.ast.FunctionInputs, doir.components.ast.LookupFunctionReturn, doir.components.source.ParsedParts, doir.components.ast.Block, doir.components.ast.TypeOf))
		cast(void) ecrs.registry.componentId!C();
	immutable id = doir.strings.intern(strings, path);
	if (id == doir.strings.noName) return invalidEntity;
	// A transaction, because removing the entity after a refusal would still leave its id on the freelist.
	ecrs.context.beginTransaction(*engine.store);
	immutable e = ecrs.context.addEntity(*engine.store);
	if (e != invalidEntity && ecrs.context.setComponent!(doir.components.source.SourceFile)(*engine.store, e, doir.components.source.SourceFile(id))) {
		ecrs.context.commitTransaction(*engine.store);
		return e;
	}
	ecrs.context.rollbackTransaction(*engine.store);
	return invalidEntity;
}

/// `file`'s root block, or `invalidEntity` before its first commit.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.strings;
/// static import doir.query;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.query.create(store);
/// scope(exit) doir.query.free(engine);
/// doir.strings.Strings strings;
/// scope(exit) doir.strings.free(strings);
/// immutable file = addFile(engine, strings, "a.doir");
/// assert(rootOf(engine, file) == invalidEntity);
/// ---
EntityId rootOf(ref doir.query.QueryEngine engine, EntityId file) {
	auto root = ecrs.context.findComponent!(doir.components.source.FileRoot)(*engine.store, file);
	return root is null ? invalidEntity : root.root;
}

/// `file`'s text as of its last commit, borrowed: it stays valid until the next commit of `file`, and `fp.rope.share` keeps it longer. Empty before the first commit.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.strings;
/// static import doir.query;
/// static import fp.rope;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.query.create(store);
/// scope(exit) doir.query.free(engine);
/// doir.strings.Strings strings;
/// scope(exit) doir.strings.free(strings);
/// immutable file = addFile(engine, strings, "a.doir");
/// cast(void) commit(engine, strings, file, "x : T\n");
/// assert(fp.rope.length(textOf(engine, file)) == 6 && fp.rope.equal(textOf(engine, file), 0, "x : T\n"));
/// ---
fp.rope.Rope textOf(ref doir.query.QueryEngine engine, EntityId file) {
	auto source = ecrs.context.findComponent!(doir.components.source.SourceText)(*engine.store, file);
	return source is null ? fp.rope.Rope.init : source.text;
}


// --- the commit --------------------------------------------------------------

// The state of one commit. It runs in a store transaction, so slices of components it removes or replaces stay valid until it ends.
private struct Commit {
	doir.query.QueryEngine* engine;
	ecrs.context.Context* store;
	doir.strings.Strings* strings;
	doir.syntax.parser.Syntax* syntax;
	const(char)[] file; // the new text whole, for a whole-file commit
	const(char)[] text; // what `syntax` was skimmed from: the file, a chunk of it, or one declaration
	fp.rope.Rope oldText; // borrowed from the `SourceText` the commit replaces
	bool hadText;
	const(char)[] path;
	size_t base; // where `text` starts in the file
	Owned* owned; // each syntax error with the record whose block holds it, ordered by record; an fp dynarray
	doir.syntax.parser.Description* described; // descriptions of `describedSyntax`'s records, made on workers, which `rebuild` applies; an fp dynarray
	const(doir.syntax.parser.Syntax)* describedSyntax;
	Deferred* deferred; // rebuilds `commitRecord` leaves to workers, while it is collecting them; an fp dynarray
	bool deferring;
}

// A rebuild `commitRecord` leaves for a worker, which also writes what the rebuild would clear: `entity`'s name, parent and block, and its change marks.
private struct Deferred {
	size_t record;
	EntityId entity, block;
	doir.strings.StringId name;
	bool mark;
	EntityId* fresh; // part entities made for it on the commit's thread, beyond its old ones; an fp dynarray
	EntityId* leftover; // old parts it no longer uses, which the commit's thread removes; an fp dynarray
}

// A block's contents are skimmed in chunks of about this many bytes, so a whole-file commit never holds the whole file's tokens and records; tests make it small.
private __gshared size_t chunkBytes = 1 << 18;

// Whether rebuilds run on workers under libECRS's concurrent writes. Off: on the million-line file it measured slower than applying on the commit's thread (1.47 against 1.27 s), the storages it prepares and the interning workers share costing more than the writes it spreads; the tests turn it on.
private __gshared bool deferBuilds = false;

// A syntax error and the record whose block holds it directly, `rootOwner` for the root.
private struct Owned {
	uint owner;
	uint error;
}

private enum uint rootOwner = uint.max;

// Removes `e`, first marking stale the queries that read it, since its id may be handed out again. False on refusal.
private bool remove(ref Commit c, EntityId e) {
	doir.query.invalidate(*c.engine, e);
	return ecrs.context.removeEntity(*c.store, e);
}

// Removes `e`, its parts and everything nested in it. Returns false on refusal, partway; the commit's transaction undoes it.
private bool removeTree(ref Commit c, EntityId e) {
	if (auto block = ecrs.context.findComponent!(doir.components.ast.Block)(*c.store, e))
		foreach (child; fp.dynarray.slice(block.related))
			if (!removeTree(c, child)) return false;
	if (auto parts = ecrs.context.findComponent!(doir.components.source.ParsedParts)(*c.store, e))
		foreach (part; fp.dynarray.slice(parts.related))
			if (!remove(c, part)) return false;
	return remove(c, e);
}

// Builds record `r` into `e`, reusing its old parts in order, then `fresh`, and removing the old ones left over, or, with `leftover`, appending them there for the caller to remove. A deferred rebuild passes both, since a worker may not remove entities. Returns false on refusal.
private bool rebuild(ref Commit c, size_t r, EntityId e, const(EntityId)[] fresh = null, EntityId** leftover = null) {
	const(EntityId)[] old = null;
	if (auto parts = ecrs.context.findComponent!(doir.components.source.ParsedParts)(*c.store, e)) {
		old = fp.dynarray.slice(parts.related);
		if (!ecrs.context.removeComponent!(doir.components.source.ParsedParts)(*c.store, e)) return false;
	}
	if (!doir.syntax.parser.removeParsed(*c.store, e)) return false;
	foreach (part; old)
		if (!doir.syntax.parser.removeParsed(*c.store, part)) return false;

	EntityId* reuse = null;
	scope(exit) fp.dynarray.free(reuse);
	if (fresh.length && (!fp.dynarray.concatenate(reuse, old) || !fp.dynarray.concatenate(reuse, fresh))) return false;
	auto b = doir.syntax.parser.Builder(c.store, c.strings, e, fresh.length ? fp.dynarray.slice(reuse) : old);
	doir.components.source.ParsedParts built;
	scope(exit) built.finalize();
	immutable ok = c.described !is null && c.describedSyntax is c.syntax ? doir.syntax.parser.apply(c.described[r], b) : doir.syntax.parser.build(*c.syntax, c.text, r, b);
	built.related = b.parts;
	if (!ok) return false;
	immutable used = fp.dynarray.length(b.parts) < old.length ? fp.dynarray.length(b.parts) : old.length;
	foreach (part; old[used .. $])
		if (leftover !is null ? !fp.dynarray.pushBack(*leftover, part) : !remove(c, part)) return false;
	if (b.annotated && !ecrs.context.setComponent!(doir.components.source.SourceAnnotation)(*c.store, e, doir.components.source.SourceAnnotation(b.annotation))) return false;
	if (built.related is null) return true;
	auto moved = built;
	built.related = null;
	return ecrs.context.setComponent!(doir.components.source.ParsedParts)(*c.store, e, moved);
}

private enum size_t maxEdits = 1024;

// Myers' alignment of `x` and `y`, which start at `offset` in the whole sequences: appends their common pairs, none past `maxEdits` edits. False on refusal.
private bool alignMiddle(const(ulong)[] x, const(ulong)[] y, size_t offset, ref size_t[2]* pairs) {
	immutable n = cast(long) x.length, m = cast(long) y.length;
	if (n == 0 || m == 0) return true;

	immutable max = n + m, width = 2 * max + 1;
	long* v = null, trace = null;
	scope(exit) { fp.dynarray.free(v); fp.dynarray.free(trace); }
	foreach (i; 0 .. width)
		if (!fp.dynarray.pushBack(v, 0L)) return false;
	long found = -1;
	for (long d = 0; d <= max && d <= cast(long) maxEdits; ++d) {
		if (!fp.dynarray.concatenate(trace, fp.dynarray.slice(v))) return false;
		for (long k = -d; k <= d; k += 2) {
			long px = (k == -d || (k != d && v[k - 1 + max] < v[k + 1 + max])) ? v[k + 1 + max] : v[k - 1 + max] + 1;
			long py = px - k;
			while (px < n && py < m && x[px] == y[py]) { ++px; ++py; }
			v[k + max] = px;
			if (px >= n && py >= m) { found = d; break; }
		}
		if (found >= 0) break;
	}
	if (found < 0) return true;

	size_t[2]* middle = null;
	scope(exit) fp.dynarray.free(middle);
	long px = n, py = m;
	for (long d = found; d >= 0; --d) {
		auto vd = trace[d * width .. (d + 1) * width];
		immutable k = px - py;
		immutable prevK = (k == -d || (k != d && vd[k - 1 + max] < vd[k + 1 + max])) ? k + 1 : k - 1;
		immutable prevX = vd[prevK + max], prevY = prevX - prevK;
		while (px > prevX && py > prevY) {
			--px; --py;
			if (!fp.dynarray.pushBack(middle, cast(size_t[2]) [offset + px, offset + py])) return false;
		}
		px = prevX;
		py = prevY;
	}
	foreach_reverse (pair; fp.dynarray.slice(middle))
		if (!fp.dynarray.pushBack(pairs, pair)) return false;
	return true;
}

// Appends the index pairs of a longest common subsequence of `a` and `b`, giving up on the middle past `maxEdits` edits. False on refusal.
private bool align_(const(ulong)[] a, const(ulong)[] b, ref size_t[2]* pairs) {
	size_t prefix = 0;
	for (; prefix < a.length && prefix < b.length && a[prefix] == b[prefix]; ++prefix)
		if (!fp.dynarray.pushBack(pairs, cast(size_t[2]) [prefix, prefix])) return false;
	size_t suffix = 0;
	while (suffix < a.length - prefix && suffix < b.length - prefix && a[$ - 1 - suffix] == b[$ - 1 - suffix]) ++suffix;
	if (!alignMiddle(a[prefix .. $ - suffix], b[prefix .. $ - suffix], prefix, pairs)) return false;
	foreach (s; 0 .. suffix)
		if (!fp.dynarray.pushBack(pairs, cast(size_t[2]) [a.length - suffix + s, b.length - suffix + s])) return false;
	return true;
}

private struct Keyed {
	ulong key;
	EntityId e;
}

private size_t hashKeyed(inout(ubyte)[] bytes) @trusted { return cast(size_t) (cast(const(Keyed)*) bytes.ptr).key; }
private bool equalKeyed(inout(ubyte)[] a, inout(ubyte)[] b) @trusted { return (cast(const(Keyed)*) a.ptr).key == (cast(const(Keyed)*) b.ptr).key; }

// An empty table of `Keyed` by key, or null on refusal.
private Keyed* keyedTable() {
	fp.hashtable.Config config;
	config.hashFunction = &hashKeyed;
	config.equalFunction = &equalKeyed;
	return fp.hashtable.create!Keyed(config);
}

// The old entities a block's new entries match, or `invalidEntity`: each entry is its name, `noName` for `_`, and its hash. False on refusal.
private bool match(ref Commit c, const(EntityId)[] old, const(doir.strings.StringId)[] names, const(ulong)[] hashes, ulong parentPath, EntityId* matched, ulong* paths) {
	auto byPath = keyedTable();
	if (byPath is null) return false;
	scope(exit) fp.hashtable.free(byPath);
	foreach (e; old)
		if (auto path = ecrs.context.findComponent!(doir.components.source.PathHash)(*c.store, e))
			if (fp.hashtable.insert(byPath, Keyed(path.value, e)) is null) return false;

	// Named: the name path, with the occurrence index among same-named siblings.
	auto occurrences = keyedTable();
	if (occurrences is null) return false;
	scope(exit) fp.hashtable.free(occurrences);
	foreach (i, name; names) {
		matched[i] = invalidEntity;
		paths[i] = 0;
		if (name == doir.strings.noName) continue;
		immutable nameHash = fp.hash.murmur(cast(const(ubyte)[]) doir.strings.text(*c.strings, name));
		auto seen = fp.hashtable.find(occurrences, Keyed(nameHash));
		immutable occurrence = seen is null ? 0 : seen.e + 1;
		if (seen is null) {
			if (fp.hashtable.insert(occurrences, Keyed(nameHash, 0)) is null) return false;
		} else seen.e = occurrence;
		paths[i] = fp.hash.mix(fp.hash.mix(parentPath, nameHash), occurrence);
		auto found = fp.hashtable.find(byPath, Keyed(paths[i]));
		if (found is null) continue;
		auto oldName = ecrs.context.findComponent!(doir.components.ast.Name)(*c.store, found.e);
		if (oldName !is null && oldName.value == name) {
			matched[i] = found.e;
			fp.hashtable.remove(byPath, Keyed(paths[i]));
		}
	}

	// Unnamed: aligned by hash.
	ulong* oldHashes = null, newHashes = null;
	EntityId* oldUnnamed = null;
	size_t* newIndex = null;
	size_t[2]* pairs = null;
	scope(exit) { fp.dynarray.free(oldHashes); fp.dynarray.free(newHashes); fp.dynarray.free(oldUnnamed); fp.dynarray.free(newIndex); fp.dynarray.free(pairs); }
	foreach (e; old) {
		if (ecrs.context.hasComponent!(doir.components.source.PathHash)(*c.store, e)) continue;
		if (!fp.dynarray.pushBack(oldUnnamed, e) || !fp.dynarray.pushBack(oldHashes, ecrs.context.getComponent!(doir.components.source.SyntaxHash)(*c.store, e).value)) return false;
	}
	foreach (i, name; names) {
		if (name != doir.strings.noName) continue;
		if (!fp.dynarray.pushBack(newIndex, i) || !fp.dynarray.pushBack(newHashes, hashes[i])) return false;
	}
	if (!align_(fp.dynarray.slice(oldHashes), fp.dynarray.slice(newHashes), pairs)) return false;
	foreach (pair; fp.dynarray.slice(pairs)) matched[newIndex[pair[1]]] = oldUnnamed[pair[0]];
	return true;
}

// Order keys for a block's new entries: matched ones keep theirs along a longest increasing run, the rest go between neighbours. False on refusal.
private bool assignPositions(ref Commit c, Position parent, const(EntityId)[] matched, bool rekey, Position* out_) {
	immutable n = matched.length;
	Position* old = null;
	size_t* tails = null, previous = null;
	bool* keep = null;
	scope(exit) { fp.dynarray.free(old); fp.dynarray.free(tails); fp.dynarray.free(previous); fp.dynarray.free(keep); }
	foreach (i; 0 .. n) {
		auto at = matched[i] == invalidEntity || rekey ? null : ecrs.context.findComponent!(doir.components.source.LexicalPosition)(*c.store, matched[i]);
		if (!fp.dynarray.pushBack(old, at is null ? doir.engine.positions.none : at.at)
			|| !fp.dynarray.pushBack(previous, size_t.max)
			|| !fp.dynarray.pushBack(keep, false))
			return false;
	}
	foreach (i; 0 .. n) {
		if (old[i] == doir.engine.positions.none) continue;
		size_t lo = 0, hi = fp.dynarray.length(tails);
		while (lo < hi) {
			immutable mid = (lo + hi) / 2;
			if (doir.engine.positions.precedes(c.engine.positions, old[tails[mid]], old[i])) lo = mid + 1;
			else hi = mid;
		}
		if (lo > 0) previous[i] = tails[lo - 1];
		if (lo == fp.dynarray.length(tails)) {
			if (!fp.dynarray.pushBack(tails, i)) return false;
		} else tails[lo] = i;
	}
	if (fp.dynarray.length(tails))
		for (size_t i = tails[fp.dynarray.length(tails) - 1]; i != size_t.max; i = previous[i]) keep[i] = true;

	Position before = doir.engine.positions.none;
	foreach (i; 0 .. n) {
		if (keep[i]) {
			out_[i] = before = old[i];
			continue;
		}
		Position after = doir.engine.positions.none;
		foreach (j; i + 1 .. n) if (keep[j]) { after = old[j]; break; }
		out_[i] = before = doir.engine.positions.between(c.engine.positions, parent, before, after);
		if (before == doir.engine.positions.none) return false;
	}
	return true;
}

// Whether `e`'s old text, starting at `oldStart`, equals `record`'s up to `end`; `whole` also requires the same length.
private bool sameText(ref Commit c, size_t oldStart, uint oldLength, ref const doir.syntax.parser.Record record, size_t end, bool whole) {
	immutable length = end - record.spanStart;
	if (!c.hadText || (whole && length != oldLength) || length > oldLength) return false;
	return fp.rope.equal(c.oldText, oldStart, c.text[record.spanStart .. end]);
}

// --- syntax errors -----------------------------------------------------------

private extern(C) int compareOwned(const(void)* a, const(void)* b) {
	auto x = cast(const(Owned)*) a, y = cast(const(Owned)*) b;
	if (x.owner != y.owner) return x.owner < y.owner ? -1 : 1;
	return x.error < y.error ? -1 : x.error > y.error;
}

// Fills `c.owned`: each error's innermost record whose block holds its token, the closing brace included, ordered by that record. False on refusal.
private bool assignErrors(ref Commit c) @trusted {
	auto records = fp.dynarray.slice(c.syntax.records);
	auto errors = fp.dynarray.slice(c.syntax.errors);
	if (errors.length == 0) return true;
	uint* parents = null;
	uint* open = null;
	scope(exit) { fp.dynarray.free(parents); fp.dynarray.free(open); }
	if (records.length && fp.dynarray.growToSize(parents, records.length) is null) return false;
	foreach (r, record; records) {
		while (fp.dynarray.length(open) && records[open[fp.dynarray.length(open) - 1]].end <= r) cast(void) fp.dynarray.popBack(open);
		parents[r] = fp.dynarray.length(open) ? open[fp.dynarray.length(open) - 1] : rootOwner;
		if (!fp.dynarray.pushBack(open, cast(uint) r)) return false;
	}
	if (fp.dynarray.growToSize(c.owned, errors.length) is null) return false;
	foreach (i, error; errors) {
		// The last record starting at or before the token, then out through its parents to one whose block holds it.
		size_t lo = 0, hi = records.length;
		while (lo < hi) {
			immutable mid = (lo + hi) / 2;
			if (records[mid].first <= error.token) lo = mid + 1;
			else hi = mid;
		}
		uint r = lo == 0 ? rootOwner : cast(uint) (lo - 1);
		while (r != rootOwner && !(records[r].blockOpen != doir.syntax.parser.noToken && records[r].blockOpen < error.token && error.token <= records[r].blockClose))
			r = parents[r];
		c.owned[i] = Owned(r, cast(uint) i);
	}
	core.stdc.stdlib.qsort(c.owned, errors.length, Owned.sizeof, &compareOwned);
	return true;
}

// Appends to `list` the errors of `owner`'s block in `c.syntax`, offsets taken from `holderStart` in the file. False on refusal.
private bool gatherErrors(ref Commit c, uint owner, size_t holderStart, ref doir.components.source.SyntaxErrors list) {
	auto owned = fp.dynarray.slice(c.owned);
	size_t lo = 0, hi = owned.length;
	while (lo < hi) {
		immutable mid = (lo + hi) / 2;
		if (owned[mid].owner < owner) lo = mid + 1;
		else hi = mid;
	}
	size_t end = lo;
	while (end < owned.length && owned[end].owner == owner) ++end;
	foreach (o; owned[lo .. end]) {
		immutable error = c.syntax.errors[o.error];
		assert(c.base + error.at >= holderStart);
		doir.components.source.StoredError stored;
		stored.at = cast(uint) (c.base + error.at - holderStart);
		immutable open = doir.syntax.parser.opening(*c.syntax, error);
		if (open != fp.pointer.notFound) stored.opening = cast(uint) (c.base + open - holderStart);
		stored.message = doir.syntax.parser.describe(*c.syntax, c.text, error);
		stored.hint = doir.syntax.parser.hint(*c.syntax, c.text, error);
		stored.note = doir.syntax.parser.explain(*c.syntax, c.text, error);
		stored.fixes = doir.syntax.parser.fixes(*c.syntax, c.text, error);
		if (stored.message is null || stored.hint is null || stored.note is null || !fp.dynarray.pushBack(list.errors, stored)) {
			fp.string.free(stored.message);
			fp.string.free(stored.hint);
			fp.string.free(stored.note);
			return false;
		}
	}
	return true;
}

// Makes `list`, which it takes over, `e`'s `SyntaxErrors`, or removes the component if `list` is empty. False on refusal.
private bool setErrors(ref Commit c, EntityId e, ref doir.components.source.SyntaxErrors list) {
	if (fp.dynarray.length(list.errors) == 0) {
		list.finalize();
		return !ecrs.context.hasComponent!(doir.components.source.SyntaxErrors)(*c.store, e) || ecrs.context.removeComponent!(doir.components.source.SyntaxErrors)(*c.store, e);
	}
	auto moved = list;
	list.errors = null;
	return ecrs.context.setComponent!(doir.components.source.SyntaxErrors)(*c.store, e, moved);
}

// Replaces `e`'s `SyntaxErrors` with those of `owner`'s block in `c.syntax`, offsets taken from `holderStart` in the file, removing the component if there are none. False on refusal.
private bool storeErrors(ref Commit c, uint owner, EntityId e, size_t holderStart) {
	doir.components.source.SyntaxErrors list;
	scope(exit) list.finalize();
	return gatherErrors(c, owner, holderStart, list) && setErrors(c, e, list);
}

// Moves `holder`'s errors at or after `from`, bytes from its start, by `delta`, writing a copy so a rollback restores them. False on refusal.
private bool shiftErrors(ref Commit c, EntityId holder, size_t from, ptrdiff_t delta) {
	auto held = ecrs.context.findComponent!(doir.components.source.SyntaxErrors)(*c.store, holder);
	if (held is null) return true;
	doir.components.source.SyntaxErrors list;
	scope(exit) list.finalize();
	foreach (error; fp.dynarray.slice(held.errors)) {
		doir.components.source.StoredError copy = error;
		if (copy.at >= from) copy.at = cast(uint) (copy.at + delta);
		if (copy.opening != doir.components.source.noOpening && copy.opening >= from) copy.opening = cast(uint) (copy.opening + delta);
		copy.message = fp.string.makeDynamic(fp.string.slice(error.message));
		copy.hint = fp.string.makeDynamic(fp.string.slice(error.hint));
		copy.note = fp.string.makeDynamic(fp.string.slice(error.note));
		if (copy.message is null || copy.hint is null || copy.note is null || !fp.dynarray.pushBack(list.errors, copy)) {
			fp.string.free(copy.message);
			fp.string.free(copy.hint);
			fp.string.free(copy.note);
			return false;
		}
	}
	auto moved = list;
	list.errors = null;
	return ecrs.context.setComponent!(doir.components.source.SyntaxErrors)(*c.store, holder, moved);
}


// --- the commit, continued ---------------------------------------------------

// Queues record `r`'s rebuild into `e`, an entry of `block` named `name`, for a worker, first making on this thread the part entities its description needs beyond `e`'s old ones. False on refusal.
private bool defer(ref Commit c, size_t r, EntityId e, EntityId block, doir.strings.StringId name) {
	auto old = ecrs.context.findComponent!(doir.components.source.ParsedParts)(*c.store, e);
	immutable have = old is null ? 0 : fp.dynarray.length(old.related);
	Deferred d = Deferred(r, e, block, name);
	foreach (i; have .. c.described[r].parts) {
		immutable part = ecrs.context.addEntity(*c.store);
		if (part == invalidEntity || !fp.dynarray.pushBack(d.fresh, part)) {
			fp.dynarray.free(d.fresh);
			return false;
		}
	}
	if (fp.dynarray.pushBack(c.deferred, d)) return true;
	fp.dynarray.free(d.fresh);
	return false;
}

// Runs `d` on a worker: the rebuild, then what it cleared. False on refusal.
private bool runDeferred(ref Commit c, ref Deferred d) {
	auto store = c.store;
	doir.components.ast.Block list;
	// Only a declaration that still has a block keeps the list its contents wrote; a rebuild clears any other.
	auto block = c.syntax.records[d.record].blockOpen == doir.syntax.parser.noToken ? null : ecrs.context.findComponent!(doir.components.ast.Block)(*store, d.entity);
	if (block !is null) {
		list.related = fp.dynarray.clone(block.related);
		if (list.related is null && fp.dynarray.length(block.related)) return false;
	}
	if (!rebuild(c, d.record, d.entity, fp.dynarray.slice(d.fresh), &d.leftover)
		|| (d.name != doir.strings.noName && !ecrs.context.setComponent!(doir.components.ast.Name)(*store, d.entity, doir.components.ast.Name(d.name)))
		|| !ecrs.context.setComponent!(doir.components.ast.Parent)(*store, d.entity, doir.components.ast.Parent([d.block]))) {
		fp.dynarray.free(list.related);
		return false;
	}
	if (block !is null && !ecrs.context.setComponent!(doir.components.ast.Block)(*store, d.entity, list)) return false;
	return !d.mark || markChanged(c, d.entity);
}

// A worker's share of the deferred rebuilds.
private struct DeferredJob {
	Commit* commit;
	Deferred[] deferred;
	bool ok;
}

private void deferredJob(void* arg) @trusted {
	auto job = cast(DeferredJob*) arg;
	job.ok = true;
	foreach (ref d; job.deferred)
		if (!runDeferred(*job.commit, d)) {
			job.ok = false;
			return;
		}
}

// Runs the rebuilds `commitRecord` deferred, split among the workers, writing the store concurrently, then removes the old parts they left over and empties the queue. False on refusal.
private bool flushDeferred(ref Commit c) @trusted {
	auto all = fp.dynarray.slice(c.deferred);
	scope(exit) {
		foreach (ref d; all) {
			fp.dynarray.free(d.fresh);
			fp.dynarray.free(d.leftover);
		}
		fp.dynarray.clear(c.deferred);
	}
	if (all.length == 0) return true;
	// Each entity a rebuild writes gains each component at most once, so that many slots per storage are made beforehand.
	size_t entities = 0;
	foreach (ref d; all) entities += 1 + c.described[d.record].parts;
	static foreach (C; imported!"std.meta".AliasSeq!(doir.syntax.parser.ParsedComponents, doir.components.source.ParsedParts, doir.components.source.SourceSpan, doir.components.query.ChangedAt))
		if (!ecrs.context.prepareConcurrentAdds!C(*c.store, entities)) return false;
	auto pool = c.engine.workers;
	immutable workers = bc.threadpool.workerCount(pool);
	immutable share = (all.length + workers - 1) / workers;
	DeferredJob* jobs = null;
	bc.threadpool.Job* work = null;
	scope(exit) { fp.dynarray.free(jobs); fp.dynarray.free(work); }
	for (size_t from = 0; from < all.length; from += share)
		if (!fp.dynarray.pushBack(jobs, DeferredJob(&c, all[from .. from + share < all.length ? from + share : all.length]))) return false;
	foreach (ref job; fp.dynarray.slice(jobs))
		if (!fp.dynarray.pushBack(work, bc.threadpool.Job(&deferredJob, &job))) return false;
	ecrs.context.beginConcurrentWrites(*c.store);
	immutable ran = bc.threadpool.run(pool, fp.dynarray.slice(work));
	ecrs.context.endConcurrentWrites(*c.store);
	if (!ran) return false;
	foreach (ref job; fp.dynarray.slice(jobs)) if (!job.ok) return false;
	foreach (ref d; all)
		foreach (part; fp.dynarray.slice(d.leftover))
			if (!remove(c, part)) return false;
	return true;
}

// Writes record `r` of `c.syntax`, an entry of `block`, into `e`, the old entity it matched or `invalidEntity`, with name path `path` and order key `key`, recursing into its block; `parentStart` is `block`'s start in the file and `oldBase` its old start. Appends the entity to `entries`. False on refusal.
private bool commitRecord(ref Commit c, EntityId block, size_t r, EntityId e, ulong path, Position key, size_t parentStart, size_t oldBase, ref EntityId* entries) {
	immutable record = c.syntax.records[r];
	immutable start = c.base + record.spanStart;
	if (!fp.dynarray.pushBack(entries, e)) return false;
	immutable span = doir.components.source.SourceSpan(cast(uint) (start - parentStart), record.spanEnd - record.spanStart);
	bool changed = false, built = false;
	size_t oldStart = 0;
	const(EntityId)[] oldChildren = null;
	if (e != invalidEntity) {
		immutable oldSpan = ecrs.context.getComponent!(doir.components.source.SourceSpan)(*c.store, e);
		oldStart = oldBase + oldSpan.offset;
		immutable kept = ecrs.context.getComponent!(doir.components.source.LexicalPosition)(*c.store, e).at == key;
		// Unchanged text, nested declarations included, at an unchanged key: nothing below it can differ but where it starts.
		if (kept && sameText(c, oldStart, oldSpan.length, record, record.spanEnd, true))
			return ecrs.context.setComponent!(doir.components.source.SourceSpan)(*c.store, e, span);
		if (auto inner = ecrs.context.findComponent!(doir.components.ast.Block)(*c.store, e)) oldChildren = fp.dynarray.slice(inner.related);
		immutable header = record.blockOpen == doir.syntax.parser.noToken ? record.spanEnd : c.syntax.tokens[record.blockOpen].start;
		if (ecrs.context.getComponent!(doir.components.source.SyntaxHash)(*c.store, e).value != record.hash) changed = built = true;
		else if (!sameText(c, oldStart, oldSpan.length, record, header, record.blockOpen == doir.syntax.parser.noToken))
			built = true; // only trivia moved in its own text: rebuilt for its parts' spans, unchanged
	} else {
		e = ecrs.context.addEntity(*c.store);
		if (e == invalidEntity) return false;
		entries[fp.dynarray.length(entries) - 1] = e;
		changed = built = true;
	}

	immutable deferred = built && c.deferring && c.described !is null && c.describedSyntax is c.syntax;
	if (built) {
		immutable name = record.name == doir.syntax.parser.noToken ? doir.strings.noName : doir.syntax.parser.nameOf(doir.syntax.lexer.text(c.syntax.tokens[record.name], c.text), *c.strings);
		if (record.name != doir.syntax.parser.noToken && name == doir.strings.noName) return false;
		if (deferred) {
			if (!defer(c, r, e, block, name)) return false;
		} else {
			if (!rebuild(c, r, e)) return false;
			if (name != doir.strings.noName && !ecrs.context.setComponent!(doir.components.ast.Name)(*c.store, e, doir.components.ast.Name(name))) return false;
			if (!ecrs.context.setComponent!(doir.components.ast.Parent)(*c.store, e, doir.components.ast.Parent([block]))) return false;
		}
	}
	if (record.name != doir.syntax.parser.noToken && !ecrs.context.setComponent!(doir.components.source.PathHash)(*c.store, e, doir.components.source.PathHash(path))) return false;
	if (!ecrs.context.setComponent!(doir.components.source.SyntaxHash)(*c.store, e, doir.components.source.SyntaxHash(record.hash))) return false;
	if (!ecrs.context.setComponent!(doir.components.source.SourceSpan)(*c.store, e, span)) return false;

	auto at = ecrs.context.findComponent!(doir.components.source.LexicalPosition)(*c.store, e);
	immutable moved = at is null || at.at != key;
	if (!ecrs.context.setComponent!(doir.components.source.LexicalPosition)(*c.store, e, doir.components.source.LexicalPosition(key))) return false;
	if (changed || moved) {
		// A deferred rebuild has not made the parts yet, so the worker marks them.
		if (deferred) c.deferred[fp.dynarray.length(c.deferred) - 1].mark = true;
		else if (!markChanged(c, e)) return false;
	}

	if (record.blockOpen == doir.syntax.parser.noToken) {
		if (ecrs.context.hasComponent!(doir.components.source.SyntaxErrors)(*c.store, e) && !ecrs.context.removeComponent!(doir.components.source.SyntaxErrors)(*c.store, e)) return false;
		foreach (child; oldChildren)
			if (!removeTree(c, child)) return false;
		return true;
	}
	return storeErrors(c, cast(uint) r, e, start)
		&& commitBlock(c, e, oldChildren, r + 1, record.end, path ? path : record.hash, key, start, oldStart, moved);
}

// Marks `e` and the parts the parse made for it changed. False on refusal.
private bool markChanged(ref Commit c, EntityId e) {
	if (!doir.query.markChanged(*c.engine, e)) return false;
	if (auto all = ecrs.context.findComponent!(doir.components.source.ParsedParts)(*c.store, e))
		foreach (part; fp.dynarray.slice(all.related))
			if (!doir.query.markChanged(*c.engine, part)) return false;
	return true;
}

// Gives `block` its new `entries`, which it takes over, removing the `old` ones none of `matched` kept and marking the block if its list changed. False on refusal.
private bool finishBlock(ref Commit c, EntityId block, const(EntityId)[] old, const(EntityId)[] matched, ref EntityId* entries) {
	foreach (e; old) {
		bool kept = false;
		foreach (m; matched) if (m == e) { kept = true; break; }
		if (!kept && !removeTree(c, e)) return false;
	}
	// Compared with `old`, not the list in the store, which a rebuild of `block` emptied.
	immutable differs = old != fp.dynarray.slice(entries);
	doir.components.ast.Block list;
	list.related = entries;
	entries = null;
	if (!ecrs.context.setComponent!(doir.components.ast.Block)(*c.store, block, list)) return false;
	return !differs || doir.query.markChanged(*c.engine, block);
}

// Matches records `lo` to `hi` of `c.syntax`, `block`'s contents, against its `old` contents and writes them, recursing into blocks; `parentStart` is `block`'s start in the file and `oldBase` its old start. False on refusal.
private bool commitBlock(ref Commit c, EntityId block, const(EntityId)[] old, size_t lo, size_t hi, ulong parentPath, Position parentAt, size_t parentStart, size_t oldBase, bool rekey) {
	auto records = c.syntax.records;
	uint* news = null;
	doir.strings.StringId* names = null;
	ulong* hashes = null;
	EntityId* matched = null, entries = null;
	ulong* paths = null;
	Position* keys = null;
	scope(exit) { fp.dynarray.free(news); fp.dynarray.free(names); fp.dynarray.free(hashes); fp.dynarray.free(matched); fp.dynarray.free(entries); fp.dynarray.free(paths); fp.dynarray.free(keys); }
	for (size_t r = lo; r < hi; r = records[r].end) {
		immutable name = records[r].name == doir.syntax.parser.noToken ? doir.strings.noName : doir.syntax.parser.nameOf(doir.syntax.lexer.text(c.syntax.tokens[records[r].name], c.text), *c.strings);
		if ((records[r].name != doir.syntax.parser.noToken && name == doir.strings.noName)
			|| !fp.dynarray.pushBack(news, cast(uint) r) || !fp.dynarray.pushBack(names, name) || !fp.dynarray.pushBack(hashes, records[r].hash))
			return false;
	}
	immutable n = fp.dynarray.length(news);
	if (n) {
		if (fp.dynarray.growToSize(matched, n) is null || fp.dynarray.growToSize(paths, n) is null || fp.dynarray.growToSize(keys, n) is null) return false;
		if (!match(c, old, fp.dynarray.slice(names), fp.dynarray.slice(hashes), parentPath, matched, paths)) return false;
		if (!assignPositions(c, parentAt, fp.dynarray.slice(matched), rekey, keys)) return false;
	}
	foreach (i, r; fp.dynarray.slice(news))
		if (!commitRecord(c, block, r, matched[i], paths[i], keys[i], parentStart, oldBase, entries)) return false;
	return finishBlock(c, block, old, fp.dynarray.slice(matched), entries);
}


// --- chunks ------------------------------------------------------------------

// Bytes of `Commit.file` skimmed together; or, with `blockOpen` set, one large named block-valued declaration whose contents are chunked in turn, its braces at `blockOpen` and `blockClose`.
private struct Piece {
	size_t start, end;
	size_t blockOpen = fp.pointer.notFound, blockClose;
}

// An entry of a chunked block as `survey` found it: its text, its name (`noName` for `_`), its hash, and its piece.
private struct Child {
	size_t start, end;
	doir.strings.StringId name;
	ulong hash;
	size_t piece;
}

// What `survey` found in a block's contents: its pieces and entries, the block's own syntax errors, and, if `hashed`, its hash carried through them. Plain data, released by `free`.
private struct Survey {
	Piece* pieces = null;
	Child* children = null;
	doir.components.source.SyntaxErrors errors;
	bool hashed; // a file's root has no hash to carry
	ulong hash;
}

private void free(ref Survey s) {
	fp.dynarray.free(s.pieces);
	fp.dynarray.free(s.children);
	s.errors.finalize();
}

// The bytes `cut` stops at; it skips every other byte without looking at it.
private immutable bool[256] structural = () {
	bool[256] table;
	foreach (c; "\n{}()\"'/#") table[c] = true;
	return table;
}();

// Cuts bytes `lo` to `hi` of `text`, a block's contents, into pieces of about `chunkBytes`, at lines that start a statement at the block's own level; a block-valued declaration larger than a piece is a piece of its own. It reads bytes, not tokens, skipping strings, characters and comments: a cut it places wrongly fails `settled` and merges into the next piece, so it need only be cheap and usually right. False on refusal.
private bool cut(const(char)[] text, size_t lo, size_t hi, ref Piece* pieces) {
	size_t from = lo, statement = lo, open = fp.pointer.notFound, close = fp.pointer.notFound;
	size_t braces = 0, parens = 0;
	// A statement starts at `at`, or the contents end there.
	bool boundary(size_t at) {
		bool ok = true;
		if (open != fp.pointer.notFound && close != fp.pointer.notFound && close - open > chunkBytes) {
			if (statement > from) ok = fp.dynarray.pushBack(pieces, Piece(from, statement));
			ok = ok && fp.dynarray.pushBack(pieces, Piece(statement, at, open, close));
			from = at;
		} else if (at > from && (at - from >= chunkBytes || at == hi)) {
			ok = fp.dynarray.pushBack(pieces, Piece(from, at));
			from = at;
		}
		statement = at;
		open = close = fp.pointer.notFound;
		return ok;
	}
	size_t i = lo;
	while (i < hi) {
		while (i < hi && !structural[text[i]]) ++i;
		if (i == hi) break;
		immutable c = text[i];
		if (c == '\n') {
			++i;
			if (braces || parens) continue;
			size_t j = i;
			while (j < hi && (text[j] == ' ' || text[j] == '\t')) ++j;
			if (j < hi) {
				immutable d = text[j];
				if (((d >= 'a' && d <= 'z') || (d >= 'A' && d <= 'Z') || d == '_' || d == '%' || d >= 0x80) && !boundary(i)) return false;
			}
		} else if ((c == '/' && i + 1 < hi && text[i + 1] == '/') || c == '#') {
			while (i < hi && text[i] != '\n') ++i;
		} else if (c == '/' && i + 1 < hi && text[i + 1] == '*') {
			i += 2;
			while (i + 1 < hi && !(text[i] == '*' && text[i + 1] == '/')) ++i;
			i += 2;
		} else if (c == '"') {
			size_t quotes = 0;
			while (i < hi && text[i] == '"') { ++quotes; ++i; }
			if (quotes >= 3) {
				// A raw string closes at the next run of as many quotes.
				for (size_t run = 0; i < hi && run < quotes; ++i) run = text[i] == '"' ? run + 1 : 0;
			} else if (quotes == 1) {
				while (i < hi && text[i] != '"' && text[i] != '\n') i += text[i] == '\\' ? 2 : 1;
				++i;
			}
		} else if (c == '\'') {
			++i;
			while (i < hi && text[i] != '\'' && text[i] != '\n') i += text[i] == '\\' ? 2 : 1;
			++i;
		} else {
			if (c == '(') ++parens;
			else if (c == ')') { if (parens) --parens; }
			else if (c == '{') {
				if (braces == 0 && parens == 0 && open == fp.pointer.notFound) {
					// A block value follows `=`, perhaps across whitespace and newlines.
					size_t j = i;
					while (j > lo && (text[j - 1] == ' ' || text[j - 1] == '\t' || text[j - 1] == '\n' || text[j - 1] == '\r')) --j;
					if (j > lo && text[j - 1] == '=') open = i;
				}
				++braces;
			} else if (c == '}' && braces && --braces == 0 && open != fp.pointer.notFound && close == fp.pointer.notFound) close = i;
			++i;
		}
	}
	return boundary(hi);
}

// Whether a piece skimmed into `syntax` ends where a whole parse would have reached its end between statements: no unterminated token, no error at its end, and, unless it ends the file, no statement ended by its end, since a block's `}` ends none.
private bool settled(ref const doir.syntax.parser.Syntax syntax, bool atEnd) {
	if (atEnd) return true;
	immutable last = fp.dynarray.length(syntax.tokens) - 1;
	foreach (t; fp.dynarray.slice(syntax.tokens)) if (t.kind == doir.syntax.lexer.TokenKind.unterminated) return false;
	foreach (error; fp.dynarray.slice(syntax.errors)) if (error.token == last) return false;
	auto records = fp.dynarray.slice(syntax.records);
	for (size_t r = 0; r < records.length; r = records[r].end) if (records[r].terminator == last) return false;
	return true;
}

// Skims `piece`, a large declaration, with its contents left out: its header, an empty block, and what follows the block, into `syntax` and `text`, which the caller frees. False on refusal.
private bool skimHeader(ref Commit c, ref const Piece piece, uint depth, ref doir.syntax.parser.Syntax syntax, ref char* text) {
	doir.syntax.parser.free(syntax);
	fp.string.free(text);
	text = fp.string.createFromConcatenation(c.file[piece.start .. piece.blockOpen], "{}", c.file[piece.blockClose + 1 .. piece.end]);
	return text !is null && doir.syntax.parser.skim(fp.string.slice(text), syntax, depth);
}

// How many pieces each worker skims ahead of the commit: enough to keep it busy while the store is written, few enough that the batch's tokens stay small beside the file.
private enum size_t aheadPerWorker = 2;

// One piece for a worker to skim and, if `strings` is set, to describe every record of, reading nothing but its text and interning only into `strings`.
private struct SkimJob {
	const(char)[] text;
	uint depth;
	size_t piece;
	doir.strings.Strings* strings;
	doir.syntax.parser.Syntax syntax;
	doir.syntax.parser.Description* described; // one per record; an fp dynarray
	bool skimmed;
}

private void freeDescribed(ref doir.syntax.parser.Description* described) {
	foreach (ref d; fp.dynarray.slice(described)) doir.syntax.parser.free(d);
	fp.dynarray.free(described);
}

private void skimJob(void* job) @trusted {
	auto j = cast(SkimJob*) job;
	j.skimmed = doir.syntax.parser.skim(j.text, j.syntax, j.depth);
	if (!j.skimmed || j.strings is null) return;
	immutable n = fp.dynarray.length(j.syntax.records);
	if (n && fp.dynarray.growToSize(j.described, n) is null) {
		j.skimmed = false;
		return;
	}
	foreach (r; 0 .. n) {
		j.described[r] = doir.syntax.parser.Description.init;
		if (!doir.syntax.parser.describe(j.syntax, j.text, r, *j.strings, j.described[r])) {
			j.skimmed = false;
			return;
		}
	}
}

// Pieces skimmed ahead, handed out in order. Plain data, released by `free`.
private struct Ahead {
	SkimJob* jobs = null;
	size_t next;
}

private void free(ref Ahead ahead) {
	foreach (ref job; fp.dynarray.slice(ahead.jobs)) {
		doir.syntax.parser.free(job.syntax);
		freeDescribed(job.described);
	}
	fp.dynarray.free(ahead.jobs);
	ahead = Ahead.init;
}

// Skims piece `p` of `pieces` into `syntax`, which must be empty: from `ahead`, or else from a new batch of it and the pieces after it that `wanted` selects, skimmed at once on `c.engine.workers` if there is a pool. With `described`, which must be null, and a pool, it also describes every record ahead, for `rebuild` to apply; without a pool `rebuild` describes only what it builds. False on refusal.
private bool skimPiece(ref Commit c, ref Ahead ahead, const(Piece)[] pieces, const(bool)[] wanted, size_t p, uint depth, ref doir.syntax.parser.Syntax syntax, doir.syntax.parser.Description** described = null) @trusted {
	if (ahead.next == fp.dynarray.length(ahead.jobs) || ahead.jobs[ahead.next].piece != p) {
		free(ahead);
		auto pool = c.engine.workers;
		immutable batch = pool is null ? 1 : bc.threadpool.workerCount(pool) * aheadPerWorker;
		for (size_t q = p; q < pieces.length && fp.dynarray.length(ahead.jobs) < batch; ++q)
			if (q == p || wanted[q])
				if (!fp.dynarray.pushBack(ahead.jobs, SkimJob(c.file[pieces[q].start .. pieces[q].end], depth, q, described is null || pool is null ? null : c.strings))) return false;
		immutable n = fp.dynarray.length(ahead.jobs);
		if (pool is null || n == 1) skimJob(ahead.jobs);
		else {
			bc.threadpool.Job* jobs = null;
			scope(exit) fp.dynarray.free(jobs);
			foreach (ref job; fp.dynarray.slice(ahead.jobs))
				if (!fp.dynarray.pushBack(jobs, bc.threadpool.Job(&skimJob, &job))) return false;
			if (!bc.threadpool.run(pool, fp.dynarray.slice(jobs))) return false;
		}
	}
	auto job = &ahead.jobs[ahead.next++];
	if (!job.skimmed) return false;
	syntax = job.syntax;
	job.syntax = doir.syntax.parser.Syntax.init;
	if (described !is null) {
		*described = job.described;
		job.described = null;
	}
	return true;
}

// Surveys bytes `lo` to `hi` of `c.file`, the contents at nesting `depth` of a block starting at `holderStart`: cuts them into pieces and skims each, merging a piece into the next when its cut would not fall between statements in a whole parse, and records each entry, the block's own errors and its hash, carried on from `s.hash`. `atEnd` says the contents end the file. Returns false when the contents cannot be cut, as when their last statement runs into the closing `}`, having written nothing to the store, and null on refusal.
private std.typecons.Nullable!bool survey(ref Commit c, size_t lo, size_t hi, uint depth, bool atEnd, size_t holderStart, ref Survey s) {
	if (!cut(c.file, lo, hi, s.pieces)) return typeof(return).init;
	doir.syntax.parser.Syntax syntax;
	char* header = null;
	Ahead ahead;
	bool* wanted = null;
	scope(exit) { doir.syntax.parser.free(syntax); fp.string.free(header); free(ahead); fp.dynarray.free(wanted); }
	foreach (piece; fp.dynarray.slice(s.pieces))
		if (!fp.dynarray.pushBack(wanted, piece.blockOpen == fp.pointer.notFound)) return typeof(return).init;
	for (size_t p = 0; p < fp.dynarray.length(s.pieces);) {
		immutable piece = s.pieces[p];
		immutable last = p + 1 == fp.dynarray.length(s.pieces);
		if (piece.blockOpen != fp.pointer.notFound) {
			if (!skimHeader(c, piece, depth, syntax, header)) return typeof(return).init;
			auto records = fp.dynarray.slice(syntax.records);
			if (!settled(syntax, atEnd && last) || fp.dynarray.length(syntax.errors) || records.length != 1 || records[0].blockOpen == doir.syntax.parser.noToken || records[0].name == doir.syntax.parser.noToken) {
				s.pieces[p].blockOpen = fp.pointer.notFound; // taken as an ordinary piece instead
				wanted[p] = true;
				continue;
			}
			immutable name = doir.syntax.parser.nameOf(doir.syntax.lexer.text(syntax.tokens[records[0].name], fp.string.slice(header)), *c.strings);
			if (name == doir.strings.noName) return typeof(return).init;
			// Past the empty block, the header's offsets are the file's less the contents left out.
			immutable start = piece.start + records[0].spanStart, end = piece.start + records[0].spanEnd + (piece.blockClose - piece.blockOpen - 1);
			if (!fp.dynarray.pushBack(s.children, Child(start, end, name, 0, p))) return typeof(return).init;
			if (s.hashed) s.hash = doir.syntax.parser.hashLevel(s.hash, syntax, fp.string.slice(header), 0, fp.dynarray.length(syntax.tokens) - 1, 0);
			++p;
			continue;
		}
		c.text = c.file[piece.start .. piece.end];
		c.base = piece.start;
		doir.syntax.parser.free(syntax);
		if (!skimPiece(c, ahead, fp.dynarray.slice(s.pieces), fp.dynarray.slice(wanted), p, depth, syntax)) return typeof(return).init;
		if (!settled(syntax, atEnd && last)) {
			if (last) return typeof(return)(false);
			version(unittest) ++mergedPieces;
			s.pieces[p + 1].start = piece.start;
			s.pieces[p + 1].blockOpen = fp.pointer.notFound;
			cast(void) fp.dynarray.deleteRange(s.pieces, p, 1);
			cast(void) fp.dynarray.deleteRange(wanted, p, 1);
			wanted[p] = true;
			// The pieces skimmed ahead are numbered as they were, and the merged one must be skimmed again.
			free(ahead);
			continue;
		}
		c.syntax = &syntax;
		fp.dynarray.free(c.owned);
		immutable gathered = assignErrors(c) && gatherErrors(c, rootOwner, holderStart, s.errors);
		fp.dynarray.free(c.owned);
		if (!gathered) return typeof(return).init;
		auto records = fp.dynarray.slice(syntax.records);
		for (size_t r = 0; r < records.length; r = records[r].end) {
			immutable name = records[r].name == doir.syntax.parser.noToken ? doir.strings.noName : doir.syntax.parser.nameOf(doir.syntax.lexer.text(syntax.tokens[records[r].name], c.text), *c.strings);
			if (records[r].name != doir.syntax.parser.noToken && name == doir.strings.noName) return typeof(return).init;
			if (!fp.dynarray.pushBack(s.children, Child(piece.start + records[r].spanStart, piece.start + records[r].spanEnd, name, records[r].hash, p))) return typeof(return).init;
		}
		if (s.hashed) s.hash = doir.syntax.parser.hashLevel(s.hash, syntax, c.text, 0, fp.dynarray.length(syntax.tokens) - 1, records.length ? 0 : doir.syntax.parser.noToken);
		++p;
	}
	return typeof(return)(true);
}

// Whether `child`, matched to `e`, has its old text and order key `key`, so a commit only moves it; `oldBase` is its block's old start.
private bool unchanged(ref Commit c, ref const Child child, EntityId e, Position key, size_t oldBase) {
	if (e == invalidEntity || !c.hadText || ecrs.context.getComponent!(doir.components.source.LexicalPosition)(*c.store, e).at != key) return false;
	immutable span = ecrs.context.getComponent!(doir.components.source.SourceSpan)(*c.store, e);
	return span.length == child.end - child.start && fp.rope.equal(c.oldText, oldBase + span.offset, c.file[child.start .. child.end]);
}

// Writes `child`, the large declaration `piece`, into `e`, the old entity it matched or `invalidEntity`, as `commitRecord` writes a record: its header from `skimHeader`, its contents chunked one level down, and its hash carried through them. If its contents cannot be cut it is skimmed whole instead. Appends the entity to `entries`. False on refusal.
private bool commitLarge(ref Commit c, EntityId block, ref const Piece piece, ref const Child child, EntityId e, ulong path, Position key, uint depth, size_t parentStart, size_t oldBase, ref EntityId* entries) {
	immutable span = doir.components.source.SourceSpan(cast(uint) (child.start - parentStart), cast(uint) (child.end - child.start));
	if (unchanged(c, child, e, key, oldBase))
		return fp.dynarray.pushBack(entries, e) && ecrs.context.setComponent!(doir.components.source.SourceSpan)(*c.store, e, span);

	doir.syntax.parser.Syntax header;
	char* headerText = null;
	Survey inner;
	scope(exit) { doir.syntax.parser.free(header); fp.string.free(headerText); free(inner); }
	if (!skimHeader(c, piece, depth, header, headerText)) return false;
	immutable record = header.records[0];
	inner.hashed = true;
	inner.hash = doir.syntax.parser.hashLevel(doir.syntax.parser.hashStart, header, fp.string.slice(headerText), record.first, record.blockOpen + 1);
	immutable surveyed = survey(c, piece.blockOpen + 1, piece.blockClose, depth + 1, false, child.start, inner);
	if (surveyed.isNull) return false;
	if (!surveyed.get) {
		version(unittest) ++largeFallbacks;
		doir.syntax.parser.Syntax whole;
		scope(exit) doir.syntax.parser.free(whole);
		c.text = c.file[piece.start .. piece.end];
		c.base = piece.start;
		if (!doir.syntax.parser.skim(c.text, whole, depth)) return false;
		c.syntax = &whole;
		fp.dynarray.free(c.owned);
		scope(exit) fp.dynarray.free(c.owned);
		return assignErrors(c) && commitRecord(c, block, 0, e, path, key, parentStart, oldBase, entries);
	}

	version(unittest) ++largeCommits;
	size_t oldStart = 0;
	const(EntityId)[] oldChildren = null;
	bool headerMoved = true;
	ulong oldHash = 0;
	if (e != invalidEntity) {
		immutable oldSpan = ecrs.context.getComponent!(doir.components.source.SourceSpan)(*c.store, e);
		oldStart = oldBase + oldSpan.offset;
		if (auto inside = ecrs.context.findComponent!(doir.components.ast.Block)(*c.store, e)) oldChildren = fp.dynarray.slice(inside.related);
		oldHash = ecrs.context.getComponent!(doir.components.source.SyntaxHash)(*c.store, e).value;
		immutable headerLength = piece.blockOpen - child.start;
		headerMoved = !c.hadText || oldSpan.length < headerLength || !fp.rope.equal(c.oldText, oldStart, c.file[child.start .. piece.blockOpen]);
	}
	immutable fresh = e == invalidEntity;
	if (fresh) {
		e = ecrs.context.addEntity(*c.store);
		if (e == invalidEntity) return false;
	}
	if (!fp.dynarray.pushBack(entries, e)) return false;
	if (!ecrs.context.setComponent!(doir.components.source.PathHash)(*c.store, e, doir.components.source.PathHash(path))) return false;
	if (!ecrs.context.setComponent!(doir.components.source.SourceSpan)(*c.store, e, span)) return false;
	auto at = ecrs.context.findComponent!(doir.components.source.LexicalPosition)(*c.store, e);
	immutable moved = at is null || at.at != key;
	if (!ecrs.context.setComponent!(doir.components.source.LexicalPosition)(*c.store, e, doir.components.source.LexicalPosition(key))) return false;

	if (!commitRegion(c, e, oldChildren, inner, depth + 1, path, key, child.start, oldStart, moved)) return false;
	immutable hash = doir.syntax.parser.hashLevel(inner.hash, header, fp.string.slice(headerText), record.blockClose, record.terminator);
	// Only now is the hash known, so the declaration is rebuilt after its contents, as `commitRecord` rebuilds it before them; the rebuild empties the `Block` they wrote, which is put back.
	if (fresh || headerMoved || hash != oldHash) {
		doir.components.ast.Block list;
		list.related = fp.dynarray.clone(ecrs.context.getComponent!(doir.components.ast.Block)(*c.store, e).related);
		if (list.related is null && fp.dynarray.length(ecrs.context.getComponent!(doir.components.ast.Block)(*c.store, e).related)) return false;
		c.syntax = &header;
		c.text = fp.string.slice(headerText);
		c.base = piece.start;
		if (!rebuild(c, 0, e)
			|| !ecrs.context.setComponent!(doir.components.ast.Name)(*c.store, e, doir.components.ast.Name(child.name))
			|| !ecrs.context.setComponent!(doir.components.ast.Parent)(*c.store, e, doir.components.ast.Parent([block]))) {
			fp.dynarray.free(list.related);
			return false;
		}
		if (!ecrs.context.setComponent!(doir.components.ast.Block)(*c.store, e, list)) return false;
	}
	if (!ecrs.context.setComponent!(doir.components.source.SyntaxHash)(*c.store, e, doir.components.source.SyntaxHash(hash))) return false;
	return !(fresh || moved || hash != oldHash) || markChanged(c, e);
}

// Writes the entries `s` found in `block`'s contents into the store, as `commitBlock` writes a block's records: matched and keyed together, each piece skimmed again only if something in it changed, and the block's own errors stored. False on refusal.
private bool commitRegion(ref Commit c, EntityId block, const(EntityId)[] old, ref Survey s, uint depth, ulong parentPath, Position parentAt, size_t parentStart, size_t oldBase, bool rekey) {
	auto children = fp.dynarray.slice(s.children);
	immutable n = children.length;
	doir.strings.StringId* names = null;
	ulong* hashes = null;
	EntityId* matched = null, entries = null;
	ulong* paths = null;
	Position* keys = null;
	doir.syntax.parser.Syntax syntax;
	scope(exit) { fp.dynarray.free(names); fp.dynarray.free(hashes); fp.dynarray.free(matched); fp.dynarray.free(entries); fp.dynarray.free(paths); fp.dynarray.free(keys); doir.syntax.parser.free(syntax); }
	foreach (child; children)
		if (!fp.dynarray.pushBack(names, child.name) || !fp.dynarray.pushBack(hashes, child.hash)) return false;
	if (n) {
		if (fp.dynarray.growToSize(matched, n) is null || fp.dynarray.growToSize(paths, n) is null || fp.dynarray.growToSize(keys, n) is null) return false;
		if (!match(c, old, fp.dynarray.slice(names), fp.dynarray.slice(hashes), parentPath, matched, paths)) return false;
		if (!assignPositions(c, parentAt, fp.dynarray.slice(matched), rekey, keys)) return false;
	}

	// Which pieces have something changed, and so are skimmed again: workers can skim them ahead.
	bool* wanted = null;
	Ahead ahead;
	scope(exit) { fp.dynarray.free(wanted); free(ahead); }
	for (size_t p = 0, k = 0; p < fp.dynarray.length(s.pieces); ++p) {
		bool want = false;
		for (; k < n && children[k].piece == p; ++k)
			if (!unchanged(c, children[k], matched[k], keys[k], oldBase)) want = true;
		if (!fp.dynarray.pushBack(wanted, want && s.pieces[p].blockOpen == fp.pointer.notFound)) return false;
	}

	size_t i = 0;
	foreach (p, piece; fp.dynarray.slice(s.pieces)) {
		size_t j = i;
		while (j < n && children[j].piece == p) ++j;
		if (piece.blockOpen != fp.pointer.notFound) {
			assert(j == i + 1);
			if (!commitLarge(c, block, piece, children[i], matched[i], paths[i], keys[i], depth, parentStart, oldBase, entries)) return false;
			i = j;
			continue;
		}
		if (!wanted[p]) {
			foreach (k; i .. j) {
				immutable span = doir.components.source.SourceSpan(cast(uint) (children[k].start - parentStart), cast(uint) (children[k].end - children[k].start));
				if (!fp.dynarray.pushBack(entries, matched[k]) || !ecrs.context.setComponent!(doir.components.source.SourceSpan)(*c.store, matched[k], span)) return false;
			}
			i = j;
			continue;
		}
		c.text = c.file[piece.start .. piece.end];
		c.base = piece.start;
		doir.syntax.parser.free(syntax);
		doir.syntax.parser.Description* described = null;
		scope(exit) freeDescribed(described);
		if (!skimPiece(c, ahead, fp.dynarray.slice(s.pieces), fp.dynarray.slice(wanted), p, depth, syntax, &described)) return false;
		c.syntax = &syntax;
		c.described = described;
		c.describedSyntax = &syntax;
		// Described pieces may have their rebuilds deferred to the workers, which run them before the piece's syntax goes.
		c.deferring = deferBuilds && described !is null;
		scope(exit) { c.described = null; c.deferring = false; }
		fp.dynarray.free(c.owned);
		if (!assignErrors(c)) return false;
		auto records = fp.dynarray.slice(syntax.records);
		for (size_t r = 0; r < records.length; r = records[r].end, ++i)
			if (!commitRecord(c, block, r, matched[i], paths[i], keys[i], parentStart, oldBase, entries)) return false;
		assert(i == j);
		if (c.deferring && !flushDeferred(c)) return false;
		fp.dynarray.free(c.owned);
	}
	return finishBlock(c, block, old, fp.dynarray.slice(matched), entries) && setErrors(c, block, s.errors);
}

// Makes `made` `file`'s text, which the store takes over even on refusal, keeping the old version in `c` to compare against. False on refusal.
private bool replaceText(ref Commit c, EntityId file, fp.rope.Rope made) {
	auto owned = ecrs.context.findComponent!(doir.components.source.SourceText)(*c.store, file);
	c.hadText = owned !is null;
	if (c.hadText) c.oldText = owned.text;
	c.path = doir.strings.text(*c.strings, ecrs.context.getComponent!(doir.components.source.SourceFile)(*c.store, file).path);
	return ecrs.context.setComponent!(doir.components.source.SourceText)(*c.store, file, doir.components.source.SourceText(c.path, made));
}

// Everything a whole-file commit writes to the store, inside its transaction. False on refusal.
private bool applyFile(ref Commit c, EntityId file, fp.rope.Rope made) {
	auto store = c.store;
	if (!replaceText(c, file, made)) return false;
	immutable same = c.hadText && fp.rope.length(c.oldText) == c.file.length && fp.rope.equal(c.oldText, 0, c.file);
	if (!same && !doir.query.markChanged(*c.engine, file)) return false;

	EntityId root = rootOf(*c.engine, file);
	if (root == invalidEntity) {
		root = ecrs.context.addEntity(*store);
		if (root == invalidEntity
			|| ecrs.context.addComponent!(doir.components.ast.Block)(*store, root) is null
			|| !ecrs.context.setComponent!(doir.components.source.LexicalPosition)(*store, root, doir.components.source.LexicalPosition(doir.engine.positions.root))
			|| !ecrs.context.setComponent!(doir.components.source.InFile)(*store, root, doir.components.source.InFile([file]))
			|| !ecrs.context.setComponent!(doir.components.source.FileRoot)(*store, file, doir.components.source.FileRoot([root]))
			|| !doir.query.markChanged(*c.engine, root))
			return false;
	}
	if (!ecrs.context.setComponent!(doir.components.source.SourceSpan)(*store, root, doir.components.source.SourceSpan(0, cast(uint) c.file.length))) return false;

	auto oldEntries = fp.dynarray.slice(ecrs.context.getComponent!(doir.components.ast.Block)(*store, root).related);
	Survey contents;
	scope(exit) free(contents);
	immutable surveyed = survey(c, 0, c.file.length, 0, true, 0, contents);
	if (surveyed.isNull) return false;
	assert(surveyed.get, "doir.source: a file's end always ends its last piece");
	return commitRegion(c, root, oldEntries, contents, 0, fp.hash.murmur(cast(const(ubyte)[]) c.path), doir.engine.positions.root, 0, 0, false);
}

// Everything a commit of one declaration writes, as `applyFile` but for `chain[$ - 1]` alone, whose text is `c.text` from `c.base`: `chain` is it and the declarations enclosing it, outermost first, and every span and syntax error after it on that path moves by `delta`. A whole-file commit of the same text writes the same: it would match the declaration to its entity (`fits`), find its enclosing declarations' hashes unchanged, and skip every other declaration.
private bool applyBlock(ref Commit c, EntityId file, fp.rope.Rope made, const(EntityId)[] chain, ptrdiff_t delta, bool changed) {
	auto store = c.store;
	if (!replaceText(c, file, made) || !assignErrors(c)) return false;
	if (changed && !doir.query.markChanged(*c.engine, file)) return false;
	immutable root = rootOf(*c.engine, file);
	immutable total = fp.rope.length(ecrs.context.getComponent!(doir.components.source.SourceText)(*store, file).text);
	if (!ecrs.context.setComponent!(doir.components.source.SourceSpan)(*store, root, doir.components.source.SourceSpan(0, cast(uint) total))) return false;

	EntityId parent = root;
	uint oldLength;
	foreach (e; chain) {
		auto entries = fp.dynarray.slice(ecrs.context.getComponent!(doir.components.ast.Block)(*store, parent).related);
		size_t i = 0;
		while (entries[i] != e) ++i;
		foreach (sibling; entries[i + 1 .. $]) {
			auto span = ecrs.context.getComponent!(doir.components.source.SourceSpan)(*store, sibling);
			span.offset = cast(uint) (span.offset + delta);
			if (!ecrs.context.setComponent!(doir.components.source.SourceSpan)(*store, sibling, span)) return false;
		}
		auto own = ecrs.context.getComponent!(doir.components.source.SourceSpan)(*store, e);
		// The enclosing block's own errors after `e` move with the text, as its later declarations do.
		if (!shiftErrors(c, parent, own.offset + own.length, delta)) return false;
		oldLength = own.length;
		own.length = cast(uint) (own.length + delta);
		if (!ecrs.context.setComponent!(doir.components.source.SourceSpan)(*store, e, own)) return false;
		if (e != chain[$ - 1]) parent = e;
	}

	immutable e = chain[$ - 1];
	immutable record = c.syntax.records[0];
	auto oldChildren = fp.dynarray.slice(ecrs.context.getComponent!(doir.components.ast.Block)(*store, e).related);
	// As `commitBlock` treats a matched declaration: a new hash is a change, and trivia moved before the block a rebuild alone.
	immutable hashChanged = ecrs.context.getComponent!(doir.components.source.SyntaxHash)(*store, e).value != record.hash;
	if (hashChanged || !sameText(c, c.base, oldLength, record, c.syntax.tokens[record.blockOpen].start, false)) {
		if (!rebuild(c, 0, e)) return false;
		if (record.name != doir.syntax.parser.noToken) {
			immutable name = doir.syntax.parser.nameOf(doir.syntax.lexer.text(c.syntax.tokens[record.name], c.text), *c.strings);
			if (name == doir.strings.noName || !ecrs.context.setComponent!(doir.components.ast.Name)(*store, e, doir.components.ast.Name(name))) return false;
		}
		if (!ecrs.context.setComponent!(doir.components.ast.Parent)(*store, e, doir.components.ast.Parent([parent]))) return false;
	}
	if (hashChanged) {
		if (!ecrs.context.setComponent!(doir.components.source.SyntaxHash)(*store, e, doir.components.source.SyntaxHash(record.hash))) return false;
		if (!doir.query.markChanged(*c.engine, e)) return false;
		if (auto all = ecrs.context.findComponent!(doir.components.source.ParsedParts)(*store, e))
			foreach (part; fp.dynarray.slice(all.related))
				if (!doir.query.markChanged(*c.engine, part)) return false;
	}
	auto path = ecrs.context.findComponent!(doir.components.source.PathHash)(*store, e);
	immutable at = ecrs.context.getComponent!(doir.components.source.LexicalPosition)(*store, e).at;
	return storeErrors(c, 0, e, c.base) && commitBlock(c, e, oldChildren, 1, record.end, path is null ? record.hash : path.value, at, c.base, c.base, false);
}

// Where `holder`'s span starts in `file`, or `fp.pointer.notFound` if it is not in `file`.
private size_t startIn(ref ecrs.context.Context store, EntityId holder, EntityId file) {
	auto found = doir.engine.locations.bytesOf(store, holder);
	return found.isNull || found.get.file != file ? fp.pointer.notFound : found.get.bytes.startByte;
}

/// The number of syntax errors in `file` as of its last commit. It cannot fail.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.strings;
/// static import doir.query;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.query.create(store);
/// scope(exit) doir.query.free(engine);
/// doir.strings.Strings strings;
/// scope(exit) doir.strings.free(strings);
/// immutable file = addFile(engine, strings, "a.doir");
/// cast(void) commit(engine, strings, file, "ns : namespace = {\n\tx : = 1\n}\ny : = 2\n");
/// assert(syntaxErrorCount(engine, file) == 2);
/// ---
size_t syntaxErrorCount(ref doir.query.QueryEngine engine, EntityId file) {
	immutable id = ecrs.registry.componentId!(doir.components.source.SyntaxErrors)();
	auto storage = id == fp.pointer.notFound ? null : ecrs.context.getStorage(cast(const) *engine.store, id);
	if (storage is null) return 0;
	size_t count = 0;
	foreach (holder; ecrs.storage.owners(*storage))
		if (holder != invalidEntity && startIn(*engine.store, holder, file) != fp.pointer.notFound)
			count += fp.dynarray.length(ecrs.context.getComponent!(doir.components.source.SyntaxErrors)(*engine.store, holder).errors);
	return count;
}

private struct Found {
	size_t at; // in the file
	size_t start; // the holder's start in the file
	size_t order; // among the holder's errors
	const(doir.components.source.StoredError)* error;
}

private extern(C) int compareFound(const(void)* a, const(void)* b) {
	auto x = cast(const(Found)*) a, y = cast(const(Found)*) b;
	if (x.at != y.at) return x.at < y.at ? -1 : 1;
	if (x.start != y.start) return x.start < y.start ? -1 : 1;
	return x.order < y.order ? -1 : x.order > y.order;
}

// The diagnostic for `found` in `file`, its location at the error with the parser's hint, and at the bracket a missing closer would close. False on refusal, leaving `d` for the caller to free.
private bool describeFound(ref ecrs.context.Context store, EntityId file, const(char)[] path, ref const Found found, ref diagnose.Diagnostic d) {
	d.kind = diagnose.Kind.error;
	immutable at = doir.engine.locations.pairAt(store, file, found.at);
	if (at.isNull) return false;
	d.location = diagnose.Detailed(path, at.get, at.get);
	d.message = fp.string.makeDynamic(fp.string.slice(found.error.message));
	d.additionalNote = fp.string.makeDynamic(fp.string.slice(found.error.note));
	if (d.message is null || d.additionalNote is null) return false;
	auto fix = diagnose.Diagnostic.Annotation(at.get, null, fp.string.makeDynamic(fp.string.slice(found.error.hint)));
	if (fix.message is null || !diagnose.pushAnnotation(d, fix)) {
		fp.string.free(fix.message);
		return false;
	}
	if (found.error.opening == doir.components.source.noOpening) return true;
	immutable open = doir.engine.locations.pairAt(store, file, found.start + found.error.opening);
	if (open.isNull) return false;
	auto opened = diagnose.Diagnostic.Annotation(open.get);
	opened.message = fp.string.makeDynamic("opened here");
	if (opened.message !is null && diagnose.pushAnnotation(d, opened)) return true;
	fp.string.free(opened.message);
	return false;
}

/// Pushes a diagnostic to `manager` for each syntax error in `file` as of its last commit, in source order: at the error, with the parser's hint saying how to fix it, and at the bracket a missing closer would close, closing with the parser's explanation for someone new to DOIR. The caller registers the file's text with `manager` (`diagnose.registerSource`) for them to print with context.
///
/// Returns false if allocation fails, leaving `manager` as it was.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import diagnose;
/// static import doir.strings;
/// static import doir.query;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.query.create(store);
/// scope(exit) doir.query.free(engine);
/// doir.strings.Strings strings;
/// scope(exit) doir.strings.free(strings);
/// diagnose.Manager manager;
/// scope(exit) diagnose.free(manager);
/// immutable file = addFile(engine, strings, "a.doir");
/// cast(void) commit(engine, strings, file, "x : = 1\n");
/// assert(reportSyntaxErrors(engine, file, manager) && diagnose.count(manager) == 1);
/// ---
bool reportSyntaxErrors(ref doir.query.QueryEngine engine, EntityId file, ref diagnose.Manager manager) @trusted {
	auto store = engine.store;
	immutable id = ecrs.registry.componentId!(doir.components.source.SyntaxErrors)();
	auto storage = id == fp.pointer.notFound ? null : ecrs.context.getStorage(cast(const) *store, id);
	if (storage is null) return true;
	Found* found = null;
	diagnose.Diagnostic* made = null;
	scope(exit) {
		fp.dynarray.free(found);
		foreach (ref d; fp.dynarray.slice(made)) diagnose.free(d);
		fp.dynarray.free(made);
	}
	foreach (holder; ecrs.storage.owners(*storage)) {
		if (holder == invalidEntity) continue;
		immutable start = startIn(*store, holder, file);
		if (start == fp.pointer.notFound) continue;
		foreach (i, ref error; fp.dynarray.slice(ecrs.context.getComponent!(doir.components.source.SyntaxErrors)(*store, holder).errors))
			if (!fp.dynarray.pushBack(found, Found(start + error.at, start, i, &error))) return false;
	}
	immutable n = fp.dynarray.length(found);
	if (n == 0) return true;
	core.stdc.stdlib.qsort(found, n, Found.sizeof, &compareFound);
	const path = ecrs.context.getComponent!(doir.components.source.SourceText)(*store, file).path;
	foreach (ref f; fp.dynarray.slice(found)) {
		diagnose.Diagnostic d;
		if (!describeFound(*store, file, path, f, d) || !fp.dynarray.pushBack(made, d)) {
			diagnose.free(d);
			return false;
		}
	}
	// Pushing cannot be undone, so the room for every diagnostic is made first.
	if (fp.dynarray.reserve(manager.diagnostics, fp.dynarray.length(manager.diagnostics) + n) is null) return false;
	foreach (d; fp.dynarray.slice(made)) cast(void) diagnose.push(manager, d); // reserved above
	fp.dynarray.clear(made);
	return true;
}

// Runs `apply` on `c` in a store transaction, or rolls it back on refusal; `commit` and `commitEdit` return what it does.
private size_t transact(alias apply, Args...)(ref Commit c, EntityId file, Args args) {
	scope(exit) {
		fp.dynarray.free(c.owned);
		foreach (ref d; fp.dynarray.slice(c.deferred)) {
			fp.dynarray.free(d.fresh);
			fp.dynarray.free(d.leftover);
		}
		fp.dynarray.free(c.deferred);
	}
	ecrs.context.beginTransaction(*c.store);
	if (!apply(c, file, args)) {
		ecrs.context.rollbackTransaction(*c.store);
		return fp.pointer.allocationRefused;
	}
	ecrs.context.commitTransaction(*c.store);
	return syntaxErrorCount(*c.engine, file);
}

/// Commits `text` as the new contents of `file`, one input commit in a revision of its own: lexes and parses it, matches its declarations against the previous commit's, builds the new and changed ones into the store, assigns order keys, writes the spans of what moved, and marks what changed. A declaration whose text is unchanged, nested declarations included, is skipped with everything inside it. Locations are derived from the spans only when asked for (`doir.engine.locations.locate`). A failed declaration is skipped, so the rest of the file still commits, and its syntax error is kept on the block holding it (`SyntaxErrors`) until that block is parsed again; `reportSyntaxErrors` reports them. No query may be running, and no store transaction may be open: the commit runs in one of its own.
///
/// Returns the number of syntax errors in the file, or `fp.pointer.allocationRefused` if allocation fails, having rolled the store back to the previous commit. Only the revision count, order keys and interned strings it made are left behind, none of which a later commit or query observes.
///
/// Examples:
/// ---
/// static import fp.dynarray;
/// static import ecrs.context;
/// static import doir.strings;
/// static import doir.query;
/// static import doir.components.ast;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.query.create(store);
/// scope(exit) doir.query.free(engine);
/// doir.strings.Strings strings;
/// scope(exit) doir.strings.free(strings);
/// immutable file = addFile(engine, strings, "a.doir");
/// assert(commit(engine, strings, file, "a : T = 1\nb : = 2\nc : T = 3\n") == 1);
/// assert(fp.dynarray.length(ecrs.context.getComponent!(doir.components.ast.Block)(store, rootOf(engine, file)).related) == 2);
/// ---
size_t commit(ref doir.query.QueryEngine engine, ref doir.strings.Strings strings, EntityId file, const(char)[] text) {
	doir.query.beginRevision(engine);
	// The commit reads `text` while it runs; the store keeps a copy, and the transaction keeps the old one alive until it ends.
	auto made = fp.rope.create(text);
	if (made.isNull) return fp.pointer.allocationRefused;

	Commit c;
	c.engine = &engine;
	c.store = engine.store;
	c.strings = &strings;
	c.file = text;
	return transact!applyFile(c, file, made.get);
}

// The block-valued declarations whose braces may enclose bytes `start` to `end` of the committed text, outermost first, and where each starts. False on refusal.
private bool enclosing(ref ecrs.context.Context store, EntityId root, size_t start, size_t end, ref EntityId* chain, ref size_t* starts) {
	EntityId parent = root;
	size_t base = 0;
	for (;;) {
		auto entries = fp.dynarray.slice(ecrs.context.getComponent!(doir.components.ast.Block)(store, parent).related);
		size_t lo = 0, hi = entries.length;
		while (lo < hi) {
			immutable mid = (lo + hi) / 2;
			if (base + ecrs.context.getComponent!(doir.components.source.SourceSpan)(store, entries[mid]).offset <= start) lo = mid + 1;
			else hi = mid;
		}
		if (lo == 0) return true;
		immutable e = entries[lo - 1];
		immutable span = ecrs.context.getComponent!(doir.components.source.SourceSpan)(store, e);
		immutable at = base + span.offset;
		// Strictly inside, so the declaration still starts where it did and keeps its closing brace.
		if (!ecrs.context.hasComponent!(doir.components.ast.Block)(store, e) || at >= start || end >= at + span.length) return true;
		if (!fp.dynarray.pushBack(chain, e) || !fp.dynarray.pushBack(starts, at)) return false;
		parent = e;
		base = at;
	}
}

// Whether `syntax`, skimmed from `e`'s new text `source`, is still `e` whole: one declaration with a block and no error outside it, which a whole-file commit would match to `e`. That takes an unchanged hash, or, for a named declaration, which matches by its path, an unchanged name. False on refusal too, leaving the whole-file commit to report it.
private bool fits(ref Commit c, EntityId e, const(char)[] source) {
	auto records = fp.dynarray.slice(c.syntax.records);
	if (records.length == 0) return false;
	immutable r = records[0];
	if (r.end != records.length || r.spanStart != 0 || r.spanEnd != source.length || r.blockOpen == doir.syntax.parser.noToken) return false;
	foreach (error; fp.dynarray.slice(c.syntax.errors))
		if (error.token <= r.blockOpen || error.token > r.blockClose) return false;
	if (r.hash == ecrs.context.getComponent!(doir.components.source.SyntaxHash)(*c.store, e).value) return true;
	if (r.name == doir.syntax.parser.noToken || !ecrs.context.hasComponent!(doir.components.source.PathHash)(*c.store, e)) return false;
	immutable name = doir.syntax.parser.nameOf(doir.syntax.lexer.text(c.syntax.tokens[r.name], source), *c.strings);
	return name != doir.strings.noName && name == ecrs.context.getComponent!(doir.components.ast.Name)(*c.store, e).value;
}

/// Commits one edit to `file`, which must have been committed: bytes `start` to `end` of its text replaced by `replacement`. It writes what `commit` of the edited text would, but reparses only the innermost declaration whose braces enclose the edit and still parse as its block, with its hash unchanged, retrying outwards and falling back to a whole-file commit when none does, as when the edit crosses or unbalances a block. An edit inside a block therefore costs in proportion to that block, not the file. The syntax errors of every block it reparses replace that block's, and those elsewhere stay as they were.
///
/// Returns the number of syntax errors in the file, or `fp.pointer.allocationRefused` if allocation fails, having rolled the store back to the previous commit, as `commit` does.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.strings;
/// static import doir.query;
/// static import fp.rope;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.query.create(store);
/// scope(exit) doir.query.free(engine);
/// doir.strings.Strings strings;
/// scope(exit) doir.strings.free(strings);
/// immutable file = addFile(engine, strings, "a.doir");
/// assert(commit(engine, strings, file, "ns : namespace = {\n\tx : T = 1\n}\n") == 0);
/// assert(commitEdit(engine, strings, file, 28, 29, "2") == 0);
/// assert(fp.rope.equal(textOf(engine, file), 20, "x : T = 2"));
/// ---
size_t commitEdit(ref doir.query.QueryEngine engine, ref doir.strings.Strings strings, EntityId file, size_t start, size_t end, const(char)[] replacement) {
	auto store = engine.store;
	auto source = ecrs.context.findComponent!(doir.components.source.SourceText)(*store, file);
	assert(source !is null && start <= end && end <= fp.rope.length(source.text), "doir.source.commitEdit: the file has no text, or the range is outside it");
	doir.query.beginRevision(engine);
	auto made = fp.rope.edit(source.text, start, end, replacement);
	if (made.isNull) return fp.pointer.allocationRefused;
	auto text = made.get;
	bool handed = false;
	scope(exit) if (!handed) fp.rope.free(text);
	immutable delta = cast(ptrdiff_t) replacement.length - cast(ptrdiff_t) (end - start);
	immutable changed = end - start != replacement.length || !fp.rope.equal(source.text, start, replacement);

	EntityId* chain = null;
	size_t* starts = null;
	char* flat = null;
	scope(exit) { fp.dynarray.free(chain); fp.dynarray.free(starts); fp.dynarray.free(flat); }
	if (!enclosing(*store, rootOf(engine, file), start, end, chain, starts)) return fp.pointer.allocationRefused;

	doir.syntax.parser.Syntax syntax;
	scope(exit) doir.syntax.parser.free(syntax);
	Commit c;
	c.engine = &engine;
	c.store = store;
	c.strings = &strings;
	c.syntax = &syntax;
	for (size_t depth = fp.dynarray.length(chain); depth > 0; --depth) {
		immutable e = chain[depth - 1];
		immutable length = ecrs.context.getComponent!(doir.components.source.SourceSpan)(*store, e).length + delta;
		if (fp.dynarray.growToSize(flat, length) is null) return fp.pointer.allocationRefused;
		fp.rope.copy(text, starts[depth - 1], starts[depth - 1] + length, flat[0 .. length]);
		doir.syntax.parser.free(syntax);
		if (!doir.syntax.parser.skim(flat[0 .. length], syntax, cast(uint) (depth - 1))) return fp.pointer.allocationRefused;
		if (!fits(c, e, flat[0 .. length])) continue;
		version(unittest) ++blockCommits;
		c.text = flat[0 .. length];
		c.base = starts[depth - 1];
		handed = true;
		return transact!applyBlock(c, file, text, fp.dynarray.slice(chain)[0 .. depth], delta, changed);
	}

	immutable length = fp.rope.length(text);
	if (fp.dynarray.growToSize(flat, length ? length : 1) is null) return fp.pointer.allocationRefused;
	fp.rope.copy(text, 0, length, flat[0 .. length]);
	c.file = flat[0 .. length];
	handed = true;
	return transact!applyFile(c, file, text);
}

version(unittest) {
	static import core.stdc.stdio;
	static import core.stdc.string;

	private __gshared int valueRuns, lookupRuns, useRuns, fileRuns;

	// How many `commitEdit`s reparsed one declaration rather than the file.
	private __gshared size_t blockCommits;
	// How often a whole-file commit chunked a large declaration's contents, merged a piece whose cut was unsafe, and fell back to skimming a large declaration whole.
	private __gshared size_t largeCommits, mergedPieces, largeFallbacks;

	// Reads a declaration's literal.
	private struct ValueOf {
		alias Key = ecrs.relation.Relation!1;
		alias Value = ulong;
		static ulong compute(ref doir.query.QueryEngine engine, Key key) @nogc nothrow {
			++valueRuns;
			doir.query.read(engine, key.related[0]);
			auto value = ecrs.context.findComponent!(doir.components.ast.ConstantVal)(*engine.store, key.related[0]);
			return value is null ? ulong.max : value.integerValue;
		}
	}

	// Finds `name` in `block`, then in the blocks enclosing it (R-Shadow).
	private struct Lookup {
		struct Key {
			mixin ecrs.relation.Relates!"block";
			doir.strings.StringId name;
		}
		alias Value = ecrs.relation.Relation!1;
		static Value compute(ref doir.query.QueryEngine engine, Key key) @nogc nothrow {
			++lookupRuns;
			doir.query.read(engine, key.block);
			foreach (e; fp.dynarray.slice(ecrs.context.getComponent!(doir.components.ast.Block)(*engine.store, key.block).related)) {
				auto name = ecrs.context.findComponent!(doir.components.ast.Name)(*engine.store, e);
				if (name !is null && name.value == key.name) return Value([e]);
			}
			auto parent = ecrs.context.findComponent!(doir.components.ast.Parent)(*engine.store, key.block);
			if (parent is null) return Value([invalidEntity]);
			return *doir.query.query!Lookup(engine, Key([parent.parent], key.name));
		}
	}

	// Depends on a lookup's answer only.
	private struct UsesLookup {
		alias Key = Lookup.Key;
		alias Value = ecrs.relation.Relation!1;
		static Value compute(ref doir.query.QueryEngine engine, Key key) @nogc nothrow {
			++useRuns;
			return *doir.query.query!Lookup(engine, key);
		}
	}

	// Stands in for an evaluation that reads its own source location (AT-Source): it depends on the file's text.
	private struct ReadsFile {
		alias Key = ecrs.relation.Relation!1;
		alias Value = size_t;
		static size_t compute(ref doir.query.QueryEngine engine, Key key) @nogc nothrow {
			++fileRuns;
			doir.query.read(engine, key.related[0]);
			return fp.rope.length(textOf(engine, key.related[0]));
		}
	}

	// The entity at dotted path `path` below `block`.
	private EntityId named(ref doir.query.QueryEngine engine, ref doir.strings.Strings strings, EntityId block, const(char)[] path) {
		size_t dot = 0;
		while (dot < path.length && path[dot] != '.') ++dot;
		foreach (e; fp.dynarray.slice(ecrs.context.getComponent!(doir.components.ast.Block)(*engine.store, block).related)) {
			auto name = ecrs.context.findComponent!(doir.components.ast.Name)(*engine.store, e);
			if (name is null || doir.strings.text(strings, name.value) != path[0 .. dot]) continue;
			return dot == path.length ? e : named(engine, strings, e, path[dot + 1 .. $]);
		}
		return invalidEntity;
	}

	// Every parsed entity below `block`, in preorder, parts after their declaration.
	private void collect(ref doir.query.QueryEngine engine, EntityId block, ref EntityId* out_) {
		foreach (e; fp.dynarray.slice(ecrs.context.getComponent!(doir.components.ast.Block)(*engine.store, block).related)) {
			assert(fp.dynarray.pushBack(out_, e));
			if (auto parts = ecrs.context.findComponent!(doir.components.source.ParsedParts)(*engine.store, e))
				foreach (part; fp.dynarray.slice(parts.related)) assert(fp.dynarray.pushBack(out_, part));
			if (ecrs.context.hasComponent!(doir.components.ast.Block)(*engine.store, e)) collect(engine, e, out_);
		}
	}

	private __gshared char* locatedBytes = null;

	// `e`'s text, valid until the next call.
	private const(char)[] located(ref doir.query.QueryEngine engine, EntityId file, EntityId e) {
		const at = doir.engine.locations.bytesOf(*engine.store, e).get.bytes;
		immutable length = at.endByte - at.startByte;
		assert(fp.dynarray.growToSize(locatedBytes, length ? length : 1) !is null);
		fp.rope.copy(textOf(engine, file), at.startByte, at.endByte, locatedBytes[0 .. length]);
		return locatedBytes[0 .. length];
	}

	// Whether `file`'s committed text is `expected`.
	private bool textIs(ref doir.query.QueryEngine engine, EntityId file, const(char)[] expected) {
		return fp.rope.length(textOf(engine, file)) == expected.length && fp.rope.equal(textOf(engine, file), 0, expected);
	}

	// The revisions of `entities`, to compare across a commit.
	private doir.query.Revision* revisions(ref doir.query.QueryEngine engine, const(EntityId)[] entities) {
		doir.query.Revision* out_ = null;
		foreach (e; entities) assert(fp.dynarray.pushBack(out_, doir.query.changedAt(engine, e)));
		return out_;
	}
}

unittest { // the corpus parses, and every parsed entity's location slices back to its text
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	auto engine = doir.query.create(store);
	scope(exit) doir.query.free(engine);
	doir.strings.Strings strings;
	scope(exit) doir.strings.free(strings);

	foreach (path; ["standard.doir", "test.doir", "test_call.doir"]) {
		auto text = fp.file.readFile(path).get;
		scope(exit) fp.string.free(text);
		immutable file = addFile(engine, strings, path);
		assert(commit(engine, strings, file, fp.string.slice(text)) == 0);

		doir.syntax.parser.Syntax syntax;
		scope(exit) doir.syntax.parser.free(syntax);
		assert(doir.syntax.parser.skim(fp.string.slice(text), syntax));
		EntityId* all = null;
		scope(exit) fp.dynarray.free(all);
		collect(engine, rootOf(engine, file), all);

		// Declarations come in the records' preorder; parts slice to a function type or a parameter.
		size_t r = 0;
		foreach (e; fp.dynarray.slice(all)) {
			auto span = located(engine, file, e);
			if (ecrs.context.hasComponent!(doir.components.source.SyntaxHash)(store, e)) {
				immutable record = syntax.records[r++];
				assert(span == fp.string.slice(text)[record.spanStart .. record.spanEnd]);
				if (auto name = ecrs.context.findComponent!(doir.components.ast.Name)(store, e)) {
					const spelled = doir.strings.text(strings, name.value);
					assert(span[0 .. spelled.length] == spelled || span[0 .. 7] == "export ");
				}
			} else if (ecrs.context.hasComponent!(doir.components.ast.FunctionInputs)(store, e)) assert(span[0] == '(' && span[$ - 1] != ' ');
			else {
				const spelled = doir.strings.text(strings, ecrs.context.getComponent!(doir.components.ast.Name)(store, e).value);
				assert(span == "_" || span[0 .. spelled.length] == spelled);
			}
		}
		assert(r == fp.dynarray.length(syntax.records));
		assert(located(engine, file, rootOf(engine, file)) == fp.string.slice(text));
	}

	// Order keys follow preorder across a whole file.
	immutable standard = addFile(engine, strings, "again.doir");
	auto text = fp.file.readFile("standard.doir").get;
	scope(exit) fp.string.free(text);
	assert(commit(engine, strings, standard, fp.string.slice(text)) == 0);
	EntityId* all = null;
	scope(exit) fp.dynarray.free(all);
	collect(engine, rootOf(engine, standard), all);
	Position last = doir.engine.positions.root;
	foreach (e; fp.dynarray.slice(all)) {
		auto at = ecrs.context.findComponent!(doir.components.source.LexicalPosition)(store, e);
		if (at is null) continue;
		assert(doir.engine.positions.precedes(engine.positions, last, at.at));
		last = at.at;
	}
}

unittest { // reparsing: what an edit keeps, changes and re-runs
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	auto engine = doir.query.create(store);
	scope(exit) doir.query.free(engine);
	doir.strings.Strings strings;
	scope(exit) doir.strings.free(strings);
	immutable file = addFile(engine, strings, "edit.doir");

	immutable original =
		"a : T = 1\n" ~
		"f : (x: T, y: T) -> T = {\n" ~
		"\t_ : _ = std.print(x)\n" ~
		"\t_ : _ = std.return(y)\n" ~
		"}\n" ~
		"ns : namespace = {\n" ~
		"\tb : T = 2\n" ~
		"\tinner : block = {\n" ~
		"\t\tc : T = 3\n" ~
		"\t\t_ : _ = std.block_result(b)\n" ~
		"\t}\n" ~
		"}\n";
	assert(commit(engine, strings, file, original) == 0);
	immutable root = rootOf(engine, file);
	immutable a = named(engine, strings, root, "a"), f = named(engine, strings, root, "f"), ns = named(engine, strings, root, "ns");
	immutable b = named(engine, strings, root, "ns.b"), inner = named(engine, strings, root, "ns.inner"), c = named(engine, strings, root, "ns.inner.c");
	immutable print = ecrs.context.getComponent!(doir.components.ast.Block)(*engine.store, f).related[0], ret = ecrs.context.getComponent!(doir.components.ast.Block)(*engine.store, f).related[1], yield = ecrs.context.getComponent!(doir.components.ast.Block)(*engine.store, inner).related[1];
	immutable ft = ecrs.context.getComponent!(doir.components.ast.TypeOf)(store, f).type;
	immutable x = ecrs.context.getComponent!(doir.components.ast.FunctionInputs)(store, ft).related[0];

	EntityId* all = null;
	scope(exit) fp.dynarray.free(all);
	collect(engine, root, all);
	immutable everything = fp.dynarray.length(all);
	assert(everything == 12); // a, f, its type and two parameters, two statements, ns, b, inner, c, the yield

	immutable bName = doir.strings.intern(strings, "b");
	void demandAll() {
		assert(*doir.query.query!ValueOf(engine, ValueOf.Key([a])) == 1);
		assert(*doir.query.query!ValueOf(engine, ValueOf.Key([c])) == 3);
		assert(doir.query.query!UsesLookup(engine, UsesLookup.Key([inner], bName)).related[0] == b);
		assert(*doir.query.query!ReadsFile(engine, ReadsFile.Key([file])) == fp.rope.length(textOf(engine, file)));
	}
	void counts(int value, int lookup, int use, int reads) {
		assert(valueRuns == value && lookupRuns == lookup && useRuns == use && fileRuns == reads);
		valueRuns = lookupRuns = useRuns = fileRuns = 0;
	}
	demandAll();
	counts(2, 2, 1, 1); // the lookup of b runs in inner, then in ns

	// Reparsing unchanged text builds nothing, keeps every id and changes no ChangedAt, so nothing re-runs.
	auto before = revisions(engine, fp.dynarray.slice(all));
	scope(exit) fp.dynarray.free(before);
	doir.query.Revision was(EntityId e) {
		foreach (i, old; fp.dynarray.slice(all)) if (old == e) return before[i];
		assert(false);
	}
	immutable keyOfA = ecrs.context.getComponent!(doir.components.source.LexicalPosition)(store, a).at;
	doir.syntax.parser.builds = 0;
	assert(commit(engine, strings, file, original) == 0);
	assert(doir.syntax.parser.builds == 0);
	{
		EntityId* again = null;
		scope(exit) fp.dynarray.free(again);
		collect(engine, root, again);
		assert(fp.dynarray.slice(again) == fp.dynarray.slice(all));
		auto now = revisions(engine, fp.dynarray.slice(again));
		scope(exit) fp.dynarray.free(now);
		assert(fp.dynarray.slice(now) == fp.dynarray.slice(before));
	}
	demandAll();
	counts(0, 0, 0, 0);

	// A blank line and a comment above `a` move every span, but keep its order key and ChangedAt; only the file's readers re-run.
	enum moved = "\n// a comment\n" ~ original;
	doir.syntax.parser.builds = 0;
	assert(commit(engine, strings, file, moved) == 0);
	assert(doir.syntax.parser.builds == 0); // every declaration's text is unchanged, so each is skipped whole
	assert(named(engine, strings, root, "a") == a && ecrs.context.getComponent!(doir.components.source.LexicalPosition)(store, a).at == keyOfA);
	foreach (i, e; fp.dynarray.slice(all)) assert(doir.query.changedAt(engine, e) == before[i]);
	assert(located(engine, file, a) == "a : T = 1" && located(engine, file, x) == "x: T");
	demandAll();
	counts(0, 0, 0, 1);

	// A comment inside a declaration changes no ChangedAt, and keeps its parts, whose spans follow the text.
	enum commented = "\n// a comment\n" ~
		"a : T = 1\n" ~
		"f : (x: T, /* the second */ y: T) -> T = {\n" ~
		original["a : T = 1\nf : (x: T, y: T) -> T = {\n".length .. $];
	doir.syntax.parser.builds = 0;
	assert(commit(engine, strings, file, commented) == 0);
	assert(doir.syntax.parser.builds == 1); // f alone, for its parameters' spans
	{
		EntityId* again = null;
		scope(exit) fp.dynarray.free(again);
		collect(engine, root, again);
		assert(fp.dynarray.slice(again) == fp.dynarray.slice(all));
		foreach (i, e; fp.dynarray.slice(again)) assert(doir.query.changedAt(engine, e) == before[i]);
		immutable y = ecrs.context.getComponent!(doir.components.ast.FunctionInputs)(store, ft).related[1];
		assert(located(engine, file, y) == "y: T" && located(engine, file, ft) == "(x: T, /* the second */ y: T) -> T");
	}
	demandAll();
	counts(0, 0, 0, 1);

	// Editing one declaration's value re-runs only its readers, and changes only its ChangedAt.
	enum edited = "a : T = 5\n" ~ original["a : T = 1\n".length .. $];
	assert(commit(engine, strings, file, edited) == 0);
	assert(named(engine, strings, root, "a") == a && doir.query.changedAt(engine, a) == engine.revision);
	foreach (i, e; fp.dynarray.slice(all)) if (e != a) assert(doir.query.changedAt(engine, e) == before[i]);
	assert(*doir.query.query!ValueOf(engine, ValueOf.Key([a])) == 5);
	assert(*doir.query.query!ValueOf(engine, ValueOf.Key([c])) == 3);
	assert(doir.query.query!UsesLookup(engine, UsesLookup.Key([inner], bName)).related[0] == b);
	counts(1, 0, 0, 0);

	// Editing inside a block changes the nested declaration, not the one around it.
	enum deeper = edited[0 .. $ - "\t\tc : T = 3\n\t\t_ : _ = std.block_result(b)\n\t}\n}\n".length] ~ "\t\tc : T = 4\n\t\t_ : _ = std.block_result(b)\n\t}\n}\n";
	doir.syntax.parser.builds = 0;
	assert(commit(engine, strings, file, deeper) == 0);
	assert(doir.syntax.parser.builds == 1); // c alone: ns and inner are descended, not rebuilt
	assert(named(engine, strings, root, "ns.inner.c") == c && doir.query.changedAt(engine, c) == engine.revision);
	assert(doir.query.changedAt(engine, inner) == was(inner) && doir.query.changedAt(engine, ns) == was(ns));
	assert(*doir.query.query!ValueOf(engine, ValueOf.Key([c])) == 4);
	counts(1, 0, 0, 0);

	// A comment inside a namespace builds nothing, and what follows it is located at its new place.
	enum spaced = deeper[0 .. "a : T = 5\n".length + "f : (x: T, y: T) -> T = {\n\t_ : _ = std.print(x)\n\t_ : _ = std.return(y)\n}\nns : namespace = {\n".length] ~ "\t// note\n" ~ deeper["a : T = 5\nf : (x: T, y: T) -> T = {\n\t_ : _ = std.print(x)\n\t_ : _ = std.return(y)\n}\nns : namespace = {\n".length .. $];
	doir.syntax.parser.builds = 0;
	assert(commit(engine, strings, file, spaced) == 0);
	assert(doir.syntax.parser.builds == 0 && doir.query.changedAt(engine, ns) == was(ns));
	assert(located(engine, file, c) == "c : T = 4" && located(engine, file, b) == "b : T = 2");
	assert(commit(engine, strings, file, deeper) == 0);

	// Inserting a declaration marks its block: lookups through it re-run, and early cutoff stops them when nothing is shadowed.
	enum inserted = deeper[0 .. $ - "\t\t_ : _ = std.block_result(b)\n\t}\n}\n".length] ~ "\t\td : T = 9\n\t\t_ : _ = std.block_result(b)\n\t}\n}\n";
	assert(commit(engine, strings, file, inserted) == 0);
	assert(fp.dynarray.length(ecrs.context.getComponent!(doir.components.ast.Block)(*engine.store, inner).related) == 3 && ecrs.context.getComponent!(doir.components.ast.Block)(*engine.store, inner).related[2] == yield && doir.query.changedAt(engine, inner) == engine.revision);
	assert(doir.query.query!UsesLookup(engine, UsesLookup.Key([inner], bName)).related[0] == b);
	counts(0, 1, 0, 0);

	// A new name that shadows the one found re-runs the lookup's dependents too (R-Shadow).
	enum shadowing = inserted[0 .. $ - "\t\t_ : _ = std.block_result(b)\n\t}\n}\n".length] ~ "\t\tb : T = 8\n\t\t_ : _ = std.block_result(b)\n\t}\n}\n";
	assert(commit(engine, strings, file, shadowing) == 0);
	immutable shadow = named(engine, strings, root, "ns.inner.b");
	assert(shadow != invalidEntity && shadow != b);
	assert(doir.query.query!UsesLookup(engine, UsesLookup.Key([inner], bName)).related[0] == shadow);
	counts(0, 1, 1, 0);

	// An inserted `_` declaration between two others matches both of them.
	enum statements = shadowing[0 .. "a : T = 5\nf : (x: T, y: T) -> T = {\n".length] ~ "\t_ : _ = std.print(x)\n\t_ : _ = std.log(x)\n\t_ : _ = std.return(y)\n}\n" ~ shadowing["a : T = 5\nf : (x: T, y: T) -> T = {\n\t_ : _ = std.print(x)\n\t_ : _ = std.return(y)\n}\n".length .. $];
	assert(commit(engine, strings, file, statements) == 0);
	assert(fp.dynarray.length(ecrs.context.getComponent!(doir.components.ast.Block)(*engine.store, f).related) == 3 && ecrs.context.getComponent!(doir.components.ast.Block)(*engine.store, f).related[0] == print && ecrs.context.getComponent!(doir.components.ast.Block)(*engine.store, f).related[2] == ret);
	assert(doir.query.changedAt(engine, print) == was(print) && doir.query.changedAt(engine, ret) == was(ret));
	assert(doir.query.changedAt(engine, f) == engine.revision);
	assert(ecrs.context.getComponent!(doir.components.ast.TypeOf)(store, f).type == ft); // f was not rebuilt: its body is not its hash

	// Reordering keeps both ids; one keeps its order key, the moved one gets a new key and is marked changed.
	enum reordered = statements[0 .. "a : T = 5\n".length] ~ "zz : T = 7\n" ~ statements["a : T = 5\n".length .. $];
	assert(commit(engine, strings, file, reordered) == 0);
	immutable zz = named(engine, strings, root, "zz");
	enum swapped = "zz : T = 7\n" ~ reordered[0 .. "a : T = 5\n".length] ~ reordered["a : T = 5\nzz : T = 7\n".length .. $];
	assert(commit(engine, strings, file, swapped) == 0);
	assert(named(engine, strings, root, "zz") == zz && named(engine, strings, root, "a") == a);
	assert(ecrs.context.getComponent!(doir.components.ast.Block)(*engine.store, root).related[0] == zz && ecrs.context.getComponent!(doir.components.ast.Block)(*engine.store, root).related[1] == a);
	assert(doir.engine.positions.precedes(engine.positions, ecrs.context.getComponent!(doir.components.source.LexicalPosition)(store, zz).at, ecrs.context.getComponent!(doir.components.source.LexicalPosition)(store, a).at));
	assert(doir.query.changedAt(engine, zz) == engine.revision && doir.query.changedAt(engine, a) != engine.revision);
	assert(doir.query.changedAt(engine, root) == engine.revision);

	// Renaming is a new key: the old entity is removed and a new one made; a removed declaration leaves its block.
	enum renamed = "zz : T = 7\nalpha : T = 5\n" ~ swapped["zz : T = 7\na : T = 5\n".length .. $];
	assert(commit(engine, strings, file, renamed) == 0);
	assert(named(engine, strings, root, "a") == invalidEntity && named(engine, strings, root, "alpha") != invalidEntity);
	enum removed = renamed["zz : T = 7\n".length .. $];
	assert(commit(engine, strings, file, removed) == 0);
	assert(named(engine, strings, root, "zz") == invalidEntity && fp.dynarray.length(ecrs.context.getComponent!(doir.components.ast.Block)(*engine.store, root).related) == 3);

	// A parameter edit rebuilds the function's type in its old parts, keeping their ids.
	enum retyped = removed[0 .. "alpha : T = 5\n".length] ~ "f : (x: U, y: T) -> T = {\n" ~ removed["alpha : T = 5\nf : (x: T, y: T) -> T = {\n".length .. $];
	assert(commit(engine, strings, file, retyped) == 0);
	assert(named(engine, strings, root, "f") == f && ecrs.context.getComponent!(doir.components.ast.TypeOf)(store, f).type == ft);
	assert(ecrs.context.getComponent!(doir.components.ast.FunctionInputs)(store, ft).related[0] == x);
	assert(doir.strings.text(strings, ecrs.context.getComponent!(doir.components.ast.LookupTypeOf)(store, x).name) == "U");
	assert(doir.query.changedAt(engine, f) == engine.revision && doir.query.changedAt(engine, x) == engine.revision);
	assert(fp.dynarray.length(ecrs.context.getComponent!(doir.components.ast.Block)(*engine.store, f).related) == 3 && ecrs.context.getComponent!(doir.components.ast.Block)(*engine.store, f).related[0] == print); // the body was matched, not rebuilt

	// A declaration that changes kind keeps its entity; its new block's contents are new.
	enum kind = "alpha : namespace = {\n\tk : T\n}\n" ~ retyped["alpha : T = 5\n".length .. $];
	immutable alpha = named(engine, strings, root, "alpha");
	assert(commit(engine, strings, file, kind) == 0);
	assert(named(engine, strings, root, "alpha") == alpha && !ecrs.context.hasComponent!(doir.components.ast.ConstantVal)(store, alpha));
	assert(named(engine, strings, root, "alpha.k") != invalidEntity);
	assert(ecrs.context.getComponent!(doir.components.ast.Flags)(store, alpha).flags == doir.components.ast.Flags.Namespace);

	// A syntax error drops only the broken declaration; fixing it brings it back.
	enum broken = kind[0 .. $ - "}\n".length] ~ "\toops : = 1\n}\n";
	assert(commit(engine, strings, file, broken) == 1);
	assert(named(engine, strings, root, "ns.b") == b && named(engine, strings, root, "ns.inner.c") == c);
	assert(commit(engine, strings, file, kind) == 0);
	assert(named(engine, strings, root, "ns.b") == b);

	// Dropping a parameter rebuilds the type in fewer parts, removing the one left over.
	immutable y = ecrs.context.getComponent!(doir.components.ast.FunctionInputs)(store, ft).related[1];
	enum unary = "alpha : namespace = {\n\tk : T\n}\nf : (x: U) -> T = {\n" ~ retyped["alpha : T = 5\nf : (x: U, y: T) -> T = {\n".length .. $];
	assert(commit(engine, strings, file, unary) == 0);
	assert(fp.dynarray.length(ecrs.context.getComponent!(doir.components.ast.FunctionInputs)(store, ft).related) == 1);
	assert(!ecrs.context.hasComponent!(doir.components.ast.Parent)(store, y));

	// Removing a declaration removes its parts and everything nested in its block.
	assert(commit(engine, strings, file, "alpha : namespace = {\n\tk : T\n}\n") == 0);
	assert(fp.dynarray.length(ecrs.context.getComponent!(doir.components.ast.Block)(*engine.store, root).related) == 1);
	immutable EntityId[7] gone = [f, ft, x, ns, b, inner, c];
	foreach (e; gone) assert(!ecrs.context.hasComponent!(doir.components.source.SyntaxHash)(store, e) && !ecrs.context.hasComponent!(doir.components.ast.Parent)(store, e));
}

unittest { // reopened namespaces match by occurrence, and unnamed declarations by alignment
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	auto engine = doir.query.create(store);
	scope(exit) doir.query.free(engine);
	doir.strings.Strings strings;
	scope(exit) doir.strings.free(strings);
	immutable file = addFile(engine, strings, "merge.doir");

	assert(commit(engine, strings, file, "m : namespace = {\n\tx : T = 1\n}\nm : namespace = {\n\ty : T = 2\n}\n") == 0);
	immutable root = rootOf(engine, file);
	immutable first = ecrs.context.getComponent!(doir.components.ast.Block)(*engine.store, root).related[0], second = ecrs.context.getComponent!(doir.components.ast.Block)(*engine.store, root).related[1];
	immutable y = ecrs.context.getComponent!(doir.components.ast.Block)(*engine.store, second).related[0];
	assert(commit(engine, strings, file, "m : namespace = {\n\tx : T = 1\n}\nm : namespace = {\n\ty : T = 3\n}\n") == 0);
	assert(ecrs.context.getComponent!(doir.components.ast.Block)(*engine.store, root).related[0] == first && ecrs.context.getComponent!(doir.components.ast.Block)(*engine.store, root).related[1] == second && ecrs.context.getComponent!(doir.components.ast.Block)(*engine.store, second).related[0] == y);
	assert(doir.query.changedAt(engine, y) == engine.revision && doir.query.changedAt(engine, first) != engine.revision);

	// Alignment: unchanged runs at both ends, and the longest common run in the middle.
	size_t[2]* pairs = null;
	scope(exit) fp.dynarray.free(pairs);
	static immutable ulong[6] before = [1, 2, 3, 4, 5, 6], after = [1, 3, 9, 4, 6, 7];
	assert(align_(before[], after[], pairs));
	assert(fp.dynarray.slice(pairs) == cast(size_t[2][]) [[0, 0], [2, 1], [3, 3], [5, 4]]);
	fp.dynarray.clear(pairs);
	assert(align_(before[], before[], pairs));
	assert(fp.dynarray.length(pairs) == 6);
	fp.dynarray.clear(pairs);
	assert(align_(before[0 .. 0], before[], pairs));
	assert(fp.dynarray.length(pairs) == 0);
}

unittest { // diagnostics: syntax errors at their position, query diagnostics at their subject, annotations instead of either, each pointed at with a hint
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	diagnose.Manager manager;
	scope(exit) diagnose.free(manager);
	auto engine = doir.query.create(store);
	scope(exit) doir.query.free(engine);
	engine.diagnostics = &manager;
	doir.strings.Strings strings;
	scope(exit) doir.strings.free(strings);
	immutable file = addFile(engine, strings, "diag.doir");

	assert(commit(engine, strings, file, "a : T = 1\n\nb : = 2\nc : T = 3 <\"gen.doir\":7:2>\n") == 1);
	assert(diagnose.count(manager) == 0 && reportSyntaxErrors(engine, file, manager) && diagnose.count(manager) == 1);
	assert(manager.diagnostics[0].location.file == "diag.doir" && manager.diagnostics[0].location.start == diagnose.Pair(3, 5));
	assert(fp.string.slice(manager.diagnostics[0].message) == "syntax error, unexpected '=' where the declared type should be");
	assert(fp.dynarray.length(manager.diagnostics[0].annotations) == 1 && manager.diagnostics[0].annotations[0].position == diagnose.Pair(3, 5));
	assert(fp.string.slice(manager.diagnostics[0].annotations[0].message) == "insert a type or `_` here");
	assert(fp.string.slice(manager.diagnostics[0].additionalNote) == "Every declaration names its type between `:` and `=`. Write `_` there to have the compiler work the type out, as in `count : _ = 5`."); // the explanation is the closing note

	// The hint is drawn at the subject, and each related entity gets an annotation, naming its file when it is another.
	immutable root = rootOf(engine, file);
	immutable a = named(engine, strings, root, "a"), c = named(engine, strings, root, "c");
	immutable doir.query.Related[1] toC = [doir.query.Related([c], "c is involved")], toA = [doir.query.Related([a], "a is involved")];
	assert(doir.query.report(engine, a, diagnose.Kind.warning, "about a", "fix a", toC[]));
	const aboutA = &manager.diagnostics[1];
	assert(aboutA.location.start == diagnose.Pair(1, 1) && aboutA.location.end == diagnose.Pair(1, 10) && aboutA.additionalNote is null);
	assert(fp.dynarray.length(aboutA.annotations) == 2);
	assert(aboutA.annotations[0].position == diagnose.Pair(1, 1) && aboutA.annotations[0].file is null && fp.string.slice(aboutA.annotations[0].message) == "fix a");
	assert(aboutA.annotations[1].position == diagnose.Pair(7, 2) && aboutA.annotations[1].file == "gen.doir" && fp.string.slice(aboutA.annotations[1].message) == "c is involved");
	assert(doir.query.report(engine, c, diagnose.Kind.warning, "about c", "fix c", toA[]));
	const aboutC = &manager.diagnostics[2];
	assert(aboutC.location.file == "gen.doir" && aboutC.location.start == diagnose.Pair(7, 2));
	assert(aboutC.annotations[0].position == diagnose.Pair(7, 2) && aboutC.annotations[1].file == "diag.doir" && aboutC.annotations[1].position == diagnose.Pair(1, 1));

	// A refused allocation loses the diagnostic whole, never a part of it.
	for (size_t budget = 0;; ++budget) {
		immutable before = diagnose.count(manager);
		auto allocator = fp.testing.beginRationedAllocator(budget);
		immutable reported = doir.query.report(engine, a, diagnose.Kind.warning, "about a", "fix a", toC[]);
		fp.testing.endRationedAllocator(allocator);
		if (!reported) {
			assert(diagnose.count(manager) == before && engine.refused);
			engine.refused = false;
			continue;
		}
		assert(budget > 0 && fp.dynarray.length(manager.diagnostics[before].annotations) == 2);
		break;
	}

	// A missing closer points at the bracket it would close.
	diagnose.clear(manager);
	immutable open = addFile(engine, strings, "open.doir");
	assert(commit(engine, strings, open, "ns : namespace = {\n\tx : T = 1\n") == 1 && reportSyntaxErrors(engine, open, manager));
	const unclosed = &manager.diagnostics[0];
	assert(fp.dynarray.length(unclosed.annotations) == 2);
	assert(fp.string.slice(unclosed.annotations[0].message) == "insert `}` here to close the `{` left open");
	assert(unclosed.annotations[1].position == diagnose.Pair(1, 18) && fp.string.slice(unclosed.annotations[1].message) == "opened here");

	// The annotation is the declaration's own: removing it from the text removes it from the entity.
	assert(commit(engine, strings, file, "a : T = 1\nc : T = 3\n") == 0);
	assert(!ecrs.context.hasComponent!(doir.components.source.SourceAnnotation)(store, named(engine, strings, root, "c")));
}

unittest { // a refused allocation anywhere in a commit rolls the store back to the previous commit and reports nothing
	static import ecrs.serialization;
	static immutable original = "a : T = 1\nns : namespace = {\n\tx : T = 2\n\tf : (p: T = 0) -> T\n}\n_ : _ = std.return(a)\n";
	// Each edit with its syntax errors: `ns` losing its block removes its contents, and an unclosed block points back at its `{`.
	static immutable edits = [
		"a : T = 1\nns : namespace = {\n\tx : U = 2\n\tnew : T\n\tf : (p: T = 1, q: T) -> T <\"g.doir\":1:1>\n}\nb : = 3\n",
		"// moved\nns : namespace = {\n\tf : (p: T = 0) -> T\n}\n_ : _ = std.return(a)\n_ : _ = std.block_result(a)\n",
		"",
		"a : T = 1\nns : T\n_ : _ = std.return(a)\n",
		"a : T = 1\nns : namespace = {\n\tx : T = 2\n",
	];
	static immutable size_t[edits.length] errors = [1, 0, 0, 0, 1];
	// Emptying the file allocates little: the skim, and the root's new entry list.
	static immutable size_t[edits.length] leastRefusals = [50, 50, 5, 25, 25];

	// A file's first commit and the `addFile` before it: a refusal in either leaves the store as it was.
	for (size_t budget = 0;; ++budget) {
		auto store = ecrs.context.create();
		scope(exit) ecrs.context.free(store);
		auto engine = doir.query.create(store);
		scope(exit) doir.query.free(engine);
		doir.strings.Strings strings;
		scope(exit) doir.strings.free(strings);
		auto empty = ecrs.serialization.serialize(store);
		assert(empty !is null);
		scope(exit) fp.dynarray.free(empty);

		auto allocator = fp.testing.beginRationedAllocator(budget);
		immutable file = addFile(engine, strings, "r.doir");
		fp.testing.endRationedAllocator(allocator);
		if (file == invalidEntity) {
			auto after = ecrs.serialization.serialize(store);
			assert(after !is null);
			scope(exit) fp.dynarray.free(after);
			assert(fp.dynarray.slice(after) == fp.dynarray.slice(empty));
			continue;
		}
		auto before = ecrs.serialization.serialize(store);
		assert(before !is null);
		scope(exit) fp.dynarray.free(before);
		allocator = fp.testing.beginRationedAllocator(budget);
		immutable result = commit(engine, strings, file, original);
		fp.testing.endRationedAllocator(allocator);
		if (result != fp.pointer.allocationRefused) {
			assert(result == 0 && textIs(engine, file, original));
			break;
		}
		auto after = ecrs.serialization.serialize(store);
		assert(after !is null);
		scope(exit) fp.dynarray.free(after);
		assert(fp.dynarray.slice(after) == fp.dynarray.slice(before) && rootOf(engine, file) == invalidEntity);
	}

	foreach (i, edit; edits) {
		size_t refusals = 0;
		for (size_t budget = 0;; ++budget) {
			auto store = ecrs.context.create();
			scope(exit) ecrs.context.free(store);
			diagnose.Manager manager;
			scope(exit) diagnose.free(manager);
			auto engine = doir.query.create(store);
			scope(exit) doir.query.free(engine);
			engine.diagnostics = &manager;
			doir.strings.Strings strings;
			scope(exit) doir.strings.free(strings);
			immutable file = addFile(engine, strings, "r.doir");
			assert(file != invalidEntity && commit(engine, strings, file, original) == 0);
			auto before = ecrs.serialization.serialize(store);
			assert(before !is null);
			scope(exit) fp.dynarray.free(before);

			auto allocator = fp.testing.beginRationedAllocator(budget);
			immutable result = commit(engine, strings, file, edit);
			fp.testing.endRationedAllocator(allocator);
			if (result != fp.pointer.allocationRefused) {
				assert(result == errors[i] && textIs(engine, file, edit));
				break;
			}
			++refusals;
			auto after = ecrs.serialization.serialize(store);
			assert(after !is null);
			scope(exit) fp.dynarray.free(after);
			assert(fp.dynarray.slice(after) == fp.dynarray.slice(before));
			assert(textIs(engine, file, original) && diagnose.count(manager) == 0);
			// The rolled-back store still commits, and an unchanged text is still recognised as unchanged.
			immutable x = named(engine, strings, rootOf(engine, file), "ns.x");
			assert(commit(engine, strings, file, original) == 0 && named(engine, strings, rootOf(engine, file), "ns.x") == x);
		}
		assert(refusals >= leastRefusals[i]);
	}
}

version(unittest) {
	// Asserts that `a`, committed by edits into `ea`, and `b`, committed whole into `eb`, are the same tree: names, spans, keys, hashes, parts and revisions.
	private void assertSameTree(ref doir.query.QueryEngine ea, ref doir.strings.Strings sa, EntityId a, ref doir.query.QueryEngine eb, ref doir.strings.Strings sb, EntityId b) {
		auto storeA = ea.store, storeB = eb.store;
		static bool sameSpan(ref ecrs.context.Context x, EntityId p, ref ecrs.context.Context y, EntityId q) {
			auto s = ecrs.context.findComponent!(doir.components.source.SourceSpan)(x, p), t = ecrs.context.findComponent!(doir.components.source.SourceSpan)(y, q);
			return (s is null) == (t is null) && (s is null || *s == *t);
		}
		assert(sameSpan(*storeA, a, *storeB, b));
		assert(doir.query.changedAt(ea, a) == doir.query.changedAt(eb, b));
		auto nameA = ecrs.context.findComponent!(doir.components.ast.Name)(*storeA, a), nameB = ecrs.context.findComponent!(doir.components.ast.Name)(*storeB, b);
		assert((nameA is null) == (nameB is null) && (nameA is null || doir.strings.text(sa, nameA.value) == doir.strings.text(sb, nameB.value)));
		auto hashA = ecrs.context.findComponent!(doir.components.source.SyntaxHash)(*storeA, a), hashB = ecrs.context.findComponent!(doir.components.source.SyntaxHash)(*storeB, b);
		assert((hashA is null) == (hashB is null) && (hashA is null || hashA.value == hashB.value));
		auto pathA = ecrs.context.findComponent!(doir.components.source.PathHash)(*storeA, a), pathB = ecrs.context.findComponent!(doir.components.source.PathHash)(*storeB, b);
		assert((pathA is null) == (pathB is null) && (pathA is null || pathA.value == pathB.value));
		auto atA = ecrs.context.findComponent!(doir.components.source.LexicalPosition)(*storeA, a), atB = ecrs.context.findComponent!(doir.components.source.LexicalPosition)(*storeB, b);
		assert((atA is null) == (atB is null) && (atA is null || doir.engine.positions.compare(ea.positions, atA.at, atB.at) == 0 || atA.at.value == atB.at.value));
		auto partsA = ecrs.context.findComponent!(doir.components.source.ParsedParts)(*storeA, a), partsB = ecrs.context.findComponent!(doir.components.source.ParsedParts)(*storeB, b);
		assert((partsA is null) == (partsB is null));
		if (partsA !is null) {
			assert(fp.dynarray.length(partsA.related) == fp.dynarray.length(partsB.related));
			foreach (i, part; fp.dynarray.slice(partsA.related)) {
				assert(sameSpan(*storeA, part, *storeB, partsB.related[i]));
				assert(doir.query.changedAt(ea, part) == doir.query.changedAt(eb, partsB.related[i]));
			}
		}
		auto errorsA = ecrs.context.findComponent!(doir.components.source.SyntaxErrors)(*storeA, a), errorsB = ecrs.context.findComponent!(doir.components.source.SyntaxErrors)(*storeB, b);
		assert((errorsA is null) == (errorsB is null));
		if (errorsA !is null) {
			assert(fp.dynarray.length(errorsA.errors) == fp.dynarray.length(errorsB.errors));
			foreach (i, error; fp.dynarray.slice(errorsA.errors)) {
				const other = &errorsB.errors[i];
				assert(error.at == other.at && error.opening == other.opening);
				assert(fp.string.slice(error.message) == fp.string.slice(other.message) && fp.string.slice(error.hint) == fp.string.slice(other.hint) && fp.string.slice(error.note) == fp.string.slice(other.note));
			}
		}
		auto blockA = ecrs.context.findComponent!(doir.components.ast.Block)(*storeA, a), blockB = ecrs.context.findComponent!(doir.components.ast.Block)(*storeB, b);
		assert((blockA is null) == (blockB is null));
		if (blockA is null) return;
		assert(fp.dynarray.length(blockA.related) == fp.dynarray.length(blockB.related));
		foreach (i, child; fp.dynarray.slice(blockA.related)) assertSameTree(ea, sa, child, eb, sb, blockB.related[i]);
	}
}

unittest { // edits: an edit inside a block reparses that declaration alone and writes what a whole-file commit of the edited text would
	static import doir.printer;

	// Each case: the text, the edit, and whether it stays inside one declaration's block.
	static struct Case { string text; size_t start, end; string replacement; bool inBlock; }
	static immutable nested = "outer : namespace = {\n\tinner : namespace = {\n\t\tx : T = 1\n\t}\n\ty : T = 2\n}\nz : T = 3\n";
	static immutable Case[] cases = [
		Case(nested, 55, 56, "7", true), // x's value
		Case(nested, 60, 60, "\tw : T = 4\n", true), // a declaration added to outer
		Case(nested, 8, 8, "/* c */ ", true), // trivia inside outer's header: rebuilt, unchanged
		Case(nested, 47, 47, "/*", false), // an unclosed comment swallows the braces
		Case(nested, 58, 59, "", false), // inner's `}` removed
		Case(nested, 50, 65, "", false), // across inner's end
		Case(nested, 0, 5, "renamed", false), // outer's name: its hash changes
		Case(nested, 73, 73, "q : T = 1\n", false), // at the top level
		Case(nested, 55, 55, "r\"\"\"", true), // an unclosed raw string, which the lexer ends where it opens
		Case(nested, 55, 56, "", true), // x loses its value: an error inside a block
	];
	foreach (k, test; cases) {
		auto storeA = ecrs.context.create(), storeB = ecrs.context.create();
		scope(exit) { ecrs.context.free(storeA); ecrs.context.free(storeB); }
		auto ea = doir.query.create(storeA), eb = doir.query.create(storeB);
		scope(exit) { doir.query.free(ea); doir.query.free(eb); }
		doir.strings.Strings sa, sb;
		scope(exit) { doir.strings.free(sa); doir.strings.free(sb); }
		immutable fa = addFile(ea, sa, "a.doir"), fb = addFile(eb, sb, "a.doir");
		assert(commit(ea, sa, fa, test.text) == 0 && commit(eb, sb, fb, test.text) == 0);
		immutable z = named(ea, sa, rootOf(ea, fa), "z");
		immutable before = blockCommits;
		assert(commitEdit(ea, sa, fa, test.start, test.end, test.replacement) != fp.pointer.allocationRefused);
		assert((blockCommits > before) == test.inBlock);
		auto edited = fp.string.createFromConcatenation(test.text[0 .. test.start], test.replacement, test.text[test.end .. $]);
		scope(exit) fp.string.free(edited);
		assert(commit(eb, sb, fb, fp.string.slice(edited)) != fp.pointer.allocationRefused);
		assert(textIs(ea, fa, fp.string.slice(edited)));
		assertSameTree(ea, sa, rootOf(ea, fa), eb, sb, rootOf(eb, fb));
		// A declaration outside the edited one keeps its entity and its revision.
		if (test.inBlock) assert(named(ea, sa, rootOf(ea, fa), "z") == z && doir.query.changedAt(ea, z) < ea.revision);
	}

	// Random edits over the corpus, each compared with a whole-file commit of the same text.
	size_t inBlock = 0, total = 0;
	// Typing-like replacements, and ones that unbalance a block or swallow what follows, which are rarer since the file stays broken after them.
	static immutable string[] replacements = ["", "x", "\n", " ", "1", "q : T = 1\n", "//c\n", "_ : T = 1\n", "n : namespace = {\n\ta : T = 1\n}\n", "f : (p: T) -> T\n"];
	static immutable string[] breaking = ["}", "{", "/*", "*/", "\""];
	uint seed = 7;
	uint next() { seed = seed * 1103515245 + 12345; return seed >> 8; }
	foreach (path; ["standard.doir", "test.doir", "test_call.doir"]) {
		auto read = fp.file.readFile(path).get;
		scope(exit) fp.string.free(read);
		auto storeA = ecrs.context.create(), storeB = ecrs.context.create();
		scope(exit) { ecrs.context.free(storeA); ecrs.context.free(storeB); }
		auto ea = doir.query.create(storeA), eb = doir.query.create(storeB);
		scope(exit) { doir.query.free(ea); doir.query.free(eb); }
		doir.strings.Strings sa, sb;
		scope(exit) { doir.strings.free(sa); doir.strings.free(sb); }
		immutable fa = addFile(ea, sa, path), fb = addFile(eb, sb, path);
		char* model = fp.string.makeDynamic(fp.string.slice(read));
		scope(exit) fp.string.free(model);
		assert(commit(ea, sa, fa, fp.string.slice(model)) != fp.pointer.allocationRefused);
		assert(commit(eb, sb, fb, fp.string.slice(model)) != fp.pointer.allocationRefused);
		foreach (round; 0 .. 150) {
			immutable size = fp.string.length(model);
			immutable start = next() % (size + 1);
			immutable span = round % 10 == 0 ? next() % 200 : next() % 6;
			immutable end = start + span > size ? size : start + span;
			const(char)[] replacement = round % 10 == 9 ? breaking[next() % breaking.length] : replacements[next() % replacements.length];
			size_t from = start, to = end;
			// Back to the original now and then, as a whole-text edit.
			if (round % 25 == 24) {
				from = 0;
				to = size;
				replacement = fp.string.slice(read);
			}
			immutable before = blockCommits;
			assert(commitEdit(ea, sa, fa, from, to, replacement) != fp.pointer.allocationRefused);
			inBlock += blockCommits - before;
			++total;
			assert(fp.string.replaceRange(model, replacement, from, to - from) !is null || fp.string.length(model) == 0);
			assert(commit(eb, sb, fb, fp.string.slice(model)) != fp.pointer.allocationRefused);
			assert(textIs(ea, fa, fp.string.slice(model)));
			assertSameTree(ea, sa, rootOf(ea, fa), eb, sb, rootOf(eb, fb));
			auto printedA = doir.printer.print(*ea.store, sa, rootOf(ea, fa)).get, printedB = doir.printer.print(*eb.store, sb, rootOf(eb, fb)).get;
			scope(exit) { fp.string.free(printedA); fp.string.free(printedB); }
			assert(fp.string.slice(printedA) == fp.string.slice(printedB));
			// The errors kept per block report as a whole-file parse finds them.
			assert(syntaxErrorCount(ea, fa) == syntaxErrorCount(eb, fb));
			diagnose.Manager ma, mb;
			scope(exit) { diagnose.free(ma); diagnose.free(mb); }
			assert(reportSyntaxErrors(ea, fa, ma) && reportSyntaxErrors(eb, fb, mb) && diagnose.count(ma) == diagnose.count(mb));
			foreach (i, d; fp.dynarray.slice(ma.diagnostics)) {
				const other = &mb.diagnostics[i];
				assert(d.location.start == other.location.start && fp.string.slice(d.message) == fp.string.slice(other.message));
				assert(fp.dynarray.length(d.annotations) == fp.dynarray.length(other.annotations));
				foreach (j, annotation; fp.dynarray.slice(d.annotations))
					assert(annotation.position == other.annotations[j].position && fp.string.slice(annotation.message) == fp.string.slice(other.annotations[j].message));
			}
		}
	}
	// Both paths were taken often enough to mean something.
	assert(inBlock > total / 5 && inBlock < total);
}

unittest { // a refused allocation anywhere in an edit, reparsed alone or whole, rolls the store back to the previous commit
	static import ecrs.serialization;
	// The error after `ns` is the root's, which an edit inside `ns` moves.
	static immutable original = "a : T = 1\nns : namespace = {\n\tx : T = 2\n\tf : (p: T = 0) -> T\n}\nb : = 3\n";
	static struct Edit { size_t start, end; string replacement; }
	static immutable Edit[] edits = [Edit(37, 38, "3\n\ty : T = 4"), Edit(30, 30, "/*")];
	foreach (edit; edits) {
		for (size_t budget = 0;; ++budget) {
			auto store = ecrs.context.create();
			scope(exit) ecrs.context.free(store);
			auto engine = doir.query.create(store);
			scope(exit) doir.query.free(engine);
			doir.strings.Strings strings;
			scope(exit) doir.strings.free(strings);
			immutable file = addFile(engine, strings, "r.doir");
			assert(file != invalidEntity && commit(engine, strings, file, original) == 1);
			auto before = ecrs.serialization.serialize(store);
			assert(before !is null);
			scope(exit) fp.dynarray.free(before);

			auto allocator = fp.testing.beginRationedAllocator(budget);
			immutable result = commitEdit(engine, strings, file, edit.start, edit.end, edit.replacement);
			fp.testing.endRationedAllocator(allocator);
			if (result != fp.pointer.allocationRefused) break;
			auto after = ecrs.serialization.serialize(store);
			assert(after !is null);
			scope(exit) fp.dynarray.free(after);
			assert(fp.dynarray.slice(after) == fp.dynarray.slice(before) && textIs(engine, file, original));
		}
	}
}

unittest { // syntax errors are kept on the block that holds them: an edit replaces its own block's, moves the rest, and they report in source order
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	auto engine = doir.query.create(store);
	scope(exit) doir.query.free(engine);
	doir.strings.Strings strings;
	scope(exit) doir.strings.free(strings);
	immutable file = addFile(engine, strings, "e.doir");
	static immutable text = "a : namespace = {\n\tx : = 1\n}\nb : namespace = {\n\ty : = 2\n}\nz : = 3\n";
	assert(commit(engine, strings, file, text) == 3);
	immutable a = named(engine, strings, rootOf(engine, file), "a"), b = named(engine, strings, rootOf(engine, file), "b");
	assert(fp.dynarray.length(ecrs.context.getComponent!(doir.components.source.SyntaxErrors)(store, a).errors) == 1);
	assert(fp.dynarray.length(ecrs.context.getComponent!(doir.components.source.SyntaxErrors)(store, rootOf(engine, file)).errors) == 1);

	// Fixing `a`'s error inside it removes its errors and leaves `b`'s and the root's; a line added above moves them down.
	immutable before = blockCommits;
	assert(commitEdit(engine, strings, file, 23, 23, "T ") == 2 && blockCommits == before + 1);
	assert(!ecrs.context.hasComponent!(doir.components.source.SyntaxErrors)(store, a));
	assert(commitEdit(engine, strings, file, 18, 18, "\tw : T = 0\n") == 2 && blockCommits == before + 2);
	diagnose.Manager manager;
	scope(exit) diagnose.free(manager);
	assert(reportSyntaxErrors(engine, file, manager) && diagnose.count(manager) == 2);
	assert(manager.diagnostics[0].location.start == diagnose.Pair(6, 6) && manager.diagnostics[1].location.start == diagnose.Pair(8, 5));
	assert(fp.string.slice(manager.diagnostics[0].annotations[0].message) == "insert a type or `_` here");
	assert(fp.dynarray.length(ecrs.context.getComponent!(doir.components.source.SyntaxErrors)(store, b).errors) == 1);

	// Errors at one offset report in their holders' order, then their own.
	static immutable Found[4] ties = [Found(5, 2, 1), Found(5, 2, 0), Found(5, 0, 3), Found(4, 9, 9)];
	assert(compareFound(&ties[0], &ties[1]) == 1 && compareFound(&ties[1], &ties[0]) == -1 && compareFound(&ties[0], &ties[0]) == 0);
	assert(compareFound(&ties[0], &ties[2]) == 1 && compareFound(&ties[2], &ties[0]) == -1 && compareFound(&ties[3], &ties[2]) == -1);

	// A refused allocation reports nothing.
	for (size_t budget = 0;; ++budget) {
		diagnose.Manager rationed;
		scope(exit) diagnose.free(rationed);
		auto allocator = fp.testing.beginRationedAllocator(budget);
		immutable reported = reportSyntaxErrors(engine, file, rationed);
		fp.testing.endRationedAllocator(allocator);
		if (!reported) {
			assert(diagnose.count(rationed) == 0);
			continue;
		}
		assert(diagnose.count(rationed) == 2);
		break;
	}

	// An error pointing back at its opening bracket reports both or neither.
	immutable unclosed = addFile(engine, strings, "u.doir");
	assert(commit(engine, strings, unclosed, "ns : namespace = {\n\tf : (x: T\n") == 1);
	for (size_t budget = 0;; ++budget) {
		diagnose.Manager rationed;
		scope(exit) diagnose.free(rationed);
		auto allocator = fp.testing.beginRationedAllocator(budget);
		immutable reported = reportSyntaxErrors(engine, unclosed, rationed);
		fp.testing.endRationedAllocator(allocator);
		if (!reported) {
			assert(diagnose.count(rationed) == 0);
			continue;
		}
		assert(diagnose.count(rationed) == 1 && fp.dynarray.length(rationed.diagnostics[0].annotations) == 2);
		assert(fp.string.slice(rationed.diagnostics[0].annotations[1].message) == "opened here");
		break;
	}
}

unittest { // chunked whole-file commits write what unchunked ones do, large declarations included, through edits and broken text
	static import doir.printer;
	immutable saved = chunkBytes;
	scope(exit) chunkBytes = saved;
	// Nested namespaces and blocks, with what a cut must not split: a raw string and a `language` body whose lines start like statements, a statement carried onto its next line, a multi-line function type, `;`-separated statements, a failed statement, an unnamed block and an annotation after a block.
	static immutable crafted = "outer : namespace = {\n\tinner : namespace = {\n\t\tx : T = 1\n\t\ty : T = \"\"\"\nz : T = 2\n\t\t\"\"\"\n\t\tbad : = 3\n\t}\n\tf : (a: T,\n\t\tb: T) -> T\n\tg : T\n\t\t= 4\n\th : T = 5; i : T = 6\n\t_ : block = {\n\t\tw : T = 7\n\t}\n\tlanguage \"c\" {\nk : T = 8\n\t}\n\tblk : block = {\n\t\tv : T = 9\n\t} <\"gen.doir\":3:1>\n}\nafter : T = 10\nlast : namespace = {\n\tm : T = 11\n}\n";
	char* craftedText = fp.string.makeDynamic(crafted);
	scope(exit) fp.string.free(craftedText);
	static immutable string[] replacements = ["", "x", "\n", "q : T = 1\n", "n : namespace = {\n\ta : T = 1\n}\n", "}", "{", "/*", "\"\"\"", "_ : T = 1\n"];
	uint seed = 11;
	uint next() { seed = seed * 1103515245 + 12345; return seed >> 8; }
	// Half the chunked commits skim, describe and rebuild on workers, which must not change what they write.
	auto pool = bc.threadpool.create(4);
	assert(pool !is null);
	scope(exit) bc.threadpool.free(pool);
	deferBuilds = true;
	scope(exit) deferBuilds = false;
	foreach (source; ["standard.doir", "test_call.doir", null]) {
		char* original = source is null ? fp.string.makeDynamic(crafted) : fp.file.readFile(source).get;
		scope(exit) fp.string.free(original);
		foreach (size; [1, 40, 600]) {
			auto storeA = ecrs.context.create(), storeB = ecrs.context.create();
			scope(exit) { ecrs.context.free(storeA); ecrs.context.free(storeB); }
			auto ea = doir.query.create(storeA), eb = doir.query.create(storeB);
			scope(exit) { doir.query.free(ea); doir.query.free(eb); }
			doir.strings.Strings sa, sb;
			scope(exit) { doir.strings.free(sa); doir.strings.free(sb); }
			immutable fa = addFile(ea, sa, "c.doir"), fb = addFile(eb, sb, "c.doir");
			if (size != 40) ea.workers = pool;
			char* model = fp.string.makeDynamic(fp.string.slice(original));
			scope(exit) fp.string.free(model);
			foreach (round; 0 .. 40) {
				if (round) {
					immutable length = fp.string.length(model);
					immutable start = next() % (length + 1);
					immutable span = next() % 8;
					immutable end = start + span > length ? length : start + span;
					// Breaking edits leave the file broken for good, so most rounds put the original back first.
					if (round % 4 == 0) assert(fp.string.replaceRange(model, fp.string.slice(original), 0, length) !is null);
					else assert(fp.string.replaceRange(model, replacements[next() % replacements.length], start, end - start) !is null || fp.string.length(model) == 0);
				}
				chunkBytes = size;
				immutable chunked = commit(ea, sa, fa, fp.string.slice(model));
				chunkBytes = size_t.max;
				immutable whole = commit(eb, sb, fb, fp.string.slice(model));
				assert(chunked != fp.pointer.allocationRefused && chunked == whole);
				assertSameTree(ea, sa, rootOf(ea, fa), eb, sb, rootOf(eb, fb));
				auto printedA = doir.printer.print(*ea.store, sa, rootOf(ea, fa)).get, printedB = doir.printer.print(*eb.store, sb, rootOf(eb, fb)).get;
				scope(exit) { fp.string.free(printedA); fp.string.free(printedB); }
				assert(fp.string.slice(printedA) == fp.string.slice(printedB));
			}
		}
	}
	assert(largeCommits && mergedPieces && largeFallbacks);

	// A refused allocation anywhere in a chunked commit, first or not, rolls the store back.
	static import ecrs.serialization;
	chunkBytes = 1;
	foreach (workers; [null, pool])
	foreach (first; [true, false]) {
		for (size_t budget = 0;; ++budget) {
			auto store = ecrs.context.create();
			scope(exit) ecrs.context.free(store);
			auto engine = doir.query.create(store);
			scope(exit) doir.query.free(engine);
			engine.workers = workers;
			doir.strings.Strings strings;
			scope(exit) doir.strings.free(strings);
			immutable file = addFile(engine, strings, "r.doir");
			assert(file != invalidEntity);
			if (!first) assert(commit(engine, strings, file, "outer : namespace = {\n\tinner : namespace = {\n\t\tx : T = 1\n\t}\n}\n") == 0);
			auto before = ecrs.serialization.serialize(store);
			assert(before !is null);
			scope(exit) fp.dynarray.free(before);
			auto allocator = fp.testing.beginRationedAllocator(budget);
			immutable result = commit(engine, strings, file, crafted);
			fp.testing.endRationedAllocator(allocator);
			if (result != fp.pointer.allocationRefused) break;
			auto after = ecrs.serialization.serialize(store);
			assert(after !is null);
			scope(exit) fp.dynarray.free(after);
			assert(fp.dynarray.slice(after) == fp.dynarray.slice(before));
		}
	}

	// So does one in a worker's rebuild of a block that keeps its contents, or in removing the parts a rebuild left over.
	static immutable rebuilt = ["n : namespace = {\n\tx : T = 1\n}\nf : (a: T, b: T) -> T\n", "n : block = {\n\tx : T = 1\n}\nf : (a: T) -> T\n"];
	// One worker, so the allocations are made in one order and each budget refuses the same one every run.
	auto one = bc.threadpool.create(1);
	assert(one !is null);
	scope(exit) bc.threadpool.free(one);
	foreach (workers; [pool, one])
	for (size_t budget = 0;; ++budget) {
		auto store = ecrs.context.create();
		scope(exit) ecrs.context.free(store);
		auto engine = doir.query.create(store);
		scope(exit) doir.query.free(engine);
		engine.workers = pool;
		doir.strings.Strings strings;
		scope(exit) doir.strings.free(strings);
		immutable file = addFile(engine, strings, "w.doir");
		assert(file != invalidEntity && commit(engine, strings, file, rebuilt[0]) == 0);
		engine.workers = workers;
		auto before = ecrs.serialization.serialize(store);
		assert(before !is null);
		scope(exit) fp.dynarray.free(before);
		auto allocator = fp.testing.beginRationedAllocator(budget);
		immutable result = commit(engine, strings, file, rebuilt[1]);
		fp.testing.endRationedAllocator(allocator);
		if (result != fp.pointer.allocationRefused) {
			assert(result == 0 && textIs(engine, file, rebuilt[1]));
			break;
		}
		auto after = ecrs.serialization.serialize(store);
		assert(after !is null);
		scope(exit) fp.dynarray.free(after);
		assert(fp.dynarray.slice(after) == fp.dynarray.slice(before));
	}
}
