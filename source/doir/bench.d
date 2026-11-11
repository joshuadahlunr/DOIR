/// `doir --bench`: times one-line edits to a file and the checks after them, so a change to the commit or the checks shows up in the numbers (`roadmap.md` Phases 2-3).
///
/// Examples:
/// ---
/// assert(bench("no/such/file.doir", 2) == 1);
/// ---
module doir.bench;

static import std.algorithm.sorting;

static import fp.io;
static import fp.pointer;
static import fp.string;

static import bc.thread;
static import bc.threadpool;
static import ecrs.context;
static import ecrs.registry;

static import doir.checks;
static import doir.query;
static import doir.source;
static import doir.strings;

@nogc nothrow:


// How far into a line `middleDeclaration` looks for the ` : ` that makes it a declaration.
private enum size_t declarationColonWithin = 64;

// The byte offset of a line near the middle of `source` that starts a declaration, to insert another before.
private size_t middleDeclaration(const(char)[] source) {
	for (size_t i = source.length / 2 > 0 ? source.length / 2 : 1; i < source.length; ++i) {
		if (source[i - 1] != '\n') continue;
		size_t j = i;
		while (j < source.length && (source[j] == ' ' || source[j] == '\t')) ++j;
		// The search stops a little past the limit, so a line without a colon costs no more than that.
		const window = source[j .. j + declarationColonWithin + 3 < source.length ? j + declarationColonWithin + 3 : $];
		if (j < source.length && (source[j] == '_' || (source[j] >= 'a' && source[j] <= 'z')) && fp.string.find(window, " : ") < declarationColonWithin) return i;
	}
	return source.length;
}

// The median and worst of some timings, in milliseconds.
private struct Summary {
	double median;
	double worst;
}

// Summarizes `times`, in microseconds, sorting them in place.
private Summary summarize(ulong[] times) {
	std.algorithm.sorting.sort(times);
	return Summary(times[$ / 2] / 1000.0, times[$ - 1] / 1000.0);
}

// The bytes each timed edit inserts, then removes.
private enum string benchLine = "bench_edit : T = 1\n";

// Times the checks of `file` for `bench`: a first run, a re-run with nothing changed, and re-runs after one-line edits at `at`, each into `times`, and prints them. 0, or 1 on refusal.
private int benchChecks(ref doir.query.QueryEngine engine, ref doir.strings.Strings strings, ecrs.registry.EntityId file, const(char)* path, size_t at, ulong[] times) {
	engine.strings = &strings;
	immutable checkStart = bc.thread.monotonicMicroseconds();
	if (!doir.checks.check(engine, file)) return 1;
	immutable firstCheck = bc.thread.monotonicMicroseconds() - checkStart;
	immutable edgesStart = bc.thread.monotonicMicroseconds();
	if (!doir.query.buildDependents(engine)) return 1;
	immutable edges = bc.thread.monotonicMicroseconds() - edgesStart;
	doir.query.beginRevision(engine);
	immutable recheckStart = bc.thread.monotonicMicroseconds();
	if (!doir.checks.check(engine, file)) return 1;
	immutable recheck = bc.thread.monotonicMicroseconds() - recheckStart;
	immutable checkRounds = times.length < 20 ? times.length : 20;
	foreach (i; 0 .. checkRounds) {
		immutable result = i % 2 ? doir.source.commitEdit(engine, strings, file, at, at + benchLine.length, "") : doir.source.commitEdit(engine, strings, file, at, at, benchLine);
		if (result == fp.pointer.allocationRefused) return 1;
		immutable t = bc.thread.monotonicMicroseconds();
		if (!doir.checks.check(engine, file)) return 1;
		times[i] = bc.thread.monotonicMicroseconds() - t;
	}
	immutable checks = summarize(times[0 .. checkRounds]);
	auto checked = fp.string.format("%s: checks first %.3f ms, then edges built in %.3f ms; unchanged %.3f ms; after an edit: median %.3f ms, worst %.3f ms\n", path, firstCheck / 1000.0, edges / 1000.0, recheck / 1000.0, checks.median, checks.worst);
	if (checked.isNull) return 1;
	scope(exit) fp.string.free(checked.get);
	return fp.io.writeAll(fp.io.Console.output, fp.string.slice(checked.get)) ? 0 : 1;
}

