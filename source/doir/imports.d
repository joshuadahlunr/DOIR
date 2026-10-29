/// Imports as finished files (`I-Import`): an import is a query keyed by the file and the importing level, whose value is the root of the file evaluated to completion and frozen, as `freezeLevel` freezes a level. The importer reads its entities by entity alone, its effects never enter the importer's logs, and two levels that import one file each get their own copy of its entities (`L-Tower`).
///
/// The level supplies the semantics: its `LevelEvaluator` builds a file's entities through `createEntity` and `produce`, so the copy belongs to the import query, and runs its comptime. Two files that import each other are a cycle (`Q-Cycle`), as is an import whose path depends on the lookup it would answer. Editing an imported file re-runs its import, and early cutoff stops at importers whose reads of it are unchanged.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.query;
/// static import doir.components.ast;
/// static import doir.components.levels;
/// static EntityId empty(ref doir.query.QueryEngine engine, EntityId file, EntityId level) @nogc nothrow {
/// 	immutable root = doir.query.createEntity(engine, file);
/// 	cast(void) doir.query.produce!(doir.components.ast.Block)(engine, root);
/// 	return root;
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.query.create(store);
/// scope(exit) doir.query.free(engine);
/// immutable file = ecrs.context.addEntity(store), level = ecrs.context.addEntity(store);
/// ecrs.context.addComponent!(doir.components.levels.LevelEvaluator)(store, level).evaluate = &empty;
/// immutable root = doir.query.query!Import(engine, Import.Key([file, level])).root;
/// assert(ecrs.context.hasComponent!(doir.components.ast.Block)(store, root));
/// ---
module doir.imports;

static import fp.dynarray;

static import diagnose;
static import ecrs.context;
static import ecrs.relation;

static import doir.strings;
static import doir.builders;
static import doir.components.ast;
static import doir.components.effects;
static import doir.components.levels;
static import doir.components.source;
static import doir.effects;
static import doir.query;

public import ecrs.registry : EntityId, invalidEntity;

@nogc nothrow:


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
	/// static import doir.query;
	/// auto store = ecrs.context.create();
	/// scope(exit) ecrs.context.free(store);
	/// auto engine = doir.query.create(store);
	/// scope(exit) doir.query.free(engine);
	/// immutable file = ecrs.context.addEntity(store), level = ecrs.context.addEntity(store);
	/// assert(doir.query.query!Import(engine, Import.Key([file, level])).root == invalidEntity);
	/// ---
	static Value compute(ref doir.query.QueryEngine engine, Key key) @nogc nothrow {
		if (!doir.query.read(engine, key.file) || !doir.query.read(engine, key.level)) return Value([invalidEntity]);
		auto evaluator = ecrs.context.findComponent!(doir.components.levels.LevelEvaluator)(*engine.store, key.level);
		if (evaluator is null) {
			cast(void) doir.query.report(engine, key.file, diagnose.Kind.error, "I-Import: the importing level cannot evaluate files", "import the file from a level that declares an evaluator, or give this level one"); // a refusal fails this query
			return Value([invalidEntity]);
		}
		immutable root = evaluator.evaluate(engine, key.file, key.level);
		if (root == invalidEntity || !doir.effects.freezeLevel(engine, root)) return Value([invalidEntity]);
		return Value([root]);
	}
}

/// The exported declaration named `name` that one of `block`'s imports into `level` makes visible, or `invalidEntity` if none does (`I-Import`, `I-Export`). A lookup that misses `block`'s own declarations calls it, demanding the block's imports as a forward reference demands a declaration (`R-Order`), so the import is visible on every line. Two imports that make one name visible as different entities are a collision, reported (`WF-Unique`); the first is returned. An import that is a cycle (`Q-Cycle`) makes nothing visible.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.query;
/// static import doir.strings;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.query.create(store);
/// scope(exit) doir.query.free(engine);
/// immutable block = ecrs.context.addEntity(store), level = ecrs.context.addEntity(store);
/// assert(findImported(engine, block, level, doir.strings.StringId(0)) == invalidEntity);
/// ---
EntityId findImported(ref doir.query.QueryEngine engine, EntityId block, EntityId level, doir.strings.StringId name) {
	if (!doir.query.read(engine, block)) return invalidEntity;
	auto imports = ecrs.context.findComponent!(doir.components.source.Imports)(*engine.store, block);
	if (imports is null) return invalidEntity;
	EntityId found = invalidEntity;
	immutable n = fp.dynarray.length(imports.related);
	foreach (i; 0 .. n) {
		immutable file = ecrs.context.getComponent!(doir.components.source.Imports)(*engine.store, block).related[i];
		auto root = doir.query.query!Import(engine, Import.Key([file, level]));
		if (root is null || root.root == invalidEntity) continue;
		foreach (e; fp.dynarray.slice(ecrs.context.getComponent!(doir.components.ast.Block)(*engine.store, root.root).related)) {
			auto declared = ecrs.context.findComponent!(doir.components.ast.Name)(*engine.store, e);
			if (declared is null || declared.value != name
				|| !(doir.effects.flags(engine, e) & doir.components.ast.Flags.Export))
				continue;
			if (found == invalidEntity) found = e;
			else if (found != e) {
				immutable doir.query.Related[1] first = [doir.query.Related([found], "first made visible here")];
				cast(void) doir.query.report(engine, e, diagnose.Kind.error, "WF-Unique: two imports make the same name visible", "rename or stop exporting one of the two, or drop one of the imports", first[]); // a refusal fails the running queries or sets engine.refused
			}
		}
	}
	return found;
}


