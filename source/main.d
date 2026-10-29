/// The `doir` executable. For now it parses: each file is committed into the store (`doir.source`) and its diagnostics are printed through libdiagnose.
///
///     doir file.doir...             parse and report; exit 1 if any file has an error
///     doir --print file.doir...     parse, report, and print each file's program back as DOIR source (`doir.printer`)
///     doir --syntax file.doir...    print each file's first syntax error, as `tools/parse_diff.py` compares with `doir.peg`
///     doir --bench file.doir [n]    time n commits (200 by default) of one-line edits to the file (`roadmap.md` Phase 2)
module main;

static import core.stdc.stdio;
static import core.stdc.stdlib;
static import core.stdc.time;

static import fp.dynarray;
static import fp.pointer;
static import fp.string;

static import diagnose;
static import ecrs.context;

static import doir.strings;
static import doir.printer;
static import doir.query;
static import doir.source;
static import doir.syntax.parser;

@nogc nothrow:

// Prints `path: ok` or `path: line L:C: message` for the first syntax error, as `tools/parse_diff.py` reads.
private bool syntaxOnly(const(char)* path) {
	auto read = doir.source.readFile(fp.string.slice(path));
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

private double seconds() {
	return cast(double) core.stdc.time.clock() / core.stdc.time.CLOCKS_PER_SEC;
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

private int bench(const(char)* path, int rounds) {
	auto read = doir.source.readFile(fp.string.slice(path));
	if (read.isNull) return 1;
	auto text = read.get;
	scope(exit) fp.string.free(text);
	auto original = fp.string.slice(text);
	immutable at = middleDeclaration(original);
	auto edited = fp.string.createFromConcatenation(original[0 .. at], "bench_edit : T = 1\n", original[at .. $]);
	if (edited is null) return 1;
	scope(exit) fp.string.free(edited);

	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	auto engine = doir.query.create(store);
	scope(exit) doir.query.free(engine);
	doir.strings.Strings strings;
	scope(exit) doir.strings.free(strings);
	immutable file = doir.source.addFile(engine, strings, fp.string.slice(path));
	if (file == doir.source.invalidEntity) return 1;

	immutable start = seconds();
	if (doir.source.commit(engine, strings, file, original) == fp.pointer.allocationRefused) return 1;
	immutable first = seconds() - start;

	// Alternating the two texts makes every commit a one-line edit: an insertion, then its removal.
	auto times = cast(double*) core.stdc.stdlib.malloc(rounds * double.sizeof);
	if (times is null) return 1;
	scope(exit) core.stdc.stdlib.free(times);
	foreach (i; 0 .. rounds) {
		immutable t = seconds();
		if (doir.source.commit(engine, strings, file, fp.string.slice(i % 2 ? text : edited)) == fp.pointer.allocationRefused) return 1;
		times[i] = seconds() - t;
	}
	foreach (i; 1 .. rounds)
		for (size_t j = i; j > 0 && times[j - 1] > times[j]; --j) {
			immutable swap = times[j];
			times[j] = times[j - 1];
			times[j - 1] = swap;
		}
	core.stdc.stdio.printf("%s: %d bytes; first commit %.3f ms; one-line edit median %.3f ms, worst %.3f ms\n",
		path, cast(int) original.length, first * 1000, times[rounds / 2] * 1000, times[rounds - 1] * 1000);
	return 0;
}

/// Parses the files named on the command line; see the module documentation for the modes. Returns 1 if a file cannot be read or has an error, 0 otherwise. An unreadable file is reported as a diagnostic, and the other files are still parsed.
extern(C) int main(int argc, char** argv) {
	if (argc < 2) {
		core.stdc.stdio.fprintf(core.stdc.stdio.stderr, "usage: doir [--syntax | --print | --bench] file.doir...\n");
		return 1;
	}
	const mode = fp.string.slice(argv[1]);
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
	doir.strings.Strings strings;
	scope(exit) doir.strings.free(strings);

	foreach (i; printing ? 2 : 1 .. argc) {
		auto read = doir.source.readFile(fp.string.slice(argv[i]));
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
		scope(exit) fp.string.free(text);
		immutable file = doir.source.addFile(engine, strings, fp.string.slice(argv[i]));
		if (file == doir.source.invalidEntity || doir.source.commit(engine, strings, file, fp.string.slice(text)) == fp.pointer.allocationRefused) {
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
