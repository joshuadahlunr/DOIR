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

static import core.stdc.stdio;
static import std.typecons;

static import fp.dynarray;
static import fp.fnv1a;
static import fp.hashtable;
static import fp.pointer;
static import fp.string;

static import diagnose;
static import ecrs.context;
static import ecrs.relation;

static import doir.strings;
static import doir.components.ast;
static import doir.components.source;
static import doir.positions;
static import doir.query;
static import doir.engine.locations;
static import doir.syntax.lexer;
static import doir.syntax.parser;

public import ecrs.registry : EntityId, invalidEntity;
public import doir.positions : Position;

@nogc nothrow:


// --- files -------------------------------------------------------------------

/// Reads the file at `path` into a new fp string the caller releases with `fp.string.free`; an empty file gives a null `char*`, the empty fp string.
///
/// Returns null if the file cannot be opened or read, or if allocation fails.
///
/// Examples:
/// ---
/// assert(readFile("no/such/file.doir").isNull);
/// ---
std.typecons.Nullable!(char*) readFile(const(char)[] path) {
	char* name = fp.string.makeDynamic(path);
	if (name is null) return typeof(return).init;
	scope(exit) fp.string.free(name);
	auto f = core.stdc.stdio.fopen(name, "rb");
	if (f is null) return typeof(return).init;
	scope(exit) core.stdc.stdio.fclose(f);
	char* out_ = null;
	char[65536] buffer;
	for (;;) {
		immutable n = core.stdc.stdio.fread(buffer.ptr, 1, buffer.length, f);
		if (n && fp.string.concatenate(out_, buffer[0 .. n]) is null) break;
		if (n < buffer.length) {
			if (!core.stdc.stdio.ferror(f)) return typeof(return)(out_);
			break;
		}
	}
	fp.string.free(out_);
	return typeof(return).init;
}

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

/// `file`'s text as of its last commit; empty before the first.
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
/// cast(void) commit(engine, strings, file, "x : T\n");
/// assert(textOf(engine, file) == "x : T\n");
/// ---
const(char)[] textOf(ref doir.query.QueryEngine engine, EntityId file) {
	auto text = ecrs.context.findComponent!(doir.components.source.SourceText)(*engine.store, file);
	return text is null ? null : fp.string.slice(text.text);
}


// --- the commit --------------------------------------------------------------

// The state of one commit. It runs in a store transaction, so slices of components it removes or replaces stay valid until it ends.
private struct Commit {
	doir.query.QueryEngine* engine;
	ecrs.context.Context* store;
	doir.strings.Strings* strings;
	doir.syntax.parser.Syntax* syntax;
	const(char)[] text;
	const(char)[] oldText;
	const(char)[] path;
}

private ulong mix(ulong h, ulong value) {
	return (h ^ value) * 0x100000001b3;
}

// Removes `e`, its parts and everything nested in it. Returns false on refusal, partway; the commit's transaction undoes it.
private bool removeTree(ref Commit c, EntityId e) {
	if (auto block = ecrs.context.findComponent!(doir.components.ast.Block)(*c.store, e))
		foreach (child; fp.dynarray.slice(block.related))
			if (!removeTree(c, child)) return false;
	if (auto parts = ecrs.context.findComponent!(doir.components.source.ParsedParts)(*c.store, e))
		foreach (part; fp.dynarray.slice(parts.related))
			if (!ecrs.context.removeEntity(*c.store, part)) return false;
	return ecrs.context.removeEntity(*c.store, e);
}

