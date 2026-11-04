/// The `doir` executable. For now it parses: each file is committed into the store (`doir.source`) and its diagnostics are printed through libdiagnose.
///
///     doir file.doir...             parse and report; exit 1 if any file has an error
///     doir --print file.doir...     parse, report, and print each file's program back as DOIR source (`doir.printer`)
///     doir --syntax file.doir...    print each file's first syntax error, as `tests/parse_diff.py` compares with `doir.peg`
///     doir --check [-g grammar] file.doir... [-p program.doir...]
///                                   check each file, printing `path: ok` or `path: FAIL` and its diagnostics, as `tests/doir_check.py` does (`tests/conformance.py --checker`)
///     doir --bench file.doir [n]    time n one-line edits to the file (200 by default), committed whole and as edits, and the checks before and after them (`roadmap.md` Phases 2-3)
module main;

static import core.stdc.stdio;
static import core.stdc.stdlib;
static import core.sys.posix.time;

static import fp.dynarray;
static import fp.file;
static import fp.pointer;
static import fp.string;

static import bc.threadpool;
static import diagnose;
static import ecrs.context;

static import doir.checks;
static import doir.strings;
static import doir.printer;
static import doir.query;
static import doir.source;
static import doir.syntax.parser;

@nogc nothrow:

// Prints `path: ok` or `path: line L:C: message` for the first syntax error, as `tests/parse_diff.py` reads.
private bool syntaxOnly(const(char)* path) {
	auto read = fp.file.readFile(fp.string.slice(path));
	if (read.isNull) return false;
	auto text = read.get;
	scope(exit) fp.string.free(text);
	auto source = fp.string.slice(text);
	doir.syntax.parser.Syntax syntax;
	scope(exit) doir.syntax.parser.free(syntax);
	if (!doir.syntax.parser.skim(source, syntax)) return false;
	foreach (error; fp.dynarray.slice(syntax.errors)) {
		if (error.kind != doir.syntax.parser.SyntaxError.Kind.syntax && error.kind != doir.syntax.parser.SyntaxError.Kind.nesting) continue;
		immutable at = diagnose.findPair(source, error.at);
		auto message = doir.syntax.parser.describe(syntax, source, error);
		if (message is null) return false;
		scope(exit) fp.string.free(message);
		core.stdc.stdio.printf("%s: line %d:%d: %s\n", path, cast(int) at.line, cast(int) at.column, message);
		return true;
	}
	core.stdc.stdio.printf("%s: ok\n", path);
	return true;
}

// Wall-clock time, since the commit's workers make CPU time overcount.
private double seconds() {
	core.sys.posix.time.timespec now;
	cast(void) core.sys.posix.time.clock_gettime(core.sys.posix.time.CLOCK_MONOTONIC, &now);
	return now.tv_sec + now.tv_nsec * 1e-9;
}

// The byte offset of a line near the middle of `source` that starts a declaration, to insert another before.
private size_t middleDeclaration(const(char)[] source) {
	for (size_t i = source.length / 2; i < source.length; ++i) {
		if (source[i - 1] != '\n') continue;
		size_t j = i;
		while (j < source.length && (source[j] == ' ' || source[j] == '\t')) ++j;
		if (j < source.length && (source[j] == '_' || (source[j] >= 'a' && source[j] <= 'z')) && fp.string.find(source[j .. $], " : ", 0) < 64) return i;
	}
	return source.length;
}

// The median and worst of `times`, sorted in place.
private void summarize(double* times, int rounds, out double median, out double worst) {
	foreach (i; 1 .. rounds)
		for (size_t j = i; j > 0 && times[j - 1] > times[j]; --j) {
			immutable swap = times[j];
			times[j] = times[j - 1];
			times[j - 1] = swap;
		}
	median = times[rounds / 2];
	worst = times[rounds - 1];
}

