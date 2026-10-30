#!/usr/bin/env python3
"""Measures per-module test coverage: the unit tests, and `tests/lsp_test.py` run against the server. -cov needs druntime, so both build as plain D rather than -betterC.

Reports on this repository's `reference/` and `source/` modules, a line counting as covered when either run reaches it; dependencies are compiled in but left out of the report, as is the driver `source/main.d`.

Usage: python3 tools/coverage.py [-v]    (-v lists the uncovered lines; set DC to use a compiler other than ldc2)
"""
import glob, os, re, shutil, subprocess, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out = os.path.join('bin', 'coverage')
compiler = os.environ.get('DC', 'ldc2')
exe = os.path.join(out, 'doir-coverage' + ('.exe' if os.name == 'nt' else ''))
server_out = os.path.join(out, 'server')
server_exe = os.path.join(server_out, 'doir' + ('.exe' if os.name == 'nt' else ''))
# main is extern(C), so nothing starts druntime; without these hooks -cov never writes its listings. merge:1 because each LSP client is a new process.
server_runtime = '''module coverage_runtime;
extern(C) __gshared string[] rt_options = ["covopt=merge:1 dstpath:%s"];
extern(C) int rt_init();
extern(C) int rt_term();
pragma(crt_constructor) extern(C) void coverageStart() { cast(void) rt_init(); }
pragma(crt_destructor) extern(C) void coverageStop() { cast(void) rt_term(); }
''' % server_out.replace(os.sep, '/')
prefixes = ('reference-', 'source-')


def describe(*args):
	"""One `dub describe` query, as a list of non-empty lines."""
	result = subprocess.run(['dub', 'describe', *args, '-c', 'unittest', '--compiler=' + compiler],
		cwd=root, capture_output=True, text=True)
	if result.returncode != 0:
		sys.exit(f"coverage.py: 'dub describe {' '.join(args)}' failed; fix the dub error below, then run again:\n{result.stdout}{result.stderr}")
	return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def relative_to_root(path):
	"""-cov names each .lst after the source path it was given, so this repository's own paths go relative to the root: identical names on every platform."""
	path = os.path.normpath(path)
	try:
		inside = os.path.commonpath([root, os.path.abspath(path)]) == root
	except ValueError:
		# Windows raises this for paths on different drives, which cannot share a root.
		inside = False
	return os.path.relpath(path, root) if inside else path


def compile_command(import_paths, libs, sources, output):
	"""The plain-D -cov compiler command line building `sources` into `output`."""
	# LDC and DMD spell the version flag differently.
	version_flag = '-version=' if 'dmd' in os.path.basename(compiler) else '-d-version='
	# -i compiles only the dependency modules the tests import, so one that does not build as plain D stays out until it is used.
	# Plain -cov, not -cov=ctfe: nothing here is built during compilation, so counting CTFE would credit lines no test ran.
	return [compiler, '-cov', '-g', '-i', version_flag + 'DoirCoverage', *('-I' + p for p in import_paths),
		*libs, *sources, '-of=' + output]