// Builds record `r` into `e`, reusing its old parts in order and removing those left over. Returns false on refusal.
private bool rebuild(ref Commit c, size_t r, EntityId e) {
	const(EntityId)[] old = null;
	if (auto parts = ecrs.context.findComponent!(doir.components.source.ParsedParts)(*c.store, e)) {
		old = fp.dynarray.slice(parts.related);
		if (!ecrs.context.removeComponent!(doir.components.source.ParsedParts)(*c.store, e)) return false;
	}
	if (!doir.syntax.parser.removeParsed(*c.store, e)) return false;
	foreach (part; old)
		if (!doir.syntax.parser.removeParsed(*c.store, part)) return false;

	auto b = doir.syntax.parser.Builder(c.store, c.strings, e, old);
	doir.components.source.ParsedParts built;
	scope(exit) built.finalize();
	immutable ok = doir.syntax.parser.build(*c.syntax, c.text, r, b);
	built.related = b.parts;
	if (!ok) return false;
	immutable used = fp.dynarray.length(b.parts) < old.length ? fp.dynarray.length(b.parts) : old.length;
	foreach (part; old[used .. $])
		if (!ecrs.context.removeEntity(*c.store, part)) return false;
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

// The old entities each new record matches, or `invalidEntity`. False on refusal.
private bool match(ref Commit c, const(EntityId)[] old, const(uint)[] news, ulong parentPath, EntityId* matched, ulong* paths) {
	auto records = c.syntax.records;
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
	foreach (i, r; news) {
		matched[i] = invalidEntity;
		paths[i] = 0;
		if (records[r].name == doir.syntax.parser.noToken) continue;
		immutable name = doir.syntax.parser.nameOf(doir.syntax.lexer.text(c.syntax.tokens[records[r].name], c.text), *c.strings);
		if (name == doir.strings.noName) return false;
		immutable nameHash = fp.fnv1a.hash(doir.strings.text(*c.strings, name));
		auto seen = fp.hashtable.find(occurrences, Keyed(nameHash));
		immutable occurrence = seen is null ? 0 : seen.e + 1;
		if (seen is null) {
			if (fp.hashtable.insert(occurrences, Keyed(nameHash, 0)) is null) return false;
		} else seen.e = occurrence;
		paths[i] = mix(mix(parentPath, nameHash), occurrence);
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
	foreach (i, r; news) {
		if (records[r].name != doir.syntax.parser.noToken) continue;
		if (!fp.dynarray.pushBack(newIndex, i) || !fp.dynarray.pushBack(newHashes, records[r].hash)) return false;
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
		if (!fp.dynarray.pushBack(old, at is null ? doir.positions.none : at.at)
			|| !fp.dynarray.pushBack(previous, size_t.max)
			|| !fp.dynarray.pushBack(keep, false))
			return false;
	}
	foreach (i; 0 .. n) {
		if (old[i] == doir.positions.none) continue;
		size_t lo = 0, hi = fp.dynarray.length(tails);
		while (lo < hi) {
			immutable mid = (lo + hi) / 2;
			if (doir.positions.precedes(c.engine.positions, old[tails[mid]], old[i])) lo = mid + 1;
			else hi = mid;
		}
		if (lo > 0) previous[i] = tails[lo - 1];
		if (lo == fp.dynarray.length(tails)) {
			if (!fp.dynarray.pushBack(tails, i)) return false;
		} else tails[lo] = i;
	}
	if (fp.dynarray.length(tails))
		for (size_t i = tails[fp.dynarray.length(tails) - 1]; i != size_t.max; i = previous[i]) keep[i] = true;

	Position before = doir.positions.none;
	foreach (i; 0 .. n) {
		if (keep[i]) {
			out_[i] = before = old[i];
			continue;
		}
		Position after = doir.positions.none;
		foreach (j; i + 1 .. n) if (keep[j]) { after = old[j]; break; }
		out_[i] = before = doir.positions.between(c.engine.positions, parent, before, after);
		if (before == doir.positions.none) return false;
	}
	return true;
}

// Whether `e`'s old text, starting at `oldStart`, equals `record`'s up to `end`; `whole` also requires the same length.
private bool sameText(ref Commit c, size_t oldStart, uint oldLength, ref const doir.syntax.parser.Record record, size_t end, bool whole) {
	immutable length = end - record.spanStart;
	if (c.oldText is null || (whole && length != oldLength) || length > oldLength) return false;
	return c.oldText[oldStart .. oldStart + length] == c.text[record.spanStart .. end];
}

// Matches records `lo` to `hi` (`block`'s contents) against its `old` contents, recursing into blocks; `oldBase` is `block`'s old start. False on refusal.
private bool commitBlock(ref Commit c, EntityId block, const(EntityId)[] old, size_t lo, size_t hi, ulong parentPath, Position parentAt, uint parentStart, size_t oldBase, bool rekey) {
	auto records = c.syntax.records;
	uint* news = null;
	EntityId* matched = null, entries = null;
	ulong* paths = null;
	Position* keys = null;
	scope(exit) { fp.dynarray.free(news); fp.dynarray.free(matched); fp.dynarray.free(entries); fp.dynarray.free(paths); fp.dynarray.free(keys); }
	for (size_t r = lo; r < hi; r = records[r].end)
		if (!fp.dynarray.pushBack(news, cast(uint) r)) return false;
	immutable n = fp.dynarray.length(news);
	if (n) {
		if (fp.dynarray.growToSize(matched, n) is null || fp.dynarray.growToSize(paths, n) is null || fp.dynarray.growToSize(keys, n) is null) return false;
		if (!match(c, old, fp.dynarray.slice(news), parentPath, matched, paths)) return false;
		if (!assignPositions(c, parentAt, fp.dynarray.slice(matched), rekey, keys)) return false;
	}

	foreach (i, r; fp.dynarray.slice(news)) {
		auto record = records[r];
		EntityId e = matched[i];
		if (!fp.dynarray.pushBack(entries, e)) return false;
		immutable span = doir.components.source.SourceSpan(record.spanStart - parentStart, record.spanEnd - record.spanStart);
		bool changed = false, built = false;
		size_t oldStart = 0;
		const(EntityId)[] oldChildren = null;
		if (e != invalidEntity) {
			immutable oldSpan = ecrs.context.getComponent!(doir.components.source.SourceSpan)(*c.store, e);
			oldStart = oldBase + oldSpan.offset;
			immutable kept = ecrs.context.getComponent!(doir.components.source.LexicalPosition)(*c.store, e).at == keys[i];
			// Unchanged text, nested declarations included, at an unchanged key: nothing below it can differ but where it starts.
			if (kept && sameText(c, oldStart, oldSpan.length, record, record.spanEnd, true)) {
				if (!ecrs.context.setComponent!(doir.components.source.SourceSpan)(*c.store, e, span)) return false;
				continue;
			}
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

		if (built) {
			if (!rebuild(c, r, e)) return false;
			if (record.name != doir.syntax.parser.noToken) {
				immutable name = doir.syntax.parser.nameOf(doir.syntax.lexer.text(c.syntax.tokens[record.name], c.text), *c.strings);
				if (name == doir.strings.noName || !ecrs.context.setComponent!(doir.components.ast.Name)(*c.store, e, doir.components.ast.Name(name))) return false;
			}
			if (!ecrs.context.setComponent!(doir.components.ast.Parent)(*c.store, e, doir.components.ast.Parent([block]))) return false;
		}
		if (record.name != doir.syntax.parser.noToken && !ecrs.context.setComponent!(doir.components.source.PathHash)(*c.store, e, doir.components.source.PathHash(paths[i]))) return false;
		if (!ecrs.context.setComponent!(doir.components.source.SyntaxHash)(*c.store, e, doir.components.source.SyntaxHash(record.hash))) return false;
		if (!ecrs.context.setComponent!(doir.components.source.SourceSpan)(*c.store, e, span)) return false;

		auto at = ecrs.context.findComponent!(doir.components.source.LexicalPosition)(*c.store, e);
		immutable moved = at is null || at.at != keys[i];
		if (!ecrs.context.setComponent!(doir.components.source.LexicalPosition)(*c.store, e, doir.components.source.LexicalPosition(keys[i]))) return false;
		if (changed || moved) {
			if (!doir.query.markChanged(*c.engine, e)) return false;
			if (auto all = ecrs.context.findComponent!(doir.components.source.ParsedParts)(*c.store, e))
				foreach (part; fp.dynarray.slice(all.related))
					if (!doir.query.markChanged(*c.engine, part)) return false;
		}

		if (record.blockOpen != doir.syntax.parser.noToken) {
			if (!commitBlock(c, e, oldChildren, r + 1, record.end, paths[i] ? paths[i] : record.hash, keys[i], record.spanStart, oldStart, moved)) return false;
		} else foreach (child; oldChildren)
			if (!removeTree(c, child)) return false;
	}

	// The block's entries: unmatched old ones are removed, and a changed list marks the block.
	foreach (e; old) {
		bool kept = false;
		foreach (m; fp.dynarray.slice(matched)) if (m == e) { kept = true; break; }
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

// Points `d` at the offending token with the parser's hint, and at the bracket a missing closer would close. False on refusal.
private bool annotate(ref Commit c, EntityId file, doir.syntax.parser.SyntaxError error, ref diagnose.Diagnostic d) {
	auto fix = diagnose.Diagnostic.Annotation(d.location.start, null, doir.syntax.parser.hint(*c.syntax, c.text, error));
	if (fix.message is null || !diagnose.pushAnnotation(d, fix)) {
		fp.string.free(fix.message);
		return false;
	}
	immutable open = doir.syntax.parser.opening(*c.syntax, error);
	if (open == fp.pointer.notFound) return true;
	immutable position = doir.engine.locations.pairAt(*c.store, file, open);
	if (position.isNull) return false;
	auto opened = diagnose.Diagnostic.Annotation(position.get);
	opened.message = fp.string.makeDynamic("opened here");
	if (opened.message !is null && diagnose.pushAnnotation(d, opened)) return true;
	fp.string.free(opened.message);
	return false;
}

// Everything `commit` writes to the store, inside its transaction, with the diagnostics it will report gathered into `prepared`. False on refusal.
private bool apply(ref Commit c, EntityId file, char* copy, ref diagnose.Diagnostic* prepared) {
	auto store = c.store;
	auto owned = ecrs.context.findComponent!(doir.components.source.SourceText)(*store, file);
	c.oldText = owned is null || owned.text is null ? null : fp.string.slice(owned.text);
	immutable hadText = owned !is null && owned.text !is null;
	if (!ecrs.context.setComponent!(doir.components.source.SourceText)(*store, file, doir.components.source.SourceText(copy))) return false;
	c.text = fp.string.slice(copy);
	c.path = doir.strings.text(*c.strings, ecrs.context.getComponent!(doir.components.source.SourceFile)(*store, file).path);
	// Replacing the component drops its line starts, so they are computed again from the new text.
	if (!ecrs.context.setComponent!(doir.components.source.SourceLines)(*store, file, doir.components.source.SourceLines(c.path, c.text))) return false;
	if ((!hadText || c.oldText != c.text) && !doir.query.markChanged(*c.engine, file)) return false;

	EntityId root = rootOf(*c.engine, file);
	if (root == invalidEntity) {
		root = ecrs.context.addEntity(*store);
		if (root == invalidEntity
			|| ecrs.context.addComponent!(doir.components.ast.Block)(*store, root) is null
			|| !ecrs.context.setComponent!(doir.components.source.LexicalPosition)(*store, root, doir.components.source.LexicalPosition(doir.positions.root))
			|| !ecrs.context.setComponent!(doir.components.source.InFile)(*store, root, doir.components.source.InFile([file]))
			|| !ecrs.context.setComponent!(doir.components.source.FileRoot)(*store, file, doir.components.source.FileRoot([root]))
			|| !doir.query.markChanged(*c.engine, root))
			return false;
	}
	if (!ecrs.context.setComponent!(doir.components.source.SourceSpan)(*store, root, doir.components.source.SourceSpan(0, cast(uint) c.text.length))) return false;

	auto oldEntries = fp.dynarray.slice(ecrs.context.getComponent!(doir.components.ast.Block)(*store, root).related);
	if (!commitBlock(c, root, oldEntries, 0, fp.dynarray.length(c.syntax.records), fp.fnv1a.hash(c.path), doir.positions.root, 0, 0, false)) return false;

	if (c.engine.diagnostics is null) return true;
	foreach (error; fp.dynarray.slice(c.syntax.errors)) {
		diagnose.Diagnostic d;
		d.kind = diagnose.Kind.error;
		immutable at = doir.engine.locations.pairAt(*store, file, error.at);
		if (at.isNull) return false;
		d.location = diagnose.Detailed(c.path, at.get, at.get);
		d.message = doir.syntax.parser.describe(*c.syntax, c.text, error);
		if (d.message is null || !annotate(c, file, error, d) || !fp.dynarray.pushBack(prepared, d)) {
			diagnose.free(d);
			return false;
		}
	}
	return true;
}

/// Commits `text` as the new contents of `file`, one input commit in a revision of its own: lexes and parses it, matches its declarations against the previous commit's, builds the new and changed ones into the store, assigns order keys, writes the spans of what moved, and marks what changed. A declaration whose text is unchanged, nested declarations included, is skipped with everything inside it. Locations are derived from the spans only when asked for (`doir.engine.locations.locate`). Syntax errors go to `engine.diagnostics`, if set, with the file registered there for context; a failed declaration is skipped, so the rest of the file still commits. No query may be running, and no store transaction may be open: the commit runs in one of its own.
///
/// Returns the number of syntax errors, or `fp.pointer.allocationRefused` if allocation fails, having rolled the store back to the previous commit and reported nothing. Only the revision count, order keys and interned strings it made are left behind, none of which a later commit or query observes.
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
	auto store = engine.store;

	doir.syntax.parser.Syntax syntax;
	scope(exit) doir.syntax.parser.free(syntax);
	if (!doir.syntax.parser.skim(text, syntax)) return fp.pointer.allocationRefused;
	// The new text is owned before anything slices it; the transaction keeps the old one alive until it ends.
	char* copy = fp.string.makeDynamic(text);
	if (copy is null && text.length) return fp.pointer.allocationRefused;

	Commit c;
	c.engine = &engine;
	c.store = store;
	c.strings = &strings;
	c.syntax = &syntax;
	diagnose.Diagnostic* prepared = null;
	scope(exit) {
		foreach (ref d; fp.dynarray.slice(prepared)) diagnose.free(d);
		fp.dynarray.free(prepared);
	}

	ecrs.context.beginTransaction(*store);
	bool ok = apply(c, file, copy, prepared);
	// Reporting cannot be undone, so the last steps that can fail come before the first push.
	if (ok && engine.diagnostics !is null) {
		auto manager = engine.diagnostics;
		ok = fp.dynarray.reserve(manager.diagnostics, fp.dynarray.length(manager.diagnostics) + fp.dynarray.length(prepared)) !is null
			&& diagnose.registerSource(*manager, c.path, c.text);
	}
	if (!ok) {
		ecrs.context.rollbackTransaction(*store);
		return fp.pointer.allocationRefused;
	}
	if (engine.diagnostics !is null) {
		foreach (d; fp.dynarray.slice(prepared)) cast(void) diagnose.push(*engine.diagnostics, d); // reserved above
		fp.dynarray.clear(prepared);
	}
	ecrs.context.commitTransaction(*store);
	return fp.dynarray.length(syntax.errors);
}


version(unittest) {
	static import core.stdc.stdio;
	static import core.stdc.string;

	private __gshared int valueRuns, lookupRuns, useRuns, fileRuns;

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
			return textOf(engine, key.related[0]).length;
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

	private const(char)[] located(ref doir.query.QueryEngine engine, EntityId file, EntityId e) {
		const at = doir.engine.locations.bytesOf(*engine.store, e).get.bytes;
		return textOf(engine, file)[at.startByte .. at.endByte];
	}

	// The revisions of `entities`, to compare across a commit.
	private doir.query.Revision* revisions(ref doir.query.QueryEngine engine, const(EntityId)[] entities) {
		doir.query.Revision* out_ = null;
		foreach (e; entities) assert(fp.dynarray.pushBack(out_, doir.query.changedAt(engine, e)));
		return out_;
	}
}

unittest { // reading files: an empty file is null and read, a missing file or a directory is not, and a refused allocation frees what was read
	static import doir.testing;
	const empty = readFile("tests/syntax/empty.accept.doir");
	assert(!empty.isNull && empty.get is null);
	assert(readFile("tests/syntax/no-such-file.doir").isNull);
	assert(readFile("tests").isNull);
	assert(readFile("").isNull);

	// Refusals reach both the path's copy and the text.
	for (size_t budget = 0;; ++budget) {
		auto allocator = doir.testing.beginRationedAllocator(budget);
		auto read = readFile("standard.doir");
		fp.pointer.allocFunction = allocator;
		if (read.isNull) continue;
		auto text = read.get;
		scope(exit) fp.string.free(text);
		assert(budget >= 2 && fp.string.find(fp.string.slice(text), "std : namespace", 0) != size_t.max);
		break;
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
		auto text = readFile(path).get;
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
	auto text = readFile("standard.doir").get;
	scope(exit) fp.string.free(text);
	assert(commit(engine, strings, standard, fp.string.slice(text)) == 0);
	EntityId* all = null;
	scope(exit) fp.dynarray.free(all);
	collect(engine, rootOf(engine, standard), all);
	Position last = doir.positions.root;
	foreach (e; fp.dynarray.slice(all)) {
		auto at = ecrs.context.findComponent!(doir.components.source.LexicalPosition)(store, e);
		if (at is null) continue;
		assert(doir.positions.precedes(engine.positions, last, at.at));
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
		assert(*doir.query.query!ReadsFile(engine, ReadsFile.Key([file])) == textOf(engine, file).length);
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
	assert(doir.positions.precedes(engine.positions, ecrs.context.getComponent!(doir.components.source.LexicalPosition)(store, zz).at, ecrs.context.getComponent!(doir.components.source.LexicalPosition)(store, a).at));
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
	static import doir.testing;
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
	assert(diagnose.count(manager) == 1);
	assert(manager.diagnostics[0].location.file == "diag.doir" && manager.diagnostics[0].location.start == diagnose.Pair(3, 5));
	assert(fp.string.slice(manager.diagnostics[0].message) == "syntax error, unexpected '=' where the declared type should be");
	assert(fp.dynarray.length(manager.diagnostics[0].annotations) == 1 && manager.diagnostics[0].annotations[0].position == diagnose.Pair(3, 5));
	assert(fp.string.slice(manager.diagnostics[0].annotations[0].message) == "insert a type or `_` here");

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
		auto allocator = doir.testing.beginRationedAllocator(budget);
		immutable reported = doir.query.report(engine, a, diagnose.Kind.warning, "about a", "fix a", toC[]);
		fp.pointer.allocFunction = allocator;
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
	assert(commit(engine, strings, open, "ns : namespace = {\n\tx : T = 1\n") == 1);
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
	static import doir.testing;
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

		auto allocator = doir.testing.beginRationedAllocator(budget);
		immutable file = addFile(engine, strings, "r.doir");
		fp.pointer.allocFunction = allocator;
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
		allocator = doir.testing.beginRationedAllocator(budget);
		immutable result = commit(engine, strings, file, original);
		fp.pointer.allocFunction = allocator;
		if (result != fp.pointer.allocationRefused) {
			assert(result == 0 && textOf(engine, file) == original);
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

			auto allocator = doir.testing.beginRationedAllocator(budget);
			immutable result = commit(engine, strings, file, edit);
			fp.pointer.allocFunction = allocator;
			if (result != fp.pointer.allocationRefused) {
				assert(result == errors[i] && textOf(engine, file) == edit);
				break;
			}
			++refusals;
			auto after = ecrs.serialization.serialize(store);
			assert(after !is null);
			scope(exit) fp.dynarray.free(after);
			assert(fp.dynarray.slice(after) == fp.dynarray.slice(before));
			assert(textOf(engine, file) == original && diagnose.count(manager) == 0);
			// The rolled-back store still commits, and an unchanged text is still recognised as unchanged.
			immutable x = named(engine, strings, rootOf(engine, file), "ns.x");
			assert(commit(engine, strings, file, original) == 0 && named(engine, strings, rootOf(engine, file), "ns.x") == x);
		}
		assert(refusals >= leastRefusals[i]);
	}
}
