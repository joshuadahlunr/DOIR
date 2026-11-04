/// The rules `tests/doir_check.py` checks by walking a file's tree, as queries over the store (`roadmap.md` Phase 3): `WF-Term`, a block or body ends with a terminator call; `WF-Order`, a value is not read above the line that binds it; `D-Return`, a `_` destination does not receive a `_` return; `B-Tail`, a tail call sits in a function body and ends its block; `L-Scan`, `L-Sema` and `L-Bind`, the calls that shape the tower or name its checks and passes sit at level scope; and, for a program, `L-Entry`, its root ends with a terminator.
///
/// Each block's checks are a query keyed by the block (`CheckBlock`), run in no order (`L-Sema`) and memoized, so an edit re-runs the checks of the blocks whose entities it changed; a reused memo reports its diagnostics again (`doir.query.report`). What `doir_check` passes down its recursion, whether a block runs and which outer names it may read, is a query of its own (`ContextOf`), each block's derived from its parent's. A block's checks and those of every block below it are a query too (`CheckTree`), so checking a file after an edit visits only the blocks the edit reached, and those whose checks report diagnostics.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import diagnose;
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
/// diagnose.Manager manager;
/// scope(exit) diagnose.free(manager);
/// engine.diagnostics = &manager;
/// immutable file = doir.source.addFile(engine, strings, "a.doir");
/// assert(doir.source.commit(engine, strings, file, "y : T = std.copy(T, v)\nv : T = 5\n") == 0);
/// assert(check(engine, file) && diagnose.count(manager) == 1); // WF-Order
/// ---
module doir.checks;

static import core.stdc.stdio;
static import core.stdc.stdlib;

static import fp.dynarray;
static import fp.string;

static import diagnose;
static import ecrs.context;
static import ecrs.relation;

static import doir.components.ast;
static import doir.components.source;
static import doir.engine.positions;
static import doir.query;
static import doir.names;
static import doir.source;
static import doir.strings;

public import ecrs.registry : EntityId, invalidEntity;

@nogc nothrow:


// --- declarations ------------------------------------------------------------

// Calls a block ends with (`WF-Term`), qualified or not.
private static immutable string[8] terminators = ["std.return", "std.block_result", "std.halt", "return", "block_result", "halt", "compiler.return", "compiler.block_result"];

// Types whose names are not values, so they may be read above their declaration; a label may be named before it is placed (B-Label).
// How to fix a `WF-Term` error, for a block or the program's root.
private enum terminatorHint = "end it with a call that leaves it: `std.return` to return from a function, `std.block_result` to give the block its value, `std.halt`, or a tail call, as in `_ : _ = std.return(result)`";

private static immutable string[4] nonValueTypes = ["type", "namespace", "alias", "std.label"];

// Types whose block value is not a function body.
private static immutable string[3] blockTypes = ["block", "namespace", "type"];

// Calls that shape the tower, read before ascent (L-Scan), or that name its checks and passes without running (L-Sema, L-Bind), each with the rule it falls under.
private struct LevelCall { string callee, rule; }
private static immutable LevelCall[6] levelCalls = [
	LevelCall("compiler.levels.make", "L-Scan"),
	LevelCall("compiler.levels.this_file", "L-Scan"),
	LevelCall("compiler.levels.lower_to", "L-Scan"),
	LevelCall("compiler.levels.bundle", "L-Scan"),
	LevelCall("compiler.levels.check", "L-Sema"),
	LevelCall("compiler.levels.bind_pass", "L-Bind"),
];

// A declaration as `doir_check` sees it.
private struct Decl {
	EntityId e;
	doir.strings.StringId name; // `noName` for `_`
	const(char)[] typeName; // `function` for a function type written in place; empty for none
	bool complete; // it has a type and a value, as the declarations `doir_check` walks do
	bool isFunction, isValue;
}

private const(char)[] nameText(ref doir.query.QueryEngine engine, doir.strings.StringId id) {
	return id == doir.strings.noName ? "_" : doir.strings.text(*engine.strings, id);
}

private bool functionType(ref doir.query.QueryEngine engine, EntityId e) {
	return e != invalidEntity && ecrs.context.hasComponent!(doir.components.ast.FunctionInputs)(*engine.store, e);
}

// The function type `e` declares: written in place as its type, or its value.
private EntityId ownFunctionType(ref doir.query.QueryEngine engine, EntityId e) {
	if (auto type = ecrs.context.findComponent!(doir.components.ast.TypeOf)(*engine.store, e))
		if (functionType(engine, type.type)) return type.type;
	return functionType(engine, e) ? e : invalidEntity;
}

private bool among(const(char)[] word, const(string)[] words) {
	foreach (w; words) if (w == word) return true;
	return false;
}

private Decl declOf(ref doir.query.QueryEngine engine, EntityId e) {
	auto store = engine.store;
	Decl d = Decl(e);
	if (auto n = ecrs.context.findComponent!(doir.components.ast.Name)(*store, e)) d.name = n.value;
	immutable inPlace = ownFunctionType(engine, e) != invalidEntity && !functionType(engine, e);
	auto flags = ecrs.context.findComponent!(doir.components.ast.Flags)(*store, e);
	// The parser writes `namespace` as a flag, not a type it looks up.
	if (flags !is null && (flags.flags & doir.components.ast.Flags.Namespace)) d.typeName = "namespace";
	else if (inPlace) d.typeName = "function";
	else if (auto t = ecrs.context.findComponent!(doir.components.ast.LookupTypeOf)(*store, e)) d.typeName = nameText(engine, t.name);
	else if (ecrs.context.hasComponent!(doir.components.ast.LookupAlias)(*store, e)) d.typeName = "alias";
	immutable valueless = flags !is null && (flags.flags & doir.components.ast.Flags.Valueless);
	d.complete = d.typeName.length && !valueless;
	immutable block = ecrs.context.hasComponent!(doir.components.ast.Block)(*store, e);
	d.isFunction = ownFunctionType(engine, e) != invalidEntity || (block && !among(d.typeName, blockTypes[]));
	d.isValue = !d.isFunction && !among(d.typeName, nonValueTypes[]);
	return d;
}

private const(EntityId)[] entriesOf(ref doir.query.QueryEngine engine, EntityId block) {
	auto b = ecrs.context.findComponent!(doir.components.ast.Block)(*engine.store, block);
	return b is null ? null : fp.dynarray.slice(b.related);
}