version(unittest) {
	static import fp.string;
	static import doir.engine.query;

	static import doir.testing;
	static import doir.positions;

	private __gshared doir.strings.Strings strings;
	private __gshared EntityId fileA, fileB, fileC;
	private __gshared uint modifier = doir.components.ast.Flags.ReadOnly;
	private __gshared int evaluations, readerRuns;

	// B and C hold `export t : type = {} ; _ : _ = std.pointers.read_only(t)`; C adds an unexported `u`.
	private EntityId evaluate(ref doir.query.QueryEngine engine, EntityId file, EntityId level) {
		++evaluations;
		assert(doir.query.read(engine, file));
		immutable root = doir.query.createEntity(engine, file);
		auto block = doir.query.produce!(doir.components.ast.Block)(engine, root);
		assert(block !is null);
		if (auto imports = ecrs.context.findComponent!(doir.components.source.Imports)(*engine.store, file))
			foreach (other; fp.dynarray.slice(imports.related)) {
				auto imported = doir.query.query!Import(engine, Import.Key([other, level]));
				if (imported is null || imported.root == invalidEntity) return invalidEntity;
			}
		if (file != fileB && file != fileC) return root;

		immutable t = doir.query.createEntity(engine, file);
		doir.query.produce!(doir.components.ast.Name)(engine, t).value = doir.strings.intern(strings, "t");
		doir.query.produce!(doir.components.ast.Parent)(engine, t).parent = root;
		doir.query.produce!(doir.components.ast.Flags)(engine, t).flags = doir.components.ast.Flags.Export;
		immutable pushed = fp.dynarray.pushBack(block.related, t);
		assert(pushed);
		if (file == fileC) {
			immutable u = doir.query.createEntity(engine, file);
			doir.query.produce!(doir.components.ast.Name)(engine, u).value = doir.strings.intern(strings, "u");
			doir.query.produce!(doir.components.ast.Parent)(engine, u).parent = root;
			immutable pushedU = fp.dynarray.pushBack(block.related, u);
			assert(pushedU);
		}
		immutable pt = doir.positions.between(engine.positions, doir.positions.root, doir.positions.none, doir.positions.none);
		immutable pm = doir.positions.between(engine.positions, doir.positions.root, pt, doir.positions.none);
		assert(doir.effects.applyFlags(engine, t, pm, modifier));
		// Inside B, a read on t's own line still sees it unmodified.
		assert(doir.effects.flagsAt(engine, t, pt).get == doir.components.ast.Flags.Export);
		return root;
	}

	// A declaration of the importing file, on a line above its import, reading `t`'s flags.
	private struct ReadImported {
		struct Key {
			mixin ecrs.relation.Relates!("block", "level");
		}
		alias Value = uint;
		static uint compute(ref doir.query.QueryEngine engine, Key key) @nogc nothrow {
			++readerRuns;
			immutable t = findImported(engine, key.block, key.level, doir.strings.intern(strings, "t"));
			return t == invalidEntity ? 0 : doir.effects.flags(engine, t);
		}
	}
}

