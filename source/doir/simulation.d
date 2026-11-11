/// Seeded simulation of an editing session, for tests: a walk of random edits to one file, some committed under an allocator that refuses, with the store renumbered between them, where after every step the engine that took the edits must report what a new engine given the same text reports.
///
/// A run is decided by its seed alone, so a failure names the seed and step to replay: `bin/doir-simulate --seed <seed> --seeds 1 --trace` (`tests/simulate.d`).
module doir.simulation;

version(unittest):

static import diagnose;
static import ecrs.context;
static import ecrs.registry;
static import fp.algorithms;
static import fp.dynarray;
static import fp.io;
static import fp.pointer;
static import fp.rope;
static import fp.string;
static import fp.testing;

static import doir.checks;
static import doir.printer;
static import doir.query;
static import doir.source;
static import doir.strings;

@nogc nothrow:

private alias EntityId = ecrs.registry.EntityId;


// --- comparing ---------------------------------------------------------------

// Whether `d` and `other` agree in kind, message, location, closing note and context, and each annotation's position and message.
private bool sameDiagnostic(ref const diagnose.Diagnostic d, ref const diagnose.Diagnostic other) @trusted {
	if (d.kind != other.kind || fp.string.slice(d.message) != fp.string.slice(other.message)) return false;
	if (d.location.start != other.location.start || d.location.end != other.location.end) return false;
	if (fp.string.slice(d.note) != fp.string.slice(other.note) || fp.string.slice(d.contextMessage) != fp.string.slice(other.contextMessage)) return false;
	if (fp.dynarray.length(d.annotations) != fp.dynarray.length(other.annotations)) return false;
	foreach (j; 0 .. fp.dynarray.length(d.annotations))
		if (d.annotations[j].position != other.annotations[j].position || fp.string.slice(d.annotations[j].message) != fp.string.slice(other.annotations[j].message)) return false;
	return true;
}

/// Whether `a` and `b` hold the same diagnostics in the same order: kind, message, location, closing note and context, and each annotation's position and message.
///
/// Examples:
/// ---
/// static import diagnose;
/// diagnose.Manager a, b;
/// assert(sameDiagnostics(a, b));
/// ---
package(doir) bool sameDiagnostics(ref const diagnose.Manager a, ref const diagnose.Manager b) @trusted {
	if (fp.dynarray.length(a.diagnostics) != fp.dynarray.length(b.diagnostics)) return false;
	foreach (i; 0 .. fp.dynarray.length(a.diagnostics))
		if (!sameDiagnostic(a.diagnostics[i], b.diagnostics[i])) return false;
	return true;
}


// Prints one diagnostic of a failed comparison: its location, message, closing note and annotations.
private void printDiagnostic(const(char)[] side, size_t i, ref const diagnose.Diagnostic d) @trusted {
	cast(void) fp.io.print(fp.io.Console.error, "  ", side, " #", i, " at ", d.location.start.line, ":", d.location.start.column, " to ", d.location.end.line, ":", d.location.end.column, ": ", fp.string.slice(d.message), "\n");
	if (d.note !is null) cast(void) fp.io.print(fp.io.Console.error, "    note: ", fp.string.slice(d.note), "\n");
	foreach (ref a; fp.dynarray.slice(d.annotations)) cast(void) fp.io.print(fp.io.Console.error, "    at ", a.position.line, ":", a.position.column, ": ", fp.string.slice(a.message), "\n");
}

// Prints, for a failed comparison, how many diagnostics each side holds and the first that differs, as each side has it.
private void printDifference(ref const diagnose.Manager edited, ref const diagnose.Manager fresh) @trusted {
	immutable a = fp.dynarray.length(edited.diagnostics), b = fp.dynarray.length(fresh.diagnostics);
	cast(void) fp.io.print(fp.io.Console.error, "doir.simulation: the edited engine reports ", a, " diagnostics, a new one ", b, "\n");
	foreach (i; 0 .. a > b ? a : b) {
		if (i < a && i < b && sameDiagnostic(edited.diagnostics[i], fresh.diagnostics[i])) continue;
		if (i < a) printDiagnostic("edited", i, edited.diagnostics[i]);
		if (i < b) printDiagnostic("new   ", i, fresh.diagnostics[i]);
		return;
	}
}


// --- one engine --------------------------------------------------------------

// An engine with its store, strings and diagnostics, checking one file.
// It is opened in place, since the engine points at the store beside it.
private struct Side {
	ecrs.context.Context store;
	doir.query.QueryEngine engine;
	doir.strings.Strings strings;
	diagnose.Manager manager;
	EntityId file;
}

