# IR Design: Directions Beyond SSA

> **Reference, not mandate.**
> This note collects proposals and the reasoning behind them; it obliges nothing.
> `doir.spec.md`, `roadmap.md` and `AGENTS.md` decide what is built, and where this note disagrees with them, they win.
> A proposal binds only once it is written into the spec's Part II as tagged rules or into a roadmap phase.

Proposed changes to DOIR's intermediate representation, drawn from modern IR designs.
Every proposal keeps the libECRS store as the source of truth and lives inside it.
A new IR is entities, relation components for its edges, and tags for its node kinds, all owned by the query that builds them, so removing that query's `Produces` list removes the IR (`roadmap.md` Phase 1); only input commits (a parse, a level freeze) write components no query owns.
The only placement rule is that IR entities stay out of source-visible relations (block contents, scopes), since `std.types.field_count` and name lookup read those.

---

## 1. Where DOIR stands

- Bindings are SSA (`SSA`), and control flow is already structured: `std.if` yields a merged value, and `std.while`/`std.for` take block bindings (`standard.doir`).
  This is most of the way to gated SSA / RVSDG.
- **Gap 1: blocks have no explicit inputs or outputs.**
  Loop-carried values leave SSA.
  In `test.doir` the `while` counter goes through a stack cell, as `B-Loop` requires, where a block parameter would keep it in a register.
- **Gap 2: runtime effect order is implicit.**
  Lexical order is the only ordering of effects (`R-Order`, `C-Order`), so no pass can reorder or see past a `store`.

---

## 2. Program Dependence Webs → RVSDG block semantics

The original PDW (γ/μ/η gating plus control dependence) is not worth building.
Its refined form, RVSDG (regions with typed inputs and outputs; γ = if, θ = loop), maps onto DOIR blocks with two changes.

**Block parameters and results.**
`std.while`/`std.for` bodies get explicit loop variables, one in and one out per iteration (θ).
`std.if` outputs are γ exits.
Pinning workarounds disappear, and loop return types become derivable.
A block's free variables are computed by a capture query, not written in syntax.

**State tokens.**
Effectful calls thread a state value, making effect order a data edge.
Tokens are internal IR, not syntax, so they need no spec rule; they enforce `C-Order` within a target and `T-Order`'s bridge barrier across targets (`roadmap.md` Phase 7).
Use several tokens (per memory region; entity store vs. runtime memory) so ordering is only as strict as needed.

**Payoff:**
- A region query depends only on its declared inputs, so early cutoff is precise.
- A γ with a `Comptime` condition reduces to one branch, and a θ with comptime trip count unrolls, exactly.
- DCE, hoisting and CSE become graph operations rather than dataflow analyses.

**Limits.**
Keep regions an ordered tree; do not move to sea-of-nodes (V8 left it in 2025 over compile time and debuggability with effectful code).
Below the machine level, `jump_to`/`jump_to_if`/`label` remain a plain CFG.

---

## 3. E-graphs → an aegraph mid-end at descent

Use Cranelift's acyclic e-graph (aegraph), not full equality saturation (egg/egglog).
It is a descent-time query over pure code.

**Fit:**
- Levels contribute rewrite rules, as they already contribute semantics: `std` supplies algebraic identities, a backend supplies instruction-selection patterns.
- Lowering is extraction under the target's cost model.
  A build names a set of targets (`T-Value`), so there is one e-graph and one extraction per target.
- Admission is `Pure` (kept off modifiers by `M-Impure`).
  Everything else stays in a fixed skeleton of the region tree plus state tokens, so §2 is a prerequisite.

**Clashes and resolutions:**
- Entity identity is observable (`std.meta.entity_of`, attributes, `VirtualReg`, `share_register`, `pin_register`).
  E-nodes and e-classes are entities of the main store, tagged `ENode`/`EClass`: an e-node's operation component points at e-class entities, and each e-class carries a union-find `EClassParent`, which is single-parent.
  They sit in no source-visible relation, so reflection never reaches them, and the aegraph query owns them, so they are removed when it is evicted.
  Extraction writes fresh lower-level entities; `L-Erase` retires the originals.
  E-graph churn makes `compact` (an `E-Remap`) at the level boundary worthwhile.
  Pinned, aliased and reflected entities are opaque leaves.
- Saturation is not incremental: one coarse query per function or region, keyed by region content.
- User-contributed rules risk non-termination: rewrite once at insertion with a bounded budget.
- Comptime does not need it; the interpreter folds.

---

## 4. Other designs

### 4.1 Strong fits