def build_and_run():
	"""Builds the unit tests with -cov into `bin/coverage` and runs them, then builds the server with -cov into `bin/coverage/server` and runs `tests/lsp_test.py` against it, leaving a `.lst` listing per module in each. Exits on a failed build or test run."""
	import_paths = [relative_to_root(p) for p in describe('--import-paths')]
	sources = [relative_to_root(p) for p in describe('--data=source-files', '--data-list')]
	if not import_paths or not sources:
		sys.exit("coverage.py: 'dub describe' produced nothing to build; check that dub.json's unittest configuration builds with `dub build --config=unittest`")

	main_source = os.path.join('source', 'main.d')
	sources = [s for s in sources if os.path.normpath(s) != main_source]
	libs = ['-L-l' + lib for lib in describe('--data=libs', '--data-list')]

	shutil.rmtree(os.path.join(root, out), ignore_errors=True)
	os.makedirs(os.path.join(root, server_out))

	if subprocess.run([*compile_command(import_paths, libs, sources, exe), '-unittest'], cwd=root).returncode != 0:
		sys.exit(1)

	# --DRT-testmode lets druntime reach main. Run from the root: -cov reopens sources by their relative paths; `dstpath` puts listings in `bin/`.
	run = subprocess.run([os.path.join(root, exe), '--DRT-testmode=run-main', '--DRT-covopt=dstpath:' + out + ' merge:0'],
		cwd=root, capture_output=True, text=True)
	with open(os.path.join(root, out, 'run.log'), 'w') as log:
		log.write(run.stdout + run.stderr)
	if run.returncode != 0:
		sys.exit(f"coverage.py: {exe} failed; fix the failing test below (the full log is {os.path.join(out, 'run.log')}), then run again:\n{run.stdout}{run.stderr}")

	runtime_source = os.path.join(server_out, 'coverage_runtime.d')
	with open(os.path.join(root, runtime_source), 'w') as f:
		f.write(server_runtime)
	server_sources = [s for s in sources if not os.path.normpath(s).startswith('tests' + os.sep)] + [main_source, runtime_source]
	if subprocess.run(compile_command(import_paths, libs, server_sources, server_exe), cwd=root).returncode != 0:
		sys.exit(1)
	lsp = subprocess.run([sys.executable, os.path.join('tests', 'lsp_test.py'), server_exe], cwd=root, capture_output=True, text=True)
	with open(os.path.join(root, server_out, 'run.log'), 'w') as log:
		log.write(lsp.stdout + lsp.stderr)
	if lsp.returncode != 0:
		sys.exit(f"coverage.py: tests/lsp_test.py failed against {server_exe}; fix the failing check below (the full log is {os.path.join(server_out, 'run.log')}), then run again:\n{lsp.stdout}{lsp.stderr}")


def read_listing(listing, counts):
	"""Adds one listing's {line: (hits, text)} to `counts`; a line with no entry was compiled out, so it is not code."""
	with open(listing, encoding='utf-8', errors='replace') as f:
		for number, line in enumerate(f, 1):
			hits, bar, text = line.rstrip('\n').partition('|')
			if not bar or not re.fullmatch(r'\d+', hits.strip()):
				continue
			# A source can appear in more than one listing; any one running a line covers it.
			before = counts.get(number, (-1, text))[0]
			counts[number] = (max(before, int(hits)), text)


def read_listings():
	"""Maps each `reference/` and `source/` file but the driver to its line counts, merged across both runs."""
	files = {}
	for directory in (out, server_out):
		for prefix in prefixes:
			for listing in glob.glob(os.path.join(root, directory, prefix + '*.lst')):
				name = prefix[:-1] + '/' + os.path.basename(listing)[len(prefix):-len('.lst')].replace('-', '/') + '.d'
				if name != 'source/main.d':
					read_listing(listing, files.setdefault(name, {}))
	return dict(sorted(files.items()))


def report(files, verbose):
	"""Prints each file's coverage and the total; with `verbose`, also each uncovered line."""
	all_covered = all_total = 0
	for name, counts in files.items():
		missed = sorted(n for n, (hits, _) in counts.items() if hits == 0)
		total = len(counts)
		covered = total - len(missed)
		if total == 0:
			# "n/a" rather than 100%: a file with no counters has not been measured, let alone covered.
			print(f'{name:<40} {"n/a":>6}')
		else:
			flag = f'   <-- {len(missed)} uncovered' if missed else ''
			print(f'{name:<40} {100 * covered / total:6.2f}%  ({covered}/{total}){flag}')
		if verbose:
			for n in missed:
				print(f'      {n:5}: {counts[n][1]}')
		all_covered += covered
		all_total += total
	print('-' * 70)
	percent = 100 * all_covered / all_total if all_total else 100
	print(f'{"TOTAL":<40} {percent:6.2f}%  ({all_covered}/{all_total})')


def main():
	"""Builds and runs the tests with coverage, then reports it; returns 0, as a failed build or run exits earlier."""
	build_and_run()
	report(read_listings(), '-v' in sys.argv[1:])
	return 0


if __name__ == '__main__':
	sys.exit(main())