unittest { // an imported file arrives finished, once per level, and its edits stop at unchanged importers
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	diagnose.Manager manager;
	scope(exit) diagnose.free(manager);
	auto engine = doir.query.create(store);
	scope(exit) doir.query.free(engine);
	engine.diagnostics = &manager;
	scope(exit) doir.strings.free(strings);

	fileA = doir.testing.addEntity(store);
	fileB = doir.testing.addEntity(store);
	doir.testing.addComponent!(doir.components.source.SourceFile)(store, fileA).path = doir.strings.intern(strings, "a.doir");
	doir.testing.addComponent!(doir.components.source.SourceFile)(store, fileB).path = doir.strings.intern(strings, "b.doir");
	immutable level = doir.testing.addEntity(store), other = doir.testing.addEntity(store);
	doir.testing.addComponent!(doir.components.levels.LevelEvaluator)(store, level).evaluate = &evaluate;
	doir.testing.addComponent!(doir.components.levels.LevelEvaluator)(store, other).evaluate = &evaluate;
	auto rootA = doir.builders.createRoot(store);
	immutable pushed = fp.dynarray.pushBack(doir.testing.addComponent!(doir.components.source.Imports)(store, rootA.block).related, fileB);
	assert(pushed);
	immutable EntityId[5] inputs = [fileA, fileB, level, other, rootA.block];
	foreach (e; inputs) assert(doir.query.markChanged(engine, e));

	// A read of the imported type, whatever line it is on, sees every modifier the imported file applied.
	evaluations = readerRuns = 0;
	assert(*doir.query.query!ReadImported(engine, ReadImported.Key([rootA.block, level])) == (doir.components.ast.Flags.Export | doir.components.ast.Flags.ReadOnly));
	assert(evaluations == 1);
	assert(!ecrs.context.hasComponent!(doir.components.effects.FlagsLog)(store, rootA.block));

	// Another level importing the same file gets its own copy.
	immutable here = doir.query.query!Import(engine, Import.Key([fileB, level])).root;
	immutable there = doir.query.query!Import(engine, Import.Key([fileB, other])).root;
	assert(here != there && evaluations == 2);

	// Editing the file without changing what it makes re-runs the import, and early cutoff stops at the importer.
	doir.query.beginRevision(engine);
	assert(doir.query.markChanged(engine, fileB));
	assert(*doir.query.query!ReadImported(engine, ReadImported.Key([rootA.block, level])) == (doir.components.ast.Flags.Export | doir.components.ast.Flags.ReadOnly));
	assert(evaluations == 3 && readerRuns == 1);
	assert(doir.query.query!Import(engine, Import.Key([fileB, level])).root == here);

	// An edit that changes the modifier reaches the importer.
	doir.query.beginRevision(engine);
	modifier = doir.components.ast.Flags.Packed;
	assert(doir.query.markChanged(engine, fileB));
	assert(*doir.query.query!ReadImported(engine, ReadImported.Key([rootA.block, level])) == (doir.components.ast.Flags.Export | doir.components.ast.Flags.Packed));
	assert(readerRuns == 2);
	modifier = doir.components.ast.Flags.ReadOnly;

	// Two imports that make `t` visible as different entities collide (WF-Unique); the first, B's, still Packed from its last edit, wins.
	assert(diagnose.count(manager) == 0);
	doir.query.beginRevision(engine);
	fileC = doir.testing.addEntity(store);
	doir.testing.addComponent!(doir.components.source.SourceFile)(store, fileC).path = doir.strings.intern(strings, "c.doir");
	auto rootD = doir.builders.createRoot(store);
	auto both = &doir.testing.addComponent!(doir.components.source.Imports)(store, rootD.block).related;
	assert(fp.dynarray.pushBack(*both, fileB) && fp.dynarray.pushBack(*both, fileC));
	assert(doir.query.markChanged(engine, fileC));
	assert(doir.query.markChanged(engine, rootD.block));
	assert(*doir.query.query!ReadImported(engine, ReadImported.Key([rootD.block, level])) == (doir.components.ast.Flags.Export | doir.components.ast.Flags.Packed));
	assert(diagnose.count(manager) == 1);
	assert(fp.string.slice(manager.diagnostics[0].message) == "WF-Unique: two imports make the same name visible");
	assert(fp.string.slice(manager.diagnostics[0].additionalNote) == "rename or stop exporting one of the two, or drop one of the imports"); // the evaluated entities have no location
	assert(findImported(engine, rootD.block, level, doir.strings.intern(strings, "u")) == invalidEntity); // I-Export

	// A level without an evaluator cannot import, and the failed import makes nothing visible.
	immutable bare = doir.testing.addEntity(store);
	assert(doir.query.markChanged(engine, bare));
	assert(*doir.query.query!ReadImported(engine, ReadImported.Key([rootA.block, bare])) == 0);
	assert(diagnose.count(manager) == 2);
	assert(fp.string.slice(manager.diagnostics[1].message) == "I-Import: the importing level cannot evaluate files");
	assert(fp.string.slice(manager.diagnostics[1].additionalNote) == "import the file from a level that declares an evaluator, or give this level one");
	diagnose.clear(manager);

	// Two files that import each other are a cycle.
	doir.query.beginRevision(engine);
	immutable bImportsA = fp.dynarray.pushBack(doir.testing.addComponent!(doir.components.source.Imports)(store, fileB).related, fileA);
	immutable aImportsB = fp.dynarray.pushBack(doir.testing.addComponent!(doir.components.source.Imports)(store, fileA).related, fileB);
	assert(bImportsA && aImportsB);
	assert(doir.query.markChanged(engine, fileA));
	assert(doir.query.markChanged(engine, fileB));
	assert(doir.query.query!Import(engine, Import.Key([fileA, level])).root == invalidEntity);
	assert(diagnose.count(manager) == 1);
	enum prefix = "Q-Cycle: a query needs its own answer: Import -> Import -> Import";
	assert(fp.string.slice(manager.diagnostics[0].message) == prefix);
	assert(fp.string.slice(manager.diagnostics[0].additionalNote) == doir.engine.query.cycleHint);
}
