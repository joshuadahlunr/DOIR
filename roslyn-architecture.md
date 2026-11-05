# Roslyn Architecture, and Where DOIR Departs From It

> **Reference, not mandate.**
> This note describes Roslyn and suggests how DOIR might depart from it; it obliges nothing.
> `doir.spec.md`, `roadmap.md` and `AGENTS.md` decide what is built, and where this note disagrees with them, they win.

A summary of [dotnet/roslyn](https://github.com/dotnet/roslyn) as an architectural reference for this compiler.
Paths are relative to the Roslyn repository root; `CSharp/` abbreviates `src/Compilers/CSharp/Portable/`.

---

## Part 1: Roslyn

### 1.1 Layers

```
Features / IDE      completion, refactoring, LSP            (out of scope)
Workspaces          Solution → Project → Document snapshots
Compilers           Syntax → Declarations → Symbols → Binding → Lowering → Emit
```

C# and VB share `src/Compilers/Core` (common symbols, emit, `IOperation`).
Every public object is immutable; edits return new snapshots that share unchanged parts.

### 1.2 Syntax: green/red trees

- **Green nodes** (`Core/Portable/Syntax/GreenNode.cs`, `CSharp/Syntax/InternalSyntax`) hold kind, width, children and trivia.
  They have no parent and no absolute position, so they can be shared across edits and between trees.
- **Red nodes** (`SyntaxNode`) are created lazily on navigation.
  They wrap a green node and add a parent and an absolute offset.
- Trees are full-fidelity: whitespace, comments and malformed input are kept as trivia or missing/skipped tokens, so the original text round-trips exactly.
- **Incremental reparse** (`CSharp/Parser/Blender.cs`) feeds the parser old green nodes that lie outside the changed span.
  The parser re-lexes only around the edit and splices old subtrees back in.

### 1.3 Declarations: the cheap per-tree summary

Before any symbol exists, each tree is reduced to a `SingleNamespaceDeclaration`/`SingleTypeDeclaration` skeleton holding names, kinds, member names and syntax references.
`DeclarationTable` (`CSharp/Declarations/`) merges these across trees, so partial types and repeated namespaces become `MergedTypeDeclaration`s.
Adding or removing a tree updates the table incrementally.
Name lookup and "does this type have member X" are answered from this table without binding anything.

### 1.4 Symbols: lazy, write-once slots

- Source symbols (`CSharp/Symbols/Source/`) are created from merged declarations.
  Every expensive property (base type, members, attributes, return type, constant value) is a lazily computed field, published once with `Interlocked.CompareExchange`.
  Concurrent readers either see the final value or compute an identical one.
- `SymbolCompletionState` tracks which `CompletionPart`s of a symbol (attributes, base types, members, ...) are complete.
  `ForceComplete` drives a symbol to full completion and is what the batch compiler calls.
  The IDE never calls it and pays only for what it reads.
- **Cycles are handled case by case, not by an engine.**
  Base-type resolution threads a `ConsList` of symbols already being resolved.
  Constant evaluation tracks fields in progress (`ConstantValueUtils.cs`) and reports a circular-definition error.
  Attributes are decoded in an "early" pass for the few well-known attributes that binding itself depends on.
- **Metadata symbols** (`Symbols/Metadata/PE`) decode referenced assemblies lazily from PE tables.
- **Retargeting symbols** (`Symbols/Retargeting/`) wrap one compilation's source symbols so they can be seen from a compilation with a different core library.
  They are lazy views; nothing is copied until it is read.

### 1.5 Binding: binder chains and bound trees

- A `Binder` is one scope (namespace, type, method, block, lambda...).
  Binders link outward through `Next`.
  `BinderFactory` maps a syntax position to the innermost binder, and `Binder_Lookup.cs` walks the chain outward, checking each scope and its imports.
- Binding a method body produces a **bound tree**: an immutable semantic tree with every name resolved, conversions explicit and types attached.
  Flow analysis (definite assignment, reachability, nullability) runs over it.
- **`SemanticModel`** is the per-tree query API (`GetSymbolInfo`, `GetTypeInfo`, ...).
  `MemberSemanticModel.cs` binds one member on demand and caches the syntax→bound-node map.
  Speculative binding binds hypothetical syntax against an existing model.
- `IOperation` is a language-neutral view over bound trees, used by analyzers.

### 1.6 Lowering and emit

- `CSharp/Compiler/MethodCompiler.cs` visits every method, in parallel: bind → flow-analyze → lower → emit IL.
- Lowering (`CSharp/Lowering/`) is a chain of bound-tree rewriters: `LocalRewriter` desugars most constructs, and further rewriters turn lambdas into closures and async/iterator methods into state machines.
  New types and methods are produced as `Synthesized*Symbol`s.
- `CSharp/CodeGen/CodeGenerator.cs` turns the lowered tree into IL through `ILBuilder`, which handles stack scheduling and peephole cleanup.
  `Core/Portable/PEWriter` serializes metadata and IL into the PE file.
- Lowered trees are temporary.
  They exist per method during emit and are never queryable.

### 1.7 Compilation and incrementality

- A `Compilation` is an immutable value: references, syntax trees and options.
  `AddSyntaxTrees`/`ReplaceSyntaxTree` return a new compilation that reuses syntax trees and declaration-table entries.
  **Symbols and bound trees are not reused**: the new compilation rebuilds them lazily on demand.
- Compilations reference each other (`CompilationReference`).
  A referenced compilation is just another immutable input.
- Diagnostics are collected per phase into `DiagnosticBag`s.
  Analyzers subscribe to an ordered `CompilationEvent` queue and run concurrently.
- **Workspaces** add the real incrementality.
  `SolutionCompilationState.RegularCompilationTracker.cs` keeps an in-progress compilation per project and applies queued "translation actions" (tree added, tree changed).
  The IDE can ask for *frozen partial* semantics before the compilation is finished.
  Out-of-process sync uses a Merkle tree of content checksums.
- **Incremental source generators** (`Core/Portable/SourceGeneration/Nodes/`) are Roslyn's only true dependency-tracked pipeline.
  Each pipeline step keeps a `NodeStateTable` that marks every entry `Cached`, `Modified`, `Added` or `Removed`, and a step is skipped when its inputs compare equal to last run.
  This is the closest in-tree analog to a Salsa- or rustc-style query engine.

### 1.8 What Roslyn is *not*

Roslyn is a **lazy, immutable-snapshot** compiler.
It is not a dependency-tracked query engine.
It has no global memo table keyed by query, no red/green invalidation of semantic results, no general cycle detector and no compile-time execution beyond constant folding.
Incremental generators are the exception.

---

## Part 2: Expected deviations for DOIR

Roughly in order of significance.

### D1. A real query engine has to come from outside Roslyn

`AGENTS.md` mandates memoized `query(Key) -> Value` with built-in cycle detection.
Roslyn supplies the *style* (lazy, pure, write-once results) but not the *engine*.
Better references for the engine are rustc's query system and Salsa: dependency edges recorded during execution, red/green revalidation, and cycle detection on the active query stack.
Roslyn's `NodeStateTable` shows the cached/modified bookkeeping on a small scale.
**Recommendation:** treat "Roslyn model" as the symbol and IDE API design reference (syntax: see D7), and take the engine design from Salsa/rustc.

### D2. The store is mutated during comptime; Roslyn symbols never are

Roslyn's write-once slots rely on each value being a pure function of declarations.
DOIR comptime writes to the store: `M-Flag` changes types in place, `AT-Type` attaches components, `TF-Overload` adds overload set members, and `I-Import` inserts names, visible to the whole scope rather than from a position.
`L-Freeze`/`M-Lexical` then require in-level reads keyed by ⟨entity, lexical position⟩.

- Model each level's comptime effects as an **ordered effect log** (`C-Order`).
  A read of component `C` on `e` at position `k` is a query over the log prefix before `k`.
  After `freeze_level`, the folded result becomes the plain `e`-keyed answer.
- Memoization must not treat `Flags(t)` as a single slot until the level is frozen.
  This has no Roslyn analog.
  The nearest is the early/late attribute split in §1.4.

### D3. ECS store instead of an object graph, so identity is renumberable

Roslyn's identity is object reference: symbols are never renumbered, and caches hold pointers.
DOIR keeps the monolithic libECRS store with natural-number `EntityId`s and permits renumbering (`E-Remap`).

- A Roslyn lazy field becomes "a component computed by a query on first read".
  `SymbolCompletionState` becomes per-entity, per-component readiness.
- Memo tables are not a separate structure: query instances are entities whose keys and values are components, so libECRS's `remapEntities` hooks renumber them with everything else.
  Live `std.meta.entity` comptime values are the remaining holder, which is why renumbering happens only while no VM frame is live.
  Roslyn has no counterpart to this.

### D4. Compile-time execution re-enters the query engine

Roslyn never runs user code during compilation.
DOIR runs the Mizu VM (or a JIT host) inside `evaluate_comptime`, and host-service thunks call back into queries.

- Cycle detection has to see through VM frames.
  A host-service call is itself a query edge, so a comptime block that ends up depending on its own result is reported as a cycle and does not deadlock or recurse forever.
- Results must be deterministic (`H-Det`) and evaluated against target layout (`H-Target`).
  VM-observable state therefore has to come only from query answers, never from host addresses or host iteration order.

### D5. Levels are a tower of compilations, not one compilation

Roslyn has nothing like `L-Stage`.
Its `CompilationReference` is a usable analogy: **level n behaves like a compilation that references the frozen compilations of the levels below it.**
`L-Mono` corresponds to references being one-way, and `L-Freeze` to referenced compilations being immutable.
The difference is that all levels share one entity store, so the separation is a rule enforced on queries, not a separate object graph.
The engine should assert that a query on level n reads levels below n only after they are frozen.

### D6. Lowering writes to the store and the result is kept

Roslyn's lowered trees are temporary.
DOIR descent creates real lower-level entities and keeps the retired ones queryable (`L-Erase`).

- `lower_level(e, n, τ)` is a memoized query, one per target, whose value is the mapping from high entities to low entities.
  Re-running it must yield the same entities, so lowering cannot allocate fresh ids nondeterministically.
- The `Lowered` relation (entity to the targets that retired it) together with a read barrier (lower-level rewrites, allocation and emission never read retired entities) replaces Roslyn's simple "throw the tree away".
- Synthesized entities without syntax are the counterpart of Roslyn's `Synthesized*Symbol`s.
  They need provenance (the source entity they were derived from) so that diagnostics have a location; roadmap Phase 1 gives every created entity a `Provenance` component.

### D7. No syntax tree: the reuse idea, applied to entities

The green/red tree does not carry over.
Green nodes are shared between trees, so a node can have several parents, which the plain-data ECS store cannot represent without duplicated parent components or heap side-structures (Dahl & Harris, Onward! '25, §4.2).
Red nodes add a parent and an absolute offset, which entities already carry as `Parent` and a source span.
The parser therefore builds entities directly, and there is no declaration table (§1.3) or binder between syntax and entities.

What carries over is the reuse idea, at declaration granularity (roadmap Phase 2):

- **Identity, not sharing.**
  On reparse, a declaration matched to the previous parse by a stable key (name path) and a hash of its token text keeps its entity id.
  Unchanged ones are left alone; changed ones have their components replaced and their `ChangedAt` revision bumped.
  No colour is stored: Salsa-style revision checks on query entities decide what re-runs.
  The old-to-new mapping is applied as one `E-Remap` renumbering.
- **Positions out of the dependency graph.**
  Entities store a `SourceSpan` relative to the parent block and an order key rather than an ordinal position.
  Spans are untracked reads, so moving text re-runs nothing; the absolute `SourceLocation` is derived, like a red node's offset, and only diagnostics and the editor read it.
- **Trivia stays in the lexer's token stream**, which the editor reads for highlighting.
  It never becomes entities.

DOIR's grammar is line-oriented assignments with brace blocks, so Blender-style token-level reuse is unnecessary.
Whole-file reparse with matching is enough for v1; reparsing only the innermost changed `{}` block is the next step if parsing itself becomes the cost.
`R-Merge` still corresponds to Roslyn's namespace merging, done as a query over entities rather than a declaration table.

### D8. Name lookup depends on comptime because of imports

The binder chain maps cleanly onto `R-Unqual`/`R-Qual`.
However, `I-Import` makes the contents of a scope depend on comptime, and resolving the import call itself needs name lookup.
Roslyn's `using` directives raise the same problem; Roslyn resolves usings in a separate, earlier, restricted lookup.
DOIR does not restrict the lookup.
An imported file is evaluated to completion and frozen before its importer reads it, like a referenced compilation (D5), so the importer sees its final state; its names are visible to every lookup in the scope (`R-Order`, `I-Import`), a lookup that misses a block's declarations demands the block's imports as queries, and an import whose path depends on its own names is reported as a cycle (`Q-Cycle`; `rustc-architecture.md` D8).

### D9. Back end and diagnostics

- Roslyn's IL codegen is stack-based and irrelevant here.
  Register allocation (`REG-*`, legacy `assign_temporaries.d`) is per function and not incremental below function granularity, so one query per function is the right size.
- **Diagnostics must be part of query results**, not side-channel bags.
  When a memoized result is reused, its diagnostics must still be reported.
  Roslyn avoids the issue by never reusing semantic results across compilations.
- Roslyn's retargeting symbols (§1.4) are the nearest analog of a multi-target build (`T-Value`), but DOIR does not wrap: one entity answers per target through target-keyed queries and per-target components (`T-Split`).

### D10. Concurrency can wait

Roslyn is pervasively concurrent, with lock-free lazies and parallel `MethodCompiler`.
`C-Order` serializes comptime within a level, so parallelism in DOIR only becomes worthwhile in descent (independent functions).
A single-threaded engine first is consistent with the roadmap, provided query values stay immutable once published.

### Out of scope

The Workspaces layer (snapshots, out-of-process checksum sync) and analyzers.
An LSP is planned (roadmap Phase 3), but it reads the live entity store and the query engine rather than snapshots.
From Features, only the IDE-facing semantic model is borrowed; `RegularCompilationTracker`'s in-progress/frozen-partial model is worth revisiting if the editor needs answers while a compilation is still running.
