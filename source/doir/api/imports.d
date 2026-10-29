/// Imports as finished files (`I-Import`): an import is a query keyed by the file and the importing level, whose value is the root of the file evaluated to completion and frozen, as `freezeLevel` freezes a level. The importer reads its entities by entity alone, its effects never enter the importer's logs, and two levels that import one file each get their own copy of its entities (`L-Tower`).
///
/// The level supplies the semantics: its `LevelEvaluator` builds a file's entities through `createEntity` and `produce`, so the copy belongs to the import query, and runs its comptime. Two files that import each other are a cycle (`Q-Cycle`), as is an import whose path depends on the lookup it would answer. Editing an imported file re-runs its import, and early cutoff stops at importers whose reads of it are unchanged.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.query;
/// static import doir.api.components;
/// static EntityId empty(ref doir.api.query.QueryEngine engine, EntityId file, EntityId level) @nogc nothrow {
/// 	immutable root = doir.api.query.createEntity(engine, file);
/// 	cast(void) doir.api.query.produce!(doir.api.components.Block)(engine, root);
/// 	return root;
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.api.query.create(store);
/// scope(exit) doir.api.query.free(engine);
/// immutable file = ecrs.context.addEntity(store), level = ecrs.context.addEntity(store);
/// ecrs.context.addComponent!LevelEvaluator(store, level).evaluate = &empty;
/// immutable root = doir.api.query.query!Import(engine, Import.Key([file, level])).root;
/// assert(ecrs.context.hasComponent!(doir.api.components.Block)(store, root));
/// ---
module doir.api.imports;

static import fp.dynarray;

static import diagnose;
static import ecrs.context;
static import ecrs.registry;
static import ecrs.relation;

static import doir.strings;
static import doir.api.builders;
static import doir.api.components;
static import doir.api.effects;
static import doir.api.query;

public import ecrs.registry : EntityId, invalidEntity;

@nogc nothrow:


// --- types and layout --------------------------------------------------------

/// A source file's input entity: its path, interned. The file's contents join it with the parser (`roadmap.md` Phase 2).
struct SourceFile {
	doir.strings.StringId path; /// The path, as the build named it.
}

/// Builds the entities of `file` for `level` through `createEntity` and `produce`, and runs its comptime, inside the import query. Returns its root block, or `invalidEntity` if it cannot be evaluated, having reported why.
alias EvaluateFunction = EntityId function(ref doir.api.query.QueryEngine engine, EntityId file, EntityId level) @nogc nothrow;

/// How a level evaluates a file it imports: its parse and its comptime. An input on the level entity, set when the tower is built.
struct LevelEvaluator {
	EvaluateFunction evaluate; /// The evaluator.
}

/// The files a block's `std.import` declarations name, resolved to their input entities, in declaration order. An input, written by the commit that parses them, or by evaluation once paths are comptime values.
struct Imports {
	mixin ecrs.relation.Relates;
}

unittest { // libECRS silently skips a holder whose hook is not `@nogc nothrow`; every holder of an entity id must pass (E-Remap)
	static assert(ecrs.registry.hasRemapEntities!Imports);
}


// --- queries -----------------------------------------------------------------

/// The import of `file` into `level`: its root block, evaluated by the level's `LevelEvaluator` and frozen (`I-Import`, `L-Freeze`), or `invalidEntity` if the level has no evaluator or the evaluation failed.
struct Import {
	/// The imported file's input entity and the importing level.
	struct Key {
		mixin ecrs.relation.Relates!("file", "level");
	}
	/// The imported file's root block.
	struct Value {
		mixin ecrs.relation.Relates!"root";
	}

