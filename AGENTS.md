# AGENTS.md

This file provides architectural rules and guidance for building the query-based DOIR compiler.

## Core Mission & References

This project is a clean-sheet, query-driven DOIR compiler.
It replaces the legacy linear waterfall pipeline with an incremental, query-evaluated compiler architecture.

Three reference codebases guide implementation (`rustc-architecture.md` summarizes rustc and where DOIR departs from it):
1. **Query-Based Architecture:** [rustc (`rust-lang/rust`, `compiler/`)](https://github.com/rust-lang/rust)
   - Consult for the query engine (`rustc_middle/src/query`), cycle reporting, the red/green dep graph, entity creation inside queries (`create_def`/`TyCtxtFeed`), the comptime interpreter (`rustc_const_eval`, `Machine` trait), and mono-item collection and codegen units.
2. **Syntax & Semantic API:** [Roslyn (`dotnet/roslyn`)](https://github.com/dotnet/roslyn)
   - Consult for IDE-facing semantic models and the idea behind green/red reuse.
     DOIR has no separate syntax tree: the parser builds entities directly, and reuse across edits is reparse matching that keeps entity ids, with Salsa-style revisions on entities deciding what re-runs (`roadmap.md` Phases 1–2).
     Roslyn is lazy and snapshot-based, not dependency-tracked; do not take the query engine from it.
3. **Legacy Implementation:** [DOIR Waterfall Branch (`doir-lang/DOIR/tree/D`)](https://github.com/doir-lang/DOIR/tree/D)
   - Consult for raw semantics, instruction tables (`tools/mizu_gen.d`), and register allocator interval sweeps (`opt/assign_temporaries.d`).
     The parser is written from scratch; consult `source/doir/parser.d` only for which builder calls each declaration form makes and for the edge cases its tests pin down.
     We want to maintain the monolithic libECRS based store, whose design rationale is Dahl & Harris, Onward!
     '25 ([doi:10.1145/3759429.3762622](https://doi.org/10.1145/3759429.3762622)): plain-data components, entity ids in place of pointers, one parent per node, and tags for node kinds.

## Architectural Mandates

1. **Demand-Driven Queries (rustc Model):**
   - The compiler is a collection of pure, memoized queries (`query(Key) -> Value`).
   - Query instances are entities.
     Their keys, values, dependencies and revisions are components, and every component a query writes is listed in its `Outputs` component and removed when the query re-runs with a new value or is evicted.
   - Every semantic pass, type check, lowering, and comptime execution runs on demand.
   - Cycle detection is built into the query engine to report recursion errors cleanly.
   - Comptime reads inside a level are ordered (`C-Order`, `M-Lexical`) and keyed by ⟨entity, lexical position⟩; queries against a frozen level are keyed by entity alone (`L-Freeze`).
     A level over more than one target adds the target to both keys (`T-Split`).

2. **Entity Ids & Renumbering (`E-Remap`):**
   - Entities are natural-number ids (`EntityId`).
     Renumbering is allowed.
   - Every renumbering rewrites all holders of entity ids in one step: entity-valued components, attribute values and query entities included, through libECRS's `remapEntities` hooks.
     It runs only between levels or between edits (matching a reparse), when no comptime frame or comptime memory is live, and `std.meta.entity` values never enter memory (`MEM-Escape`).
     The legacy corruption (`canon/sort.d` in `tree/D`) came from skipped holders.
   - Anything that holds an `EntityId` holds it by mixing in libECRS's relation, `mixin ecrs.relation.Relates!n;` (`Relates;` for a list), as its first member, naming fixed slots where a name reads better (`Relates!("file", "level")`, then `key.file`).
     That gives it the remap, lifetime, copy, encoding, `contentHash` and `equal` hooks in one place; never hand-write those for entity ids.

3. **Stratified Level Tower (spec Part II §16):**
   - DOIR has no standalone runtime semantics; a level supplies them (`compiler` -> `machine` -> `std` -> source languages).
   - The tower is a DAG of levels, file roots and namespaces made into levels, joined by `compiler.levels.lower_to` edges that carry the passes (`L-Tower`, `L-Lower`).
   - A level declares both halves of its own compilation: `compiler.levels.check(t, name)` adds a check to the semantic analysis run over its own entities (`L-Sema`), and `compiler.levels.lower_to(t, u, passes)` defines its lowering (`L-Lower`).
     Both name checks and passes the compiler provides or that `compiler.levels.bind_pass(f, name)` binds to a DOIR function (`L-Bind`).
     A check is a query per entity, run in no order; passes are an ordered pipeline over the store; neither is a compiler edit.
     A scan reads the tower from the source before ascent (`L-Scan`); never derive it from comptime.
   - Ascent: Type deduction, semantic analysis, and compile-time execution evaluate bottom-up by level.
   - Descent: Optimizations and lowering rewrite from top-down.
     Lowering retires a level (`L-Erase`): its entities stay queryable but are never read by lower levels.

4. **Abstract Host Services ABI:**
   - Comptime is not bound to VM opcode hacks.
   - Host services (memory allocation, entity queries, type creation, diagnostics) form a C-compatible thunk table.
   - The Mizu VM reaches it through hook instructions whose handlers call the table; native JIT hosts call the same entries as indirect function pointers.

5. **Bootstrap versus Interface (`H-Boot`, spec Part II §11):**
   - `compiler` holds the bootstrap, functions the compiler treewalk-interprets itself before any target code exists (the minimum that builds types and emits bytes), and the floor, what code that cannot name `std` needs: the levels below `std`, and builds without `standard.doir`, since DOIR must not depend on `std` existing.
   - `std.meta` is the boundary: hooks, not code.
     Each is one `HostServices` entry: a mizu backend reaches it through an instruction, a JIT through a direct call.
   - Prefer `std.meta`.
     New names go to `std.meta` unless code that cannot name `std` needs them, or they are needed before level 1 can run; any other name left in `compiler` is debt.
     Keep `compiler` as small as possible.

## Source & Semantics Authority

- `doir.spec.md`: The normative language specification.
  Rule tags (e.g., `M-Flag`, `R-Unqual`, `L-Stage`, `D-Deduce`) must be cited in code and commits.
- `standard.doir`: The canonical interface specification.
- `standard.os.doir`: The canonical operating-system interface, `std.os`, which `standard.doir` pastes into `std`.
  A target is a machine, an operating system and an executable format pasted into one backend namespace (`OS-Target`); `reference/operating_system.doir` is what an operating system supplies, and `os.linux.doir`, `os.windows.doir` and `os.freestanding.doir` are the ones there are.
  `reference/format.doir` is what a format supplies, its sections and its writer (Part II §20), and `format.flat.doir` is the one there is; never put a format's sections or headers in an operating system or a machine, which write only to the `object.*` roles.
- If code contradicts `doir.spec.md`, the specification is authoritative unless recorded in Part III (Divergences) of `doir.spec.md`.
- `roadmap.md`: The build plan.
  What it schedules is what gets built.
- `rustc-architecture.md`, `roslyn-architecture.md` and `ir-design.md` are references, not mandates: background and proposals to consult, never requirements.
  Where one disagrees with the spec, the roadmap or this file, those win.

## Code Style

The compiler is written in D under `-betterC` on LDC, on libfp; its tools and test drivers are Python 3 (`tools/`, `tests/*.py`), and its interfaces, references and tests are DOIR (`standard.doir`, `reference/`, `tests/`).
The D rules are forwarded from libfp's `AGENTS.md`; they apply to every D, Python and DOIR source in this repository, except where a rule names the languages it covers.

### Comments

- Keep comments minimal.
  Write one only where the code does something difficult to follow on its own: a non-obvious invariant, a subtle memory or lifetime rule, a workaround for a compiler bug, or why an apparently simpler approach would be wrong.
  Do not restate what the code already says.
- Cap every free-standing comment (a `//`, `/* */` or `#` comment that is not documentation) at 25 words.
  If it needs more, the code or its documentation should carry the explanation instead.
- Editors here soft-wrap, so never hard-wrap a comment at a column.
  Write a free-standing comment on a single line, and put each sentence of a DDoc comment, docstring or DOIR documentation comment on its own line, with a blank line between paragraphs.
- Do not leave commented-out code, change logs, or notes about what was changed in a comment; those belong in commit messages.
- A comment that implements a spec rule carries that rule tag (`M-Flag`, `R-Unqual`, `L-Stage`, `D-Deduce`), which does not count toward the 25-word cap.

### Documentation

- Document every publicly accessible definition, directly where the language puts its documentation:
  - D: a DDoc comment (`///` or `/** */`) above each public or package-visible function, struct, enum, alias, template, mixin template, and module-level variable.
  - Python: a docstring on each module, and on each function and class whose name does not start with `_`.
  - DOIR, which has no documentation comment: a `//` comment directly above a declaration outside every function body and block documents it, and one at the top of each file says what the file is.
    Give one to each `export`ed declaration, and each declaration of `reference/`'s interfaces, whose use is not plain from its name and type.

  Private helpers do not need one.
- Every DDoc comment on a function or template includes an example of its use in an `Examples:` section, as a `---` code block:

  ```d
  /// Memoizes `query(key)`, returning the cached value on a repeat call.
  /// Reports a recursion cycle as `CycleError` and leaves the cache empty.
  ///
  /// Examples:
  /// ---
  /// QueryEngine engine;
  /// assert(engine.query(key) == engine.query(key));
  /// ---
  Value query(ref QueryEngine engine, Key key) { ... }
  ```

- Keep examples short, and make them correct against the current API: they should compile and pass as written under `-betterC`.
  Check them with `python3 tests/doctest.py`, which compiles and runs every example and reports public definitions missing documentation or an example.
  With no arguments it checks `source/**/*.d`; pass files and `-I dir` import paths for the modules those sources import.
- Examples see their own module unqualified, as user code would; anything else needs its full name.
- When a platform `static if` or `version` gives an API several implementations, document the first branch's definitions; an `else` branch reimplementing the same API needs no second copy.
- Generate DOIR documentation with `uv run tools/doir_doc.py`, which writes a Markdown page per file to `bin/docs`, and check DOIR comments against these rules with `uv run tools/doir_doc.py --check`.
- A Python tool's module docstring says how to run it, as a usage line (`uv run tests/parse_diff.py [file.doir...]`).
- Documentation is not a free-standing comment, so the 25-word cap does not apply to it, but keep it as brief as the definition allows.

### Style

- In D, prefer plain-data structs operated on by free functions that take them by `ref` (for example `pushBack(arr, x)`, `free(arr)`), rather than methods, so the code stays close to what a DOIR port of it would be.
  Use member functions only for operator overloads, for `@property` accessors that name part of a field (such as `ecrs.relation.Relates` naming a slot of `related`), and for what a language protocol requires to be a member, such as range primitives (`empty`, `front`, `popFront`) or an `alias this` target.
  Python is not ported, so it uses classes and methods where they are idiomatic.
- Prefer fully qualified names to aliasing imports: call `fp.string.free(s)` rather than `import fp.string : stringFree = free;` or `alias stringFree = fp.string.free;`, and `doir_grammar.parse(…)` rather than `from doir_grammar import parse` or `import doir_grammar as g`.
  In D, a `static import` keeps a module's names out of scope so every use has to be qualified.
- One module uses another through a qualified import, so every call names its layer (`fp.dynarray.pushBack`, `fp.pointer.notFound`, `pathlib.Path`): in D a `static import`, in Python a plain `import`.
  The exceptions are a D `public import` that re-exports names as part of the module's own API, and Python's `from __future__ import …`.
- Avoid one-line wrappers: a function whose body only forwards to another call, fixing an argument or two or reaching into a field, adds a name to learn and hides the call it stands for.
  Write the call out at each use, even when it is long; a long call is not a reason to wrap it.
  Write a function only when it adds something, such as a check, a loop, or a name for an operation the spec or `standard.doir` defines.
  Before keeping a wrapper, see whether renaming what it wraps would make the direct call read as well.
  The exception is a wrapper the spec requires, as `RF-Wrapper` requires each `std.types` and `std.functions` entry to wrap its `std.meta` hook, or a protocol does (a hook found by name, an accessor of a private field); in D, mark it `// wrapper: <reason>` on the line above its documentation comment.
- Name D in camelCase, and Python and DOIR in snake_case, with Python classes in PascalCase and DOIR function and type aliases ending `_t` (`modifier_t`).
  Add a trailing underscore only when the plain name is a keyword of its language (`out_`, `in_`, `with_`, `null_`, `string_`).
  D names that mirror `standard.doir` or the spec keep their spec spelling (`std.meta.entity`, `compiler.base_type_t`).
- Make names document themselves, so neither a comment nor a wrapper is needed to explain them:
  - Spell words out: no C-heritage names or abbreviations (`allocate`, not `malloc`; `context`, not `ctx`; `array`, not `da`).
  - Name the effect or the result, not the mechanism (`lockForReading`, not `readLock`; `wordEnd` for a function returning where a word ends).
  - Do not repeat what the qualified module path or the types already say: calls are always qualified, so `fp.pointer.allocate` needs no `Memory`.
  - Name a sentinel for what it means where it is used, and split a sentinel that would mean two things (`notInterned` and `refused`, not one `none`).
  - Purpose suffixes read `ForReading`/`ForWriting` (`lockForWriting`, `getForWriting`, `mapForWriting`).
  - Keep the words every reader already knows: `free`, `length`, `find`, `insert`, `hash`, `create`, `contains`, `pushBack`, `pushFront`, `removeAt`.
- Indent with tabs.
- In D, under a `@nogc nothrow:` label, do not repeat those attributes on the declarations the label covers: every declaration at that scope, including those inside `version` and `static if` blocks.
  Function attributes do not propagate into aggregate declarations, so members of a non-template struct, class or union, and hooks of a non-template struct declared inside a function or `unittest`, must state `@nogc nothrow` themselves, or calls from `@nogc` code fail to compile.
  Members of a template struct need no repetition because their attributes are inferred.

### Failure and invariants

- Every function that can fail says in its documentation how it reports failure (null, `false`, an empty `Nullable`, `fp.pointer.notFound`, `fp.pointer.allocationRefused`, `None`, the exception it raises), and what state it leaves its arguments in; prefer leaving them as they were.
- Do not return a `bool` with the result in an `out` parameter (`bool find(…, out T x)`): return `std.typecons.Nullable!T`, null on failure, so the result cannot be read without the check.
  Several results go in a struct the `Nullable` holds.
- Never drop the result of a call that can fail: check it, or discard it explicitly when failure is impossible or harmless there, with `cast(void)` in D and `_ = …` in Python.
  Tests assert on it.
- When a limit on one value follows from another (such as a bit position), name the constant once, derive the others from it, and `assert` the limit where the value is accepted.
- Put test-only code, such as helper functions and globals the tests use, inside `version(unittest)` in D, and in the test files rather than the modules they test in Python.
- `tests/runner.d` runs only the modules it lists, so add a new module with unittests to its `modules` list.
- Keep test coverage as close to 100% as possible: add a test for every new branch and failure path, and check with `python3 tools/coverage.py`; an uncovered line needs a reason, such as being unreachable or platform-specific.

### Diagnostics

- Every diagnostic the compiler reports to the user carries at least one annotation (`diagnose.Diagnostic.Annotation`) pointing at the offending item, and a hint saying how to fix it, as that annotation's message or as the diagnostic's `note`.
  "Expected `}`" alone is not enough; "insert `}` here to close the namespace opened above" is.
- When other items are involved, such as the earlier import in a `WF-Unique` clash or the opening brace of an unclosed block, point an annotation at each, saying what part it plays.
- A diagnostic with no source location, such as a file that cannot be read, still gives a hint.
- A Python tool's error names the file and line it is about, the rule tag when there is one, and a hint; it keeps the rule tag first where another tool matches on it (`tests/conformance.py` on `doir_check`).
- Tests of a diagnostic assert on its annotations and hint, not only on its kind and count.

### Markdown

- Put each sentence of a Markdown file on its own line, a list item's or block quote's later sentences continuing under its marker, so a diff shows the sentences an edit changed.
  Never hard-wrap a sentence; editors here soft-wrap.

### Organization

- Where possible, group related definitions into sections (for example: types and layout, queries, creation and freeing, growth, removal), separated by blank lines, and order them so a reader meets a type before the functions built on it.
- Whenever possible, define a function before anything that uses it, so a module reads bottom-up from its building blocks; a Python tool ends with `main`.  
When functions use each other in a cycle, define first the one that more of the module uses.
- Keep a module's tests in the same order as the code they test.
- Prefer merging a new test case into an existing test (a D `unittest` block, a Python test function) covering the same section over adding a new one; add one only when no existing test fits.
  A DOIR test is a file of its own, named as `tests/conformance.py` or `tests/parse_diff.py` describes.
- Prefer grouping components together in a file in `source/doir/components` rather than scattering components through every file.

### Layering

DOIR is the top of a stack: libfp at the bottom, bc-threads on it, libdiagnose, libECRS, Mizu and bc-fetch on those, and DOIR on all of them.
Every library in the stack forwards these rules from libfp's `AGENTS.md`.

- Put code in the lowest library that has everything it needs.
  A library above may hold only what is specific to it: threads in bc-threads, entities in libECRS, diagnostics in libdiagnose, networking in bc-fetch, the language in DOIR.
  Before writing a helper, search the libraries below for it; if it is missing, add it there, with a test, rather than locally.
- Only libfp, bc-threads, bc-fetch and Mizu's FFI layer (`mizu.ffi`, which loads and calls into native libraries) import `core.sys.*` or `core.stdc.*`, or call OS APIs; everything else reaches the OS and the C runtime through them (`fp.pointer.copy` and `fill`, `fp.string.sliceTerminated`, `fp.io.print` and `abort`).
- View a plain field atomically through `bc.platform.asShared`, never a hand-written `cast(shared …)`.
- Hold owned memory in a struct through `fp.lifecycle.Owned` rather than hand-written `finalize` and `copyTo` hooks.
- Compare and hash a value through `fp.lifecycle.equal` and `fp.lifecycle.contentHash`, which use its hooks if it declares them.
  Never `memcmp` or hash a struct's raw bytes: its padding is in them.
- Write a component in place only through `ecrs.context.getForWriting`, `findForWriting`, `ensureComponent` or `setComponent`, which count the change and journal it; `getComponent` and `findComponent` are for reading.
- Check these rules with `python3 tools/lint.py`, which every library keeps a copy of, each with its own `CONFIG` and the same `PUSHED` registry.
  When code moves into a lower library, add the pattern it replaced to `PUSHED` in every copy, with the replacement as its hint, so the old way cannot come back.

### Bugs

- If you find a bug while working, fix it, with a test that would have caught it, rather than only reporting it.
  Only when the fix would likely take a long time, report it instead, saying what you found and where.

## Profiling

```sh
DFLAGS="--frame-pointer=all" dub build --config=doir --compiler=ldc2 --build=release-debug --force
perf record --call-graph fp -e cpu_core/cycles/ -- ./bin/doir test.doir # the run to profile
perf script > perf.script
FlameGraph/stackcollapse-perf.pl perf.script > perf.folded
FlameGraph/flamegraph.pl perf.folded > perf.svg
```

To profile the tests, build them with `DFLAGS="-g -unittest -O --frame-pointer=all" dub build --config=unittest --compiler=ldc2 --build=plain --force`: dub ignores `DFLAGS` under `--build=unittest`, and `release-debug` would compile out the tests' asserts.
The suite runs in milliseconds, so record many runs at a high rate (`perf record -F 20000 … -- sh -c 'for i in $(seq 500); do ./bin/doir-tests; done'`).

The scripts are from [FlameGraph](https://github.com/brendangregg/FlameGraph).
The same steps are written up for no-api in its [README](https://github.com/doir-lang/no-api#profiling); keep the two in step.

The frame pointer flag is what makes the profile readable, and it is not optional.
In the waterfall compiler, `--call-graph dwarf` against a build without it unwound 0.1% of cycles to a real stack, left 65% of samples with no frames at all, throttled the sample period 5x and wrote 4.6GB of `perf.data`.
It goes in `DFLAGS` rather than `dub.json`'s `dflags` because `DFLAGS` reaches every dependency too (libfp, libECRS, libdiagnose, Mizu), and a stack is only as unwindable as the least cooperative frame on it.
With frame pointers in the binary, `--call-graph fp` needs no stack copying; `dwarf` also works, but it adds nothing and makes `perf.data` much larger.

`-e cpu_core/cycles/` because a hybrid CPU otherwise reports `cpu_atom` and `cpu_core` as two events with their own sample periods, and anything that sums raw sample counts across them is measuring nothing.

Check `kernel.perf_event_paranoid` before reading any of the numbers.
At the default of 2, perf quietly records user space only (the event shows up as `cpu_core/cycles/u`), so kernel time is invisible or lands on a single unresolvable `0xffffffff...` address, ~40% of the cycles in one waterfall run.
`sudo sysctl kernel.perf_event_paranoid=1` brings it back.

Mind what the driver spends its time on.
Printing the IR took 20–39% of the waterfall `bin/doir`'s cycles, none of it compilation.
Profile `bin/doir-tests`, or subtract the driver's output, when the question is about compile speed rather than the driver.

`perf.script` grows quickly with run length, so stream it with `awk` rather than loading it.
Weight each sample by the period in its header line: once perf has throttled, that period is not constant, and counting every sample as one unit silently reweights the profile.