private void open(ref Side side) {
	side.store = ecrs.context.create();
	side.engine = doir.query.create(side.store);
	side.engine.strings = &side.strings;
	side.engine.diagnostics = &side.manager;
	side.file = doir.source.addFile(side.engine, side.strings, "simulated.doir");
	assert(side.file != doir.source.invalidEntity);
}

private void close(ref Side side) {
	diagnose.free(side.manager);
	doir.query.free(side.engine);
	doir.strings.free(side.strings);
	ecrs.context.free(side.store);
}

// Reports `side`'s syntax errors and checks afresh into its manager.
// False if an allocation was refused, which loses some.
private bool report(ref Side side) {
	diagnose.clear(side.manager);
	return doir.source.reportSyntaxErrors(side.engine, side.file, side.manager) && doir.checks.check(side.engine, side.file);
}


// --- a run -------------------------------------------------------------------

/// What `simulate` did, so a test can tell its walk reached what it means to.
struct Outcome {
	size_t steps; /// Edits committed.
	size_t refusedCommits; /// Commits an allocation refused, which must leave the file as it was.
	size_t refusedChecks; /// Checks an allocation refused, which must not spoil the next.
	size_t renumberings; /// Renumberings and compactions of the store between edits.
}

private struct Run {
	Side edited;
	char* text; // what the file should hold
	char* before; // with `trace`, what it held before this step's edit, for a failure to print
	fp.algorithms.Random random;
	ulong seed;
	size_t step;
	bool trace;
	Outcome outcome;
}

private noreturn fail(ref Run run, const(char)[] what) {
	if (run.trace && run.before !is null) cast(void) fp.io.print(fp.io.Console.error, "the text before this step:\n", fp.string.slice(run.before), "\n");
	cast(void) fp.io.print(fp.io.Console.error, "doir.simulation: seed ", run.seed, ", step ", run.step, ": ", what, "; replay with `bin/doir-simulate --seed ", run.seed, " --seeds 1 --trace`, adding the file if it walked one\n");
	assert(false, "doir.simulation: the edited engine and a new one disagree");
}

// The edited engine holds `run.text` and reports what a new engine given that text does: syntax errors, checks and the printed tree.
private void compare(ref Run run) {
	if (!fp.rope.equal(doir.source.textOf(run.edited.engine, run.edited.file), fp.string.slice(run.text))) fail(run, "the committed text is not the edited text");
	if (!report(run.edited)) fail(run, "reporting failed though nothing refused it");

	Side fresh;
	open(fresh);
	scope(exit) close(fresh);
	if (doir.source.commit(fresh.engine, fresh.strings, fresh.file, fp.string.slice(run.text)) == fp.pointer.allocationRefused || !report(fresh)) fail(run, "a new engine failed though nothing refused it");

	if (doir.source.syntaxErrorCount(run.edited.engine, run.edited.file) != doir.source.syntaxErrorCount(fresh.engine, fresh.file)) fail(run, "the syntax errors differ in number");
	if (!sameDiagnostics(run.edited.manager, fresh.manager)) {
		printDifference(run.edited.manager, fresh.manager);
		fail(run, "the diagnostics differ");
	}
	auto printedEdited = doir.printer.print(run.edited.store, run.edited.strings, doir.source.rootOf(run.edited.engine, run.edited.file));
	auto printedFresh = doir.printer.print(fresh.store, fresh.strings, doir.source.rootOf(fresh.engine, fresh.file));
	if (printedEdited.isNull || printedFresh.isNull) fail(run, "printing failed though nothing refused it");
	scope(exit) { fp.string.free(printedEdited.get); fp.string.free(printedFresh.get); }
	if (fp.string.slice(printedEdited.get) != fp.string.slice(printedFresh.get)) fail(run, "the printed trees differ");
}

// What an edit types in: text that keeps the file well formed, declarations the checks have something to say about, and text that unbalances a block.
private static immutable string[] typed = [
	"", "", "x", "\n", " ", "1", "v", "q : std.u8 = 1\n", "//c\n", "_ : T = 1\n",
	"\tw : std.u8 = std.copy(std.u8, v)\n", "\t_ : _ = std.return(std.nothing)\n", "\t_ : _ = std.return(v)\n",
	"n : namespace = {\n\ta : T = 1\n}\n", "g : () -> void = {\n\tv : std.u8 = 1\n\t_ : _ = std.return(std.nothing)\n}\n", "f : (p: T) -> T\n",
];
private static immutable string[] breaking = ["}", "{", "/*", "*/", "\"", "\"\"\"", "= {\n"];