	/// Evaluates and freezes the file.
	///
	/// Examples:
	/// ---
	/// static import ecrs.context;
	/// static import doir.api.query;
	/// auto store = ecrs.context.create();
	/// scope(exit) ecrs.context.free(store);
	/// auto engine = doir.api.query.create(store);
	/// scope(exit) doir.api.query.free(engine);
	/// immutable file = ecrs.context.addEntity(store), level = ecrs.context.addEntity(store);
	/// assert(doir.api.query.query!Import(engine, Import.Key([file, level])).root == invalidEntity);
	/// ---
	static Value compute(ref doir.api.query.QueryEngine engine, Key key) @nogc nothrow {
		if (!doir.api.query.read(engine, key.file) || !doir.api.query.read(engine, key.level)) return Value([invalidEntity]);
		auto evaluator = ecrs.context.findComponent!LevelEvaluator(*engine.store, key.level);
		if (evaluator is null) {
			cast(void) doir.api.query.report(engine, key.file, diagnose.Kind.error, "I-Import: the importing level cannot evaluate files"); // a refusal fails this query
			return Value([invalidEntity]);
		}
		immutable root = evaluator.evaluate(engine, key.file, key.level);
		if (root == invalidEntity || !doir.api.effects.freezeLevel(engine, root)) return Value([invalidEntity]);
		return Value([root]);
	}
}

/// The exported declaration named `name` that one of `block`'s imports into `level` makes visible, or `invalidEntity` if none does (`I-Import`, `I-Export`). A lookup that misses `block`'s own declarations calls it, demanding the block's imports as a forward reference demands a declaration (`R-Order`), so the import is visible on every line. Two imports that make one name visible as different entities are a collision, reported (`WF-Unique`); the first is returned. An import that is a cycle (`Q-Cycle`) makes nothing visible.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.query;
/// static import doir.strings;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.api.query.create(store);
/// scope(exit) doir.api.query.free(engine);
/// immutable block = ecrs.context.addEntity(store), level = ecrs.context.addEntity(store);
/// assert(findImported(engine, block, level, doir.strings.StringId(0)) == invalidEntity);
/// ---
EntityId findImported(ref doir.api.query.QueryEngine engine, EntityId block, EntityId level, doir.strings.StringId name) {
	if (!doir.api.query.read(engine, block)) return invalidEntity;
	auto imports = ecrs.context.findComponent!Imports(*engine.store, block);
	if (imports is null) return invalidEntity;
	EntityId found = invalidEntity;
	immutable n = fp.dynarray.length(imports.related);
	foreach (i; 0 .. n) {
		immutable file = ecrs.context.getComponent!Imports(*engine.store, block).related[i];
		auto root = doir.api.query.query!Import(engine, Import.Key([file, level]));
		if (root is null || root.root == invalidEntity) continue;
		foreach (e; fp.dynarray.slice(ecrs.context.getComponent!(doir.api.components.Block)(*engine.store, root.root).related)) {
			auto declared = ecrs.context.findComponent!(doir.api.components.Name)(*engine.store, e);
			if (declared is null || declared.value != name
				|| !(doir.api.effects.flags(engine, e) & doir.api.components.Flags.Export))
				continue;
			if (found == invalidEntity) found = e;
			else if (found != e) cast(void) doir.api.query.report(engine, e, diagnose.Kind.error, "WF-Unique: two imports make the same name visible"); // a refusal fails the running queries or sets engine.refused
		}
	}
	return found;
}