/// Times `rounds` one-line edits to the file at `path`, committed whole and as edits, and the checks before and after them, printing the median and worst of each (`roadmap.md` Phases 2-3); `doir --bench` runs it.
/// Times are wall-clock, since the commit's workers make processor time overcount.
///
/// Returns 0, or 1 if the file cannot be read or an allocation was refused.
///
/// Examples:
/// ---
/// assert(bench("no/such/file.doir", 2) == 1);
/// ---
int bench(const(char)* path, size_t rounds) {
	auto read = fp.io.readFile(fp.string.slice(path));
	if (read.isNull) return 1;
	auto text = read.get;
	scope(exit) fp.string.free(text);
	auto original = fp.string.slice(text);
	immutable at = middleDeclaration(original);
	auto edited = fp.string.joined(original[0 .. at], benchLine, original[at .. $]).get(null);
	if (edited is null) return 1;
	scope(exit) fp.string.free(edited);

	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	auto engine = doir.query.create(store);
	scope(exit) doir.query.free(engine);
	// As the server does, the reverse edges are built once the first check has answered.
	engine.edgesMissing = true;
	// Without a pool the commit skims on this thread.
	engine.workers = bc.threadpool.create();
	scope(exit) bc.threadpool.free(engine.workers);
	doir.strings.Strings strings;
	scope(exit) doir.strings.free(strings);
	immutable file = doir.source.addFile(engine, strings, fp.string.slice(path));
	if (file == doir.source.invalidEntity) return 1;

	immutable start = bc.thread.monotonicMicroseconds();
	if (doir.source.commit(engine, strings, file, original) == fp.pointer.allocationRefused) return 1;
	immutable first = bc.thread.monotonicMicroseconds() - start;

	auto times = fp.pointer.allocate!ulong(rounds);
	if (times is null) return 1;
	scope(exit) fp.pointer.free(times);
	// Alternating makes every commit a one-line edit: an insertion, then its removal.
	foreach (i; 0 .. rounds) {
		immutable t = bc.thread.monotonicMicroseconds();
		if (doir.source.commit(engine, strings, file, fp.string.slice(i % 2 ? text : edited)) == fp.pointer.allocationRefused) return 1;
		times[i] = bc.thread.monotonicMicroseconds() - t;
	}
	immutable whole = summarize(times[0 .. rounds]);
	// The last whole commit left the original text; the edits start from it.
	foreach (i; 0 .. rounds) {
		immutable t = bc.thread.monotonicMicroseconds();
		immutable result = i % 2 ? doir.source.commitEdit(engine, strings, file, at, at + benchLine.length, "") : doir.source.commitEdit(engine, strings, file, at, at, benchLine);
		if (result == fp.pointer.allocationRefused) return 1;
		times[i] = bc.thread.monotonicMicroseconds() - t;
	}
	immutable edit = summarize(times[0 .. rounds]);
	auto commits = fp.string.format("%s: %zu bytes; first commit %.3f ms; one-line edit committed whole: median %.3f ms, worst %.3f ms; as an edit: median %.3f ms, worst %.3f ms\n",
		path, original.length, first / 1000.0, whole.median, whole.worst, edit.median, edit.worst);
	if (commits.isNull) return 1;
	scope(exit) fp.string.free(commits.get);
	if (!fp.io.writeAll(fp.io.Console.output, fp.string.slice(commits.get))) return 1;

	return benchChecks(engine, strings, file, path, at, times[0 .. rounds]);
}


unittest { // middleDeclaration finds a declaration past the middle, stays in bounds on a 1-byte text, and looks only a little way into each line
	assert(middleDeclaration("") == 0 && middleDeclaration("x") == 1);
	assert(middleDeclaration("a : T = 1\nb : T = 2\nc : T = 3\n") == 20);
	assert(middleDeclaration("a : T\nnot one\n") == 14);
	char[4096] long_;
	long_[] = 'a';
	long_[2048] = '\n';
	long_[$ - 4 .. $] = " : T";
	assert(middleDeclaration(long_[]) == long_.length); // the colon is too far into its line
	ulong[5] times = [5000, 1000, 3000, 2000, 4000];
	immutable summary = summarize(times[]);
	assert(summary.median == 3 && summary.worst == 5);
}