**MimIR** (Thorin's successor; Leißa et al., POPL 2025).
A graph IR where plugins declare axioms (opaque typed operations) and normalizers (rewrites applied as nodes are built); lowering is plugin-by-plugin.
Types are terms, as DOIR types are bindings.
Model for levels: a level provides a signature plus normalizers, giving §3's rules a home.
Dependent typing offers a formal account of `deduced type` (`D-Deduce`) and `std.types.distinct_copy`.

**MLIR dialect conversion** (the mechanics, not the C++ infrastructure).
DOIR levels play the role of dialects.
- Conversion targets declare which operations are legal after a lowering: `L-Erase` as a checkable property, and the Phase 10 verifier (`T-Legal`).
- `MemoryEffects` interfaces (read/write/alloc/free per resource) are a design for §2's state tokens, finer than one `Pure` flag, and let generic passes reason about operations defined by user levels.
- Regions with block arguments are concrete syntax for §2.

**Swift SIL ownership SSA (OSSA).**
Each value is owned or guaranteed (borrowed), borrow scopes are explicit, and a verifier rejects use-after-consume and leaks.
This makes `V-Move` invalidation and `std.pointers.read_only` IR invariants instead of ad hoc dataflow checks, and makes copy/move elimination nearly free.

**Zig InternPool and Sema.**
Zig's Sema interprets untyped ZIR, running comptime and generic instantiation inline, and emits typed AIR: the closest working analog of DOIR comptime.
- InternPool interns every type and comptime value into one indexed pool.
  Equality is an index compare and instantiations are memoized by key.
  It fits the store and makes `TypeDefinition` identity cheap.
- Per-declaration dependency tracking for incremental compilation faces the same comptime-mutation problems as `C-Order`/`L-Freeze`.

### 4.2 Targeted wins

- **Stable path hashes** (rustc `DefPathHash`, Unison).
  A `PathHash` component on each declaration is the key reparse matching looks up (`roadmap.md` Phase 2) and would key a cross-session cache.
  Renumbering no longer motivates it: query entities are components, which `E-Remap` covers anyway.
  `EntityId` stays the dense storage index.
- **SSA-based register allocation.**
  SSA interference graphs are chordal: optimal coloring in polynomial time, with spilling as a separate pass (Hack).
  Cranelift `regalloc2` is a production reference with live-range splitting.
  Compare against the legacy interval sweep before porting it.
- **On-demand SSA construction** (Braun et al., 2013).
  Promoting `std.stack.allocate`/`load`/`store` to registers needs SSA construction; Braun's algorithm builds it lazily per read, which suits the query engine.
- **ISLE and Crocus** (Cranelift).
  ISLE is a typed term-rewriting language for instruction selection with priorities and overlap checking; Crocus (ASPLOS 2024) checks its rules with SMT.
  If user levels contribute rules, verify them this way (or with Alive2).
- **Datalog over the store** (Soufflé, Ascent, egglog).
  libECRS already has it (`ecrs/datalog.d`): components are relations, and a `Program` writes derived relations into components it owns.
  The `WF-*`/`R-*` rules are effectively Datalog clauses, alias and points-to analysis are natural here, and below the machine level CFG predecessors are a derived relation over `Successors`. egglog would unify analysis with §3's rewrites.

### 4.3 Rejected

- **Sea-of-nodes / Graal IR:** see §2.
- **CPS or ANF as the main IR:** structured blocks plus `Tail` already cover it.
- **LLVM-style opaque pointers:** structural typing (`S-Struct`) already avoids the bitcast noise they removed.

---

## 5. Sequencing

| Order | Proposal                                   | Roadmap point                 | Why then                                                 |
| ----- | ------------------------------------------ | ----------------------------- | -------------------------------------------------------- |
| 1     | Path hashes (§4.2)                         | Phases 1–2                    | Reparse matching keys on them.                           |
| 2     | State tokens (§2)                          | Phase 7                       | `T-Order`'s bridge barrier needs an internal edge to enforce in descent. |
| 3     | MimIR-style level signatures (§4.1)        | Phase 7 (`T-Sig`)             | Shapes how levels declare operations and normalizers.    |
| 4     | Dialect legality as a verifier (§4.1)      | Phase 10                      | Chapter 4 cannot claim levels behave like dialects without a check. |
| 5     | ISLE-style rule DSL (§4.2)                 | Phase 12                      | Chapter 7's students need instruction selection they can read. |
| 6     | Aegraph, SSA allocation, Datalog (§3, §4.2) | Deferred to Chapter 8         | Needs targets, cost models and the §2 skeleton, and no chapter measures transformation order. |
| 7     | RVSDG block parameters, OSSA (§2, §4.1)    | Deferred to Chapter 8         | They change the language, so they wait until written into Part II; until then `std.while` keeps its stack cell (`B-Loop`) and Phase 6 its pinning. |