// The complete declarations of `block`, as an fp dynarray, reading each. Null with `refused` set on refusal.
private Decl* declarationsOf(ref doir.query.QueryEngine engine, EntityId block, out bool refused) {
	Decl* out_ = null;
	if (!doir.query.read(engine, block)) {
		refused = true;
		return null;
	}
	foreach (e; entriesOf(engine, block)) {
		if (!doir.query.read(engine, e)) {
			refused = true;
			break;
		}
		const d = declOf(engine, e);
		if (d.complete && !fp.dynarray.pushBack(out_, d)) {
			refused = true;
			break;
		}
	}
	if (refused) fp.dynarray.free(out_);
	return refused ? null : out_;
}

// The index of the first complete declaration of `decls` named `name`, or `size_t.max`.
private size_t indexOf(const(Decl)[] decls, doir.strings.StringId name) {
	if (name == doir.strings.noName) return size_t.max;
	foreach (i, ref d; decls) if (d.name == name) return i;
	return size_t.max;
}

// Calls `f` with each name `d`'s value reads, without descending into blocks: its callee and arguments, a reference's or alias's target, and a function type value's parameter types, defaults and return type.
private bool forEachRead(alias f)(ref doir.query.QueryEngine engine, EntityId e) {
	auto store = engine.store;
	bool each(doir.strings.StringId id) {
		return id == doir.strings.noName || nameText(engine, id) == "_" || f(id);
	}
	if (auto call = ecrs.context.findComponent!(doir.components.ast.LookupCall)(*store, e)) {
		if (!each(call.name)) return false;
		if (auto inputs = ecrs.context.findComponent!(doir.components.ast.LookupFunctionInputs)(*store, e))
			foreach (a; fp.dynarray.slice(inputs.names)) if (!each(a)) return false;
	}
	if (auto v = ecrs.context.findComponent!(doir.components.ast.LookupValue)(*store, e)) if (!each(v.name)) return false;
	if (auto a = ecrs.context.findComponent!(doir.components.ast.LookupAlias)(*store, e)) if (!each(a.name)) return false;
	if (functionType(engine, e)) {
		foreach (p; fp.dynarray.slice(ecrs.context.getComponent!(doir.components.ast.FunctionInputs)(*store, e).related)) {
			if (auto t = ecrs.context.findComponent!(doir.components.ast.LookupTypeOf)(*store, p)) if (!each(t.name)) return false;
			if (auto v = ecrs.context.findComponent!(doir.components.ast.LookupValue)(*store, p)) if (!each(v.name)) return false;
		}
		if (auto r = ecrs.context.findComponent!(doir.components.ast.LookupFunctionReturn)(*store, e)) if (!each(r.name)) return false;
	}
	return true;
}

// The names `e`'s value passes as call arguments or reads plainly: where a block binding it names is executed.
private bool forEachArgument(alias f)(ref doir.query.QueryEngine engine, EntityId e) {
	auto store = engine.store;
	if (auto inputs = ecrs.context.findComponent!(doir.components.ast.LookupFunctionInputs)(*store, e))
		foreach (a; fp.dynarray.slice(inputs.names)) if (!f(a)) return false;
	if (auto v = ecrs.context.findComponent!(doir.components.ast.LookupValue)(*store, e)) if (!f(v.name)) return false;
	return true;
}


// --- the walk's context ------------------------------------------------------

private enum : ubyte { executed = 1, ordered = 2, inFunction = 4, levelScope = 8 }

/// Where a block sits in the walk `doir_check` makes: whether it runs, whether its reads are ordered, whether a function body encloses it, whether it is at level scope, and, for a block spliced into its parent, the parent whose bindings it may read and the index past which they are not yet bound.
struct Context {
	mixin ecrs.relation.Relates!"outer";
	uint deadline; /// The parent's declarations from this index on are bound after the block runs.
	ubyte flags; /// Of `executed`, `ordered`, `inFunction` and `levelScope`.
}

// Where one entry of a block sits, as `ChildContexts` lists them; `spliced` makes the block its `outer`.
private struct Placement {
	uint deadline;
	ubyte flags;
	bool spliced;
}

private struct Placements {
	Placement* items; // one per entry of the block, in order
	void finalize() @nogc nothrow { fp.dynarray.free(items); }
}

// A name passed as an argument by the declaration at `index`, for finding a block binding's first use.
private struct Use {
	doir.strings.StringId name;
	uint index;
}

private extern(C) int compareUses(const(void)* a, const(void)* b) @trusted {
	auto x = cast(const(Use)*) a, y = cast(const(Use)*) b;
	if (x.name != y.name) return x.name.value < y.name.value ? -1 : 1;
	return x.index < y.index ? -1 : x.index > y.index;
}

private size_t indexOfEntity(const(EntityId)[] entries, EntityId e) {
	foreach (i, entry; entries) if (entry == e) return i;
	return size_t.max;
}

// The index of `e` among `block`'s entries, found by its order key, or `size_t.max`.
private size_t entryIndex(ref doir.query.QueryEngine engine, EntityId block, EntityId e) {
	auto entries = entriesOf(engine, block);
	auto at = ecrs.context.findComponent!(doir.components.source.LexicalPosition)(*engine.store, e);
	if (at !is null) {
		size_t low = 0, high = entries.length;
		while (low < high) {
			immutable middle = (low + high) / 2;
			auto key = ecrs.context.findComponent!(doir.components.source.LexicalPosition)(*engine.store, entries[middle]);
			if (key is null) break;
			if (doir.engine.positions.compare(engine.positions, key.at, at.at) < 0) low = middle + 1;
			else high = middle;
		}
		if (low < entries.length && entries[low] == e) return low;
	}
	return indexOfEntity(entries, e);
}

// The contexts of every entry of a block, computed together so a block with many children reads its declarations once, not once per child.
private struct ChildContexts {
	alias Key = ecrs.relation.Relation!1;
	alias Value = Placements;

	static bool valueEqual(ref const Placements a, ref const Placements b) @nogc nothrow {
		return fp.dynarray.slice(a.items) == fp.dynarray.slice(b.items);
	}

