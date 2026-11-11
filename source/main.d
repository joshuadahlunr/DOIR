/// The `doir` executable.
/// For now it parses: each file is committed into the store (`doir.source`) and its diagnostics are printed through libdiagnose.
///
///     doir file.doir...             parse and report; exit 1 if any file has an error
///     doir --print file.doir...     parse, report, and print each file's program back as DOIR source (`doir.printer`)
///     doir --syntax file.doir...    print each file's first syntax error, as `tests/parse_diff.py` compares with `doir.peg`
///     doir --check [-g grammar] file.doir...
///     [-p program.doir...]
///                                   check each file, printing `path: ok` or `path: FAIL` and its diagnostics, as `tests/doir_check.py` does (`tests/conformance.py --checker`)
///     doir --lsp                    serve the Language Server Protocol on stdin and stdout (`doir.lsp.server`)
///     doir --bench file.doir [n]    time n one-line edits to the file (200 by default), committed whole and as edits, and the checks before and after them (`roadmap.md` Phases 2-3)
module main;

static import fp.dynarray;
static import fp.io;
static import fp.string;
static import fp.string.numbers;

static import bc.threadpool;
static import diagnose;
static import ecrs.context;
static import ecrs.schedules;

static import doir.bench;
static import doir.checks;
static import doir.lsp.server;
static import doir.strings;
static import doir.printer;
static import doir.query;
static import doir.source;
static import doir.syntax.parser;

@nogc nothrow:

// Prints `path: ok` or `path: line L:C: message` for the first syntax error, as `tests/parse_diff.py` reads.
private bool syntaxOnly(const(char)* path) {
	auto read = fp.io.readFile(fp.string.slice(path));
	if (read.isNull) return false;
	auto text = read.get;
	scope(exit) fp.string.free(text);
	auto source = fp.string.slice(text);
	doir.syntax.parser.Syntax syntax;
	scope(exit) doir.syntax.parser.free(syntax);
	if (!doir.syntax.parser.skim(source, syntax)) return false;
	foreach (error; fp.dynarray.slice(syntax.errors)) {
		if (error.kind != doir.syntax.parser.SyntaxError.Kind.syntax && error.kind != doir.syntax.parser.SyntaxError.Kind.nesting) continue;
		immutable at = diagnose.lineColumn(source, error.at);
		auto message = doir.syntax.parser.describe(syntax, source, error);
		if (message is null) return false;
		scope(exit) fp.string.free(message);
		return fp.io.print(path, ": line ", at.line, ':', at.column, ": ", message, '\n');
	}
	return fp.io.print(path, ": ok\n");
}

// Checks one file, as library or program, in its own store, printing its report as `tests/doir_check.py` does.
// False if it fails or cannot be read.
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
	auto read = fp.io.readFile(fp.string.slice(path));
	if (read.isNull) {
		cast(void) fp.io.print(path, ": FAIL\n  cannot read the file; check that the path names a readable file\n"); // failing either way
		return false;
	}
	auto text = read.get;
	scope(exit) fp.string.free(text);
	immutable file = doir.source.addFile(engine, strings, fp.string.slice(path));
	if (file == doir.source.invalidEntity || !ecrs.schedules.sequential(engine, doir.source.committing(strings, file, fp.string.slice(text)), doir.checks.Checking(file, program))) {
		cast(void) fp.io.print(path, ": FAIL\n  out of memory checking the file\n"); // failing either way
		return false;
	}
	immutable n = fp.dynarray.length(manager.diagnostics);
	bool printed = fp.io.print(path, n ? ": FAIL\n" : ": ok\n");
	foreach (ref diagnostic; fp.dynarray.slice(manager.diagnostics)) {
		auto hint = fp.dynarray.length(diagnostic.annotations) ? fp.string.slice(diagnostic.annotations[0].message) : fp.string.slice(diagnostic.note);
		printed &= fp.io.print("  ", diagnostic.message, " at line ", diagnostic.location.start.line, "; ", hint, '\n');
	}
	return printed && n == 0;
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

