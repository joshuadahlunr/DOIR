# rustc Architecture, and Where DOIR Departs From It

> **Reference, not mandate.**
> This note describes rustc and suggests how DOIR might depart from it; it obliges nothing.
> `doir.spec.md`, `roadmap.md` and `AGENTS.md` decide what is built, and where this note disagrees with them, they win.

A summary of [rust-lang/rust](https://github.com/rust-lang/rust)'s compiler (`compiler/`) as an architectural reference for this compiler.
Paths are relative to `compiler/` on `main` as of 2026-10.
The query system was recently folded from `rustc_query_system` into `rustc_middle`, so older guides cite stale paths.

---

## Part 1: rustc

### 1.1 Pipeline shape

```
 eager, mutable                     │  demand-driven queries on TyCtxt
                                    │
 lex/parse → expand ⇄ resolve → AST lowering │→ HIR → typeck → THIR → MIR → borrowck → MIR opts
 (rustc_parse) (rustc_expand) (rustc_resolve) │                                    │
                                    │        collect mono items → partition CGUs → codegen
```

`rustc_interface/src/passes.rs` drives the run.
Everything left of the bar runs once, in order, over mutable state.
Its output (`resolver_for_lowering_raw`) is fed into `TyCtxt` as an `eval_always` input.
Everything to the right is a query.

### 1.2 Front end: expansion and resolution are a fixed point

- `rustc_expand/src/expand.rs` and `rustc_resolve` interleave.
  Expanding a macro can introduce items and imports, and resolving a path can unlock the next macro to expand.
  The loop runs until no progress is made.
- `rustc_resolve/src/imports.rs` resolves imports with **determinacy tracking**.
  Each lookup answers `Determined` or `Undetermined` ("a later expansion might still add this name").
  Undetermined imports are retried, and anything still undetermined at the fixed point is reported as an error.
- This phase deliberately stays **outside** the query system.
  Its mutable, order-sensitive state does not fit memoization, and making it incremental is a long-standing open problem.

### 1.3 Identity: session-local ids, stable hashes

- `DefId = (CrateNum, DefIndex)` (`rustc_span/src/def_id.rs`) is a dense integer valid **only within one session**.
  Ids may come out differently on the next run.
- Persisted data never stores `DefId`s.
  It stores `DefPathHash`, a stable hash of the item's path (`crate::mod::Type::method`), and translates back to `DefId` when loading.
- Within a body, `HirId = (OwnerId, ItemLocalId)` (`rustc_hir_id`) numbers nodes relative to their owning item.
  An edit inside one function therefore never renumbers nodes in another.
- Spans are hashed relative to their owner, so inserting a line above an item does not invalidate the item's results.
- Results are fingerprinted with a stable hash (the `StableHash` trait).
  A fingerprint does not depend on pointer values, interning order or `HashMap` iteration order.

### 1.4 The query system

- Queries are declared in `rustc_middle/src/queries.rs` (`query typeck_root(key: LocalDefId) -> &TypeckResults`, ...).
  Providers are plain functions registered per crate, with separate local and extern providers.
  Callers write `tcx.typeck_root(def_id)`.
- Memoization uses per-query caches (`rustc_middle/src/query/caches.rs`: `VecCache` for dense integer keys, `DefIdCache`, `DefaultCache`, `SingleCache`).
  Values are arena-allocated and immutable.
- **Cycle detection** (`rustc_middle/src/query/job.rs`, `rustc_query_impl/src/handle_cycle_error.rs`).
  Every running query has a `QueryJob` on an active stack.
  Re-entering a key that is already running yields a `QueryCycle`, reported as E0391 ("cycle detected when ... which requires ...").
  Individual queries can opt into a `handle_cycle_error` fallback value instead of a hard error; `layout_of` does this for infinitely sized types.
  In parallel mode, `QueryLatch` plus a deadlock handler turns cross-thread waits on cycles into the same error.
- **Modifiers** on a query: `eval_always` (an input, never cached), `cache_on_disk` (persisted between sessions), `feedable` (the value may be supplied by another query, see 1.6), `arena_cache`, `handle_cycle_error`.

### 1.5 Incremental: the red/green dep graph

- `rustc_middle/src/dep_graph/graph.rs` records, while a query runs, every dependency node (`DepNode`) it reads (`read_index`).
  Each query's result is hashed.
- On the next session, `try_mark_green` checks a node by recursively checking its dependencies.
  If every input is unchanged (green), the old result is reused without re-execution.
  It is loaded from the on-disk cache (`query/on_disk_cache.rs`) if the query was persisted; otherwise it is recomputed only when demanded.
- **Early cutoff.**
  If a node is re-executed and its new fingerprint equals the old one, it is marked green anyway, and the change stops spreading to queries that depend on it.
- **Firewall queries.**
  Coarse inputs are split into small projections (`hir_owner`, one per item) so that a dependent reads only the part it needs.
  An edit to one item then invalidates only that item's projection.
- **Side effects.**
  Diagnostics emitted while a query runs are recorded as `QuerySideEffect::Diagnostic` and replayed whenever the cached result is reused.

### 1.6 Creating definitions from inside queries

Most queries only read.
A few must create new items, such as anonymous constants and synthetic bodies.
`TyCtxt::create_def` (`rustc_middle/src/ty/context.rs`) allocates a fresh `LocalDefId` and returns a `TyCtxtFeed`, through which the creating query supplies the new item's `feedable` query results directly.
The dep graph records this through `with_feed_task`.
Feeding is tightly restricted: the type itself warns against adding new ways to create a `TyCtxtFeed`.
A query that creates items must create the same ones, in the same way, every time, or incremental reuse breaks.

### 1.7 Middle: HIR → THIR → MIR

- `rustc_ast_lowering` desugars the AST into HIR, organized by owner.
  `rustc_hir_typeck` type-checks each body (`typeck_root`).
  Traits are solved in `rustc_trait_selection`.
- `rustc_mir_build/src/builder` builds THIR (a fully typed tree) and then MIR, a CFG of basic blocks over locals.
  Borrow checking (`rustc_borrowck`) and optimizations (`rustc_mir_transform`) run on MIR.
- MIR goes through a chain of `Steal<T>` queries (`mir_built` → ... → `optimized_mir`).
  Each stage takes ownership of the previous stage's body, and reading a stolen value afterwards is a hard error.
  This saves copying, at the cost of strict ordering between the stages.
- There are **separate MIR bodies for runtime and for compile-time evaluation** (`optimized_mir` vs `mir_for_ctfe`), because the two have different optimization and validation requirements.

### 1.8 Compile-time evaluation (CTFE)

- `rustc_const_eval/src/interpret` is a MIR interpreter, `InterpCx<M: Machine>`.
  The `Machine` trait (`interpret/machine.rs`) parameterizes the interpreter's policy: memory hooks, how calls are dispatched, which intrinsics exist and what is allowed.
  The compiler's `CompileTimeMachine` (`const_eval/machine.rs`) and the Miri tool share one interpreter core.
- Evaluation is itself a query: `eval_to_allocation_raw` / `eval_to_const_value_raw`, keyed by `GlobalId` together with the type environment.
  The interpreter calls back into queries (`layout_of`, `mir_for_ctfe`, other constants), so constants that depend on each other cyclically surface as ordinary query cycles.
- Memory is **abstract**: allocations carry provenance and use the target's data layout (`rustc_abi`).
  Evaluation results are therefore target-correct and independent of the host.
  Pointers into host memory cannot exist.
- CTFE is deliberately **pure**: it cannot create types, items or side effects in the program.
  Allowing const evaluation inside types (`generic_const_exprs`) is still unstable, largely because of the query cycles it creates.

### 1.9 Back end

- `rustc_monomorphize/src/collector.rs` walks from roots (main, exported items) and collects every concrete function and static that is needed, instantiating generics.
  `partitioning.rs` groups them into codegen units (`collect_and_partition_mono_items`).
- `rustc_codegen_ssa` defines backend traits that are generic over LLVM, Cranelift and GCC.
  Each codegen unit becomes an object file.
  A CGU whose inputs are all green reuses last session's object file as a *work product*.
- Compiled crates write `rmeta` metadata, which consists of serialized query results.
  Downstream crates answer queries about upstream items through extern providers (`rustc_metadata/src/rmeta/decoder/cstore_impl.rs`), decoding lazily.

---

## Part 2: Expected deviations for DOIR

rustc is a much closer model than Roslyn for the query engine.
These are the points where DOIR's semantics push it outside rustc's design, roughly in order of significance.

### D1. Comptime mutates the store; rustc CTFE is pure

This is the biggest gap. rustc's CTFE only computes values: it creates no types and causes no effects.
DOIR comptime writes to the store: `M-Flag` changes types in place, `AT-Type` attaches components, `TF-Overload` adds overload set members, `I-Import` inserts names, though not at a position: an import's names are visible to its whole scope, and `std.types.distinct_copy`/`M-Ctor` create entities.
`L-Freeze`/`M-Lexical` require in-level reads keyed by ⟨entity, lexical position⟩.

- In rustc terms, a level's comptime is closer to the **eager expand/resolve phase** (§1.2) than to CTFE: mutable, ordered and outside memoization.
  A DOIR level has the shape *ordered effect phase → freeze → pure queries*, which matches rustc's *resolver → `TyCtxt`* split, repeated once per level.
- The in-level phase can still use queries if each level's effects form an **ordered log** (`C-Order`).
  A read of `C(e)` at position `k` is then a query over the log prefix before `k`, and `freeze_level` folds the log into the `eval_always` input of the pure phase.
  The cost is a read keyed by ⟨e, k⟩ for every comptime read within the level, so `k` is an order key (D4).

### D2. Entity creation inside queries is the normal case, not an exception

rustc limits `create_def`/feeding to a few special cases (§1.6).
In DOIR, comptime type constructors, lowering (`L-Erase`) and register-alias bookkeeping all create entities as a matter of course.

- An entity created inside a query needs an id that is the same every time the query runs: derive it from (creating query key, sequence number within that query), as `create_def` derives a `DefPathHash` from the parent and a disambiguator.
  Do not take the next free integer.
- An entity created by a query and its components should be published together, the way `TyCtxtFeed` publishes a new item's query results, so the dep graph sees one write.

### D3. `E-Remap` versus session-local ids

rustc never renumbers ids within a session.
Its answer to "ids are unstable" is to store stable hashes (`DefPathHash`) in persisted data and dense ids everywhere else.
DOIR wants dense, renumberable `EntityId`s within the session, and every holder must be rewritten (`E-Remap`).

- If incremental compilation across sessions is ever wanted, adopt rustc's split: a stable path hash per entity for persistence, and `EntityId` only in memory.
  Renumbering then never touches persisted data.
- Within a session, DOIR stores query instances as entities (key, value, `DependsOn`, `Produces` and revisions as components), so memo tables are part of the store and libECRS's `remapEntities` hooks renumber them.
  The remaining hazard is `std.meta.entity` values in live VM frames, so renumber only when no query is running and no VM frame is live: between levels, or between edits.

### D4. Lexical positions need owner-relative keys

The ⟨e, k⟩ keys from `L-Freeze` behave like rustc's spans: if `k` is an absolute offset, inserting one line changes every key below it.
DOIR goes one step further than rustc's owner-relative `ItemLocalId`: `k` is an order key, not an ordinal.
A declaration kept by reparse matching keeps its key and an inserted one gets a key between its neighbours, so an insertion invalidates no other declaration's reads, even in the same block (`roadmap.md` Phases 1–2).

### D5. Levels resemble a crate graph that shares one store

There is no level tower in rustc, but the crate DAG is a close analog.
An upstream crate is fully compiled and frozen before its dependents, which see it only through immutable query answers (rmeta, extern providers).
That is `L-Stage` + `L-Mono` + `L-Freeze`.
The differences:

- All DOIR levels share one entity store, so the separation is a rule enforced on queries, not a separate serialized artifact.
  The engine should assert that a query on level n reads levels below n only after they are frozen, which corresponds to rustc's local/extern provider split.
- Descent runs in the opposite direction: lowering level n writes **into** lower levels (D6), which an upstream crate never receives from a downstream one.

### D6. Lowering keeps retired entities; rustc steals them

rustc's MIR pipeline uses `Steal` so that each stage is consumed exactly once.
DOIR's `L-Erase` is the reverse: retired entities stay queryable, but lower levels must not read them.

- `lower_level(e, n, τ)` is a memoized query, one per target (`L-Erase` retires per target), whose value is the mapping from high entities to low entities, with created entities following D2.
- The read barrier ("lower-level rewrites, allocation and emission do not read `Lowered` entities") is a check in the dep graph: a query at level < n for target τ that records a read of a level-n node whose `Lowered` relation holds τ is a bug.
  It plays the role `Steal` plays in rustc, but as a check on reads rather than a transfer of ownership.

### D7. The comptime VM is a `Machine`, and host services are its hooks

rustc's `InterpCx<M: Machine>` maps closely onto `AGENTS.md`'s host-services ABI.
The `Machine` hooks (`call_extra_fn`, intrinsics, memory access hooks) correspond to the thunk table.
Mizu and a JIT host are two implementations, as `CompileTimeMachine` and Miri are.

- **Keep rustc's abstract memory.**
  Comptime pointers carry provenance and use target layout, so `H-Target` and `H-Det` follow from the design and do not depend on discipline.
  A JIT host executing native code can hand out real host addresses, which breaks `H-Det`.
  It needs either the same abstract-memory rule or a check that no host address escapes into a binding.
- Host-service calls are query reads.
  As in CTFE, a comptime block that ends up depending on its own result then becomes a query cycle reported with the full chain.
- rustc evaluates runtime code and comptime code from separate bodies (§1.7).
  DOIR needs this only for machine primitives: comptime runs the level's own bindings (`C-Call`), with no separate optimized copy, except that a prototype a machine supplies is run by the host with the spec's semantics, never by interpreting the machine's body (`C-Interpret`).

### D8. Imports: borrow determinacy tracking

`I-Import` combined with `R-Order` has the same structure as rustc's expand/resolve loop: an import adds names to a scope, and resolving the import itself needs lookup in that scope. rustc solves this with `Determined`/`Undetermined` answers and a fixed point (§1.2).
DOIR needs neither, because an imported file behaves like an upstream crate (D5): it is evaluated to completion and frozen before the importer reads it, and the importer sees only its final state.
The names an import adds are visible to every lookup in the scope, whatever its position (`R-Order`), and the imported file's comptime effects never interleave with the importer's (`C-Order`).
A lookup that misses a block's declarations demands the block's imports, as a forward reference demands a declaration, and so cannot report a false "not found".
An import whose path depends on the lookup it would answer, or a pair of files that import each other, is an ordinary query cycle (`Q-Cycle`) and is reported with its chain.

### D9. Smaller points

- **Syntax.** rustc has no green/red trees or incremental reparsing: it reparses whole files and relies on owner-relative ids and hashing for incrementality.
  DOIR does the same, with reparse matching that keeps entity ids; green trees are ruled out, since their shared multi-parent nodes do not fit the store (roadmap Principle 6, Phase 2).
- **Diagnostics** should be recorded as query side effects and replayed when a cached result is reused (§1.5), not written straight to stderr (roadmap Phase 1).
- **Several targets per build** (`T-Value`), unlike rustc's one target per session.
  Layout and comptime queries of a level that reads a machine signature carry the target in their key (`T-Split`), and per-target components (`VirtualReg_τ`, `PhysicalReg_τ`) and per-target entries of the `Lowered` relation sit side by side in the one store.
- **Monomorphization.**
  `SharedBody` and `D-Deduce` call-site solving map onto the mono-item collector.
  Collection follows descent, starting from exported functions.
- **Codegen units.**
  Register allocation (`REG-*`) works per function, so one function per incremental unit is the right size.
  Work-product reuse (§1.9) corresponds to caching emitted bytes per function.
- **Parallelism.** rustc's parallel query mode (`QueryLatch`, deadlock handler) can come later.
  `C-Order` serializes comptime within a level anyway, so parallelism pays off mainly in descent.

### D10. Where rustc and Roslyn each fit

The query engine, cycle reporting, incremental compilation, CTFE and backend structure should be modeled on rustc.
Roslyn is still the better reference for IDE-facing semantic APIs, which the LSP (roadmap Phase 3) borrows; DOIR has no syntax tree to model on it.
`AGENTS.md` and `roadmap.md` cite rustc for the engine and Roslyn for the editor.