	static Placements compute(ref doir.query.QueryEngine engine, Key key) @nogc nothrow @trusted {
		immutable parent = key.related[0];
		auto outerContext = doir.query.query!ContextOf(engine, ContextOf.Key([parent]));
		if (outerContext is null) return Placements.init;
		immutable p = *outerContext;
		bool refused;
		Decl* decls = declarationsOf(engine, parent, refused);
		scope(exit) fp.dynarray.free(decls);
		Use* uses = null;
		scope(exit) fp.dynarray.free(uses);
		foreach (i, ref other; fp.dynarray.slice(decls)) {
			if (refused) break;
			cast(void) forEachArgument!((id) {
				refused = !fp.dynarray.pushBack(uses, Use(id, cast(uint) i));
				return !refused;
			})(engine, other.e);
		}
		Placements out_;
		if (!refused) {
			if (fp.dynarray.length(uses)) core.stdc.stdlib.qsort(uses, fp.dynarray.length(uses), Use.sizeof, &compareUses);
			immutable n = entriesOf(engine, parent).length;
			refused = n && fp.dynarray.reserve(out_.items, n) is null;
		}
		if (refused) {
			out_.finalize();
			doir.query.fail(engine);
			return Placements.init;
		}
		immutable inside = p.flags & inFunction;
		size_t next = 0; // the declarations are the complete entries, in order
		foreach (e; entriesOf(engine, parent)) {
			uint index = uint.max;
			if (next < fp.dynarray.length(decls) && decls[next].e == e) index = cast(uint) next++;
			Placement placed;
			if (ecrs.context.hasComponent!(doir.components.ast.Block)(*engine.store, e)) {
				const d = declOf(engine, e);
				if (d.isFunction) placed = Placement(0, executed | ordered | inFunction);
				else if (d.typeName == "namespace") placed = Placement(index, cast(ubyte) (ordered | inside | (p.flags & levelScope)), true);
				else {
					immutable runs = (p.flags & executed) && d.typeName != "type";
					immutable ubyte flags = cast(ubyte) ((runs ? executed | ordered : 0) | inside);
					// A block binding runs where it is first passed to a primitive, and reads its parent's bindings as they are there.
					immutable use = firstUse(fp.dynarray.slice(uses), d.name);
					placed = use == uint.max ? Placement(0, flags) : Placement(use, flags, true);
				}
			}
			cast(void) fp.dynarray.pushBack(out_.items, placed); // reserved
		}
		return out_;
	}
}

// The index of the first declaration passing `name` as an argument, from `uses` sorted by name then index, or `uint.max`.
private uint firstUse(const(Use)[] uses, doir.strings.StringId name) {
	if (name == doir.strings.noName) return uint.max;
	size_t low = 0, high = uses.length;
	while (low < high) {
		immutable middle = (low + high) / 2;
		if (uses[middle].name.value < name.value) low = middle + 1;
		else high = middle;
	}
	return low < uses.length && uses[low].name == name ? uses[low].index : uint.max;
}

/// The query of a block's `Context`, keyed by the block: a file's root runs, ordered, at level scope, and every other block's comes from its parent's, as `doir_check.check_block` passes it down.
struct ContextOf {
	alias Key = ecrs.relation.Relation!1; /// The block: a file's root, or a block-valued declaration.
	alias Value = Context; /// Where it sits.

	/// Computes it; a refused allocation fails the query, as `doir.query.fail` does.
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
	/// cast(void) doir.source.commit(engine, strings, file, "x : T = 1\n");
	/// assert(doir.query.query!ContextOf(engine, ContextOf.Key([doir.source.rootOf(engine, file)])).flags == 15 - 4);
	/// ---
	static Context compute(ref doir.query.QueryEngine engine, Key key) @nogc nothrow {
		immutable block = key.related[0];
		auto store = engine.store;
		if (!doir.query.read(engine, block)) return Context.init;
		if (ecrs.context.hasComponent!(doir.components.source.InFile)(*store, block)) return Context([invalidEntity], 0, executed | ordered | levelScope);
		auto parentOf = ecrs.context.findComponent!(doir.components.ast.Parent)(*store, block);
		if (parentOf is null) return Context.init;
		immutable parent = parentOf.parent;
		auto placements = doir.query.query!ChildContexts(engine, ChildContexts.Key([parent]));
		if (placements is null || !doir.query.read(engine, parent)) return Context.init;
		immutable i = entryIndex(engine, parent, block);
		if (i == size_t.max || i >= fp.dynarray.length(placements.items)) return Context.init;
		immutable placed = placements.items[i];
		return Context([placed.spliced ? parent : invalidEntity], placed.deadline, placed.flags);
	}
}




// --- resolution --------------------------------------------------------------

// The declaration `name`'s dotted segments reach from block `start`, through namespaces but the last; `invalidEntity` if none.
private EntityId lookupPath(ref doir.query.QueryEngine engine, EntityId start, const(char)[] name) {
	EntityId at = start;
	for (;;) {
		size_t dot = 0;
		while (dot < name.length && name[dot] != '.') ++dot;
		immutable id = doir.strings.find(*engine.strings, name[0 .. dot]);
		if (id == doir.strings.noName) return invalidEntity;
		immutable next = doir.names.entryNamed(engine, at, id);
		if (next == invalidEntity || dot == name.length) return next;
		if (!doir.query.read(engine, next)) return invalidEntity;
		auto flags = ecrs.context.findComponent!(doir.components.ast.Flags)(*engine.store, next);
		if (flags is null || !(flags.flags & doir.components.ast.Flags.Namespace)) return invalidEntity;
		at = next;
		name = name[dot + 1 .. $];
	}
}

// `name` looked up from block `from` in each enclosing namespace, innermost first, then the file's root (R-Unqual, as `doir_check` approximates it).
private EntityId resolve(ref doir.query.QueryEngine engine, EntityId from, const(char)[] name) {
	auto store = engine.store;
	for (EntityId at = from; at != invalidEntity;) {
		auto flags = ecrs.context.findComponent!(doir.components.ast.Flags)(*store, at);
		immutable scope_ = ecrs.context.hasComponent!(doir.components.source.InFile)(*store, at) || (flags !is null && (flags.flags & doir.components.ast.Flags.Namespace));
		if (scope_) {
			immutable found = lookupPath(engine, at, name);
			if (found != invalidEntity) return found;
		}
		auto parent = ecrs.context.findComponent!(doir.components.ast.Parent)(*store, at);
		at = parent is null ? invalidEntity : parent.parent;
	}
	return invalidEntity;
}