private int bench(const(char)* path, int rounds) {
	auto read = fp.file.readFile(fp.string.slice(path));
	if (read.isNull) return 1;
	auto text = read.get;
	scope(exit) fp.string.free(text);
	auto original = fp.string.slice(text);
	immutable at = middleDeclaration(original);
	static immutable line = "bench_edit : T = 1\n";
	auto edited = fp.string.createFromConcatenation(original[0 .. at], line, original[at .. $]);
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

	immutable start = seconds();
	if (doir.source.commit(engine, strings, file, original) == fp.pointer.allocationRefused) return 1;
	immutable first = seconds() - start;

	auto times = cast(double*) core.stdc.stdlib.malloc(rounds * double.sizeof);
	if (times is null) return 1;
	scope(exit) core.stdc.stdlib.free(times);
	// Alternating makes every commit a one-line edit: an insertion, then its removal.
	foreach (i; 0 .. rounds) {
		immutable t = seconds();
		if (doir.source.commit(engine, strings, file, fp.string.slice(i % 2 ? text : edited)) == fp.pointer.allocationRefused) return 1;
		times[i] = seconds() - t;
	}
	double wholeMedian, wholeWorst;
	summarize(times, rounds, wholeMedian, wholeWorst);
	// The last whole commit left the original text; the edits start from it.
	foreach (i; 0 .. rounds) {
		immutable t = seconds();
		immutable result = i % 2 ? doir.source.commitEdit(engine, strings, file, at, at + line.length, "") : doir.source.commitEdit(engine, strings, file, at, at, line);
		if (result == fp.pointer.allocationRefused) return 1;
		times[i] = seconds() - t;
	}
	double editMedian, editWorst;
	summarize(times, rounds, editMedian, editWorst);
	core.stdc.stdio.printf("%s: %d bytes; first commit %.3f ms; one-line edit committed whole: median %.3f ms, worst %.3f ms; as an edit: median %.3f ms, worst %.3f ms\n",
		path, cast(int) original.length, first * 1000, wholeMedian * 1000, wholeWorst * 1000, editMedian * 1000, editWorst * 1000);

	// The checks: a first run, a re-run with nothing changed, and re-runs after each one-line edit.
	engine.strings = &strings;
	immutable checkStart = seconds();
	if (!doir.checks.check(engine, file)) return 1;
	immutable firstCheck = seconds() - checkStart;
	immutable edgesStart = seconds();
	if (!doir.query.buildDependents(engine)) return 1;
	immutable edges = seconds() - edgesStart;
	doir.query.beginRevision(engine);
	immutable recheckStart = seconds();
	if (!doir.checks.check(engine, file)) return 1;
	immutable recheck = seconds() - recheckStart;
	immutable checkRounds = rounds < 20 ? rounds : 20;
	foreach (i; 0 .. checkRounds) {
		immutable result = i % 2 ? doir.source.commitEdit(engine, strings, file, at, at + line.length, "") : doir.source.commitEdit(engine, strings, file, at, at, line);
		if (result == fp.pointer.allocationRefused) return 1;
		immutable t = seconds();
		if (!doir.checks.check(engine, file)) return 1;
		times[i] = seconds() - t;
	}
	double checkMedian, checkWorst;
	summarize(times, checkRounds, checkMedian, checkWorst);
	core.stdc.stdio.printf("%s: checks first %.3f ms, then edges built in %.3f ms; unchanged %.3f ms; after an edit: median %.3f ms, worst %.3f ms\n", path, firstCheck * 1000, edges * 1000, recheck * 1000, checkMedian * 1000, checkWorst * 1000);
	return 0;
}

// Checks one file, as a library or a program, in a store of its own, and prints its report as `tests/doir_check.py` does. False if it fails or cannot be read.
private bool checkFile(const(char)* path, bool program) {
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	diagnose.Manager manager;
	scope(exit) diagnose.free(manager);
	auto engine = doir.query.create(store);
	scope(exit) doir.query.free(engine);
	engine.diagnostics = &manager;
	engine.edgesMissing = true; // nothing is edited, so no change needs pushing
	doir.strings.Strings strings;
	scope(exit) doir.strings.free(strings);
	engine.strings = &strings;
	auto read = fp.file.readFile(fp.string.slice(path));
	if (read.isNull) {
		core.stdc.stdio.printf("%s: FAIL\n  cannot read the file; check that the path names a readable file\n", path);
		return false;
	}
	auto text = read.get;
	scope(exit) fp.string.free(text);
	immutable file = doir.source.addFile(engine, strings, fp.string.slice(path));
	if (file == doir.source.invalidEntity || doir.source.commit(engine, strings, file, fp.string.slice(text)) == fp.pointer.allocationRefused
		|| !doir.source.reportSyntaxErrors(engine, file, manager) || !doir.checks.check(engine, file, program)) {
		core.stdc.stdio.printf("%s: FAIL\n  out of memory checking the file\n", path);
		return false;
	}
	immutable n = diagnose.count(manager);
	core.stdc.stdio.printf("%s: %s\n", path, n ? "FAIL".ptr : "ok".ptr);
	foreach (ref d; fp.dynarray.slice(manager.diagnostics)) {
		auto hint = fp.dynarray.length(d.annotations) ? fp.string.slice(d.annotations[0].message) : fp.string.slice(d.additionalNote);
		core.stdc.stdio.printf("  %s at line %d; %.*s\n", d.message, cast(int) d.location.start.line, cast(int) hint.length, hint.ptr);
	}
	return n == 0;
}