// `doir --bench file.doir [rounds]`: runs `doir.bench.bench`, 200 rounds unless told otherwise. 1 if the arguments are wrong.
private int benchFile(int argc, char** argv) {
	if (argc != 3 && argc != 4) return 1;
	ulong rounds = 200;
	if (argc == 4) {
		auto parsed = fp.string.numbers.parseUnsigned(fp.string.slice(argv[3]), 10);
		rounds = parsed.isNull ? 0 : parsed.get.value;
	}
	if (rounds == 0 || rounds > uint.max) {
		cast(void) fp.io.print(fp.io.Console.error, "doir: --bench takes a positive whole number of rounds, as in `doir --bench file.doir 200`\n"); // failing either way
		return 1;
	}
	return doir.bench.bench(argv[2], cast(size_t) rounds);
}

// Reports to `manager` that the file at `path` cannot be read.
// False if that report was refused.
private bool reportUnreadable(ref diagnose.Manager manager, const(char)* path) {
	diagnose.Diagnostic diagnostic;
	diagnostic.kind = diagnose.Kind.error;
	diagnostic.message = fp.string.joined("cannot read ", path).get(null);
	diagnostic.note = fp.string.clone("check that the path names a readable file, not a directory").get(null);
	if (diagnostic.message !is null && diagnostic.note !is null && diagnose.push(manager, diagnostic) !is null) return true;
	diagnose.free(diagnostic);
	return false;
}

/// Parses the files named on the command line; see the module documentation for the modes.
/// Returns 1 if a file cannot be read or has an error, 0 otherwise.
/// An unreadable file is reported as a diagnostic, and the other files are still parsed.
extern(C) int main(int argc, char** argv) {
	if (argc < 2) {
		cast(void) fp.io.print(fp.io.Console.error, "usage: doir [--syntax | --print] file.doir...\n       doir --check [-g grammar] file.doir... [-p program.doir...]\n       doir --bench file.doir [rounds]\n       doir --lsp\n"); // failing either way
		return 1;
	}
	const mode = fp.string.slice(argv[1]);
	if (mode == "--lsp") return doir.lsp.server.run(0, 1);
	if (mode == "--check") return checkFiles(argc, argv);
	if (mode == "--syntax") {
		foreach (i; 2 .. argc)
			if (!syntaxOnly(argv[i])) return 1;
		return 0;
	}
	if (mode == "--bench") return benchFile(argc, argv);

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
		auto read = fp.io.readFile(fp.string.slice(argv[i]));
		if (read.isNull) {
			if (reportUnreadable(manager, argv[i])) continue;
			cast(void) fp.io.print(fp.io.Console.error, "doir: out of memory reading ", argv[i], '\n'); // failing either way
			return 1;
		}
		auto text = read.get;
		if (!fp.dynarray.pushBack(texts, text)) {
			fp.string.free(text);
			cast(void) fp.io.print(fp.io.Console.error, "doir: out of memory reading ", argv[i], '\n'); // failing either way
			return 1;
		}
		immutable file = doir.source.addFile(engine, strings, fp.string.slice(argv[i]));
		if (file == doir.source.invalidEntity || !diagnose.addSource(manager, fp.string.slice(argv[i]), fp.string.slice(text))
			|| !ecrs.schedules.sequential(engine, doir.source.committing(strings, file, fp.string.slice(text)), doir.checks.Checking(file))) {
			cast(void) fp.io.print(fp.io.Console.error, "doir: out of memory reading ", argv[i], '\n'); // failing either way
			return 1;
		}
		if (!printing) continue;
		auto printed = doir.printer.print(store, strings, doir.source.rootOf(engine, file));
		if (printed.isNull) {
			cast(void) fp.io.print(fp.io.Console.error, "doir: out of memory printing ", argv[i], '\n'); // failing either way
			return 1;
		}
		auto program = printed.get;
		scope(exit) fp.string.free(program);
		if (!fp.io.writeAll(fp.io.Console.output, fp.string.slice(program))) return 1;
	}
	immutable printed = diagnose.printAll(manager, fp.io.Console.error);
	return printed && !diagnose.hasErrors(manager) ? 0 : 1;
}