version(unittest) {
	static import fp.string;

	static import doir.testing;
	static import doir.api.positions;

	private __gshared doir.strings.Strings strings;
	private __gshared EntityId fileA, fileB, fileC;
	private __gshared uint modifier = doir.api.components.Flags.Immutable;
	private __gshared int evaluations, readerRuns;

	private doir.strings.StringId s(const(char)[] text) { return doir.strings.intern(strings, text); }

	// B and C hold `export t : type = {} ; _ : _ = std.types.immutable(t)`; C adds an unexported `u`.
	private EntityId evaluate(ref doir.api.query.QueryEngine engine, EntityId file, EntityId level) {
		++evaluations;
		assert(doir.api.query.read(engine, file));
		immutable root = doir.api.query.createEntity(engine, file);
		auto block = doir.api.query.produce!(doir.api.components.Block)(engine, root);
		assert(block !is null);
		if (auto imports = ecrs.context.findComponent!Imports(*engine.store, file))
			foreach (other; fp.dynarray.slice(imports.related)) {
				auto imported = doir.api.query.query!Import(engine, Import.Key([other, level]));
				if (imported is null || imported.root == invalidEntity) return invalidEntity;
			}
		if (file != fileB && file != fileC) return root;

		immutable t = doir.api.query.createEntity(engine, file);
		doir.api.query.produce!(doir.api.components.Name)(engine, t).value = s("t");
		doir.api.query.produce!(doir.api.components.Parent)(engine, t).parent = root;
		doir.api.query.produce!(doir.api.components.Flags)(engine, t).flags = doir.api.components.Flags.Export;
		immutable pushed = fp.dynarray.pushBack(block.related, t);
		assert(pushed);
		if (file == fileC) {
			immutable u = doir.api.query.createEntity(engine, file);
			doir.api.query.produce!(doir.api.components.Name)(engine, u).value = s("u");
			doir.api.query.produce!(doir.api.components.Parent)(engine, u).parent = root;
			immutable pushedU = fp.dynarray.pushBack(block.related, u);
			assert(pushedU);
		}
		immutable pt = doir.api.positions.between(engine, doir.api.positions.root, doir.api.positions.none, doir.api.positions.none);
		immutable pm = doir.api.positions.between(engine, doir.api.positions.root, pt, doir.api.positions.none);
		assert(doir.api.effects.applyFlags(engine, t, pm, modifier));
		// Inside B, a read on t's own line still sees it unmodified.
		uint seen;
		assert(doir.api.effects.flagsAt(engine, t, pt, seen) && seen == doir.api.components.Flags.Export);
		return root;
	}

	// A declaration of the importing file, on a line above its import, reading `t`'s flags.
	private struct ReadImported {
		struct Key {
			mixin ecrs.relation.Relates!("block", "level");
		}
		alias Value = uint;
		static uint compute(ref doir.api.query.QueryEngine engine, Key key) @nogc nothrow {
			++readerRuns;
			immutable t = findImported(engine, key.block, key.level, s("t"));
			return t == invalidEntity ? 0 : doir.api.effects.flags(engine, t);
		}
	}
}