// `--check`: the files after it, a `-g` grammar ignored, those after `-p` checked as programs (L-Entry).
private int checkFiles(int argc, char** argv) {
	bool program = false, passed = true;
	for (int i = 2; i < argc; ++i) {
		const arg = fp.string.slice(argv[i]);
		if (arg == "-g") ++i;
		else if (arg == "-p") program = true;
		else passed &= checkFile(argv[i], program);
	}
	return passed ? 0 : 1;
}

/// Parses the files named on the command line; see the module documentation for the modes. Returns 1 if a file cannot be read or has an error, 0 otherwise. An unreadable file is reported as a diagnostic, and the other files are still parsed.
extern(C) int main(int argc, char** argv) {
	if (argc < 2) {
		core.stdc.stdio.fprintf(core.stdc.stdio.stderr, "usage: doir [--syntax | --print | --bench] file.doir...\n");
		return 1;
	}
	const mode = fp.string.slice(argv[1]);
	if (mode == "--check") return checkFiles(argc, argv);
	if (mode == "--syntax") {
		foreach (i; 2 .. argc)
			if (!syntaxOnly(argv[i])) return 1;
		return 0;
	}
	if (mode == "--bench") {
		immutable rounds = argc == 4 ? core.stdc.stdlib.atoi(argv[3]) : 200;
		return (argc == 3 || argc == 4) && rounds > 0 ? bench(argv[2], rounds) : 1;
	}

	immutable printing = mode == "--print";
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	diagnose.Manager manager;
	scope(exit) diagnose.free(manager);
	auto engine = doir.query.create(store);
	scope(exit) doir.query.free(engine);
	engine.diagnostics = &manager;
	engine.edgesMissing = true; // nothing is edited, so no change needs pushing
	// Without a pool the commit skims on this thread.
	engine.workers = bc.threadpool.create();
	scope(exit) bc.threadpool.free(engine.workers);
	doir.strings.Strings strings;
	scope(exit) doir.strings.free(strings);
	engine.strings = &strings;
	// libdiagnose borrows each text it prints from, so they live until the end.
	char** texts = null;
	scope(exit) {
		foreach (text; fp.dynarray.slice(texts)) fp.string.free(text);
		fp.dynarray.free(texts);
	}

	foreach (i; printing ? 2 : 1 .. argc) {
		auto read = fp.file.readFile(fp.string.slice(argv[i]));
		if (read.isNull) {
			diagnose.Diagnostic d;
			d.kind = diagnose.Kind.error;
			d.message = fp.string.createFromConcatenation("cannot read ", argv[i]);
			d.additionalNote = fp.string.makeDynamic("check that the path names a readable file, not a directory");
			if (d.message !is null && d.additionalNote !is null && diagnose.push(manager, d) !is null) continue;
			diagnose.free(d);
			core.stdc.stdio.fprintf(core.stdc.stdio.stderr, "doir: out of memory reading %s\n", argv[i]);
			return 1;
		}
		auto text = read.get;
		if (!fp.dynarray.pushBack(texts, text)) {
			fp.string.free(text);
			core.stdc.stdio.fprintf(core.stdc.stdio.stderr, "doir: out of memory reading %s\n", argv[i]);
			return 1;
		}
		immutable file = doir.source.addFile(engine, strings, fp.string.slice(argv[i]));
		if (file == doir.source.invalidEntity || !diagnose.registerSource(manager, fp.string.slice(argv[i]), fp.string.slice(text))
			|| doir.source.commit(engine, strings, file, fp.string.slice(text)) == fp.pointer.allocationRefused
			|| !doir.source.reportSyntaxErrors(engine, file, manager) || !doir.checks.check(engine, file)) {
			core.stdc.stdio.fprintf(core.stdc.stdio.stderr, "doir: out of memory reading %s\n", argv[i]);
			return 1;
		}
		if (!printing) continue;
		auto printed = doir.printer.print(store, strings, doir.source.rootOf(engine, file));
		if (printed.isNull) {
			core.stdc.stdio.fprintf(core.stdc.stdio.stderr, "doir: out of memory printing %s\n", argv[i]);
			return 1;
		}
		auto program = printed.get;
		scope(exit) fp.string.free(program);
		if (program !is null) core.stdc.stdio.fputs(program, core.stdc.stdio.stdout);
	}
	immutable printed = diagnose.printAll(manager, core.stdc.stdio.stderr);
	return printed && !diagnose.hasErrors(manager) ? 0 : 1;
}