private struct Edit {
	size_t start, end;
	const(char)[] replacement;
}

// A random edit of `run.text`: mostly a few bytes typed or deleted, sometimes a span removed, a line's start chosen so a declaration lands whole, or the text unbalanced.
private Edit pickEdit(ref Run run) @trusted {
	immutable size = fp.string.length(run.text);
	Edit edit;
	edit.start = fp.algorithms.randomBelow(run.random, size + 1);
	if (fp.algorithms.randomChance(run.random, 1, 3)) edit.start = fp.string.lineStart(fp.string.slice(run.text), fp.string.lineOf(fp.string.slice(run.text), edit.start));
	immutable span = fp.algorithms.randomBelow(run.random, fp.algorithms.randomChance(run.random, 1, 10) ? 200 : 6);
	edit.end = edit.start + span > size ? size : edit.start + span;
	edit.replacement = fp.algorithms.randomChance(run.random, 1, 12) ? breaking[fp.algorithms.randomBelow(run.random, breaking.length)] : typed[fp.algorithms.randomBelow(run.random, typed.length)];
	return edit;
}

// Commits `edit`, first, one time in four, under an allocator that refuses partway: a refused commit must leave the file reporting what it did.
private void commit(ref Run run, Edit edit) {
	if (run.trace) {
		cast(void) fp.io.print(fp.io.Console.error, "step ", run.step, ": replace bytes ", edit.start, " to ", edit.end, " with \"");
		foreach (c; edit.replacement) cast(void) fp.io.print(fp.io.Console.error, c == '\n' ? "\\n" : c == '\t' ? "\\t" : c == '"' ? "\\\"" : (&c)[0 .. 1]);
		cast(void) fp.io.print(fp.io.Console.error, "\"\n");
	}
	if (fp.algorithms.randomChance(run.random, 1, 4)) {
		auto previous = fp.testing.limitAllocations(fp.algorithms.randomBelow(run.random, 60));
		immutable result = doir.source.commitEdit(run.edited.engine, run.edited.strings, run.edited.file, edit.start, edit.end, edit.replacement);
		fp.testing.restoreAllocator(previous);
		if (result != fp.pointer.allocationRefused) return;
		++run.outcome.refusedCommits;
		if (run.trace) cast(void) fp.io.print(fp.io.Console.error, "  the commit was refused\n");
		compare(run);
	}
	if (doir.source.commitEdit(run.edited.engine, run.edited.strings, run.edited.file, edit.start, edit.end, edit.replacement) == fp.pointer.allocationRefused) fail(run, "a commit failed though nothing refused it");
}

// Renumbers the edited store by a random permutation that keeps entity 0, or compacts it (`E-Remap`).
// The file's id is the one this test holds, so it follows.
private void renumber(ref Run run) @trusted {
	++run.outcome.renumberings;
	immutable compacting = fp.algorithms.randomChance(run.random, 1, 2);
	if (run.trace) cast(void) fp.io.print(fp.io.Console.error, compacting ? "  compacted\n" : "  renumbered\n");
	if (compacting) {
		// Compacting keeps the live entities in order, so the file's new id is how many live ones precede it.
		EntityId before = 0;
		foreach (e; ecrs.context.entities(run.edited.store)) before += e < run.edited.file;
		if (!doir.query.compact(run.edited.engine)) fail(run, "compacting failed though nothing refused it");
		run.edited.file = before;
		return;
	}
	immutable n = fp.dynarray.length(run.edited.store.indexTable);
	size_t* order = null;
	scope(exit) fp.dynarray.free(order);
	if (fp.dynarray.growToSize(order, n ? n : 1) is null) fail(run, "the test's own allocation was refused");
	foreach (i; 0 .. n) order[i] = i;
	foreach_reverse (i; 2 .. n) {
		immutable j = 1 + fp.algorithms.randomBelow(run.random, i);
		immutable moved = order[i];
		order[i] = order[j];
		order[j] = moved;
	}
	if (!doir.query.renumber(run.edited.engine, order[0 .. n])) fail(run, "renumbering failed though nothing refused it");
	run.edited.file = cast(EntityId) fp.algorithms.find(order[0 .. n], cast(size_t) run.edited.file);
}

// Checks the edited engine under an allocator that refuses partway: whatever that loses, the next check, in a new revision, must report everything.
private void checkRationed(ref Run run) {
	diagnose.clear(run.edited.manager);
	auto previous = fp.testing.limitAllocations(fp.algorithms.randomBelow(run.random, 40));
	immutable passed = report(run.edited);
	fp.testing.restoreAllocator(previous);
	if (!passed) {
		++run.outcome.refusedChecks;
		if (run.trace) cast(void) fp.io.print(fp.io.Console.error, "  a check was refused\n");
		run.edited.engine.refused = false;
	}
	// A revision reports its diagnostics once, so `compare` checks again in a new one.
	doir.query.beginRevision(run.edited.engine);
}