unittest { // an imported file arrives finished, once per level, and its edits stop at unchanged importers
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	diagnose.Manager manager;
	scope(exit) diagnose.free(manager);
	auto engine = doir.api.query.create(store);
	scope(exit) doir.api.query.free(engine);
	engine.diagnostics = &manager;
	scope(exit) doir.strings.free(strings);

	fileA = doir.testing.addEntity(store);
	fileB = doir.testing.addEntity(store);
	doir.testing.addComponent!SourceFile(store, fileA).path = s("a.doir");
	doir.testing.addComponent!SourceFile(store, fileB).path = s("b.doir");
	immutable level = doir.testing.addEntity(store), other = doir.testing.addEntity(store);
	doir.testing.addComponent!LevelEvaluator(store, level).evaluate = &evaluate;
	doir.testing.addComponent!LevelEvaluator(store, other).evaluate = &evaluate;
	auto rootA = doir.api.builders.createRoot(store);
	immutable pushed = fp.dynarray.pushBack(doir.testing.addComponent!Imports(store, rootA.block).related, fileB);
	assert(pushed);
	immutable EntityId[5] inputs = [fileA, fileB, level, other, rootA.block];
	foreach (e; inputs) assert(doir.api.query.markChanged(engine, e));

	// A read of the imported type, whatever line it is on, sees every modifier the imported file applied.
	evaluations = readerRuns = 0;
	assert(*doir.api.query.query!ReadImported(engine, ReadImported.Key([rootA.block, level])) == (doir.api.components.Flags.Export | doir.api.components.Flags.Immutable));
	assert(evaluations == 1);
	assert(!ecrs.context.hasComponent!(doir.api.effects.FlagsLog)(store, rootA.block));

	// Another level importing the same file gets its own copy.
	immutable here = doir.api.query.query!Import(engine, Import.Key([fileB, level])).root;
	immutable there = doir.api.query.query!Import(engine, Import.Key([fileB, other])).root;
	assert(here != there && evaluations == 2);

	// Editing the file without changing what it makes re-runs the import, and early cutoff stops at the importer.
	doir.api.query.beginRevision(engine);
	assert(doir.api.query.markChanged(engine, fileB));
	assert(*doir.api.query.query!ReadImported(engine, ReadImported.Key([rootA.block, level])) == (doir.api.components.Flags.Export | doir.api.components.Flags.Immutable));
	assert(evaluations == 3 && readerRuns == 1);
	assert(doir.api.query.query!Import(engine, Import.Key([fileB, level])).root == here);

	// An edit that changes the modifier reaches the importer.
	doir.api.query.beginRevision(engine);
	modifier = doir.api.components.Flags.Packed;
	assert(doir.api.query.markChanged(engine, fileB));
	assert(*doir.api.query.query!ReadImported(engine, ReadImported.Key([rootA.block, level])) == (doir.api.components.Flags.Export | doir.api.components.Flags.Packed));
	assert(readerRuns == 2);
	modifier = doir.api.components.Flags.Immutable;

	// Two imports that make `t` visible as different entities collide (WF-Unique); the first, B's, still Packed from its last edit, wins.
	assert(diagnose.count(manager) == 0);
	doir.api.query.beginRevision(engine);
	fileC = doir.testing.addEntity(store);
	doir.testing.addComponent!SourceFile(store, fileC).path = s("c.doir");
	auto rootD = doir.api.builders.createRoot(store);
	auto both = &doir.testing.addComponent!Imports(store, rootD.block).related;
	assert(fp.dynarray.pushBack(*both, fileB) && fp.dynarray.pushBack(*both, fileC));
	assert(doir.api.query.markChanged(engine, fileC));
	assert(doir.api.query.markChanged(engine, rootD.block));
	assert(*doir.api.query.query!ReadImported(engine, ReadImported.Key([rootD.block, level])) == (doir.api.components.Flags.Export | doir.api.components.Flags.Packed));
	assert(diagnose.count(manager) == 1);
	assert(fp.string.slice(manager.diagnostics[0].message) == "WF-Unique: two imports make the same name visible");
	assert(findImported(engine, rootD.block, level, s("u")) == invalidEntity); // I-Export

	// A level without an evaluator cannot import, and the failed import makes nothing visible.
	immutable bare = doir.testing.addEntity(store);
	assert(doir.api.query.markChanged(engine, bare));
	assert(*doir.api.query.query!ReadImported(engine, ReadImported.Key([rootA.block, bare])) == 0);
	assert(diagnose.count(manager) == 2);
	assert(fp.string.slice(manager.diagnostics[1].message) == "I-Import: the importing level cannot evaluate files");
	diagnose.clear(manager);

	// Two files that import each other are a cycle.
	doir.api.query.beginRevision(engine);
	immutable bImportsA = fp.dynarray.pushBack(doir.testing.addComponent!Imports(store, fileB).related, fileA);
	immutable aImportsB = fp.dynarray.pushBack(doir.testing.addComponent!Imports(store, fileA).related, fileB);
	assert(bImportsA && aImportsB);
	assert(doir.api.query.markChanged(engine, fileA));
	assert(doir.api.query.markChanged(engine, fileB));
	assert(doir.api.query.query!Import(engine, Import.Key([fileA, level])).root == invalidEntity);
	assert(diagnose.count(manager) == 1);
	enum prefix = "Q-Cycle: a query needs its own answer: Import -> Import -> Import";
	assert(fp.string.slice(manager.diagnostics[0].message) == prefix);
}