// The function type a call to `callee` from `from` calls: the declaration's own, or that of the type it is declared with.
private EntityId signatureOf(ref doir.query.QueryEngine engine, EntityId from, const(char)[] callee) {
	immutable target = resolve(engine, from, callee);
	if (target == invalidEntity || !doir.query.read(engine, target)) return invalidEntity;
	immutable own = ownFunctionType(engine, target);
	if (own != invalidEntity) return own;
	auto type = ecrs.context.findComponent!(doir.components.ast.LookupTypeOf)(*engine.store, target);
	auto parent = ecrs.context.findComponent!(doir.components.ast.Parent)(*engine.store, target);
	if (type is null || parent is null) return invalidEntity;
	immutable named = resolve(engine, parent.parent, nameText(engine, type.name));
	return named == invalidEntity || !doir.query.read(engine, named) ? invalidEntity : ownFunctionType(engine, named);
}


// --- the checks --------------------------------------------------------------

// Whether `block`'s last entry calls a terminator, or is a tail call (`WF-Term`, B-Tail).
private bool endsWithTerminator(ref doir.query.QueryEngine engine, EntityId block) {
	auto entries = entriesOf(engine, block);
	if (entries.length == 0 || !doir.query.read(engine, entries[$ - 1])) return false;
	immutable last = entries[$ - 1];
	auto flags = ecrs.context.findComponent!(doir.components.ast.Flags)(*engine.store, last);
	if (flags !is null && (flags.flags & doir.components.ast.Flags.Tail)) return true;
	auto call = ecrs.context.findComponent!(doir.components.ast.LookupCall)(*engine.store, last);
	return call !is null && among(nameText(engine, call.name), terminators[]);
}


/// The query of one block's checks, keyed by the block: `WF-Term` for the blocks its declarations hold, `WF-Order` for the names they read, and `D-Return`, `B-Tail`, `L-Scan`, `L-Sema` and `L-Bind` for their calls. Its value is whether the block passed; its diagnostics go through `doir.query.report`.
struct CheckBlock {
	alias Key = ecrs.relation.Relation!1; /// The block: a file's root, or a block-valued declaration.
	alias Value = bool; /// Whether it passed.

	/// Checks it; a refused allocation fails the query, as `doir.query.fail` does.
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
	/// cast(void) doir.source.commit(engine, strings, file, "f : () -> void = {\n\tx : T = 1\n}\n");
	/// assert(!*doir.query.query!CheckBlock(engine, CheckBlock.Key([doir.source.rootOf(engine, file)]))); // WF-Term
	/// ---
	static bool compute(ref doir.query.QueryEngine engine, Key key) @nogc nothrow @trusted {
		version(unittest) core.atomic.atomicOp!"+="(checkRuns, 1);
		immutable block = key.related[0];
		auto context = doir.query.query!ContextOf(engine, ContextOf.Key([block]));
		if (context is null) return false;
		immutable ctx = *context;
		bool refused;
		Decl* own = declarationsOf(engine, block, refused);
		scope(exit) fp.dynarray.free(own);
		Decl* outer = ctx.outer == invalidEntity || refused ? null : declarationsOf(engine, ctx.outer, refused);
		scope(exit) fp.dynarray.free(outer);
		if (refused) {
			doir.query.fail(engine);
			return false;
		}
		auto decls = fp.dynarray.slice(own);
		auto blockFlags = ecrs.context.findComponent!(doir.components.ast.Flags)(*engine.store, block);
		immutable inNamespace = blockFlags !is null && (blockFlags.flags & doir.components.ast.Flags.Namespace);
		bool passed = true;
		char[256] message, hint;
		foreach (i, ref d; decls) {
			// WF-Term is syntactic: a body or block binding ends properly wherever it is declared.
			if (ecrs.context.hasComponent!(doir.components.ast.Block)(*engine.store, d.e) && d.typeName != "namespace" && d.typeName != "type" && !endsWithTerminator(engine, d.e)) {
				passed = false;
				// Messages name no lines: a memo outlives edits that move its declarations, and the annotations are located when reported.
				if (!doir.query.report(engine, d.e, diagnose.Kind.error, "WF-Term: the block's last statement does not say where control goes next", terminatorHint)) return false;
			}
			auto called = ecrs.context.findComponent!(doir.components.ast.LookupCall)(*engine.store, d.e);
			// L-Scan, L-Sema, L-Bind: the scan reads these calls before anything runs, so only a file root or namespace may hold them.
			if (called !is null && !(ctx.flags & levelScope)) {
				const callee = nameText(engine, called.name);
				foreach (ref c; levelCalls) {
					if (callee != c.callee) continue;
					passed = false;
					immutable n = core.stdc.stdio.snprintf(message.ptr, message.length, "%.*s: '%.*s' is called where the compiler cannot find it without running code", cast(int) c.rule.length, c.rule.ptr, cast(int) callee.length, callee.ptr);
					const doir.query.Related[1] enclosing = [doir.query.Related([block], "this block or function body encloses the call; only a file root or namespace is read without running it")];
					if (!doir.query.report(engine, d.e, diagnose.Kind.error, message[0 .. n < message.length ? n : $], "the levels are read from the source before anything runs, so move this call to the file root or into a namespace", enclosing[])) return false;
				}
			}
			// B-Tail: a tail call returns from the function enclosing it, so it needs one, and ends its block.
			auto flags = ecrs.context.findComponent!(doir.components.ast.Flags)(*engine.store, d.e);
			if (called !is null && flags !is null && (flags.flags & doir.components.ast.Flags.Tail)) {
				if (!(ctx.flags & inFunction)) {
					passed = false;
					if (!doir.query.report(engine, d.e, diagnose.Kind.error, "B-Tail: this tail call is outside every function body, so it has nothing to return from", "move it into a function body, or drop `tail` to make it a plain call")) return false;
				} else if (i + 1 < decls.length) {
					passed = false;
					const doir.query.Related[1] after = [doir.query.Related([decls[i + 1].e], "this statement follows the tail call, so it never runs")];
					if (!doir.query.report(engine, d.e, diagnose.Kind.error, "B-Tail: this tail call ends its block, but statements follow it", "make the tail call the block's last statement, or drop `tail` to make it a plain call", after[])) return false;
				}
			}
			if (ctx.flags & ordered) {
				bool ok = forEachRead!((id) {
					immutable j = indexOf(decls, id);
					if (j != size_t.max) {
						if (j <= i || !decls[j].isValue) return true;
						const name = nameText(engine, id);
						immutable n = core.stdc.stdio.snprintf(message.ptr, message.length, "WF-Order: '%.*s' is used before the declaration that gives it a value", cast(int) name.length, name.ptr);
						immutable m = core.stdc.stdio.snprintf(hint.ptr, hint.length, "a block runs from top to bottom, so move the declaration of '%.*s' above this statement", cast(int) name.length, name.ptr);
						const doir.query.Related[1] bound = [doir.query.Related([decls[j].e], "it gets its value here, after it is used")];
						passed = false;
						return doir.query.report(engine, d.e, diagnose.Kind.error, message[0 .. n < message.length ? n : $], hint[0 .. m < hint.length ? m : $], bound[]);
					}
					immutable k = indexOf(fp.dynarray.slice(outer), id);
					if (k == size_t.max || !outer[k].isValue || k <= ctx.deadline) return true;
					const name = nameText(engine, id);
					immutable n = core.stdc.stdio.snprintf(message.ptr, message.length, inNamespace ? "WF-Order: '%.*s' is used in a namespace before the enclosing block gives it a value" : "WF-Order: '%.*s' is used in a block that runs before the enclosing block gives it a value", cast(int) name.length, name.ptr);
					immutable m = core.stdc.stdio.snprintf(hint.ptr, hint.length, inNamespace ? "a namespace binds in source order, so move the declaration of '%.*s' above the namespace" : "a spliced block runs where it is called, so move the declaration of '%.*s' above the statement that runs the block", cast(int) name.length, name.ptr);
					const doir.query.Related[1] bound = [doir.query.Related([outer[k].e], inNamespace ? "it gets its value here, after the namespace" : "it gets its value here, after the block runs")];
					passed = false;
					return doir.query.report(engine, d.e, diagnose.Kind.error, message[0 .. n < message.length ? n : $], hint[0 .. m < hint.length ? m : $], bound[]);
				})(engine, d.e);
				if (!ok) return false;
			}
			// D-Return: a `_` destination receiving a `_` return leaves the return type unsolved, control flow included (B-If).
			if (called !is null && d.typeName == "_") {
				const callee = nameText(engine, called.name);
				immutable ft = signatureOf(engine, block, callee);
				auto returned = ft == invalidEntity ? null : ecrs.context.findComponent!(doir.components.ast.LookupFunctionReturn)(*engine.store, ft);
				if (returned !is null && nameText(engine, returned.name) == "_") {
					passed = false;
					immutable n = core.stdc.stdio.snprintf(message.ptr, message.length, "D-Return: this declaration's type cannot be worked out, since both it and the return type of '%.*s' are `_`", cast(int) callee.length, callee.ptr);
					immutable m = core.stdc.stdio.snprintf(hint.ptr, hint.length, "write the type in place of `_`, as in `x : std.u8 = ...`, or give '%.*s' a return type after its `->`", cast(int) callee.length, callee.ptr);
					if (!doir.query.report(engine, d.e, diagnose.Kind.error, message[0 .. n < message.length ? n : $], hint[0 .. m < hint.length ? m : $])) return false;
				}
			}
		}
		return passed;
	}
}

