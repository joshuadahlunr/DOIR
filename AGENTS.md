# CLAUDE.md

This file provides architectural rules and guidance for building the query-based DOIR compiler.

## Core Mission & References

This project is a clean-sheet, query-driven DOIR compiler. It replaces the legacy linear waterfall pipeline with an incremental, query-evaluated compiler architecture.

Three reference codebases guide implementation (`rustc-architecture.md` summarizes rustc and where DOIR departs from it):
1. **Query-Based Architecture:** [rustc (`rust-lang/rust`, `compiler/`)](https://github.com/rust-lang/rust)
   - Consult for the query engine (`rustc_middle/src/query`), cycle reporting, the red/green dep graph, entity creation inside queries (`create_def`/`TyCtxtFeed`), the comptime interpreter (`rustc_const_eval`, `Machine` trait), and mono-item collection and codegen units.
2. **Syntax & Semantic API:** [Roslyn (`dotnet/roslyn`)](https://github.com/dotnet/roslyn)
   - Consult for IDE-facing semantic models and the idea behind green/red reuse. DOIR has no separate syntax tree: the parser builds entities directly, and reuse across edits is reparse matching that keeps entity ids, with Salsa-style revisions on entities deciding what re-runs (`roadmap.md` Phases 1–2). Roslyn is lazy and snapshot-based, not dependency-tracked; do not take the query engine from it.
3. **Legacy Implementation:** [DOIR Waterfall Branch (`doir-lang/DOIR/tree/D`)](https://github.com/doir-lang/DOIR/tree/D)
   - Consult for raw semantics, instruction tables (`tools/mizu_gen.d`), and register allocator interval sweeps (`opt/assign_temporaries.d`). The parser is written from scratch; consult `source/doir/parser.d` only for which builder calls each declaration form makes and for the edge cases its tests pin down. We want to maintain the monolithic libECRS based store, whose design rationale is Dahl & Harris, Onward! '25 ([doi:10.1145/3759429.3762622](https://doi.org/10.1145/3759429.3762622)): plain-data components, entity ids in place of pointers, one parent per node, and tags for node kinds.

## Architectural Mandates

1. **Demand-Driven Queries (rustc Model):**
   - The compiler is a collection of pure, memoized queries (`query(Key) -> Value`).
   - Query instances are entities. Their keys, values, dependencies and revisions are components, and every component a query writes is listed in its `Produces` component and removed when the query re-runs with a new value or is evicted.
   - Every semantic pass, type check, lowering, and comptime execution runs on demand.
   - Cycle detection is built into the query engine to report recursion errors cleanly.
   - Comptime reads inside a level are ordered (`C-Order`, `M-Lexical`) and keyed by ⟨entity, lexical position⟩; queries against a frozen level are keyed by entity alone (`L-Freeze`). A level over more than one target adds the target to both keys (`T-Split`).

2. **Entity Ids & Renumbering (`E-Remap`):**
   - Entities are natural-number ids (`EntityId`). Renumbering is allowed.
   - Every renumbering rewrites all holders of entity ids in one step: entity-valued components, attribute values and query entities included, through libECRS's `remapEntities` hooks. It runs only between levels or between edits (matching a reparse), when no comptime frame or comptime memory is live, and `std.meta.entity` values never enter memory (`MEM-Escape`). The legacy corruption (`canon/sort.d` in `tree/D`) came from skipped holders.

3. **Stratified Level Tower (spec Part II §16):**
   - DOIR has no standalone runtime semantics; a level supplies them (`compiler` -> `machine` -> `std` -> source languages).
   - The tower is a DAG of levels, file roots and namespaces made into levels, joined by `compiler.levels.lower_to` edges that carry the passes (`L-Tower`, `L-Lower`).
   - A level declares both halves of its own compilation: `compiler.levels.check(t, name)` adds a check to the semantic analysis run over its own entities (`L-Sema`), and `compiler.levels.lower_to(t, u, passes)` defines its lowering (`L-Lower`). Both name checks and passes the compiler provides or that `compiler.levels.bind_pass(f, name)` binds to a DOIR function (`L-Bind`). A check is a query per entity, run in no order; passes are an ordered pipeline over the store; neither is a compiler edit. A scan reads the tower from the source before ascent (`L-Scan`); never derive it from comptime.
   - Ascent: Type deduction, semantic analysis, and compile-time execution evaluate bottom-up by level.
   - Descent: Optimizations and lowering rewrite from top-down. Lowering retires a level (`L-Erase`): its entities stay queryable but are never read by lower levels.

4. **Abstract Host Services ABI:**
   - Comptime is not bound to VM opcode hacks.
   - Host services (memory allocation, entity queries, type creation, diagnostics) form a C-compatible thunk table.
   - The Mizu VM reaches it through hook instructions whose handlers call the table; native JIT hosts call the same entries as indirect function pointers.

5. **Bootstrap versus Interface (`H-Boot`, spec Part II §11):**
   - `compiler` holds the bootstrap, functions the compiler treewalk-interprets itself before any target code exists (the minimum that builds types and emits bytes), and the floor, what code that cannot name `std` needs: the levels below `std`, and builds without `standard.doir`, since DOIR must not depend on `std` existing.
   - `std.meta` is the boundary: hooks, not code. Each is one `HostServices` entry: a mizu backend reaches it through an instruction, a JIT through a direct call.
   - Prefer `std.meta`. New names go to `std.meta` unless code that cannot name `std` needs them, or they are needed before level 1 can run; any other name left in `compiler` is debt. Keep `compiler` as small as possible.

## Source & Semantics Authority

- `doir.spec.md`: The normative language specification. Rule tags (e.g., `M-Flag`, `R-Unqual`, `L-Stage`, `D-Deduce`) must be cited in code and commits.
- `standard.doir`: The canonical interface specification.
- If code contradicts `doir.spec.md`, the specification is authoritative unless recorded in Part III (Divergences) of `doir.spec.md`.
- `roadmap.md`: The build plan. What it schedules is what gets built.
- `rustc-architecture.md`, `roslyn-architecture.md` and `ir-design.md` are references, not mandates: background and proposals to consult, never requirements. Where one disagrees with the spec, the roadmap or this file, those win.

## Code Style

The compiler is written in D under `-betterC` on LDC, on libfp. These rules are forwarded from libfp's `AGENTS.md` and apply to every D source in this repository.

### Comments

- Keep comments minimal.
  Write one only where the code does something difficult to follow on its own: a non-obvious invariant, a subtle memory or lifetime rule, a workaround for a compiler bug, or why an apparently simpler approach would be wrong.
  Do not restate what the code already says.
- Cap every free-standing comment (a `//` or `/* */` block that is not a documentation comment) at 25 words.
  If it needs more, the code or its documentation should carry the explanation instead.
- Editors here soft-wrap, so write each comment, and each paragraph of a DDoc comment, on a single line rather than hard-wrapping it at a column.
- Do not leave commented-out code, change logs, or notes about what was changed in a comment; those belong in commit messages.
- A comment that implements a spec rule carries that rule tag (`M-Flag`, `R-Unqual`, `L-Stage`, `D-Deduce`), which does not count toward the 25-word cap.

### Documentation

- Put a DDoc comment (`///` or `/** */`) directly above every publicly accessible definition: each public or package-visible function, struct, enum, alias, template, mixin template, and module-level variable.
  Private helpers do not need one.
- Every DDoc comment on a function or template includes an example of its use in an `Examples:` section, as a `---` code block:

  ```d
  /// Memoizes `query(key)`, returning the cached value on a repeat call. Reports a recursion cycle as `CycleError` and leaves the cache empty.
  ///
  /// Examples:
  /// ---
  /// QueryEngine engine;
  /// assert(engine.query(key) == engine.query(key));
  /// ---
  Value query(ref QueryEngine engine, Key key) { ... }
  ```

- Keep examples short, and make them correct against the current API: they should compile and pass as written under `-betterC`.
  Check them with `python3 tools/doctest.py`, which compiles and runs every example and reports public definitions missing documentation or an example.
  With no arguments it checks `reference/*.d` and `source/**/*.d`; pass files and `-I dir` import paths for the modules those sources import.
- A DDoc comment is documentation, not a free-standing comment, so the 25-word cap does not apply to it, but keep it as brief as the definition allows.

### Style

- Prefer plain-data structs operated on by free functions that take them by `ref` (for example `pushBack(arr, x)`, `free(arr)`), rather than methods.
  Use member functions only for operator overloads and for what a language protocol requires to be a member, such as range primitives (`empty`, `front`, `popFront`) or an `alias this` target.
- Prefer fully qualified names to aliasing imports: call `fp.string.free(s)` rather than `import fp.string : stringFree = free;` or `alias stringFree = fp.string.free;`.
  A `static import` keeps a module's names out of scope so every use has to be qualified.
- One module uses another through a `static import`, so every call names its layer (`fp.dynarray.pushBack`, `fp.pointer.notFound`).
  The exception is a `public import` that re-exports names as part of the module's own API.
- Name everything in camelCase.
  Add a trailing underscore only when the plain name is a D keyword (`out_`, `in_`, `with_`).
  Names that mirror `standard.doir` or the spec keep their spec spelling (`std.meta.entity`, `compiler.base_type_t`).
- Indent with tabs.
- Under a `@nogc nothrow:` label, do not repeat those attributes on the declarations it already covers, including struct members and `version` blocks.

### Failure and invariants

- Every function that can fail says in its DDoc how it reports failure (null, `false`, `fp.pointer.notFound`, `fp.pointer.allocationRefused`), and what state it leaves its arguments in; prefer leaving them as they were.
- Never drop the result of a call that can fail: check it, or discard it explicitly with `cast(void)` when failure is impossible or harmless there.
  Tests assert on it.
- When a limit on one value follows from another (such as a bit position), name the constant once, derive the others from it, and `assert` the limit where the value is accepted.
- Put test-only code, such as helper functions and globals the tests use, inside `version(unittest)`.

### Organization

- Where possible, group related definitions into sections (for example: types and layout, queries, creation and freeing, growth, removal), separated by blank lines, and order them so a reader meets a type before the functions built on it.
- Whenever possible, define a function before anything that uses it, so a module reads bottom-up from its building blocks.
  When functions use each other in a cycle, define first the one that more of the module uses.
- Keep a module's unittests in the same order as the code they test.
- Prefer merging a new test case into an existing `unittest` block covering the same section over adding a new block; add one only when no existing block fits.

### Bugs

- If you find a bug while working, fix it, with a test that would have caught it, rather than only reporting it.
  Only when the fix would likely take a long time, report it instead, saying what you found and where.