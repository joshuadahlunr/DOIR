/// Long runs of `doir.simulation`, past the unittests' fixed seeds: `bin/doir-simulate [--seed S] [--seeds K] [--steps N] [--trace] [file.doir...]`, built by `dub build --config=simulate --build=unittest --compiler=ldc2`, since `doir.simulation` is test code; every validator is asserted there.
/// Seeds S to S + K - 1 (1 and 100 unless told) each walk N (200) random edits of a program `doir.simulation.generate` draws, and each file named walks N edits from seed S, so `tests/conformance/*.accept.doir` is a corpus.
/// The first disagreement aborts, naming its seed and step; `--trace` with that seed prints each edit up to it.
/// Exits 0 when every walk agrees, and 1 on a bad argument or an unreadable file.
module simulate;

static import std.typecons;

static import fp.io;
static import fp.string;
static import fp.string.numbers;

static import doir.simulation;

@nogc nothrow:

// The whole number `argv[i]`, the value of an option, or null if it is missing or not one.
private std.typecons.Nullable!ulong number(int argc, char** argv, int i) {
	if (i >= argc) return std.typecons.Nullable!ulong.init;
	auto parsed = fp.string.numbers.parseUnsigned(fp.string.slice(argv[i]), 10);
	if (parsed.isNull) return std.typecons.Nullable!ulong.init;
	return std.typecons.Nullable!ulong(parsed.get.value);
}

// Adds `outcome` to `total`.
private void add(ref doir.simulation.Outcome total, doir.simulation.Outcome outcome) {
	total.steps += outcome.steps;
	total.refusedCommits += outcome.refusedCommits;
	total.refusedChecks += outcome.refusedChecks;
	total.renumberings += outcome.renumberings;
}

/// Walks the seeds and files the command line names; see the module documentation.
extern(C) int main(int argc, char** argv) {
	ulong seed = 1, seeds = 100, steps = 200;
	bool trace = false;
	int firstFile = argc;
	for (int i = 1; i < argc; ++i) {
		const arg = fp.string.slice(argv[i]);
		if (arg == "--trace") {
			trace = true;
			continue;
		}
		if (arg != "--seed" && arg != "--seeds" && arg != "--steps") {
			firstFile = i;
			break;
		}
		immutable value = number(argc, argv, ++i);
		if (value.isNull) {
			cast(void) fp.io.print(fp.io.Console.error, "doir-simulate: ", arg, " takes a whole number, as in `", arg, " 10`\n");
			return 1;
		}
		if (arg == "--seed") seed = value.get;
		else if (arg == "--seeds") seeds = value.get;
		else steps = value.get;
	}
	doir.simulation.Outcome total;
	foreach (s; seed .. seed + seeds) {
		char* program = doir.simulation.generate(s);
		scope(exit) fp.string.free(program);
		add(total, doir.simulation.simulate(s, steps, fp.string.slice(program), trace));
	}
	foreach (i; firstFile .. argc) {
		auto read = fp.io.readFile(fp.string.slice(argv[i]));
		if (read.isNull) {
			cast(void) fp.io.print(fp.io.Console.error, "doir-simulate: cannot read ", argv[i], "\n");
			return 1;
		}
		scope(exit) fp.string.free(read.get);
		add(total, doir.simulation.simulate(seed, steps, fp.string.slice(read.get), trace));
	}
	cast(void) fp.io.print(fp.io.Console.error, "doir-simulate: ", seeds, " seeds and ", argc - firstFile, " files agree over ", total.steps, " edits, ", total.refusedCommits, " commits and ", total.refusedChecks, " checks refused, ", total.renumberings, " renumberings\n");
	return 0;
}