/// The query of the checks of a block and of every block below it, keyed by the block: whether they all passed. An edit marks stale only the trees along its path and those of the blocks whose checks it reaches (`doir.query.markChanged`), so re-validating a file's tree visits only those.
struct CheckTree {
	alias Key = ecrs.relation.Relation!1; /// The block: a file's root, or a block-valued declaration.
	alias Value = bool; /// Whether every block's checks passed.

	/// Checks them; a refused allocation fails the query, as `doir.query.fail` does.
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
	/// cast(void) doir.source.commit(engine, strings, file, "n : namespace = {\n\tf : () -> void = {\n\t\tx : T = 1\n\t}\n}\n");
	/// assert(!*doir.query.query!CheckTree(engine, CheckTree.Key([doir.source.rootOf(engine, file)]))); // WF-Term, two blocks down
	/// ---
	static bool compute(ref doir.query.QueryEngine engine, Key key) @nogc nothrow {
		immutable block = key.related[0];
		auto own = doir.query.query!CheckBlock(engine, CheckBlock.Key([block]));
		if (own is null || !doir.query.read(engine, block)) return false;
		bool passed = *own;
		// Every entry is read, since one that becomes a block need not change its block's list.
		foreach (e; entriesOf(engine, block)) {
			if (!doir.query.read(engine, e)) return false;
			if (!ecrs.context.hasComponent!(doir.components.ast.Block)(*engine.store, e)) continue;
			auto below = doir.query.query!CheckTree(engine, Key([e]));
			if (below is null) return false;
			passed = passed && *below;
		}
		return passed;
	}
}

// Appends the checks of `block` and the blocks below it whose trees are not up to date, in `doir_check`'s order. False on refusal.
private bool collectStale(ref doir.query.QueryEngine engine, EntityId block, ref CheckBlock.Key* out_) {
	if (doir.query.upToDate!CheckTree(engine, CheckTree.Key([block]))) return true;
	if (!fp.dynarray.pushBack(out_, CheckBlock.Key([block]))) return false;
	foreach (e; entriesOf(engine, block))
		if (ecrs.context.hasComponent!(doir.components.ast.Block)(*engine.store, e) && !collectStale(engine, e, out_)) return false;
	return true;
}