/// Commits `program` to a new engine, then makes `steps` random edits drawn from `seed`, comparing the engine with a new one after each; `trace` prints each edit to standard error.
/// It aborts, naming the seed and step, on the first difference.
///
/// Examples:
/// ---
/// assert(simulate(1, 3, "x : std.u8 = 1\n").steps == 3);
/// ---
Outcome simulate(ulong seed, size_t steps, const(char)[] program, bool trace = false) {
	Run run;
	run.random = fp.algorithms.createRandom(seed);
	run.seed = seed;
	run.trace = trace;
	open(run.edited);
	scope(exit) close(run.edited);
	run.text = fp.string.clone(program).get(null);
	scope(exit) {
		fp.string.free(run.text);
		fp.string.free(run.before);
	}
	if (program.length && run.text is null) fail(run, "the test's own allocation was refused");
	if (doir.source.commit(run.edited.engine, run.edited.strings, run.edited.file, program) == fp.pointer.allocationRefused) fail(run, "the first commit failed though nothing refused it");
	compare(run);

	foreach (step; 0 .. steps) {
		run.step = step;
		const edit = pickEdit(run);
		if (run.trace) {
			fp.string.free(run.before);
			run.before = fp.string.clone(fp.string.slice(run.text)).get(null);
		}
		commit(run, edit);
		if (!fp.string.replaceRange(run.text, edit.start, edit.end - edit.start, edit.replacement) && fp.string.length(run.text) != 0) fail(run, "the test's own allocation was refused");
		++run.outcome.steps;
		if (fp.algorithms.randomChance(run.random, 1, 6)) renumber(run);
		if (fp.algorithms.randomChance(run.random, 1, 5)) checkRationed(run);
		compare(run);
	}
	return run.outcome;
}

/// A small program for `simulate` to edit, drawn from `seed`: namespaces of functions whose declarations read names declared before and after them, with and without the terminator a body needs, as a new fp string the caller frees.
///
/// Examples:
/// ---
/// static import fp.string;
/// char* program = generate(1);
/// scope(exit) fp.string.free(program);
/// assert(fp.string.contains(program, "namespace", 0));
/// ---
char* generate(ulong seed) {
	auto random = fp.algorithms.createRandom(seed);
	char* text = null;
	bool ok = true;
	foreach (n; 0 .. 2 + fp.algorithms.randomBelow(random, 4)) {
		ok = ok && fp.string.append(text, "n", n, " : namespace = {\n");
		foreach (f; 0 .. 1 + fp.algorithms.randomBelow(random, 3)) {
			ok = ok && fp.string.append(text, "\tf", f, " : () -> void = {\n");
			immutable count = 1 + fp.algorithms.randomBelow(random, 4);
			foreach (d; 0 .. count) {
				if (fp.algorithms.randomChance(random, 1, 2)) ok = ok && fp.string.append(text, "\t\tv", d, " : std.u8 = ", d, "\n");
				else ok = ok && fp.string.append(text, "\t\tv", d, " : std.u8 = std.copy(std.u8, v", fp.algorithms.randomBelow(random, count), ")\n");
			}
			if (!fp.algorithms.randomChance(random, 1, 4)) ok = ok && fp.string.concatenate(text, "\t\t_ : _ = std.return(std.nothing)\n");
			ok = ok && fp.string.concatenate(text, "\t}\n");
		}
		ok = ok && fp.string.concatenate(text, "}\n");
	}
	assert(ok, "doir.simulation: the test's own allocation was refused");
	return text;
}

unittest { // every seed's walk over a generated program agrees with a new engine at each step, through refused commits and checks and renumberings
	Outcome total;
	foreach (seed; 1 .. 31) {
		char* program = generate(seed);
		scope(exit) fp.string.free(program);
		immutable outcome = simulate(seed, 100, fp.string.slice(program));
		total.steps += outcome.steps;
		total.refusedCommits += outcome.refusedCommits;
		total.refusedChecks += outcome.refusedChecks;
		total.renumberings += outcome.renumberings;
	}
	assert(total.steps == 30 * 100 && total.refusedCommits > 100 && total.refusedChecks > 50 && total.renumberings > 200);
	assert(simulate(1, 2, "").steps == 2);
}
