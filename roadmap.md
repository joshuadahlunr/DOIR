# Roadmap: Query-Driven DOIR Compiler

Phased construction plan for the query-driven DOIR compiler.

Architectural reference: [rust-lang/rust](https://github.com/rust-lang/rust) (`compiler/`; see `rustc-architecture.md`).  
Data-structure reference: Dahl & Harris, *An Argument for the Practicality of Entity Component Systems as the Primary Data Structure for an Interpreter or Compiler*, Onward!
'25 ([doi:10.1145/3759429.3762622](https://doi.org/10.1145/3759429.3762622)).  
Editor reference: [dotnet/roslyn](https://github.com/dotnet/roslyn) (IDE semantic model and the green/red reuse idea only; DOIR parses into the entity store, not a separate syntax tree).  
Legacy behavior reference: [doir-lang/DOIR/tree/D](https://github.com/doir-lang/DOIR/tree/D).  
`rustc-architecture.md`, `roslyn-architecture.md` and `ir-design.md` are references, not mandates: a phase that cites one adopts only the part it names, and where one disagrees with this roadmap or `doir.spec.md`, the roadmap and spec win.

---

## Architectural Principles

1. **Pull, Don't Push:** Results are requested via memoized queries (`query(Key)`), calculated on demand, and cached.
   A query instance is itself an entity: its key, value, dependencies and revisions are components, so the store holds the engine's state along with the program's.
2. **Names Denote Bindings; Registers Are Internal:** Source declarations bind entity ids (`EntityId`, a natural number) representing bindings.
   Virtual registers (temporaries) and physical registers are allocated and coalesced internally.
3. **Levels Are Stratified:** Ascent (sema/comptime) and descent (lowering/emission) are strictly level-indexed (`L-Stage`, `L-Freeze`, `L-Erase`).
4. **Bootstrap Is Not the Interface (`H-Boot`):** `compiler` is the treewalk-interpreted minimum that gets a first implementation off the ground; `std.meta` is the hook surface every comptime host implements once, as `HostServices` entries that a mizu instruction or a JIT call reaches (`H-Hook`).
   `compiler` keeps only that minimum and the floor that code unable to name `std` needs, since DOIR must work without `std`.
   Every other name moves toward `std.meta`, never the other way.
5. **The Editor Is a Consumer, Not an Afterthought:** Source locations, statement-level recovery, and token-level highlighting only pay for themselves if something reads them.
   The LSP is that consumer, and once its comptime-aware features land (Phase 5) it is the strictest test of position-keyed comptime state (`C-Order`, `L-Freeze`).
6. **Components Are the Tree:** The parser builds binding entities directly through the builders (`source/doir/builders.d`).
   There is no separate syntax tree.
   Components stay plain data with entity ids in place of pointers, and a node has one `Parent`: a shared, multi-parent green tree would bring back the duplication and serialization problems the ECS design avoids.
   Node kinds and states are valueless tags, and passes are systems over the entities carrying a component set.
   Every IR lives in this one store: its nodes are entities, its edges are relation components, and every component that was not written by an input commit (a parse and the location pass that follows it, or a level freeze) is owned by the query that produced it.
   Source-visible relations (block contents, scopes) hold only declarations.
   Trivia never becomes an entity.
7. **Edits Preserve Identity:** A reparse keeps the entity id of every declaration it can match to the previous parse and replaces only the components of declarations that changed, so memos keyed by unchanged entities stay valid without any change marking.
   Declaration order is an order key rather than an ordinal, so an insertion reorders nothing else, and source spans are untracked reads, so moving text re-runs only the comptime evaluations that read their own source location (`AT-Source`).
   Absolute locations are derived, and only diagnostics, the editor and those evaluations read them.
8. **A Target Is a Library, Not a Fork:** A backend is an ordinary DOIR namespace over the host ABI (`T-Sig`, `H-Hook`), and the tower is values too: `compiler.levels.make` makes the backend a level, `compiler.levels.check` adds to the semantic analysis a level runs over its own entities (`L-Sema`), and `compiler.levels.lower_to` edges with their own passes lower one level onto another (`T-Value`, `L-Lower`).
   Adding a target means writing a backend and its edges, not editing the compiler, and a build may have several targets at once.
9. **Every Claim Names the Chapter That Measures It:** A design property is stated with the rule tag that defines it and the phase that produces the artifact that tests it.
   A claim with no phase behind it is future work, not a goal.

## Architecture Blueprint

```
                         [ Source Files ]
                                 │
                                 ▼
                      [ Lexer / RD Parser ] ───────► [ Editor Front-End (LSP) ]
                                 │                              ▲
                                 ▼                              │
                  [ Reparse Match: ChangedAt, E-Remap ]         │
                                 │                              │
                                 ▼                              │
                   ┌───────────────────────────┐                │
                   │       Entity Store        │                │
                   │  - EntityId (ℕ) Handles   │                │
                   │  - Component Slot Maps    │                │
                   │  - Query Entities, Spans  │ ── absolute ───┘
                   └─────────────┬─────────────┘    locations
                                 │
                                 ▼
                   ┌───────────────────────────┐
                   │       Query Engine        │
                   │  - Memoized Queries       │
                   │  - Cycle/Recursion Guard  │
                   │  - Revisions, Cutoff      │
                   └─────────────┬─────────────┘
                                 │
               Ascent ───►  [ L-Stage Tower ]  ───► Descent
            (Sema & VM)     builtin: Compiler        (Rewrites & Lowering)
                            Backends τ₁, τ₂ …  (targets: lower_to builtin)
                            Standard            (lower_to each backend)
                            Source Languages    (implicit edges)
                            a DAG, found by the scan (L-Scan)
                                 │
                                 ▼
                      [ Byte Emission / JIT ]  (one artifact per target)
```

---

## Build Phases

### Phase 1: Query Engine & Entity Store
- **Goal:** Implement the memoized query runtime and the entity store for bindings.
- **Reference:** `rustc_middle/src/query` (`QueryJob` cycle stack) and `rustc_middle/src/dep_graph` (early cutoff) in rustc; Salsa's revision scheme (`verified_at`/`changed_at`) for lazy validation; `ecrs/datalog.d` in libECRS, whose `Program` already owns its derived relations and re-evaluates on component `generation`.
  The engine is `source/doir/engine/` (it grew from the former `reference/query.d`, whose linear key scan became a hashtable over the key components); programs use it through the modules directly under `source/doir/`.
- **Deliverables:**
  - Query entities: each query instance is an entity carrying its key, its value, a `Reads` relation to the entities and query entities it read, and an `Outputs` list of the (entity, component type) pairs it wrote.
    Lookup by key is a key component array sorted into a hashtable; it is rehashed after a renumbering.
    Memo tables are therefore ordinary components, and `E-Remap` covers them through libECRS like any other.
  - Revisions instead of colours: a global revision bumped once per batch of input changes; `ChangedAt` on each input entity (source declarations and blocks), set when an input commit replaces its components; `Verification` and `ChangedAt` on each query entity.
    A demanded query verified in the current revision is reused.
    Otherwise it is reused if no dependency has `ChangedAt` after its `Verification`, and re-run if one has.
    A re-run whose value equals the old one keeps its old `ChangedAt` (early cutoff), so its dependents still verify.
    Validation is lazy: an edit walks no dependency edge.
  - Ownership: when a query re-runs, the components in its `Outputs` list are removed before it runs again; when it is evicted, they are removed along with the entities it created.
    Overlays (analyses, `VirtualReg`, interned types) and graph IRs (the interference graph, and any e-graph a later phase builds) are owned this way.
  - Stable created ids: an entity a query creates is identified by (query entity, creation sequence number), as rustc's `create_def` derives a `DefPathHash` from parent and disambiguator.
    A re-run hands back the same entity for the same sequence number, so a value holding created ids compares equal and early cutoff still fires; entities a re-run no longer creates are removed.
    A created entity carries a `Provenance` component naming the entity it was derived from, so a diagnostic about it resolves to a source location.
  - Dependency granularity: a dependency is on a whole entity, so a query that reads only `x`'s `Name` re-verifies when `x`'s value changes, and early cutoff absorbs the cost.
    Per (entity, component type) dependencies are the refinement if profiling shows the extra re-runs matter.
  - Cycle detection: a stack of active query entities; a demand for a query already on the stack reports the cycle (`Q-Cycle`).
    A query kind may instead declare a cycle fallback, as rustc's `handle_cycle_error` does: structural equivalence assumes a pair under comparison equal, so a recursive type compares equal to itself (`S-Struct`, `TF-Self`).
  - Diagnostics as query results: a diagnostic emitted while a query runs is stored on its query entity and replayed whenever the memo is reused, so a cached answer reports the same diagnostics as a fresh one.
  - `EntityId`: Natural-number entity ids, with a renumbering primitive that rewrites every entity-storing component (attribute values and query entities included) in one step through libECRS's `remapEntities` hooks, run only when no comptime value is live: between levels, and between edits when a reparse maps old ids to new (`E-Remap`).
  - The binding components of `doir.spec.md` Part II §1 (`Name`, `SymbolName`, `Parent`, `Block`, `TypeOf`, `TypeDefinition`, `Alias`, `Pointer`, `FunctionInputs`, `FunctionReturn`, `Call`, `ConstantVal`, `Rank`, `Flags`, `On`), the internal register components indexed by target (`VirtualReg_τ`, `PhysicalReg_τ`; a single-target build has one index), and the `Lowered` relation from an entity to the targets that retired it.
  - Positioned effect logs: comptime-mutable state (`Flags`, attributes, an overload set's `Overloads`) is a log of ⟨position, effect⟩ entries, never overwritten in place.
    A read at position k folds the entries before k in position order (`C-Order`, `M-Lexical`, `L-Freeze`), so demand may evaluate a forward-referenced declaration early (`R-Order`) without an earlier read seeing its effects.
    `freeze_level(n)` folds each log once into the plain component that cross-level queries read by entity alone.
    Positions totally order the declarations of each file.
    Positions are order keys, not ordinals: a declaration kept across a reparse keeps its key, and an inserted one gets a key between its neighbours, so an insertion does not reorder every later log entry.
    Logs are libECRS components with `remapEntities` hooks, so renumbering covers them (`E-Remap`).
  - Imports as finished files (`I-Import`): an import is a query keyed by the file and the importing level, whose value is the imported file evaluated to completion and frozen, its logs folded as `freeze_level` folds a level's, so the importer reads its entities by entity alone and its effects never enter the importer's logs.
    Two levels that import one file each get their own copy (`L-Tower`).
    Its names are visible to every lookup in the importing scope (`R-Order`): a lookup that misses a block's declarations demands that block's imports, as a forward reference demands a declaration.
    An import whose path depends on the lookup it would answer, or two files that import each other, is a cycle (`Q-Cycle`).
    Editing an imported file re-runs its import query, and early cutoff stops at importers whose reads of it are unchanged.
- **Verification:** Recursive and mutually dependent queries resolve or report cycle diagnostics without stack overflows; a renumbering leaves every query answer unchanged up to the permutation; a read before a modifier's position sees the type unmodified even when demand evaluated the modifier first; a read of an imported type on any line, even above the import, sees every modifier the imported file applied; changing one declaration re-runs only the queries that read it, and a re-run query whose value is unchanged does not re-run its dependents; a re-run hands back the same ids for the entities it creates; evicting a query removes everything in its `Outputs` list; a reused memo reports the same diagnostics as the run that produced it.

### Phase 2: Parsing into the Entity Store
- **Goal:** A new, resilient parser, written from scratch for the query architecture, that builds binding entities and their components directly, with a source location on every entity it creates.
- **Reference:** `doir.peg` is the grammar; `tests/doir_check.py` (pe over `doir.peg`) is the conformance oracle.
  `source/doir/parser.d` in `tree/D` is not a base to port: consult it only for which builder calls each declaration form makes and for the edge cases its tests pin down.
- **Deliverables:**
  - A lexer producing a token stream that both the parser and the LSP's highlighting read; the parser's leaves trivia out, since trivia is the gap between the tokens around it, and highlighting asks for it.
    None of its decisions needs the parser's state, so it lexes the whole file before parsing starts.
    The lexer decides what a token is: identifiers and keywords, constants (a `RawString` closed by the run of quotes that opened it), comments, and `Newline` as a token of its own, so a newline inside a `LongComment` is never one.
    It reads a `language` body (`matching_braces`) and a `SourceInfo` as single opaque tokens, since neither is made of DOIR tokens.
    Whether a `Newline` is a `Terminator` depends on the production (`x : T` then `= 5` on the next line is one assignment, and newlines inside `(…)` are whitespace), so the parser decides it, skipping newlines where `doir.peg` has `_` and not where it has `wsc`.
    Characters below `0x80` are classified without decoding UTF-8 or searching the Unicode tables, which identifiers would otherwise spend most of the lexing time on.
    The commit keeps no token array after it finishes: highlighting re-lexes what it shows (Phase 3).
  - A recursive-descent parser over that stream and `source/doir/builders.d`, rule names matching `doir.peg` so the two can be diffed.
    Each declaration form becomes builder calls (`pushDeclaration`, `pushConstant`, `pushCall`, and the `Lookup*` components for names resolved later), with names interned by `source/doir/strings.d`.
  - Parsing is an input commit, not a memoized query: like a Salsa input or a rustc `eval_always` query, the edit step reparses the file, matches declarations, writes the parsed components, and sets `ChangedAt` on what changed.
    Matching comes before building: the parse first yields a record per declaration (its key, its hash and its token range), and the builders run only for declarations that are new or whose hash changed, parsing their token range again, so a reparse that changes nothing writes nothing to the store.
    Blocks are still descended, since a declaration's hash leaves out its nested declarations.
    A rebuild writes into the declaration's old parts (its in-place function types and parameters) in order, so their ids survive it; a declaration whose hash is unchanged but whose text moved inside it (a comment) is rebuilt that way without being marked changed, so its parts' spans follow the text.
    Parsed entities are inputs and belong to no query's `Outputs` list, so no re-run can remove them.
    A matched declaration whose text is byte-for-byte unchanged, nested declarations included, and whose order key is kept, is skipped with everything inside it: nothing below it is matched, keyed or written but its own span's offset, so an edit costs the commit only the path of blocks down to it, beside the lexing and parsing of the file.
  - Each declaration gets its lexical position, an order key, when the commit assigns keys after reparse matching, giving the total order within a level that the positioned effect logs and ⟨entity, position⟩ comptime keys need (`C-Order`, `M-Lexical`).
  - Identifier and keyword tables generated from `doir.peg` (`UnicodeIdentifierStart`, `UnicodeIdentifierContinue`, `Keywords`) by a script in `tools/`, so they match the grammar exactly.
  - Locations: every parsed entity gets a `SourceSpan` component, a view (offset from its parent block's start, length) into the file's single source string.
    Absolute locations are not stored: a diagnostic, the editor or an `AT-Source` evaluation derives one when it asks, by adding the spans up the `Parent` chain to the file's root block and finding the line in a table of line starts the file computes on first use after each commit.
    Spans are untracked: no query records a dependency on `SourceSpan`, and a diagnostic names the entity it is about and resolves its location only when reported.
    Moving text therefore invalidates nothing, even within one block, where it does change the spans after it.
    The one tracked read is comptime's: `std.meta.source_location.get` and its siblings (`AT-Source`) depend on the file's text, because a metaprogram can fold a line number into a value, so moving text re-runs those evaluations and nothing else.
    A declaration with a source annotation gets the annotation's `LineColumnRange` (`AT-Source`), which overrides the derived location.
    None of these holds an entity id, so `E-Remap` leaves them alone.
    The file contents and path they slice are held by the file's input entity and outlive its parsed entities.
  - `language` blocks (`I-Language`): the grammar keeps them, and the parser skips the matched braces and reports an `I-Language` error, since this compiler registers no frontend.
    They create no entities.
  - Statement-level recovery: a failed assignment reports a libdiagnose diagnostic at the furthest position reached, skips to the next `Terminator` at the same brace depth (or the enclosing `}`), and parsing continues, so a file with an error still yields its other declarations.
  - File roots: the commit records each file's root block entity; queries read it as an input.
  - Reparse matching: names are single-assignment within a block (`WF-Unique`), so a named declaration's key is its name path, stored as a `PathHash` (`ir-design.md` §4.2).
    A name repeated in the same block, as a namespace reopened there is (`R-Merge`, as `reference/machine.doir` reopens `machine`), adds its occurrence index among the same-named siblings to the key.
    A declaration's hash covers its non-trivia tokens, with each declaration nested in its block replaced by a placeholder, so an edit inside a block changes the nested declaration's hash and not the enclosing one's, and a comment changes no hash.
    Unnamed `_` declarations have no key: within each block, the old and new sequences of them are aligned by that hash (a longest-common-subsequence diff, computed by Myers' algorithm after the common prefix and suffix are stripped, so a small edit to a long block costs near-linear time rather than quadratic), and aligned pairs match.
    Matching runs before order keys are assigned, so a matched declaration carries its order key over and an unmatched one gets a key between its neighbours; when matched declarations are reordered, those along a longest run of increasing keys keep theirs and the rest are re-keyed and marked changed.
    A declaration whose key and hash match the previous parse keeps its entity and components untouched; one whose key matches but whose hash differs keeps its entity, has its parsed components replaced, and gets `ChangedAt` set to the new revision; an unmatched one is a new entity.
    Old entities left unmatched are removed, and a block that loses or gains an entry gets a new `ChangedAt`, so lookups that found a removed name, or that a new name now shadows (`R-Shadow`), re-run.
    Matched declarations are written into their old entities, so the commit needs no `E-Remap` renumbering.
- **Verification:** Parse `standard.doir`, `test.doir`, and `test_call.doir` into binding entities.
  A differential test runs the parser and `doir_check` over the corpus plus a set of malformed files: both accept and reject the same files, and agree on the statement of each syntax error.
  Every parsed entity's derived `ByteRange` slices back to the text of its declaration.
  Reparsing an unchanged file changes no id and no `ChangedAt`; editing one declaration's value changes only that declaration's `ChangedAt`; inserting a blank or comment line above a declaration leaves its order key and `ChangedAt` unchanged and re-runs no query except evaluations that read their own source location (`AT-Source`); editing a comment inside a declaration changes no `ChangedAt`; inserting a declaration re-runs only the lookups through its block, and early cutoff stops there unless the new name shadows one; inserting a `_` declaration between two others matches both of them.
  Reparsing an unchanged file makes no builder call.
  A one-line edit to `standard.doir` commits (lex, parse, match, build, locations) in under 5 ms in a release build, measured by `bin/doir --bench standard.doir`.
  A whole-file commit meets it at this size (0.2 ms median on 2026-10-28) and misses it about thirty times over on a million-line file (162 ms), most of it lexing and parsing, which is why Phase 3 makes commits proportional to the edit.

### Phase 3: Editor Front-End (LSP)
- **Goal:** A language server reading the entity store Phase 2 builds while the compiler is still incomplete, whose keystrokes cost in proportion to the edit rather than the file, up to a file of a million lines.
- **Reference:** Roslyn's IDE-facing semantic model (`dotnet/roslyn`, `src/Features`).
  `tests/doir_check.py` already implements the diagnostics, the namespace walk, and the scope map this phase ports onto components.
- **Deliverables:**
  - The `doir_check` rules (`WF-Term`, `WF-Order`, `D-Return`) ported from its AST walk to queries over `Block`, `Parent`, `Name`, and the `Lookup*` components, reporting through libdiagnose at each entity's `ByteRange`.
  - Highlighting from the lexer's token stream (keywords, literals, comments, whitespace), not from the store: trivia never becomes entities.
    Highlighting is requested by range, and Phase 2 keeps no token array, so the server re-lexes the blocks in view; a whole-file array would be about 11 million tokens and 130 MB on the million-line file, three times the text.
  - A position→entity index for hover and go-to, built per block from block-relative spans when a request reaches the block, so an edit invalidates only the index of the block it is in.
  - The server, one for every editor (`doir --lsp`, `source/doir/lsp/`): JSON-RPC 2.0 over stdio with `Content-Length` framing, stdout carrying only the protocol, through bc-fetch's `bc.jsonrpc` and its minimal JSON reader and writer `bc.json`, since `-betterC` has no Phobos; `initialize`, `initialized`, `shutdown`, `exit` and `$/cancelRequest`.
    Positions in the encoding the client offers: `utf-8` when it does, as Neovim does, since the store counts bytes, and otherwise `utf-16`, VS Code's only one, converted a line at a time through the rope's line index.
    Incremental `didOpen`/`didChange`/`didClose`, each edit a `commitEdit`, a burst of changes drained before one publish, and an open document shadowing its file on disk for imports (`I-Import`).
    `publishDiagnostics` from `reportSyntaxErrors` and the ported checks, each with its rule tag as `code`, its hint in the message and its other annotations as `relatedInformation`.
    Semantic tokens by range and whole file from the lexer; `documentSymbol` and `foldingRange` from `Block`, `Name` and `SourceSpan`; `definition` and a plain `hover` through the position→entity index and the `Lookup*` components.
  - Where the server stands (2026-10-29): `source/doir/lsp/` has position conversion (`positions`), semantic tokens lexed as they are encoded (`tokens`), the session its handlers share (`session`), the store lookups they make (`store`), a module per feature (`features`), and the server (`server`): lifecycle, both encodings, incremental sync drained before each publish, diagnostics with their rule tag as `code` and hint in the message, semantic tokens by range and whole file, `documentSymbol`, `foldingRange`, `definition` and `hover`, the last two resolving a name outward through the enclosing blocks and then down a dotted path, each block's entries found through a query per block indexing them by name (`doir.names`).
    Hover shows the declaration up to the brace opening its block, then its documentation as `doir_doc` reads it: the comment lines directly above it and its trailing comment.
    `selectionRange` grows from the identifier through the enclosing declarations to the file, and `signatureHelp` lexes back to the innermost open call and lists the parameters of the function type its callee resolves to, the active one counted past deduced parameters, which a call never writes (`D-Deduce`).
    `completion` offers the names of every block enclosing the cursor, an inner one shadowing an outer, and the keywords, or after `a.` the entries of the block `a` resolves to, each through the block's name index; `inlayHint` names the parameter each argument of a call in the range binds, walking only the declarations the range overlaps.
    Comments, which are trivia, fold by a lexing pass, each run of comment-only lines and each block comment over several lines.
    Formatting a file the lexer cannot finish shows a warning naming the line, since its empty answer would otherwise look ignored.
    Pull diagnostics (`textDocument/diagnostic`) wait: both editors take pushed ones, and the server already checks only open documents.
    Definition and hover across files wait for the parser to write `Imports` and for a level the server can evaluate them in (`I-Import`).
    Formatting, whole-file, by range and on typing `}`, comes from the lexer's tokens (`doir.format`), so comments survive and a file with parse errors still formats: it indents a tab per open bracket, spaces punctuation as the corpus does and keeps one blank line in a row, changing only whitespace between tokens and leaving multi-line tokens as they are; a range is formatted from the start of the root declaration it begins in.
    Two settings, `doir.format.minify` and `doir.format.semicolons`, read from `initializationOptions` and `workspace/didChangeConfiguration` and offered by both editors' glue: minifying writes the whole file on one line, dropping comments and turning each newline that ends a statement into `;`, and `semicolons` keeps each `;` that ends a statement, replaces it with a line break, or does that and also breaks after a `{` with a statement after it on its line.
    A newline ends a statement where `doir.peg` has `Terminator`: outside parentheses, after a token a statement can end with, and before one that cannot continue it.
    `doir.printer` chooses only tokens and line breaks and has `doir.format` lay them out, so the two cannot disagree; a test formats the corpus and checks that the printer prints the same store before and after.
    `doir.checks` ports `WF-Term`, `WF-Order`, `D-Return`, `B-Tail`, `L-Scan`, `L-Sema`, `L-Bind` and `L-Entry` to queries per block, with a query per block for the context `doir_check` passes down its walk; on the corpus, the support files and `reference/` they report what `doir_check` does, file for file, and `tests/conformance.py --checker "bin/doir --check"` passes with the same pending cases as `doir_check`.
    `tests/lsp_test.py` drives the server over the protocol.
    On the million-line file an edit inside a block commits in 0.2 ms, and publishing first took about 300 ms, re-demanding every block's checks, which the engine verifies against every entity they read.
    Three quadratic costs made most of it: `read` searched a query's whole dependency list for a repeat, so a query reading thousands of entries took quadratic time (it now searches the latest 16); each block's context rebuilt its parent's declarations, once per sibling (a block's children are now placed together, by one query per block, `ChildContexts`); and every declaration's line was located whether or not a message needed it.
    With those and the checks run on workers (below), an edit's round trip from `didChange` to `publishDiagnostics` took 32 ms (2026-10-29), and with invalidation pushed along reverse edges (below) it takes 0.5 ms (2026-10-30).
    Check messages name no lines, since a reused memo outlives edits that move its declarations; the diagnostic's location and its annotations, such as where a name read too early is bound, are located when it is reported.
    Opening the 14-million-line file took 495 s before the framing read a message's body into room made once from its `Content-Length`, instead of regrowing its buffer by an exact copy every 64 KiB, and takes 41 s since: 29 s committing, 6 s in the first checks, the rest decoding the JSON.
  - Editor glue, in `editors/`: for Neovim (0.11 or later) an `lsp/doir.lua` config for `vim.lsp.enable`, filetype detection and a `commentstring`, highlighting coming from semantic tokens; for VS Code an extension (TypeScript, confined to `editors/vscode/`) that registers the language, its comment and bracket configuration, a baseline TextMate grammar whose keywords are generated from `doir.peg`, and starts `doir --lsp` through `vscode-languageclient`.
    A Python harness (`tests/lsp_test.py`) drives `bin/doir --lsp` over the protocol.
  - Commits in proportion to the edit.
    On the million-line file (`tools/gen_scale.py`, 42 MB), Phase 2's first version took 721 ms per one-line edit against its 5 ms budget, and peaked at 1.3 GB.
    Profiled with `perf` on 2026-10-28, a steady-state edit spent 35% lexing, 9% parsing and hashing, 22% matching, 10% rewriting every entity's absolute location and 8% assigning order keys; copying the text cost under 1%, so mapping files into memory would not help.
    Phase 2 then took the fixes that live inside its commit (skipping unchanged declarations whole, locations on demand, no stored token array, an ASCII lexer fast path), which brought an edit to 242 ms median and the peak to 1.17 GB; profiled again, 84% of what remained was lexing and parsing the whole file, and matching was 1%.
    Leaving trivia out of the parser's tokens (6.6 million instead of 10.9 million), sizing their array from the measured density instead of over-reserving pages that were then zeroed, and lexing identifiers in one pass over an ASCII class table brought lexing from 26 to 13 ns per non-trivia token (300 to 570 MB/s) and an edit to 162 ms, about 140 ms of it the whole-file skim at roughly 21 ns per token.
    The rest of the work is not proportional to the edit until the edit stops relexing the file:
    - Text as a persistent rope per file (`fp.rope`), its versions immutable and sharing every leaf an edit leaves alone, so applying an edit and keeping the previous version for comparison cost O(log n), and line starts are maintained by the tree rather than rescanned.
      Files are copied into it rather than mapped, since copying was under 1% of an edit.
    - Per-block reparse (`doir.source.commitEdit`): an edit relexes and reparses only the innermost declaration whose braces enclose it and which a whole-file commit would still match to its entity (one record with a block and no error outside it, its hash unchanged or, if named, its name), retrying outwards and falling back to a whole-file commit when the edit crosses a block boundary or unbalances braces.
      Spans are relative to their parent, so an edit shifts only the spans after it along its path, and no records are kept between commits: the reparsed declaration is skimmed again from the rope.
      A one-line edit inside a block of the million-line file commits in 0.17 ms median (2026-10-29), against 160 ms committed whole; a randomized test checks every edit against a whole-file commit of the same text.
      Syntax errors are kept on the block holding them (`SyntaxErrors`), relative to its start, so a reparse replaces only that block's and an edit moves the rest with the spans; `reportSyntaxErrors` gathers a file's in source order, for the CLI once and for the LSP per publish.
    - Memory: the peak during a commit holds the whole file's tokens and records beside the store, which per-block reparse bounds by the edited block.
      On 2026-10-29 the million-line file's first commit peaked at 1.35 GB; profiled with massif, a quarter was libECRS's transaction journal, which recorded every component a first commit adds, a quarter the interned order keys, a fifth libECRS's per-entity index lists, and a ninth the tokens and records. libECRS now journals additions once per storage and restores the storage on rollback, and its index lists hold 32-bit slots; order keys share pooled chunks and 16-byte table entries; libfp's hashtable moves keys to make room as hopscotch hashing does, and fills to about 90% before growing instead of 12-25%; `addFile` registers the components most parsed entities hold first, since an index list runs to its highest component id; and `readFile` sizes its buffer from the file.
      Together they brought the peak to 536 MB, 12.6 times the text.
    - Chunked whole-file commits, to keep the tokens and records from ever covering the whole file: a block's contents, the file's root included, are cut into chunks of statements at the block's own level, found by a byte scan that tracks braces and parentheses and skips strings, characters and comments, and each chunk is skimmed on its own (`skim` at the block's depth).
      A cut is kept only if the chunk before it lexes with no unterminated token and parses with no error at its end, so a whole-file parse of the same text would have reached the cut between statements; otherwise the chunk grows to the next cut.
      A first pass gives each child's key and hash for matching and order keys, which need all of a block's children at once; a second skims each chunk again and builds it.
      A named block-valued declaration larger than a chunk is not skimmed whole: its header is parsed alone, its contents are chunked the same way one level down, and its hash, which covers its own tokens with each nested declaration a placeholder, is carried across those chunks.
      Errors are stored as before, a block's own gathered across its chunks.
      The randomized test compares chunked commits, with chunks made small, against unchunked ones.
      Chunks are skimmed ahead in batches on the engine's worker pool (`QueryEngine.workers`, a `bc-threads` pool, two pieces per worker), since a skim reads only its text; building stays serial, since the store, order keys and interned strings take no concurrent writers.
      On 12 threads that halves a one-line edit committed whole (186 to 91 ms wall-clock) and takes a first commit from 1.73 to 1.48 s, and the batch adds about 25 MB to the peak.
      With 256 KB chunks the million-line file's first commit peaks at 435 MB, 10.3 times the text, and a 100,000-line one at 9.9 times (2026-10-29); what remains is the store, chiefly libECRS's per-entity index lists, and the text held twice, once in the rope and once by `bin/doir` for printing.
      Two passes cost time: a one-line edit committed whole takes 178 ms against 148 ms in one pass, and a first commit about a fifth longer.
  - Parallel commits and queries.
    Profiled on 2026-10-29, with chunks skimmed on workers, the first commit of the million-line file spent about 89% of its time on the main thread: 36% interning order keys (21% of it FNV-1a over each key's digits a byte at a time), 20% parsing each declaration a second time to build it, 15% adding components, 7% interning strings.
    In order:
    - Order keys hashed a word at a time and their table sized from the records, before anything moves to another thread.
    - Building split in two: the parser turns a record into a plain description of what it writes (types, lookups, constants, parts, flags, annotation), which a worker produces right after skimming the piece, and the commit applies descriptions to the store on its thread.
      The second parse goes, and the parse half of building runs in parallel.
    - Concurrent interning: strings and order keys interned through tables split into shards, each behind a `bc.spinlock`, with append-only storage, so any thread may intern and readers never wait.
      Order keys of different parents never collide, since a key begins with its parent's digits.
    - libECRS bulk structure and parallel fill: `addEntities` hands out a contiguous run of ids and a bulk add gives many entities one component each, journaled once per storage as any addition is; workers then write the values of components that already exist, which the store already allows of distinct entities.
      The commit creates a piece's entities and slots on its thread and fills them on workers.
    - Where it stands (2026-10-29, best of five runs of `bin/doir bin/scale.doir` on 12 threads): the interning (`bc.interner`), hashing a word at a time with each shard's table indexing by bits the shard choice leaves alone, and describing on workers took the first commit from 1.58 s on one thread to 1.27 s. libECRS gained `addEntities`, `reserveConcurrentAdds` and `beginConcurrentWrites`: prepared storages hand out slots by an atomic counter, nothing another thread reads moves, the journal is the one lock, and a replaced component of an entity the transaction added is not journaled, since a rollback removes the entity whole.
      Rebuilds deferred to workers on it measured slower, 1.47 s: every piece prepares about twenty storages for its entities and trims what it did not use, workers contend for the interner shards that hold the common type names, and the commit's thread cannot keep matching while workers write, since the phase forbids its structural changes.
      So `doir.source` leaves them off (`deferBuilds`), tested; what would make them pay is preparing storages by what each description writes rather than for every entity, and a per-thread cache in front of interning.
    - Parallel queries: each check is a query per entity run in no order (`L-Sema`), so `doir.query.demandEach` runs a batch of independent demands on the engine's workers, each with its own stack of running queries and depth (thread-local), reporting their diagnostics in the order demanding them one after another would.
      Every query entity carries its value and a `Claim` component from the start, so bringing a query up to date writes only components that already exist, as libECRS's concurrent-write phase allows, which the batch runs in to assert that no worker changes the store's structure.
      A worker claims a query by setting its `Claim.owner` atomically; a demand from another worker waits until it is released, as rustc's `QueryLatch` does, and a wait that would close a loop through the queries other workers wait on is a cycle across threads.
      Whatever only the engine's thread may do is handed back to it: adding a query entity, writing a component (`produce`), creating an entity, and settling any cycle (`Q-Cycle`), so cycle reports and fallbacks are exactly those of one thread.
      A worker records the query entities it needed, which the engine's thread adds between rounds, so a first run reaches the workers a level deeper each round instead of falling back whole; what is still handed back after the last round runs on the engine's thread, in order.
      Diagnostics a worker brings up to date are withheld on the query and reported afterwards in the order one thread would have reached them.
      Queries are read without locks: the query tables are only read during a batch, and libECRS reads are safe beside writes to other entities.
      Created entities never come from a worker, so ids stay independent of scheduling.
      On the million-line file (2026-10-29, a 15 W 2+8-core laptop CPU, 12 threads) the checks' first run went from 364 ms on one thread to about 150 ms, and re-validating them from 48 ms to 21 ms; the workers' share levels off from 8 threads, where the efficiency cores and memory bandwidth limit it, and the rest is the serial walk collecting the blocks and the batch's own bookkeeping.
      ThreadSanitizer finds no race in the tests or in `--bench`, after two found in dependencies were fixed: libfp's dummy header for a null container was shared by every thread, and libECRS did not advance the generation of a storage written in place during concurrent writes.
    - Invalidation pushed along reverse edges, so re-validating after an edit costs in proportion to what the edit reached rather than to what was demanded.
      Salsa and rustc pull: a demand re-verifies a query by walking its dependencies, which for a file's checks is every block's checks and every entity they read.
      Here each entity lists the queries that read it (`ReadBy`), updated after each run from the difference between what it read and what it read before (on workers, recorded and applied afterwards, shared among the workers by entity).
      `doir.query.markChanged` marks the direct readers stale and queues them; before the next demand `settle` brings the queued queries that something reads up to date, and only one whose value changed marks its own readers in turn, so early cutoff stops the push where it stops a pull.
      A query that is not stale is then reused at once, unless a query below it holds diagnostics, which reusing it must report and so walks to; one nothing reads waits for its demand, as any query does.
      The checks are a system (`doir.checks.BlockChecks`) the engine runs as one memoized query per block (`doir.schedules.runSystem`): after an edit it visits only the memos a change marked stale, the blocks the commit added, and those holding diagnostics, batched on the workers.
      A refused allocation that loses an edge turns the shortcut off (`edgesMissing`).
      On 2026-10-30 (12 threads), re-checking after a one-line edit took 0.86 ms on a million-line file regenerated from today's `standard.doir`, from 23 ms, and 0.07 ms on 14 million lines, from 388 ms; the 42 MB file generated on 2026-10-28, whose copies carry 1,948 diagnostics, took 11 ms, the walk to those diagnostics, which re-verified every dependency of every query on the way.
      Each query now lists the queries below it that hold diagnostics (`ReportingReads`), in the order it read them, and reusing a current query walks only those, on the engine's thread and on workers alike; `doir.checks` collects for its batch only the blocks whose checks must run, leaving the reuse of the rest to report their diagnostics.
      That takes the 42 MB file's re-check to 1.4 ms (2026-10-30).
      Whether a query reports is not part of its value, so a query that starts or stops reporting while keeping its value marks its readers stale, which before let a reader be reused without ever reaching new diagnostics.
      The edges cost the first check (146 to about 380 ms on a million lines, 2.6 to 6.2 s on 14 million) and memory (14 million lines peaked at 20.2 GB, from 18.3 GB; a commit alone already peaks well over the ten-times budget at that size).
      So an engine may defer them (`edgesMissing` from the start): its queries record none and are re-verified by pulling, and `doir.query.buildDependents` builds every edge at once from what each query last read, counting each entity's edges first so its list is found and sized once, shared among the workers by entity.
      `doir --check` never builds them, since it never edits, and the server builds them once a file's first diagnostics are out and no message waits; it also rebuilds them after a refused allocation lost one.
      On the 42 MB file (2026-10-30, 12 threads) the first check went from about 330 to 225 ms, and the build, run while the server is idle, takes about 105 ms.
    - Whole-file requests stay in proportion to the file, as their answers are: on a million lines (2026-10-30) the server takes about 0.8 s for semantic tokens (52 MB of JSON), 1.7 s for document symbols (156 MB) and 0.1 s for folding ranges, a tenth of that at 100,000 lines.
      Converting offsets to positions was most of the symbols' time; positions now go through a cache of the last line converted and how far into it is counted (`doir.lsp.positions.LineCache`), which took symbols from 2.2 s.
      Semantic tokens by range, which an editor asks for what is in view, take 0.3 ms.
      `semanticTokens/full/delta` would shrink what is sent but keep about four bytes per token of the last answer per document, 100 MB at a million lines, so it waits for a file that needs it.
- **Order of work:** commits in proportion to the edit first (the rope, per-block reparse and syntax errors per block are done; memory, with chunked commits, is in progress), then the server's transport, JSON, lifecycle and position encodings, which need nothing from the commit work, then document sync and diagnostics, the first point at which both editors work, then the editor glue, semantic tokens and the store-backed features, with the ported `doir_check` checks feeding diagnostics as they land.
- **Verification:** A file with a deliberate syntax error still highlights, still lists its symbols, and still reports every other rule violation in it.
  The ported checks report the same violations as `doir_check` on the corpus.
  Typing inside one declaration re-runs the checks for that declaration and its dependents only.
  On the million-line file a one-line edit inside a block commits within Phase 2's 5 ms budget in a release build (`bin/doir --bench bin/scale.doir`), touching only the records and entities of the edited block, and the process peaks under ten times the text's size.
- **Deferred:** hover with deduced types, and references and rename, once deduction (`D-Deduce`), comptime evaluation and the `std.meta` entity queries exist (Phase 5).

### Phase 4: Level 0 (`compiler`) & Emission Base
- **Goal:** Query-driven byte emission of lowest-level binding primitives.
- **Reference:** `source/doir/pipeline/opt/byte_emiter.d` in `tree/D`.
- **Deliverables:**
  - Queries: `type_of(EntityId)` and `emit_object(Target)`, one artifact per target.
    A build with no target gets the default one (`T-Value`), but no backend exists to supply it until Phase 5, so here the default lowers nothing and its artifact is the bytes comptime emitted.
    `lower_level` waits for Phase 5.
  - Output sections (`O-Section`): `compiler.section` and `compiler.sections.make`, and `compiler.emit_artifact`, which writes a section to a path under the output directory once the build succeeds, as many files as the build makes (`O-Artifact`).
    `compiler.emit`, `emit_bytes`, `emit_bits` and `reserve` append to a section, bit by bit in the order `compiler.assembler.bit_order` declares (`O-Bits`), and `position` and `patch` work within the current contribution (`O-Fixup`).
    These are bootstrap builtins the compiler runs itself, not host hooks (`H-Boot`, `H-Hook`), so the `HostServices` table waits for Phase 5.
  - `format.flat.doir`, the format with no header (`O-Format`), so the first backend writes an image with no ELF to get right first.
  - The `compiler` namespace at its minimum (`H-Boot`): primitive type creation (`base_type`, and `pointer`, which builds `compiler.byte_pointer`) and byte emission only.
    Every other builtin-block name waits until a level-1 runner exists.
- **Verification:** Compile `test_string.doir`, which emits into a section and writes it to `res.bin` itself with `compiler.emit_artifact`.
  A ModRM byte written as fields of 2, 3 and 3 bits most significant first equals the byte written whole, and a 32-bit word written least significant first equals its little-endian bytes; each `O-Section`, `O-Bits`, `O-Fixup` and `O-Artifact` reject case fails with its annotation and hint, and a failed build writes no file.
  The build makes no target and there is no backend yet to supply the default, so nothing runs the root as a script (`L-Entry`): every line folds, and the root needs no terminator until Phase 5.

### Phase 5: Comptime Host ABI & Level 1 (`mizu`)
- **Goal:** Implement two-level ascent/descent and VM comptime execution via the host ABI.
- **Reference:** `source/doir/pipeline/opt/mizu/comptime_evaluate.d` and `mizu/instructions.d` in `tree/D`; `rustc_const_eval/src/interpret` (`InterpCx<M: Machine>`, abstract memory) in rustc for the host-services split.
- **Deliverables:**
  - `mizu.doir` and `standard.mizu.doir` ported from `tree/D` (not yet in this repository): the mizu backend this phase runs, imported into a backend namespace, made a target and lowered onto `compiler.levels.builtin` as `reference/backends.doir` does, and what `test.doir` and `test_call.doir` include.
    `reference/machine.doir` states what the port has to satisfy.
  - The `compiler` names a backend needs before level 1 can run (`H-Boot`): `compiler.signed_base_type`, `float_base_type`, `comptime_base_type`, the modifiers `never_comptime`, `always_inline` and `share_body_across_values`, the encoder helpers `shift_right` and `truncate_to_byte`, `indicate_return`, `return`, `block_result`, the `compiler.level` type and `levels.make`, `this_file`, `lower_to`, `check`, `set_host` and `builtin`, and `compiler.paste_file`, which the backends file pastes `machine.doir` in with (`I-Paste`).
    These are what the Mizu port and its backends file call; each system in the port's `run_schedule` calls becomes a `compiler.levels.check` on the target whose entities it analyses (`L-Sema`), and its `override_fallback_schedule` becomes the passes of the Mizu edges, onto `builtin` and from `std`, which both run the legacy schedule as it stands.
  - The tower scan (`L-Scan`, `L-Tower`): before ascent, read every `make`, `this_file` and `lower_to` call, resolve their arguments by name across the build's files, add the implicit edges (`L-Lower`), reject cycles, and rank the levels.
    This phase needs only the conventional tower, one target under `std` and the program; Phase 7 exercises the rest.
  - C-compatible `HostServices` thunk table (store queries, type builder, allocator, diagnostics), versioned and looked up by name from the start (`H-Services`, `H-ABI`), so the deferred JIT host does not change its layout.
  - Comptime bodies of the machine primitives (`C-Interpret`): the host runs the arithmetic, conversions and memory operations with the spec's semantics at the target's widths, rather than interpreting the machine's body.
  - The `std.meta.*` prototypes of `standard.doir` bound to that table (`H-Boot`), so comptime code stops reaching into `compiler`.
  - Embedded Mizu VM whose hook instructions dispatch through `HostServices` (`H-Hook`), so Mizu and a later JIT share one implementation of every hook.
  - Bidirectional type deduction (`D-Deduce`), solving a constructed parameter type from the body's opening assertions (`D-Assert`), and in-place modifiers (`M-Flag`, `M-Freeze`) over the positioned effect logs.
    `standard.doir` cannot load without them: its first lines apply modifiers, and `std.meta.entity_of` has a deduced parameter.
  - Ascent query `evaluate_comptime(EntityId, Position)`, keyed by ⟨entity, lexical position⟩ inside a level and by entity alone once it is frozen (`L-Freeze`, `M-Lexical`).
  - Level freeze transition `freeze_level(Level)`: an engine state change and an input commit, not a memoized query, that makes cross-level queries defined (`L-Freeze`).
    An edit to a frozen level marks it and every level above it unfrozen, a per-level flag that walks no dependency edge; re-freezing writes the folded components as inputs and sets `ChangedAt` only where a folded value changed, so early cutoff reaches across levels.
  - Lowering query `lower_level(EntityId, Level, Target)` from level 1 to 0.
    The lowering query for τ adds τ to the `Lowered` relation of each entity it retires and lists that entry, not the whole component, in its `Outputs`, so an edit that re-runs one target's lowering clears only that target's entry.
  - Passes and descent as schedules (`L-Lower`): a `lower_to` edge's pipeline is an `ecrs.schedules.sequential` over its pass list, built from the tower the scan read, each pass a schedule over the engine (`doir.schedules`), and descent runs the levels' pipelines top-down in the same way.
    The ordered pipeline the spec gives passes is what `sequential` already is, so the passes need no runner of their own.
  - Passes as systems over the store.
    A pass that rewrites each entity of a node kind on its own is `ecrs.schedules.sequential!pass` or `parallel!pass` over the owners of that kind's tag, inside `concurrentWrites` when it writes; `sequential!fn(owner)` visits every live entity, so libECRS gains a system restricted to the owners of a component set rather than each pass filtering for itself.
    A pass that iterates to a fixed point, such as folding and dead-code removal feeding each other, is `ecrs.schedules.untilStable` over them, watching the components they rewrite; a mutable access counts as a change, so such passes read through a `const` context.
    Reuse across edits is `doir.schedules.whenChangedAt`: an edge's pipeline, and each unit emission is split into, runs only when a query entity it lowers from changed since it last ran, with early cutoff, as rustc reuses codegen units.
    Never `ecrs.schedules.whenChanged` for this: it watches a component type's generation store-wide, so any edit anywhere re-runs everything.
    Ascent stays demand-driven: checks are queries per entity (`L-Sema`) and comptime is `evaluate_comptime`, and schedules only drive them (`doir.schedules.demanding`), so Phase 11 compares queries against scheduled passes rather than schedules against schedules (H2, H3).
  - Commits of a build's files.
    From here a build has several files (the Mizu port, `standard.doir`, the program), and `bin/doir` commits each as `sequential(committing, checking)`.
    Skimming reads only a file's text, so the commit splits into a skim of every file at once, `ecrs.schedules.parallel` over the files, then each file's matching and store writes in turn; the writes stay serial because a commit changes the store's structure outside the engine's exclusive section.
  - The `L-Erase` read barrier as a dependency-graph check (`rustc-architecture.md` D6): a query below level n for target τ that records a read of an entity whose `Lowered` relation holds τ is reported as a compiler bug.
    Phase 10 extends it to the full `T-Legal` verifier.
  - The comptime-aware LSP features Phase 3 deferred: hover with deduced types, and references and rename over the `std.meta` entity queries.
    Hover at a position reads the comptime state at that position (`L-Freeze`).
- **Verification:** `standard.doir` loads over the mizu level; fold compile-time expressions; after lowering, every Level 1 entity's `Lowered` relation holds the target, still answers queries, and is read by no level-0 rewrite or emission; editing a machine-level constant re-runs only the `std` queries that read it; hovering a type on a line above a modifier applied to it shows the type unmodified.

### Phase 6: Internal Virtual & Physical Register Allocation
- **Goal:** Manage internal virtual registers (temporaries), support explicit virtual register aliasing, and map virtual registers to physical registers.
- **Reference:** `opt/assign_temporaries.d` and `opt/lower_functions.d` in `tree/D`.
- **Deliverables:**
  - Virtual register assignment query (`REG-Virt`) and register sharing through `std.unsafe.share_register` (`REG-Share`).
  - Interval-sweep allocator mapping internal virtual registers to physical registers (`REG-Phys`) and stack spill offsets.
  - Calling convention queries (`compiler_impl.prologue`, `compiler_impl.epilogue`, `compiler_impl.pass_arguments`, `compiler_impl.call`, `compiler_impl.emit_return`).
  - The `compiler.assembler` bootstrap names the allocator reads (`H-Boot`): the register classes, `pin_register`, `share_register`, `register_for`, `return_register` and `begin_register_allocation`.
  - Object output (`O-Fixup`, `O-Format`), now that calls cross functions: the `emit_function(entity, target)` query, a function's bytes per section with its patches and relocations, and `place_sections(target)`, which joins and aligns contributions, assigns addresses and resolves internal relocations.
    `compiler.relocate`, `compiler.sections.set_address` and the writer's floor accessors (`compiler.sections`, `compiler.symbols`, `compiler.relocations`), and the `compiler_impl.write_object` hook.
  - `format.elf.doir` and `format.hex.doir`, each pairing with any operating system (`OS-Target`): Linux with ELF, freestanding with ELF or hex.
    The header constants (`e_machine`, `EI_OSABI`, the interpreter) are defined in the backends file, so neither the machine nor the operating system names the format.
- **Verification:** `test_call.doir` compiles and executes non-inlined calls; bindings aliased via `std.unsafe.share_register` occupy the identical physical register.
  On Linux with ELF, `readelf -a` accepts the file, it runs, and each libc import is a dynamic relocation; freestanding with ELF has no `PT_INTERP`; freestanding with hex, read back with `objcopy -I ihex -O binary`, is byte for byte the flat image.
  Linux paired with the flat format is rejected under `O-Format`, annotating a libc `load_from_library`.

### Phase 7: Multi-Target Builds and Target Bridges
- **Goal:** Retargeting via machine signatures (`T-Sig`) and heterogeneity inside a single build: a build names a set of targets (`T-Value`), and one program can call code lowered for more than one of them.
  Chapter 7 cannot run without this.
- **Deliverables:**
  - Machine signature interface (`T-Sig`): `machine.u1`, `machine.u8`, `machine.u32` or `machine.u64` by pointer width, `machine.pointer_sized`, `machine.pointer_difference`, `machine.byte_order`, the optional types (`T-Optional`), the `compiler_impl` hooks, the register classes, and the descent schedule.
    `reference/machine.doir` is the contract to check a machine against.
  - The tower as a DAG (`L-Tower`, `L-Lower`): every backend lowered onto `builtin` is a target, `std` lowered onto each by explicit edges, intermediate levels that are not targets (a slang level onto SPIR-V), and per-target descent along `next_σ`, an edge with no passes handing its level down to be lowered with its head.
    `std.targets.compile_for` restricts a declaration to a subset of the targets (`T-Live`), and descent and emission run once per target.
    A build with one target is the old case unchanged.
  - The host target: `compiler.levels.set_host` marks the target that runs the program's root as a script (`L-Entry`); a single target is the host, and several targets with no host, or two, is an error.
    Only the host's root is held to `WF-Term`.
  - Per-target lookup (`R-Unqual`, `I-Extern`): under target τ, looking down from a level sees only the levels below it whose way down reaches τ or no target at all, so `std` prototypes bind to τ's definitions.
  - Per-target comptime: `evaluate_comptime` (the spec's `cmp`) is keyed by ⟨entity, position, target⟩ inside a level and ⟨entity, target⟩ once it is frozen, for every level that reads a machine signature (`T-Split`).
    Sharing comes from dependencies, not early cutoff: an evaluation whose recorded dependencies include no machine-level entity cannot depend on the target, so its memo answers every target's key and it runs once.
    An answer that reads a machine entity (a resolved `std.u8`) runs per target, so how much of a shared level is evaluated once is measured (Phase 11), not assumed.
  - The bridge hooks inspect a call's arguments through `compiler.argument_count` and `compiler.argument`.
    They are floor names (`H-Boot`): a backend cannot name `std.meta` (`L-Mono`), so code below `std` needs them in `compiler`.
  - Targets, not device classes.
    There is no cpu/gpu enum in the language: a target is whatever backend the build lowers onto `builtin`, so one build can carry x86 and wasm, another SPIR-V and slang, and a third all four (`T-Device`).
    What each level can reach is declared by the levels themselves, not inferred from a hardware category.
  - Bridges (`T-Bridge`).
    Each backend writes its own half of a crossing, naming its peer by the declaration that holds its target: `compiler_impl.export_entry` emits a function other targets can call, and `compiler_impl.bridges.<target>.call` marshals the arguments and result and replaces `compiler_impl.call` for a callee live only on that target.
    A pair whose caller declares no namespace for the callee's target cannot call across, and the failed lookup names both targets.
    A callee live for several other targets is ill-formed to call across.
  - Cross-target effect order.
    `T-Order` orders effects within a target lexically and across targets only at a bridge call, which acts as a barrier.
    Enforcing that barrier in descent is built here, as internal state tokens that carry effect order as a data edge through effectful calls (`ir-design.md` §2); they are a compiler IR, not surface syntax, so the spec needs no new rule.
    A dot product whose vectors are built on one target and multiplied on another is a cross-target ordering problem, and without this the class in Chapter 7 cannot state what its program does.
  - Shared backend code (`T-Device`): two targets share encoder code by both lowering onto a level that holds it; a level is live only for the targets below it (`T-Live`).
  - Descent passes belong to edges (`L-Lower`); there is no build-wide fallback schedule.
    Mizu's schedule is split here into `std`'s edge onto Mizu and Mizu's edge onto `builtin`, which a second target makes worth doing, and the analyses in it that check rather than rewrite become `check`s (`L-Sema`); within each, nothing in this phase reorders it.
  - `format.pe.doir`, so x86 pairs with Windows as well as Linux.
  - Bundles (`O-Bundle`): `compiler.levels.bundle` makes several targets alternatives, each the host of its own slice, and the bundle level's `compiler_impl.write_bundle` joins their thin artifacts through `compiler.artifacts`.
    Slices cooperate with no one: a call from one to code live only on another is rejected, naming both.
    The bundle this is for is a macOS universal binary, an x86_64 and an arm64 Mach-O in one file; `os.macos.doir`, `format.macho.doir`, `format.universal.doir` and an arm64 machine come with it, after the x86 backend.
- **Verification:** One source file declares functions live for two different targets and compiles in a single build to both, and the build reports how many of the shared levels' comptime queries were evaluated once and how many per target.
  A declaration restricted to a target the build does not name is reported dead.
  A call across a pair with no declared bridge is rejected with a diagnostic naming both targets.
  A build naming one target produces output identical to the same build under the previous single-target rule.
  The universal build is accepted by `lipo -info` as `x86_64 arm64`, and `lipo -thin` gives back each slice byte for byte as that target's thin build.

### Phase 8: Standard Library (`std`) Integration
- **Goal:** Self-contained `standard.doir` compiled over multiple machine targets.
- **Reference:** `standard.doir`; port `test_standard.doir` from `tree/D` (not yet in this repository).
- **Deliverables:**
  - A second CPU backend: a 32-bit variant of the Mizu backend, which provides `machine.u32` as its pointer width and lacks `machine.u64`.
  - `standard.doir` compiled in one build over the Mizu target and that variant's (Phase 7), with an optional name (`T-Optional`) one provides and the other lacks, used behind `std.numbers.integer_available` so `C-Splice` drops it where it is absent.
  - Every `std` prototype that is not a host hook bound to a body on both backends (`I-Extern`), checked against `reference/machine.doir`: the backend's own, or the software body `standard.emulated.doir` gives `std`, which the lowest-ranked definition replaces.
    The 32-bit variant defines only the primitives of `reference/machine.doir`'s first `std` block, so the emulation is what it runs.
    It also declares `machine.f32` but defines nothing in `std.float` (`N-Kind`), so its binary32 arithmetic is the software floats, whose steps `tests/software_float.py` already checks.
  - Overload sets (`TF-Overload`): the `std.meta.functions.create_overload_set` and `add_overload` hooks, and call resolution as a query keyed by ⟨call, position⟩ that picks the one viable exact member, else the one viable generic one.
  - The operating system (Part II §19): each backend pastes a machine and an operating system (`OS-Target`), Mizu with `os.freestanding.doir` and a native one with `os.linux.doir` or `os.windows.doir`, and every `std.os` prototype binds on both targets, checked against `reference/operating_system.doir` (`OS-Sig`).
    That needs the floor's `compiler.library`, `load_library`, `load_from_library` and `set_symbol_name` (`H-Boot`) on the `HostServices` entries `std`'s twins use, and the comptime host serving `std.os` from the native operating system, evaluated for comptime alone when the target's is another (`OS-Comptime`).
- **Verification:** `test_standard.doir` compiles and passes verification without errors on both targets, and gives the same results on the variant, which emulates, as on Mizu, which does not: bit for bit for floats, NaN payloads aside.
  A program over `std.os` prints, reads back a file it wrote and joins a thread on the native target, gets `errors.unsupported` on freestanding Mizu, and reads the build machine's page size at comptime on both.

### Phase 9: Graphics Target Backend (Chapter 6)
- **Goal:** Prove that a target is ordinary library code and that the same source runs on two targets.
  Chapter 6 is due before Chapter 4, so this phase starts as soon as Phase 5 makes the host ABI callable, and runs in parallel with Phase 8.
- **Deliverables:**
  - A backend for the graphics API written against `HostServices` (`H-Hook`, `H-Services`), with its own register classes, made a target and lowered onto `builtin` by its own descent passes (`L-Lower`).
  - A port of that level to a second target for the web, with the concessions the port required recorded as a list.
  - The handle discipline that keeps entity ids out of host memory (`MEM-Escape`, `E-Remap`), tested by renumbering between levels while the backend holds handles.
    The table itself is Phase 5's (`H-ABI`).
- **Verification:** The same source compiled in two single-target builds, one per target, gives identical answers for every comptime query that reads no machine signature, and answers that read one differ only as the two signatures do (`H-Target`).
  Once Phase 7 exists the same check runs in one build over both (`T-Split`).
  `H-Det` is a claim about comptime hosts, not targets, and needs a second host to test (Deferred).
  The backend's pass count and lines of code are recorded, because they are the numbers Chapter 4 cites.

### Phase 10: Verifier and Conformance Corpus (Chapter 4)
- **Goal:** Make level legality a checkable property and every rule tag testable.
- **Deliverables:**
  - A legality verifier after each lowering for each target (`T-Legal`), extending Phase 5's read barrier: every entity read below the level just lowered for target τ satisfies that level's signature for τ, and nothing whose `Lowered` relation holds τ is still read.
  - A conformance corpus keyed by rule tag, with at least one file each tag alone decides (spec Part II), and both an accepted and a rejected file for every tag a program can violate, run against the parser and the semantic checks.
    It starts as `tests/conformance`, run by `tests/conformance.py`.
  - Differential testing against `tests/doir_check.py` over that corpus.
- **Verification:** Every tag in Part II has a corpus entry naming it, and every tag a program can violate has both an accepted and a rejected one.
  A lowering that leaves an entity readable below its level is caught by the verifier rather than by a crash in emission.

### Phase 11: Measurement (Chapter 4)
- **Goal:** Turn the design claims into numbers.
- **Deliverables:**
  - The control is the legacy waterfall compiler (`tree/D`), not a new implementation: it compiles the same language through a fixed pass schedule (the one `reference/machine.doir` transcribes), so it differs from this compiler in architecture and in the legacy divergences spec Part III records (`C-Specialize`, `AT-Set`, `C-Valid`).
    Deliverable: the corpus programs both compilers accept and whose result no recorded divergence changes, with their outputs checked equal, and the list of programs left out and why.
  - Wall-clock compile time and peak memory against the control.
  - Pass count and lines of code per pass, for the query-driven systems written over the store and for the legacy scheduled passes they replace.
  - Output size and quality against the control.
  - Incremental-edit re-run counts: queries re-run after a single declaration change, with and without early cutoff.
    The control has no incremental mode, so its number is a full rebuild.
  - Per-target sharing (`T-Split`): for each multi-target build of Phase 7, the comptime queries of the shared levels evaluated once versus once per target.
- **Verification:** These numbers decide H2 (demand-driven compile-time folding replaces scheduled passes, so it reduces their number without raising total compile time; the control also folds, but inside its fixed schedule) and H3 (query-driven passes are shorter than the scheduled legacy passes they replace).
  Neither is claimed before the measurement exists.

### Phase 12: Heterogeneous Teaching Language and the Classroom Study (Chapter 7)
- **Goal:** A ChocoPy-level front end over DOIR in which a function can be marked a kernel, plus the instruments for the Spring 2028 class.
- **Deliverables:**
  - A ChocoPy-level front end written as a standalone translator that emits DOIR source, which the build imports like any other file.
    `language` blocks stay unimplemented (`I-Language`, Phase 2).
  - Kernel marking lowered to Phase 9's graphics target level — SPIR-V or slang — using Phase 7's target sets and bridges.
  - Bound checks and passes (`L-Bind`): `compiler.levels.bind_pass(f, name)` binds `name` to the function `f` the way the compiler binds the checks and passes it provides, so `compiler.levels.check` (`L-Sema`) and the passes of `compiler.levels.lower_to` (`L-Lower`) name it like any builtin one.
    The teaching language's checks and its kernel lowering are the first checks and passes written outside the compiler.
    A bound function is comptime of a level that is already frozen: for a check on T, a level below T; for an edge F → T, T or a level below it.
    It is a floor name (`H-Boot`) because a backend that lowers `std` onto itself cannot name `std.meta` (`L-Mono`).
    It is scheduled this late because it needs Phase 5's entity hooks and Phase 7's explicit edges, and because Phase 11 counts the compiler-provided passes alone.
    Binding one marks it to be compiled for the machine the compiler runs on and called directly; until the native JIT host exists (Deferred), it runs on the Mizu comptime host.
    Its signature as a check and as a pass is fixed here, from what the teaching language's checks and kernel lowering need.
  - The timed backend task (one compiler lowering to two targets in a single build, with a call across them), its rubric, and the matching task in an established infrastructure to serve as the control.
  - A replacement for the byte-emission layer Chapter 5 identified as the principal usability risk: a typed rule DSL for instruction selection in the manner of ISLE, so emitting bytes is not the part students have to learn.
  - Machine-checked verification of the DSL's rules in the manner of Crocus and Alive2, limited to the rule sets small enough to state as SMT obligations.
    It waits for the DSL because hand-written emission code in a machine level is not in a form SMT obligations can be stated over.
- **Verification:** H1 — novices complete the backend task in DOIR in less time and with fewer errors than in the control.
  The instruments are in place before the class starts; the study is the chapter's results section.

## Deferred (Chapter 8)

Claims with no phase behind them (Principle 9).
Each stays out of the chapters until a phase produces its evidence.

- A second comptime host, a native JIT calling `HostServices`: until one exists `H-Det` holds by construction and is not tested.
- The aegraph mid-end, SSA-based register allocation and Datalog analyses (`ir-design.md` §5, row 6).
- RVSDG block parameters and results, and OSSA ownership (`ir-design.md` §2, §4.1), until they are written into Part II; Phase 6's pinning workarounds stay until then.
- Foreign-language frontends behind `language "name" { ... }` (`I-Language`); until then a `language` block is an error (Phase 2).
- Per (entity, component type) dependencies (Phase 1), until profiling asks for them.