/// Runs every block's checks on `file`, which must have been committed, reporting their diagnostics, fresh or remembered, to `engine.diagnostics`. After an edit it visits only the blocks the edit reached and those whose checks report diagnostics (`CheckTree`). With `program`, it also checks that the root ends with a terminator (`L-Entry`). `engine.strings` must be set.
///
/// Returns false if an allocation was refused, which loses some diagnostics.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import diagnose;
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
/// diagnose.Manager manager;
/// scope(exit) diagnose.free(manager);
/// engine.diagnostics = &manager;
/// immutable file = doir.source.addFile(engine, strings, "p.doir");
/// cast(void) doir.source.commit(engine, strings, file, "x : T = 1\n");
/// assert(check(engine, file, true) && diagnose.count(manager) == 1); // L-Entry
/// ---
bool check(ref doir.query.QueryEngine engine, EntityId file, bool program = false) {
	assert(engine.strings !is null, "doir.checks: the engine needs its strings");
	immutable root = doir.source.rootOf(engine, file);
	if (root == invalidEntity) return true;
	// Block checks are independent, so those an edit may have reached run as one batch on the workers (L-Sema); the tree then finds them current.
	CheckBlock.Key* blocks = null;
	scope(exit) fp.dynarray.free(blocks);
	if (!collectStale(engine, root, blocks)) {
		engine.refused = true;
		return false;
	}
	if (!doir.query.demandEach!CheckBlock(engine, fp.dynarray.slice(blocks))) return false;
	// Their trees are a batch too, children first, so a tree rarely waits on one below it.
	foreach (i; 0 .. fp.dynarray.length(blocks) / 2) {
		auto swap = blocks[i];
		blocks[i] = blocks[fp.dynarray.length(blocks) - 1 - i];
		blocks[fp.dynarray.length(blocks) - 1 - i] = swap;
	}
	static assert(is(CheckBlock.Key == CheckTree.Key));
	if (!doir.query.demandEach!CheckTree(engine, fp.dynarray.slice(blocks))) return false;
	if (doir.query.query!CheckTree(engine, CheckTree.Key([root])) is null && engine.refused) return false;
	if (program && !endsWithTerminator(engine, root)) {
		auto entries = entriesOf(engine, root);
		return doir.query.report(engine, entries.length ? entries[$ - 1] : invalidEntity, diagnose.Kind.error, "WF-Term: the program's last statement does not say where control goes next (L-Entry)", terminatorHint);
	}
	return !engine.refused;
}


version(unittest) {
	static import core.atomic;
	static import fp.pointer;
	static import bc.threadpool;
	static import doir.components.query;

	// How many times a block's checks have run, for tests that an edit re-runs only what it reaches.
	private shared size_t checkRuns;
}

unittest { // an edit inside one namespace re-runs that namespace's checks and no others, on one thread or on workers, with edges kept from the start or built after the first check
	auto pool = bc.threadpool.create(2);
	assert(pool !is null);
	scope(exit) bc.threadpool.free(pool);
	foreach (deferred; [false, true])
	foreach (workers; [null, pool]) {
		auto store = ecrs.context.create();
		scope(exit) ecrs.context.free(store);
		auto engine = doir.query.create(store);
		scope(exit) doir.query.free(engine);
		doir.strings.Strings strings;
		scope(exit) doir.strings.free(strings);
		engine.strings = &strings;
		engine.workers = workers;
		engine.edgesMissing = deferred;
		immutable file = doir.source.addFile(engine, strings, "n.doir");
		static immutable text = "a : namespace = {\n\tx : T = 1\n\ty : T = 2\n}\nb : namespace = {\n\tz : T = 3\n}\n";
		immutable before = core.atomic.atomicLoad(checkRuns);
		assert(doir.source.commit(engine, strings, file, text) == 0 && check(engine, file));
		immutable first = core.atomic.atomicLoad(checkRuns);
		assert(workers !is null || first == before + 3); // the root, a and b; workers also count attempts they hand back
		assert(!deferred || doir.query.buildDependents(engine));
		immutable b = entriesOf(engine, doir.source.rootOf(engine, file))[1];
		immutable verified = ecrs.context.getComponent!(doir.components.query.VerifiedAt)(store, doir.query.find!CheckBlock(engine, CheckBlock.Key([b]))).revision;
		assert(doir.source.commitEdit(engine, strings, file, 27, 28, "5") == 0 && check(engine, file));
		assert(core.atomic.atomicLoad(checkRuns) == first + 1);
		// b's tree was reused at once, so its checks were not even visited.
		assert(ecrs.context.getComponent!(doir.components.query.VerifiedAt)(store, doir.query.find!CheckBlock(engine, CheckBlock.Key([b]))).revision == verified);
	}
}

unittest { // the corpus cases for these rules: each reject case reports its rule, the accept cases nothing
	static struct Case { string text; string tag; size_t annotations = 1; } // annotations: of the diagnostic the tag names
	static immutable Case[] cases = [
		Case("address_t : type = (T: deduced type, function: T) -> _\naddress : address_t\nf : (v: std.u8) -> std.u8 = {\n\t_ : _ = std.return(v)\n}\n_ : _ = address(f)\n", "D-Return"),
		Case("flow : namespace = {\n\texport if : (condition: std.u1, then: block, else: block) -> _\n}\nc : std.u1 = 1\na : block = { _ : _ = std.block_result(std.nothing) ; }\nb : block = { _ : _ = std.block_result(std.nothing) ; }\n_ : _ = flow.if(c, a, b)\n", "D-Return"),
		Case("lib : namespace = {\n\tmake : (T: type) -> _\n\tf : () -> void = {\n\t\tt : type = std.u8\n\t\t_ : _ = make(t)\n\t\t_ : _ = std.return(std.nothing)\n\t}\n}\n", "D-Return"),
		Case("c : std.u1 = 1\na : block = { _ : _ = std.block_result(std.nothing) ; }\nb : block = { _ : _ = std.block_result(std.nothing) ; }\n_ : void = std.if(c, a, b)\n", null),
		Case("y : std.u8 = std.copy(std.u8, v)\nv : std.u8 = 5\n", "WF-Order", 2),
		Case("ns : namespace = {\n\tf : () -> void = {\n\t\tx : std.u8 = 1\n\t}\n}\n", "WF-Term"),
		Case("outer : block = {\n\tr : T = std.copy(T, late)\n\t_ : _ = std.block_result(r)\n}\n_ : _ = std.if(c, outer, outer)\nlate : T = 1\n", "WF-Order", 2),
		Case("g : (v: std.u8) -> std.u8 = {\n\t_ : _ = std.return(v)\n}\nx : std.u8 = 7\n_ : _ = tail g(x)\n", "B-Tail"),
		Case("g : (v: std.u8) -> std.u8 = {\n\t_ : _ = std.return(v)\n}\nf : (v: std.u8) -> std.u8 = {\n\tr : std.u8 = tail g(v)\n\t_ : _ = std.return(r)\n}\n", "B-Tail", 2),
		Case("g : (v: std.u8) -> std.u8 = {\n\t_ : _ = std.return(v)\n}\nf : (v: std.u8) -> std.u8 = {\n\t_ : _ = tail g(v)\n}\n", null),
		Case("ns : namespace = {\n\tt : compiler.level = compiler.levels.make(ns)\n}\n", null),
		Case("f : () -> compiler.level = {\n\tt : compiler.level = compiler.levels.make(extra)\n\t_ : _ = std.return(t)\n}\n", "L-Scan", 2),
		Case("edge : block = {\n\t_ : compiler.level = compiler.levels.lower_to(a, b, passes)\n\t_ : _ = std.block_result(std.nothing)\n}\n", "L-Scan", 2),
		Case("analysis : block = {\n\t_ : compiler.level = compiler.levels.check(t, arity)\n\t_ : _ = std.block_result(std.nothing)\n}\n", "L-Sema", 2),
		Case("setup : block = {\n\t_ : (e: std.meta.entity) -> std.u8 = compiler.levels.bind_pass(f, name)\n\t_ : _ = std.block_result(std.nothing)\n}\n", "L-Bind", 2),
		Case("ns : namespace = {\n\ty : T = std.copy(T, late)\n}\nlate : T = 1\n", "WF-Order", 2),
		Case("slices : block = {\n\t_ : compiler.level = compiler.levels.bundle(fat, a, b)\n\t_ : _ = std.block_result(std.nothing)\n}\n", "L-Scan", 2),
		Case("ns : namespace = {\n\tf : () -> compiler.pointer_sized = {\n\t\tx : compiler.pointer_sized = 1\n\t\t_ : _ = compiler.return(x)\n\t}\n}\n", null),
	];
	foreach (test; cases) {
		auto store = ecrs.context.create();
		scope(exit) ecrs.context.free(store);
		auto engine = doir.query.create(store);
		scope(exit) doir.query.free(engine);
		doir.strings.Strings strings;
		scope(exit) doir.strings.free(strings);
		engine.strings = &strings;
		diagnose.Manager manager;
		scope(exit) diagnose.free(manager);
		engine.diagnostics = &manager;
		immutable file = doir.source.addFile(engine, strings, "c.doir");
		assert(doir.source.commit(engine, strings, file, test.text) == 0);
		assert(check(engine, file));
		if (test.tag is null) {
			assert(diagnose.count(manager) == 0);
			continue;
		}
		assert(diagnose.count(manager) >= 1);
		bool tagged = false;
		foreach (ref d; fp.dynarray.slice(manager.diagnostics)) {
			auto m = fp.string.slice(d.message);
			// Each points at its declaration with a hint saying how to fix it, and at each other item involved.
			assert(fp.dynarray.length(d.annotations) >= 1);
			foreach (ref a; fp.dynarray.slice(d.annotations)) assert(fp.dynarray.length(a.message));
			if (m.length > test.tag.length && m[0 .. test.tag.length] == test.tag) {
				tagged = true;
				assert(fp.dynarray.length(d.annotations) == test.annotations);
			}
		}
		assert(tagged);

		// A second revision with nothing changed reports the same diagnostics again, from the memos.
		immutable before = diagnose.count(manager);
		diagnose.clear(manager);
		doir.query.beginRevision(engine);
		assert(check(engine, file) && diagnose.count(manager) == before);
	}

	// Every case, each in a namespace of its own, many times over: workers report what one thread does, in the same order.
	char* text = null;
	scope(exit) fp.string.free(text);
	foreach (copy; 0 .. 16)
		foreach (i, test; cases) {
			char[32] header;
			immutable n = core.stdc.stdio.snprintf(header.ptr, header.length, "n%d_%d : namespace = {\n", cast(int) copy, cast(int) i);
			assert(fp.string.concatenate(text, header[0 .. n]) !is null);
			foreach (c; test.text) {
				char[2] pair = ['\t', c];
				immutable startsLine = fp.string.length(text) == 0 || text[fp.string.length(text) - 1] == '\n';
				assert(fp.string.concatenate(text, startsLine ? pair[] : pair[1 .. 2]) !is null);
			}
			assert(fp.string.concatenate(text, "}\n") !is null);
		}
	auto pool = bc.threadpool.create(4);
	assert(pool !is null);
	scope(exit) bc.threadpool.free(pool);
	char*[2] reports;
	scope(exit) foreach (r; reports) fp.string.free(r);
	foreach (run, workers; [null, pool]) {
		auto store = ecrs.context.create();
		scope(exit) ecrs.context.free(store);
		auto engine = doir.query.create(store);
		scope(exit) doir.query.free(engine);
		doir.strings.Strings strings;
		scope(exit) doir.strings.free(strings);
		engine.strings = &strings;
		engine.workers = workers;
		diagnose.Manager manager;
		scope(exit) diagnose.free(manager);
		engine.diagnostics = &manager;
		immutable file = doir.source.addFile(engine, strings, "all.doir");
		assert(doir.source.commit(engine, strings, file, fp.string.slice(text)) == 0);
		// The first revision runs every check; the second re-validates them all.
		foreach (revision; 0 .. 2) {
			doir.query.beginRevision(engine);
			assert(check(engine, file));
			assert(diagnose.count(manager) > 16);
			foreach (ref d; fp.dynarray.slice(manager.diagnostics)) {
				assert(fp.string.concatenate(reports[run], fp.string.slice(d.message)) !is null);
				assert(fp.string.concatenate(reports[run], "\n") !is null);
			}
			diagnose.clear(manager);
		}
	}
	assert(fp.string.slice(reports[0]) == fp.string.slice(reports[1]));

	// Edits that add, move and remove diagnostics: checking after each reports what checking the same text afresh does.
	static struct Edit { string find, replacement; }
	static immutable Edit[] edits = [
		Edit("std.copy(std.u8, v)", "std.copy(std.u8, 5)"),
		Edit("n3_5 : namespace = {\n", "n3_5 : namespace = {\n\tg : () -> void = {\n\t\tx : std.u8 = 1\n\t}\n"),
		Edit("\t\t_ : _ = std.return(v)\n", ""),
		Edit("std.copy(std.u8, 5)", "std.copy(std.u8, v)"),
		Edit("n2_6 : namespace = {\n\touter : block = {\n\t\tr : T = std.copy(T, late)", "n2_6 : namespace = {\n\touter : block = {\n\t\tr : T = std.copy(T, early)"),
		Edit("\t\tx : std.u8 = 1\n", "\t\tx : std.u8 = 1\n\t\t_ : _ = std.return(std.nothing)\n"),
	];
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	auto engine = doir.query.create(store);
	scope(exit) doir.query.free(engine);
	doir.strings.Strings strings;
	scope(exit) doir.strings.free(strings);
	engine.strings = &strings;
	engine.workers = pool;
	diagnose.Manager manager;
	scope(exit) diagnose.free(manager);
	engine.diagnostics = &manager;
	immutable file = doir.source.addFile(engine, strings, "all.doir");
	assert(doir.source.commit(engine, strings, file, fp.string.slice(text)) == 0 && check(engine, file));
	foreach (edit; edits) {
		immutable at = fp.string.find(fp.string.slice(text), edit.find, 0);
		assert(at != fp.pointer.notFound);
		auto next = fp.string.createFromConcatenation(fp.string.slice(text)[0 .. at], edit.replacement, fp.string.slice(text)[at + edit.find.length .. $]);
		assert(next !is null);
		fp.string.free(text);
		text = next;
		diagnose.clear(manager);
		assert(doir.source.commitEdit(engine, strings, file, at, at + edit.find.length, edit.replacement) != fp.pointer.allocationRefused && check(engine, file));

		auto freshStore = ecrs.context.create();
		scope(exit) ecrs.context.free(freshStore);
		auto fresh = doir.query.create(freshStore);
		scope(exit) doir.query.free(fresh);
		fresh.strings = &strings;
		diagnose.Manager expected;
		scope(exit) diagnose.free(expected);
		fresh.diagnostics = &expected;
		immutable freshFile = doir.source.addFile(fresh, strings, "all.doir");
		assert(doir.source.commit(fresh, strings, freshFile, fp.string.slice(text)) != fp.pointer.allocationRefused && check(fresh, freshFile));
		assert(diagnose.count(manager) == diagnose.count(expected));
		foreach (i, ref d; fp.dynarray.slice(manager.diagnostics)) {
			assert(fp.string.slice(d.message) == fp.string.slice(expected.diagnostics[i].message));
			assert(d.location.start.line == expected.diagnostics[i].location.start.line);
			assert(fp.dynarray.length(d.annotations) == fp.dynarray.length(expected.diagnostics[i].annotations));
			foreach (a, ref annotation; fp.dynarray.slice(d.annotations)) assert(annotation.position == expected.diagnostics[i].annotations[a].position);
		}
	}
}

unittest { // L-Entry points at the program's last statement; ContextOf finds an entry with no order key by scanning; a refused allocation anywhere fails the check
	static import fp.testing;
	static import doir.components.source;
	static immutable program = "x : T = 1\ny : T = 2\n";
	{
		auto store = ecrs.context.create();
		scope(exit) ecrs.context.free(store);
		auto engine = doir.query.create(store);
		scope(exit) doir.query.free(engine);
		doir.strings.Strings strings;
		scope(exit) doir.strings.free(strings);
		engine.strings = &strings;
		diagnose.Manager manager;
		scope(exit) diagnose.free(manager);
		engine.diagnostics = &manager;
		immutable file = doir.source.addFile(engine, strings, "p.doir");
		assert(doir.source.commit(engine, strings, file, program) == 0 && check(engine, file, true));
		assert(diagnose.count(manager) == 1);
		auto d = &manager.diagnostics[0];
		assert(fp.string.slice(d.message)[0 .. 8] == "WF-Term:");
		assert(fp.dynarray.length(d.annotations) == 1 && fp.string.slice(d.annotations[0].message) == terminatorHint);
		assert(d.annotations[0].position.line == 2);
	}

	static immutable nested = "a : namespace = {\n\tx : T = 1\n\tf : () -> void = {\n\t\tv : T = x\n\t\tb : block = { _ : _ = std.block_result(v) ; }\n\t\t_ : _ = std.return(std.nothing)\n\t}\n}\ny : T = std.copy(T, x)\n";
	Context[2] contexts;
	foreach (stripped; [false, true]) {
		auto store = ecrs.context.create();
		scope(exit) ecrs.context.free(store);
		auto engine = doir.query.create(store);
		scope(exit) doir.query.free(engine);
		doir.strings.Strings strings;
		scope(exit) doir.strings.free(strings);
		engine.strings = &strings;
		immutable file = doir.source.addFile(engine, strings, "n.doir");
		assert(doir.source.commit(engine, strings, file, nested) == 0);
		immutable a = entriesOf(engine, doir.source.rootOf(engine, file))[0];
		if (stripped) assert(ecrs.context.removeComponent!(doir.components.source.LexicalPosition)(store, a));
		auto context = doir.query.query!ContextOf(engine, ContextOf.Key([a]));
		assert(context !is null);
		contexts[stripped] = *context;
	}
	assert(contexts[0] == contexts[1]);
	{
		// A block whose parent does not list it has no context.
		auto store = ecrs.context.create();
		scope(exit) ecrs.context.free(store);
		auto engine = doir.query.create(store);
		scope(exit) doir.query.free(engine);
		doir.strings.Strings strings;
		scope(exit) doir.strings.free(strings);
		engine.strings = &strings;
		immutable file = doir.source.addFile(engine, strings, "o.doir");
		assert(doir.source.commit(engine, strings, file, nested) == 0);
		immutable orphan = ecrs.context.addEntity(store);
		assert(ecrs.context.setComponent!(doir.components.ast.Parent)(store, orphan, doir.components.ast.Parent([doir.source.rootOf(engine, file)])));
		assert(*doir.query.query!ContextOf(engine, ContextOf.Key([orphan])) == Context.init);
	}

	for (size_t budget = 0;; ++budget) {
		auto store = ecrs.context.create();
		scope(exit) ecrs.context.free(store);
		auto engine = doir.query.create(store);
		scope(exit) doir.query.free(engine);
		doir.strings.Strings strings;
		scope(exit) doir.strings.free(strings);
		engine.strings = &strings;
		immutable file = doir.source.addFile(engine, strings, "r.doir");
		assert(doir.source.commit(engine, strings, file, nested) == 0);
		auto allocator = fp.testing.beginRationedAllocator(budget);
		immutable passed = check(engine, file, true);
		fp.testing.endRationedAllocator(allocator);
		if (passed) break;
		assert(engine.refused);
	}
}
