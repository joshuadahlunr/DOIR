# The DOIR Language Specification

An intermediate representation and meta-language where the module is an entity store, every value declaration is a **binding** (a name and the value it holds, known at compile time or not), bindings that survive to runtime are internally assigned to virtual registers (temporaries), and virtual registers are mapped to physical registers.

---

# Part I: Language Notation

DOIR does not possess intrinsic runtime semantics; a **level** supplies them. In DOIR source code, every declaration except an alias produces a **binding** in the entity store: a named value, which may be known at compile time (comptime) or only at runtime; an alias only adds another name for an existing binding. Every source identifier (including numbered names like `%1`) names a binding.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    DOIR Value & Register Architecture                   │
│                                                                         │
│  [ Source Level ]                                                       │
│   Assignment Statement (x : T = expr)                                   │
│          │                                                              │
│          ▼ produces & names                                             │
│   Binding ◄─────────────────────── Source Alias (y : alias = x)         │
│          │                         (another name for the same binding)  │
│  ────────┼────────────────────────────────────────────────────────────  │
│  [ Internal Compiler Lowering ]                                         │
│          │                                                              │
│          ▼ assigned to (if runtime)                                     │
│   Virtual Register (Temporary) ◄── std.unsafe.share_register        │
│          │                         (merges two bindings into one vreg)  │
│          ▼ allocated to                                                 │
│   Physical Register / Spill Slot                                        │
└─────────────────────────────────────────────────────────────────────────┘
```

## 1. Syntax & Declaration Forms

The grammar is `doir.peg`. Every line in DOIR is a declaration in one of eight forms. Seven produce a **binding**; the alias form (#4) only adds a name for an existing one:

```rust
%1 : std.pointer_sized = 5                      // #1: Constant binding (number, character, or string)
%2 : block = {                                  // #2: Block binding (quoted code)
    six : std.pointer_sized = 6
    _ : _ = std.block_result(six)                      // #3: Call binding
}
%3 : alias = %1                                 // #4: Source alias (a second name for binding %1)
math : namespace = {                            // #5: Namespace
    vec2 : type = {                             // #6: Aggregate type
        x : std.pointer_sized                   // #7: Valueless binding
        y : std.pointer_sized
    }
    length_t : (v: vec2) -> std.pointer_sized = {   // #8: Function Definition
      // Something useful should happen here...
      _ : _ = std.return(result)
    }
}
```

A constant is an integer (decimal, `0x`, `0b`, or leading-`0` octal, optionally preceded by `-`), a float (optionally preceded by `-`), a character in single quotes, a string in double quotes, or a raw string in `"""` delimiters; how each is typed is `V-Literal`.

The underscore `_` means two different things depending on position:

1. In a **name position**: gives the declaration a fresh name that no identifier can spell, so nothing can refer to it.
2. In a **type position**: requests bidirectional type deduction (`D-Deduce`). In the return position of a function type, `(...) -> _` is shorthand for a leading `deduced type` parameter returned by the function (`D-Return`). A parameter's type is never `_`; a deduced parameter is written `T: deduced type`.

Names like `%1` are ordinary identifiers. `%"any text"` names an identifier spelled by an arbitrary string.

A parameter name written in a type position names the type bound to that parameter, which is how a function type can say its return is the type of an argument: `min_value_t : type = (T: type) -> T`.

A type position is only ever a name or a function type (`TF-Name`). A constructed type is never written inline: a type former is an ordinary comptime call, so its result is bound to a binding first, and that name is then used wherever the type is needed.

```rust
u8_pointer : type = std.types.pointer(std.u8)   // the call is a value; the name is the type
p : u8_pointer = std.stack.allocate(std.u8)
```

The same holds in a parameter line: `(p: u8_pointer)` is legal, `(p: std.types.pointer(std.u8))` is not. What a parameter line cannot say — that an index is in range, that a pointer points to an aggregate — is stated with an assertion in the body (`DG-Assert`). A parameter may carry a default constant (`(n: T = 0)`), used when a call omits it (`F-Default`).

All bindings are single static assignment (SSA); a binding is bound once and never mutated at runtime, so there is no `const` keyword for values. Pointer types may be marked read-only (`std.pointers.read_only`), which raises a diagnostic if a value is stored through them.

A block may be the value of an assignment directly, without being named first (`assignment_value <- Block wsc`):

```rust
sum : std.pointer_sized = {
    a : std.pointer_sized = 5
    b : std.pointer_sized = 7
    total : std.pointer_sized = std.add(a, b)
    _ : _ = std.block_result(total)
}
```

The block's `std.block_result` value is the value of the assignment (`B-Result`), and the names declared inside it are local to it (`B-Scope`). This is the idiomatic way to write a straight-line computation whose intermediate values would otherwise have to be hoisted to satisfy `WF-Arg`. Here everything folds, so `sum` is another name for the comptime `total` (`C-Term`).

A declaration may carry no value at all:

```rust
malloc : (size: std.pointer_sized) -> std.byte_pointer   // #8 with a function type: a prototype
```

That spells a symbol DOIR does not define — one the comptime host supplies (`H-Hook`), one a lower level or a later file in the same level implements, or one the linker resolves (`I-Extern`). Every function in `standard.doir` without a body is written this way.

A declaration ends at a newline or a `;`. A block is a sequence of declarations, so an inline block must terminate its last declaration before the closing brace:

```rust
guard : block = { _ : _ = std.return(std.false); }   // ';' closes the inner declaration
skip  : block = { _ : _ = std.block_result(std.nothing); }
```

A declaration may end with a source annotation, `<file:line:column>` or `<"file":line-line:column-column>`, which sets its source location (`AT-Source`).

Besides declarations, a block may contain `language "name" { ... }`, which hands the text between the braces to another frontend (`I-Language`).

A bare call is never a statement: every line declares a binding, so an effect-only call uses the underscore name.

```rust
path : std.c_string = "./pointer.doir"
_ : _ = std.import(path)
```

`deduced`, `export`, `flatten`, `inline`, `language`, and `tail` are reserved words and cannot stand alone as an identifier; a name that merely starts with one (`tail_count`) is fine.

## 2. Calls Take Binding Names

Every argument of every call is the name of a binding (`WF-Arg`). There are no exceptions: not a literal, not a block, not a nested call. Whatever a call needs is bound to a name on its own line first.

```rust
// INVALID
%5 : std.pointer_sized = std.add(%0, 6)
%5 : std.pointer_sized = std.add(%0, std.multiply(%1, %2))
%5 : std.pointer_sized = std.if(%cond, { _ : _ = std.block_result(%0) ; })

// VALID (%0, %1, %2 and %cond are runtime values)
six  : std.pointer_sized = 6
prod : std.pointer_sized = std.multiply(%1, %2)
%5   : std.pointer_sized = std.add(%0, prod)
then : block = { six_runtime : std.pointer_sized = std.comptime_to_runtime(six) ; _ : _ = std.block_result(six_runtime) ; }
else : block = { _ : _ = std.block_result(%0) ; }
%6   : std.pointer_sized = std.if(%cond, then, else)
```

`then` converts `six` to runtime because the branch is chosen at runtime, so the value it yields must exist at runtime (`C-Term`, `WF-ToRuntime`).

This is not a restriction invented for the spec; it is the shape the store already has. A call entity carries its arguments as names (`LookupFunctionInputs`, [`reference/builders.d`](reference/builders.d)) that resolution turns into the binding entities of `FunctionInputs`. A literal becomes a `ConstantVal` entity made by `pushConstant`, and a block becomes a block entity made by `pushBlock`, before either is named in a call. Naming the argument first is what the builder does anyway — the grammar says the same thing.

A call may be prefixed with `inline`, `flatten`, or `tail`, which applies to that call only (`C-Inline`, `B-Tail`).

## 3. Source Aliases vs. Virtual Register Aliasing

DOIR distinguishes between aliasing a binding in source code and aliasing internal virtual registers:

1. **Source Alias (`: alias =`):** Adds a second name for an existing binding (`A-Res`), and nothing more. The alias and its referent are the same object, so they share one type, one value, one virtual register and one physical register (`A-Transparent`). A call that hands back an existing type, function or binding also binds its destination as an alias (`A-Bind`).
2. **Virtual Register Alias (`std.unsafe.share_register`):** Takes two distinct runtime bindings of one type and forces the compiler to assign them to the **same internal virtual register**, which subsequently maps to the **same physical register**.

```rust
// std.pointers.store returns its value argument, so %4 binds as a source alias of %3
// by A-Bind and automatically shares its virtual and physical register by A-Transparent:
%3 : std.pointer_sized = std.subtract(%2, %1)
%4 : std.pointer_sized = std.pointers.store(x, %3)

// Distinct runtime values whose live ranges do not overlap can share a register explicitly:
a : std.pointer_sized = std.add(%1, %2)
// ... a is consumed ...
b : std.pointer_sized = std.multiply(%2, %3)
_ : std.pointer_sized = std.unsafe.share_register(a, b)
// bindings a and b are forced to share one virtual register and one physical register (REG-Share).
```

## 4. Functions & Calling Conventions

Functions are bindings whose type is `(args...) -> return`. Omitting the return type means the return type is `void`; such a function returns `std.nothing`, the one value of type `void` (`WF-Void`). Every function body must end with a terminator call such as `std.return`, `std.halt` or a `tail` call (`WF-Term`, `B-Tail`). A function's parameters are in scope in its body (`R-Param`).

A function whose type carries neither `std.types.always_comptime` nor `std.types.never_comptime` runs in both stages, decided per call. A call whose arguments are all comptime is folded (`C-Call`). A call with any runtime argument is emitted against a specialization keyed on its comptime arguments: those parameters are bound to their values in that copy, the parts of the body that depend only on them are folded, and the rest is emitted (`C-Specialize`). `std.types.always_comptime` makes every call fold; `std.types.never_comptime` makes every call emit, still specialized on its comptime arguments. Which arguments are keys is decided by the parameter types: a parameter whose type is marked `std.types.always_comptime` always receives a comptime argument and is always a key, and one whose type is marked `std.types.share_body_across_values` never is, so its comptime argument must be converted to runtime by the caller (`C-SharedBody`). A runtime argument is never part of the key.

```rust
message : type = std.types.distinct_copy(std.c_string)
_ : type = std.types.share_body_across_values(message)
log_t : type = (level: std.u8, text: message) -> void
log : log_t = { ... }

msg   : message = "connecting"
msg_r : message = std.comptime_to_runtime(msg)
_ : void = log(%level, msg_r)   // one body of log for every message
```

Functions that are not inlined or evaluated away at comptime are emitted through the `compiler_impl` hooks every backend provides (`T-Sig`).

## 5. Deduction & Structural Types

Function parameters marked `deduced type` are solved bidirectionally (`D-Deduce`)—forward from argument binding types and backward from the declared type of the destination binding.
Deduced parameters are never written at the call site; the arguments bind, in order, to the remaining parameters.
A plain `type` parameter (as in `std.copy(T, v)`) is passed explicitly.
A deduced type that neither direction solves is an error, so the destination of a call returning `_` names its type: `_ : void = std.if(c, a, b)`.
A deduced type that only a constructed parameter type mentions, such as `T` in a pointer to `T`, is solved from the assertions that open the body (`D-Assert`).

```rust
my_promote : (Tret : deduced type, T : deduced type, value : T) -> Tret = { ... }
%12 : std.byte = my_promote(%4) // Tret = std.byte, T = typeof(%4)
```

DOIR types are structural (`S-Struct`): two types convert implicitly exactly when they have the same layout and the same shape, all the way down — the same pointee for pointers, the same field types for aggregates, the same signature for function types. So `pointer(header)` and `std.byte_pointer` need an explicit `std.reinterpret_bits`. Calling `std.types.distinct_copy` constructs a new type with the same layout and a distinct discriminator, blocking implicit conversion while still permitting explicit `std.reinterpret_bits`, which relabels a value's bits as another type of the same size without copying.

## 6. Programs, Files, and Targets

A program is a set of files, arranged into a tower of levels that the compiler reads from the files themselves before it evaluates anything (`L-Tower`, `L-Scan`). The levels of the tower are each file's root, the builtin block, and each namespace that `compiler.levels.make` makes into a `compiler.level`. `compiler.levels.lower_to(from, to, passes)` says that one level is lowered onto another by `passes` (`L-Lower`), and may be written in any file, so `std` never has to name the backends it runs on. `compiler.levels.check(t, name)` adds a check to the semantic analysis a level runs over its own entities (`L-Sema`): a level defines its analysis with `check` and its lowering with `lower_to`, and neither needs a change to the compiler. A level that writes no edge lowers onto the levels it names, so a program over `std` writes none. A backend lowers onto `compiler.levels.builtin`, the builtin block, and the levels that do are the build's targets: the levels above them are evaluated and lowered once for each. With more than one, `compiler.levels.set_host` marks the one that runs the program. One file is the program: on the host its top-level declarations run top to bottom, starting from its first (`L-Entry`). A build with no target gets one by default: the backend native to the machine the compiler runs on, or Mizu if that cannot be determined (`T-Value`). There is no `main`.

```rust
x86_backend : namespace = { ... }      // machine, compiler_impl and the std bodies for x86
spirv_backend : namespace = { ... }
wasm_backend : namespace = { ... }
export targets : namespace = {
	export x86 : compiler.level = compiler.levels.make(x86_backend)
	export spirv : compiler.level = compiler.levels.make(spirv_backend)
	export wasm : compiler.level = compiler.levels.make(wasm_backend)
	_ : compiler.level = compiler.levels.lower_to(x86, compiler.levels.builtin, x86_passes)
	_ : compiler.level = compiler.levels.lower_to(spirv, compiler.levels.builtin, spirv_passes)
	_ : compiler.level = compiler.levels.lower_to(wasm, compiler.levels.builtin, wasm_passes)
	_ : compiler.level = compiler.levels.lower_to(std.level, x86, std_passes)   // std onto each backend
	_ : compiler.level = compiler.levels.lower_to(std.level, spirv, std_passes)
	_ : compiler.level = compiler.levels.lower_to(std.level, wasm, std_passes)
	_ : compiler.level = compiler.levels.set_host(x86)
}
```

Restricting a declaration to some of the build's targets is not syntax: it is a modifier call, `std.targets.compile_for`, which takes the declaration and a target and marks the declaration live on that target in place. Repeated calls add targets:

```rust
dot : dot_t = { ... }            // lowered for every target in the build
kernel : dot_t = { ... }
_ : _ = std.targets.compile_for(kernel, targets.spirv)   // lowered only for the spirv target
scale : scale_t = { ... }
_ : _ = std.targets.compile_for(scale, targets.x86)
_ : _ = std.targets.compile_for(scale, targets.wasm)     // lowered for those two targets
```

A declaration never passed to `std.targets.compile_for` is live for every target its enclosing declaration is live for (`T-Live`).

## 7. The Builtin Block (Level 0)

Level 0 is the `compiler` level: the builtin block, the root of the last scope every lookup reaches (`R-Unqual`). It descends from the legacy compiler's `buildBuiltinBlock` ([`source/doir/interface_.d`](https://github.com/doir-lang/DOIR/blob/D/source/doir/interface_.d#L1951), `tree/D`), and [`reference/compiler.doir`](reference/compiler.doir) states it as declarations. Under `H-Boot` this list is the bootstrap: every name below is there because the compiler needs it before anything can be jitted, and each one is a candidate for moving to a host hook or to DOIR source.

**Builtin names reached unqualified.** `type` and `block` carry `AlwaysComptime`. `deduced type` (the entity `deduced_type`, since a declaration cannot spell two words) is a distinct always-comptime type whose parameters are solved by the call site (`D-Deduce`). `void` is the empty type and `std.nothing` its only value (`WF-Void`). `pack` is the always-comptime type of a variadic parameter (`F-Pack`). `alias` and `namespace` are markers valid only as the declared type of an alias (`A-Res`) or a namespace (`R-Merge`), and `namespace` also as a parameter type of a level-0 builtin, which receives the namespace itself (`C-Valid`). `_` in type position is a single placeholder that each use site replaces with its own type variable. `compiler.paste_file` pastes a file in place, for levels below `std` (`I-Paste`).

**Comptime builtins** (their function types carry `AlwaysComptime`):

| Builtin                                                                                       | Signature                                                       | Purpose                                                                                                    |
| --------------------------------------------------------------------------------------------- | --------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `compiler.paste_file`                                                                      | `(path: compiler.byte_pointer) -> compiler.pointer_sized`       | Pastes a file's declarations in place, as if written there; not an import (`I-Paste`).                 |
| `compiler.base_type`                                                                          | `(size_bits: pointer_sized, align_bits: pointer_sized) -> type` | Creates a primitive type with the given layout; defines `compiler.pointer_sized` and `compiler.byte`.      |
| `compiler.comptime_base_type`                                                                 | as `base_type`                                                  | As `base_type`, carrying `AlwaysComptime` and a fresh discriminator; defines `compiler.entity` and `compiler.assembler.register`. |
| `compiler.signed_base_type`                                                                   | as `base_type`                                                  | As `base_type`, carrying `Signed` and the reserved signed discriminator (`S-Numeric`); defines `machine.pointer_difference` and the optional `machine.i*`. |
| `compiler.float_base_type`                                                                    | as `base_type`                                                  | As `base_type`, carrying `Float` and the reserved float discriminator (`S-Numeric`); defines the optional `machine.f32` and `machine.f64` (`T-Optional`). |
| `compiler.emit`                                                                               | `(b: byte) -> byte`                                             | Appends one byte to the output.                                                                            |
| `compiler.emit_bytes`                                                                         | `(bytes: byte_pointer) -> byte`                                 | Appends a string of bytes to the output.                                                                   |
| `compiler.levels.make`                                                                        | `(implementation: namespace) -> level`                          | Makes a namespace a level of the tower (`T-Value`, `L-Scan`).                                              |
| `compiler.levels.this_file`                                                                   | `() -> level`                                                   | The root of the file it is written in, as a level (`T-Value`).                                             |
| `compiler.levels.lower_to`                                                                    | `(from: level, to: level, passes: byte_pointer) -> level`       | Lowers `from` onto `to` by `passes`, and returns `from` (`L-Lower`).                                       |
| `compiler.levels.check`                                                                       | `(t: level, name: byte_pointer) -> level`                       | Adds the check `name` to `t`'s semantic analysis, and returns `t` (`L-Sema`).                              |
| `compiler.levels.bind_pass`                                                                      | `(T: deduced type, f: T, name: byte_pointer) -> T`              | Binds `name` to the function `f` as a check or pass, as the compiler binds its own, and returns `f` (`L-Bind`). |
| `compiler.levels.set_host`                                                                    | `(t: level) -> level`                                           | Marks the target that runs the program's root as a script (`L-Entry`, `T-Value`).                          |
| `compiler.shift_right`                                                                        | `(value: pointer_sized, arg: pointer_sized) -> pointer_sized`   | Comptime shift used by instruction encoders.                                                               |
| `compiler.truncate_to_byte`                                                                   | `(value: pointer_sized) -> byte`                                | The one narrowing conversion, used by instruction encoders.                                                |
| `compiler.pointer`                                                                            | `(T: type) -> type`                                             | Pointer constructor (`M-Ctor`); `std.types.pointer` above level 0.                                         |
| `compiler.always_inline`, `share_body_across_values`, `never_comptime`                                | `(T: type) -> type`                                             | Flag modifiers; `std.functions.always_inline`, `std.types.share_body_across_values`, `never_comptime` above level 0. |
| `compiler.assembler.register_for`                                                             | `(T: type, value: T) -> register`                               | The physical register holding a runtime value; receives the binding, not its value (`C-Valid`).            |
| `compiler.assembler.return_register`                                                          | `(_: type) -> register`                                         | The register a function returns through.                                                                   |
| `compiler.assembler.caller_saved_registers`, `callee_saved_registers`, `argument_registers`   | `(first: register, last: register) -> register`                 | Declares the machine's register classes; repeated calls add ranges rather than replace them.               |
| `compiler.argument_count`                                                                     | `(call: entity) -> pointer_sized`                               | Number of arguments passed to `call`; allows `compiler_impl` hooks to marshal arguments without violating `L-Mono`. |
| `compiler.argument`                                                                           | `(call: entity, i: pointer_sized) -> entity`                    | Returns the binding entity handle of argument `i` of `call` (`L-Mono`, `T-Bridge`).                        |

**Other builtins** (runtime or marker functions): `compiler.indicate_return` marks what a body hands back; `compiler.return` and `compiler.block_result` (`(T: deduced type, value: T) -> T`) say which register it is handed back in; `compiler.assembler.pin_register(T: type, value: T, register)`; `compiler.assembler.share_register` (`std.unsafe.share_register` above level 0); `compiler.assembler.begin_register_allocation`. Constants and types: `compiler.pointer_sized` (host word), `compiler.byte`, `compiler.byte_pointer`, `compiler.entity` (the entity handle, `E-Remap`), `compiler.level` (a level of the tower, always-comptime, `T-Value`), `compiler.levels.builtin` (the builtin block as a level, `L-Lower`).

---

# Part II: Formal Semantics

Every rule in this part carries a tag, and the tags are the keys of the conformance corpus: each rule has at least one test that it alone decides, and changing a rule means changing the corpus entry named by its tag. An implementation conforms when it accepts and rejects exactly the files the corpus says and reports the diagnostic the rule names. A rule with no corpus entry is not yet a rule the implementation is obliged to honour.

## 1. The Store, Bindings, and Internal Registers

A module is a pair $M = \langle E, C \rangle$ where $E \subseteq_{\mathrm{fin}} \mathbb{N}$ is a finite set of entity ids (each representing a **binding**, a type, a namespace, or an alias) and $C$ is a family of partial component maps $C : E \rightharpoonup V_C$ (component values which are defined in the following table).

| Component        | Codomain                              | Layer            | Meaning                                                                            |
| ---------------- | ------------------------------------- | ---------------- | ---------------------------------------------------------------------------------- |
| `Name`           | `StringId`                            | Source binding   | Interned declaration name; absent for `_` declarations.                            |
| `SymbolName`     | `StringId`                            | Source binding   | ABI symbol of a function or static; the `R-Mangle` name unless set by `M-SymbolName`.  |
| `Parent`         | `EntityId`                            | Source binding   | Enclosing block entity; for a parameter, its function type (`R-Param`); for a function type written in place, the declaration it types.                                                            |
| `Block`          | `EntityId*`                           | Source binding   | Ordered child binding declarations.                                                |
| `TypeOf`         | `EntityId`                            | Source binding   | Type binding of this value; `type` for a type entity.                              |
| `TypeDefinition` | $\mathbb{N}^3$                        | Source binding       | $\langle \text{size}, \text{align}, \text{unique} \rangle$ in bits.                |
| `Alias`          | `EntityId`                            | Source binding   | Makes this entity another name for a binding.                                      |
| `Pointer`        | $E \times \mathbb{N}$                 | Source binding       | $\langle \text{pointee}, \text{len} \rangle$ ($0 = \text{ptr}, >0 = \text{array}$). |
| `FunctionInputs` | `EntityId*`                           | Source binding   | Parameter bindings of a function type, or argument bindings of a call (`WF-Par`).  |
| `FunctionReturn` | `EntityId`                            | Source binding   | Return type binding of a function type (`void` when omitted), copied onto functions declared with it. |
| `Call`           | `EntityId`                            | Source binding   | Callee binding.                                                                    |
| `ConstantVal`    | number or byte string                 | Source binding   | Literal payload (`V-Literal`).                                                     |
| $C_A$            | value of type $A$                     | Attribute        | One component per attribute type $A$ (`AT-Type`).                                   |
| `VirtualReg_\tau`  | `VRegId`                              | Internal IR      | The binding's internal virtual register (temporary) for target $\tau$ (`REG-Virt`).    |
| `PhysicalReg_\tau` | `PRegId` $\cup$ `SpillSlot`           | Internal Backend | The binding's assigned hardware register or spill offset for target $\tau$ (`REG-Phys`). |
| `Rank`           | `u16`                                 | Tower            | Rank of the entity's level in the tower (`L-Tower`).                               |
| `Flags`          | $\mathcal{P}(F)$                      | Metadata         | Set of flags from the table below.                                                 |
| `On`             | $\mathcal{P}(\text{target})$          | Metadata         | Targets given by `std.targets.compile_for`; absent means live wherever the parent is (`T-Live`). |
| `Overloads`      | $\mathcal{P}(\text{EntityId})$        | Metadata         | Member functions of an overload set, added by `std.functions.add_overload` (`TF-Overload`). |
| `Lowered`        | $\mathcal{P}(\text{target})$          | Descent          | Targets whose lowering has retired the entity (`L-Erase`); absent means retired under none. |

> **In Plain English:** Think of the compiler as an in-memory relational database or Entity-Component System (ECS). Every variable, type, namespace, and literal is just an ID number (an entity id $e$). Instead of using heavy object trees or AST nodes, each ID has "rows" of data attached to it—such as its name, its parent block, its data type, or its assigned virtual and physical registers. In a multi-target build (`T-Value`), backend-specific components (`VirtualReg` and `PhysicalReg`) are indexed by target $\tau$, and `Lowered` relates an entity to every target whose descent has retired it, however many the build has. Each target's part (its registers, and its own entry in `Lowered`) is owned by target $\tau$'s lowering query, allowing independent targets to coexist in the store without clobbering each other.

The flag set $F$:

| Flag                | Set by                                                         | Meaning                                                                   |
| ------------------- | -------------------------------------------------------------- | ------------------------------------------------------------------------- |
| `Valueless`         | Parser (declaration without `=`)                               | Declared without a value (struct fields, bodiless functions).             |
| `Namespace`         | `: namespace`                                                  | The entity is a namespace.                                                |
| `Export`            | `export`                                                       | Visible to importing files (`I-Export`).                                  |
| `Comptime`          | `C-Constant`, `C-Call`, `C-Type`, `C-FnType`, `C-Specialize`; comptime results (`FP-Address`, `MEM-Static`) | Known during the current level's comptime.                                |
| `AlwaysComptime`    | `std.types.always_comptime`; builtins `type`, `block`, `deduced type`, `pack`, `compiler.entity`, `compiler.level` | On a type: every value of it is `Comptime` (`C-Type`). On a function type, additionally: every call through it folds (`C-Call`). |
| `NeverComptime`     | `std.types.never_comptime`                                     | Calls through this function type are never folded (`C-Call`); they are still specialized (`C-Specialize`). |
| `SharedBody`   | `std.types.share_body_across_values`                                   | An argument passed to a parameter of this type is never a specialization key; a comptime one is converted to runtime (`C-SharedBody`). |
| `Union`             | `std.types.union`                                              | Fields overlap at offset 0 (`S-Field`).                                   |
| `Packed`            | `std.types.packed`                                             | Fields are packed to the bit, with no padding (`S-Field`).                |
| `Signed`            | `compiler.signed_base_type`                                    | Arithmetic, comparison and extension on the type are two's-complement signed (`S-Numeric`). |
| `Float`             | `compiler.float_base_type`                                     | Arithmetic and comparison on the type are IEEE 754 (`S-Numeric`, `N-Float`). |
| `ReadOnly`         | `std.pointers.read_only`                                       | Storing through a pointer of this type is a diagnostic.                   |
| `Inline`            | `std.functions.always_inline` on a function type; `inline` keyword on a call | The body is spliced into the caller (`C-Inline`).                         |
| `NeverInline`       | `std.functions.never_inline`                                   | Calls through this function type are never inlined by the optimizer; a call that must be spliced (`B-Inline`) is ill-formed. |
| `Flatten`           | `std.functions.always_inline_recursively` on a function type; `flatten` keyword on a call | The body and everything it calls are inlined.                             |
| `Tail`              | `tail` keyword on a call                                       | The call is emitted as a tail call (`B-Tail`).                            |
| `Pure`              | Compiler only                                                  | An unused call may be removed; never set on modifiers (`M-Impure`).       |

### **[SSA] Single Static Assignment of Bindings**

$$
\text{Each declaration is one binding, assigned }\textbf{exactly once}\text{, never reassigned.}
$$

> **In Plain English:** Every name is set in stone the moment it is declared. You cannot reassign a binding or point an existing identifier to something else later in the program. A declaration inside a loop body is bound once per iteration, since each iteration runs the body afresh (`B-Loop`).

### **[E-Remap] Entity Renumbering**

$$
\frac{\pi : E \to E' \text{ a bijective renumbering} \quad \text{no comptime evaluation is running}}{\forall C, e: \quad C'(\pi(e)) = \pi^{*}(C(e))}
$$

where $\pi^{*}$ applies $\pi$ to every entity id inside a component value (`Parent`, `Block`, `TypeOf`, `Alias`, `Pointer`, `FunctionInputs`, `FunctionReturn`, `Call`, the targets in `On` and `Lowered`, every attribute component $C_A$ whose value holds a `compiler.entity` or a function, the comptime value of every binding of an always-comptime type — `compiler.entity`, `compiler.level`, `type`, `block`, `pack` — or of a function pointer type, the positioned effect logs behind `C-Order`, and the keys and values of query entities).

> **In Plain English:** Entity ids are plain natural numbers and may be renumbered (compaction, canonical ordering, matching a reparse to the previous parse). A renumbering is sound only if every holder of an entity id is rewritten in the same step: entity-valued components, attribute values, comptime values that are entities (a `meta.entity` binding's value is an id), and query memo tables. Renumbering happens only between levels (`L-Stage`) or between edits, when no interpreted frame and no comptime memory exist (`MEM-Comptime`), so no entity id can be hiding in untyped bytes. The one value that does reach memory is a function address (`FP-Address`), which may be stored in static storage at comptime (`MEM-Static`); in memory it is a relocation the store issues and rewrites, never a raw id (`H-ABI`). `compiler.entity` is always-comptime, so an entity id never reaches runtime or static storage (`MEM-Escape`). The legacy compiler's comptime corruption, which once motivated generational keys, came from holders that were skipped; under this discipline it cannot arise.

---

## 2. Well-Formedness Rules

- **[val] Value Components:**  
  $$
  \text{val}(e) = \{\, k \in \{\text{ConstantVal}, \text{Call}, \text{FunctionReturn}, \text{Block}\} \mid e : k \,\} \;\cup\; \{\, \text{Valueless} \mid \text{Valueless} \in \text{Flags}(e) \,\}
  $$
  > **In Plain English:** The set of value sources an entity has: which of the constant, call, return-type and block components it carries, plus `Valueless` if it is explicitly marked as having no value.
- **[WF-Val] Single Binding Definition:**  
  $$
  \frac{e : \text{TypeOf} \quad e \not: \text{TypeDefinition}}{|\text{val}(e)| = 1 \;\lor\; \text{val}(e) = \{\text{FunctionReturn}, \text{Block}\} \;\lor\; \text{val}(e) = \{\text{FunctionReturn}, \text{Valueless}\}}
  $$
  > **In Plain English:** Every typed variable has exactly one source of data: a literal, a call result, a code block, or explicitly nothing (`Valueless`, e.g. a struct field). Functions are the only exception, in two shapes: a defined function carries its return type and its body; a declared-but-undefined function (a prototype) carries its return type and `Valueless`. A type entity's value is its definition (`WF-Kind`).
- **[WF-Arg] Arguments Name Bindings:**  
  $$
  \frac{c : \text{Call} \quad a \in \text{FunctionInputs}(c) \quad a \text{ is a literal, a block, or a nested call}}{\text{ill-formed}}
  $$
  > **In Plain English:** You cannot nest anything inside a function call: no `add(1 + 2)`, no `store(p, 0)`, no inline block handed to `std.if`. Every piece of data — a constant, a block, an intermediate — gets its own line and its own name, and only that name is passed.
- **[WF-Order] A Binding Is Read After It Is Bound:**  
  $$
  \frac{a \in \text{FunctionInputs}(c) \quad b = \alpha(a) \quad b \text{ is not a type, function, namespace, or label (B-Label)} \quad \text{bind}(b) > \text{pos}(c)}{\text{ill-formed}}
  $$
  > **In Plain English:** Name resolution is order-independent (`R-Order`), so a function or a type may be mentioned before the line that declares it, and so may a label, which a forward jump has to name (`B-Label`). A *value* is not: under `SSA` it has one binding, and under `C-Order` store effects run in lexical position, so reading `x` on the line above the one that binds `x` reads a binding that has no value yet. A block argument is checked at the call that splices it, not at the line that declares the block, which is why a branch may read a name bound after the branch is written but before the `std.if` that runs it. Bridging a limit before the limit is computed is the commonest form of this error. When jumps are involved, "before" means on every path that reaches the read (`B-Label`).
- **[WF-ToRuntime] Runtime Operands Are Named and Converted to Runtime:**  
  $$
  \frac{c : \text{Call} \quad c \text{ is emitted (neither folded nor inlined)} \quad a \in \text{FunctionInputs}(c) \quad a \text{ is not a specialization key of } c \text{ (C-Specialize)} \quad \text{Comptime} \in \text{Flags}(a) \quad \text{AlwaysComptime} \notin \text{Flags}(\text{TypeOf}(a)) \quad \alpha(\text{Call}(c)) \neq \mathrm{std.comptime\_to\_runtime}}{\text{ill-formed}}
  $$
  > **In Plain English:** A comptime binding exists only in the compiler. An emitted call to a function with a body binds its comptime arguments into a specialization (`C-Specialize`), so they never become operands. The arguments left are those that are not keys: every argument of a prototype without a body (a machine primitive or a linked symbol) or of an indirect call (`FP-Call`), and an argument whose parameter type is marked `std.types.share_body_across_values` (`C-SharedBody`). They are runtime operands, so a comptime binding of an ordinary value type cannot be passed as one without first being converted to runtime by `std.comptime_to_runtime` (`C-ToRuntime`). Literals are the commonest case: a number, string or character is comptime by `C-Constant`, so every constant a primitive such as `std.add` needs has to be named and converted to runtime first. Values of always-comptime types (types, blocks, packs, entities) are exempt: a primitive such as `std.copy(T, v)` consumes its type in the compiler when the instruction is selected, not as an operand. A body cannot consume one without a copy of its own, so passing one through a function pointer is ill-formed (`FP-Call`), and no type is both always-comptime and `SharedBody` (`M-Flag`). A folded or inlined call is not emitted, so it is not subject to the rule; the transition primitive is exempt, since converting to runtime is exactly what it does. An emitted terminator is a call like any other (`C-Term`).
- **[WF-Term] Explicit Terminators:**  
  $$
  \text{Every function body, every block binding (of type } \mathtt{block}\text{, or the direct value of a declaration not of type } \mathtt{type} \text{ or } \mathtt{namespace}\text{, B-Result), and the program's root on the host target, where it executes as a script (L-Entry) must end with a call to a terminator } (\mathtt{std.return}, \mathtt{std.block_result}, \mathtt{std.halt}\text{, or a } \mathtt{tail} \text{ call, B-Tail}).
  $$
  > **In Plain English:** Execution can never "fall off the edge" of a block. This applies to every block that runs, including the blocks spliced in by `std.if` and `B-Loop` bodies: an empty branch still has to say how it ends, so a do-nothing branch is `skip : block = { _ : _ = std.block_result(std.nothing) ; }` (`WF-Void`). The rule is syntactic, so a `block` binding must end properly even if nothing ever runs it. Bodies that are never executed — a type definition, a namespace, the root of a file that is not the program, or the root of an accelerator/compute target where the file contributes only exported entry points (`L-Entry`) — are not held to it.
- **[WF-Void] Returning and Yielding Nothing:**  
  $$
  \frac{f : (\dots) \to \mathtt{void} \;\lor\; \text{the value of block } B \text{ is unused}}{\mathrm{std.return}(\mathrm{std.nothing}) \text{ in } f \quad\text{and}\quad \mathrm{std.block\_result}(\mathrm{std.nothing}) \text{ in } B \text{ are the terminators that hand back no value}}
  $$
  > **In Plain English:** `std.nothing : void` is the single value of the empty type, made by `TF-Construct` with no fields. A function with no return type ends `std.return(std.nothing)`, and a block run only for its effects ends `std.block_result(std.nothing)`. Nothing is converted to runtime for it and it occupies no register: `void` has size 0, so `REG-Virt` never assigns it one.
- **[WF-Par] Bijective Parentage:**  
  $$
  e : \text{Parent} \land B = \text{Parent}(e) \implies e \in \text{Block}(B) \;\lor\; e \in \text{FunctionInputs}(B) \text{ with } B \text{ a function type} \;\lor\; e = \text{TypeOf}(B)
  $$
  > **In Plain English:** If declaration $e$ claims to live inside block $B$, then block $B$ must also list $e$ in its list of children. The parent-child relationship must match on both sides. Two entities have a parent that is not a block: a parameter, listed by its function type's `FunctionInputs` (`R-Param`), and a function type written in place (`x : (a: T) -> U = ...`), the type of the declaration that is its parent; their names resolve through that parent (`R-Unqual`).
- **[WF-Kind] Exclusive Entity Kinds:**  
  $$
  \text{Each entity } e \text{ is exactly one of: value } (e : \text{TypeOf},\ e \not: \text{TypeDefinition}),\ \text{type } (e : \text{TypeDefinition},\ \alpha(\text{TypeOf}(e)) = \mathtt{type}),\ \text{namespace } (\text{Namespace} \in \text{Flags}(e)),\ \text{alias } (e : \text{Alias}).
  $$
  > **In Plain English:** An entity has an unambiguous role, and each kind forbids the others' components. A type is a value of type `type` that also carries its layout; its definition is its `Block` of fields (an aggregate), its `FunctionInputs` and `FunctionReturn` (a function type), its `Pointer` (a pointer or array), or nothing beyond its layout (a base type). An alias is only a name: it carries `Name`, `Parent`, `Alias` and possibly the `Export` flag, nothing else; the type written on its declaration is checked against its referent and then dropped (`A-Bind`). A namespace likewise carries no `TypeOf`: `namespace` is a marker, like `alias`. A declaration that becomes an alias by `A-Bind` keeps its parsed components as inputs, but every read goes through $\alpha$ (`A-Transparent`), so they are never seen.
- **[WF-Unique] One Declaration per Name per Block:**  
  $$
  e_1 \ne e_2 \in \text{Block}(B) \quad \text{Name}(e_1) = \text{Name}(e_2) \implies \text{both are namespaces (R-Merge)}
  $$
  > **In Plain English:** A block may not declare the same name twice, whether by writing it twice or by importing it (`I-Import`). Namespaces are the one thing that may be reopened, and `_` declarations have no name, so they never collide.

---

## 3. Name & Alias Resolution

- **[A-Res] Source Alias Resolution:**  
  $$
  \alpha(e) = \begin{cases} \alpha(\text{Alias}(e)) & \text{if } e : \text{Alias} \\ e & \text{otherwise} \end{cases}
  $$
  > **In Plain English:** When looking up what a source alias points to, the compiler follows the redirect chain all the way to the end until it finds the actual underlying entity ($\alpha$ means "resolve all aliases"). An alias is resolved where it is used, not where it is declared: an alias whose referent does not exist is well-formed until something uses it, and that use is the error (`T-Optional` depends on this). An alias chain that returns to itself is a cycle (`Q-Cycle`).
- **[A-Transparent] Aliases Are Views:**  
  $$
  e : \text{Alias} \implies C(e) = C(\alpha(e)) \quad \text{for every component } C \notin \{\text{Name}, \text{Parent}, \text{Alias}\}, \text{ and } \text{Flags}(e) \setminus \{\text{Export}\} = \text{Flags}(\alpha(e)) \setminus \{\text{Export}\}
  $$
  > **In Plain English:** An alias is another name for the same object, not a new object. Reading its type, value, flags, virtual register or physical register reads those of the aliased entity; in particular $\text{VirtualReg}_\tau(e) = \text{VirtualReg}_\tau(\alpha(e))$ and $\text{PhysicalReg}_\tau(e) = \text{PhysicalReg}_\tau(\alpha(e))$ for each target $\tau$. The only flag an alias owns is its own `Export`.
- **[A-Bind] Results That Are Entities Bind as Aliases:**  
  $$
  \frac{\langle c : \tau = v \rangle \quad v \text{ hands back an existing entity } t \text{ (a type, a function, or a binding a splice hands back, C-Term)}}{\text{Alias}(c) := t \quad \text{and } \tau \text{ must be } \mathtt{type}, \mathtt{\_}, \text{ or } \sim \text{TypeOf}(t)}
  $$
  > **In Plain English:** A type former, a modifier, `set_symbol_name`, `from_entity`, `bind_arguments`, `packs.get`, and a block whose value is not emitted all hand back something that already exists. The declaration receiving it becomes another name for it rather than a copy, so `a : type = list(std.u8)` and `b : type = list(std.u8)` name one type (`TF-Memo`), and `out : type = meta.from_entity(e)` names the type `e` stands for. This is the only way a declaration with a value becomes an alias besides `: alias`. The `Alias` component is written by the evaluation of $c$, not by the parser, so re-evaluating $c$ after an edit replaces it, and the parsed `Call` stays as the input that evaluation reads (`WF-Kind`).
- **[findIn / nsIn] Member and Segment Lookup:**  
  $$
  \text{findIn}(B, n) = \text{the } e \in \text{Block}(B) \text{ with } \text{Name}(e) = n
  $$
  $$
  \text{nsIn}(B, s) = \alpha(e) \quad \text{if } \text{findIn}(B, s) = e \land \text{Namespace} \in \text{Flags}(\alpha(e))
  $$
  > **In Plain English:** `findIn` searches inside a specific block for the item named $n$; there is at most one (`WF-Unique`). `nsIn` does the same but verifies that the found item is actually a namespace (even if reached through an alias).
- **[R-Unqual] Unqualified Lookup:**  
  $$
  \text{Walks the scope chain } \sigma(e, \tau) = \langle B_0, B_1, \dots, R_E, R_{E_1}, \dots, R_{E_m}, R_\varepsilon \rangle \text{ outward, returning the first binding matching } \text{Name}\text{; } E = \text{LevelOf}(e)\text{, and } E_1, \dots, E_m \text{ is } \text{View}_\tau(E) = \{E' \in \text{Below}(E) \mid \text{Targets}(E') = \varnothing \lor \tau \in \text{Targets}(E')\} \text{ by decreasing rank. A root } R_{E_i} \text{ matches only namespaces; two of equal rank matching is ambiguous.}
  $$
  > **In Plain English:** When you refer to a bare name like `x`, the compiler checks your current local block first. If it is not found, it checks the enclosing outer block (and, inside a function body, the function's parameters, `R-Param`), continuing outward to the root of your level ($R_E$, `L-Tower`): your file's root, or the block of the namespace made into a level that you are written in. It then checks the roots of the levels below yours, nearest first, ending with the builtin block ($R_\varepsilon$, Part I §7). Which levels count as below depends on the target $\tau$ being evaluated for (`T-Split`). A level whose way down reaches only other targets is not seen, so under x86, looking down from `std` finds the members of x86's backend namespace: `machine.u1` names x86's type, and two backends never collide. A level that reaches no target is seen under every one. Only the namespaces at a lower level's root are found (`machine`, `compiler_impl`, `std`, `targets`). For a namespace made into a level, the root is its own block, so its members are found, not the namespace. Everything a lower level supplies is reached through its namespaces (`machine.u1`), and its other root declarations, such as the path an import reads, stay private to it. Two levels of the same rank that both answer a name make it ambiguous, and the name is ill-formed. The builtin block is the one lower root whose bare names are found too (`type`, `block`, `void`).
- **[R-Qual] Qualified Path Lookup:**  
  $$
  \text{Leading segment walks } \sigma(e)\text{; subsequent segments are sought strictly inside the resolved } \text{Block}.
  $$
  > **In Plain English:** When resolving a path like `math.vec2.x`, only the first name (`math`) is looked up across outer scopes. Once `math` is found, `vec2` must be inside it, and `x` must be inside `vec2`.
- **[R-Param] Parameters Are Declared per Function:**  
  $$
  \frac{f : \tau = B \quad \text{FunctionInputs}(\alpha(\tau)) = \langle p_1, \dots, p_n \rangle}{f \text{ owns fresh copies } \langle p_1', \dots, p_n' \rangle \text{ that sit in } \sigma \text{ between } B \text{ and } \text{Parent}(f)}
  $$
  > **In Plain English:** A function type may be declared once and shared by many functions (`modifier_t` types every `std.types` modifier). Each function declared with it gets its own copies of the type's parameters, and its body sees them as though they were declared just outside the body. A parameter named in the function type's own return type (`(T: type) -> T`) refers to that parameter.
- **[R-Merge] Namespace Merging:**  
  $$
  \text{Multiple declarations of } \mathtt{namespace}\text{ with the same name in the same block merge their children in lexical order.}
  $$
  > **In Plain English:** You can re-open a namespace multiple times (but not any other construct like types or functions). DOIR simply merges their contents together in the order they were written. Imports merge into namespaces the same way (`I-Import`).
- **[R-Shadow] Inner Names Shadow Outer Ones:**  
  $$
  \text{findIn}(B_0, n) \text{ succeeds} \implies e \vdash n \Downarrow \text{findIn}(B_0, n) \quad \text{even if } \text{findIn}(B_k, n) \text{ also succeeds for } k > 0
  $$
  > **In Plain English:** A name declared in an inner block hides a name declared in an enclosing one, exactly as in most languages. `R-Order` makes the inner binding visible to the whole inner block regardless of which line it is written on, so shadowing is not order-sensitive; the outer name is still reachable from any block that is not inside the inner one.
- **[R-Order] Block Order Independence:**  
  $$
  e \vdash n \Downarrow e' \text{ is independent of the relative declaration positions of } e \text{ and } e' \text{ within } \text{Block}(B)
  $$
  > **In Plain English:** Inside any given block, name resolution does not care what line an item was written on ($e \vdash n \Downarrow e'$ means "in context $e$, name $n$ evaluates to $e'$"). You can use a function or type before the line it is defined on; forward references and mutual recursion work naturally. Lexical order matters only for store effects (`C-Order`); an import's names are visible to the whole block, like declared names (`I-Import`).
- **[R-Mangle] Namespaces as Symbol Prefixes:**  
  $$
  \forall e \text{ declared directly in namespace } N: \quad \text{SymbolName}(e) := \text{SymbolName}(N) \cdot \texttt{"."} \cdot \text{Name}(e)
  $$
  > **In Plain English:** Namespaces do not exist as data structures at runtime.
  > A symbol's ABI name is its namespace path joined with dots (`math` + `add` becomes `math.add`); its `Name` stays `add`, so lookup is unaffected.
  > A namespace made into a level adds no prefix: its members are named as though declared at a file root, so `x86_backend.std.integer.add` has the symbol `std.integer.add` (`I-Extern`).
  > `M-SymbolName` replaces the result.

---

## 4. Modules, Import, and Export

- **[I-Export] Cross-File Export Gating:**  
  $$
  \frac{M' \text{ imports } M \quad e \in M}{e \text{ visible in } M' \iff \text{Export} \in \text{Flags}(e)}
  $$
  > **In Plain English:** When another file imports your file, it can only see items marked with the `Export` flag. All other declarations remain private to the file. A higher level sees a lower level's root namespaces through the scope chain instead (`R-Unqual`), and the same gating applies to what it can reach inside them.
- **[I-ExportPath] Namespaces on an Export's Path:**  
  $$
  \frac{M' \text{ imports } M \quad e \text{ visible in } M' \quad N \text{ a namespace enclosing } e}{N \text{ resolves as a qualified-path segment in } M'}
  $$
  > **In Plain English:** An unexported namespace that contains exports (like `std` or `std.types`) can still be named in a path to reach them, but its unexported members stay hidden.
- **[I-ExportNS] Namespace Export Propagation:**  
  $$
  \frac{\text{Export} \in \text{Flags}(N) \quad \text{Namespace} \in \text{Flags}(N) \quad e \text{ in subtree of } N}{\text{Flags}(e) := \text{Flags}(e) \cup \{\text{Export}\}}
  $$
  > **In Plain English:** If you mark a namespace as exported, every declaration inside that namespace is automatically exported as well.
- **[I-Import] Import Yields a Finished File:**  
  $$
  \mathrm{std.import}(p) \text{ evaluates file } p \text{ to completion (its semantic analysis and all of its comptime, imports included) and freezes it, then adds an alias in the enclosing scope for every name } p \text{ makes visible; a namespace whose name already names a namespace merges into it (R-Merge), recursively.}
  $$
  > **In Plain English:** An imported file arrives finished, as though it were the top of its own tower and ready for lowering: every modifier, attribute and other comptime effect it makes has already run, and the importer sees only the end result. Its names are visible to every lookup in the enclosing scope, whatever line the import is on (`R-Order`), and a read of one of its entities is keyed by the entity alone, as a read of a frozen level is (`L-Freeze`). Its types are frozen too, so the importer cannot modify them (`M-Freeze`); it makes a variant with `std.types.distinct_copy` instead. A file is finished before anything reads it, so it cannot see its importer, and two files that import each other are a cycle (`Q-Cycle`). A path is relative to the file that contains the import. A file is loaded once in each level that imports it (`L-Tower`), so its comptime runs once per level; every import of it within one level, from any scope, adds aliases to the same entities. Two levels that import one file get a copy each, with entities of their own: a backend file imported into two backend namespaces gives each backend its own types and bodies, live for its own target (`T-Live`) and invisible to the other (`L-Mono`). Code that several levels must share as one set of entities is a level of its own that they all lower onto (`T-Device`), not a file they each import. A name that already names the same entity is not a collision, so importing a file twice adds nothing. Any other collision with a declaration in that scope is an error (`WF-Unique`). An import inside a namespace places its names in that namespace. Because namespaces merge, many files may each contribute to one namespace (`fp.pointer`, `fp.dynarray`, … under `fp`). Levels below `std` cannot name `std.import`; what they have is `compiler.paste_file`, which is not an import (`I-Paste`).
- **[I-Paste] Early Include Pastes a File:**  
  $$
  \frac{\langle c : \_ = \mathrm{compiler.paste\_file}(p) \rangle \text{ at position } k \text{ of block } B}{\text{the declarations of file } p \text{ are parsed into } B \text{ at } k \text{, as if written there}}
  $$
  > **In Plain English:** `compiler.paste_file` copies a file into the block that names it; it does not import it. The pasted declarations are the includer's own: they belong to its level (`L-Tower`), run in its lexical comptime order and freeze with it (`C-Order`, `L-Freeze`), may modify and be modified by the declarations around them, and are read by the scan like any other line (`L-Scan`). Nothing is evaluated or frozen separately and no aliases are added, so pasting one file twice into a block declares its names twice (`WF-Unique`). At level scope the scan pastes the file before ascent, so there the path must be a name bound to a string literal. This is how a backends file fills a backend namespace from `machine.doir` (`reference/backends.doir`). It is a bootstrap name (`H-Boot`): wherever `std` can be named, `std.import` gives a finished, separately compiled file instead (`I-Import`).
- **[I-Language] Foreign-Language Blocks:**  
  $$
  \mathtt{language}\ \texttt{"}n\texttt{"}\ \{\ \text{text}\ \} \rightsquigarrow \text{the declarations the host's frontend for } n \text{ produces from text, added to the enclosing block at that position}
  $$
  > **In Plain English:** DOIR can carry source written in another language. The text between the matched braces is not parsed as DOIR; it is handed to the frontend the host registers for that name, which turns it into ordinary declarations in place. A name with no registered frontend is an error. Which frontends exist is the host's business; this repository's compiler registers none, so it parses a `language` block and reports it as this error.
- **[I-Extern] Bodyless Declarations Are Prototypes:**  
  $$
  \frac{f : \text{FunctionType} \quad \text{val}(f) = \{\text{FunctionReturn}, \text{Valueless}\}}{f \text{ is callable; a call to it calls the definition bound to it}}
  $$
  $$
  \text{bound to: the host (H-Hook); else, for target } \tau\text{, the definition with the same } \text{SymbolName} \text{ in } \text{LevelOf}(f) \text{ or a level of } \text{View}_\tau(\text{LevelOf}(f)) \text{ (R-Unqual), lowest rank first; else the linker}
  $$
  > **In Plain English:** Naming a function with a type but no body is how DOIR refers to something it does not define.
  > A host hook is supplied by the compiler.
  > Otherwise the prototype binds to a definition with the same symbol name in its own level or one below it that is visible under the target being lowered for (`R-Unqual`): a backend supplies `std.integer.add` by declaring `std : namespace = { integer : namespace = { add : ... = { ... } } }` in its namespace, whose symbol is also `std.integer.add` (`R-Mangle`), so each target binds its own.
  > The lowest-ranked definition wins, the one nearest the target, so a portable body written higher up is a default the target can replace.
  > That is how `standard.emulated.doir` works: it gives `std` a software body for each prototype it can write over a few primitives, each renamed to its prototype's symbol (`M-SymbolName`), and a backend that defines the same name replaces it without either naming the other.
  > A definition passed over is not lowered for that target, so the symbol is defined once; two definitions of equal rank are ambiguous, as in `R-Unqual`.
  > The definition's type must be equivalent to the prototype's (`S-Struct`).
  > With no definition anywhere, the symbol is left for the linker, so calling one whose body never appears is a link error, not a compile error.

---

## 5. Type Identity & The Modifier Discipline

- **[S-Struct] Structural Equivalence:**  
  $$
  T_1 \sim T_2 \iff \langle \text{size}, \text{align}, \text{unique} \rangle(T_1) = \langle \text{size}, \text{align}, \text{unique} \rangle(T_2) \;\land\; \text{shape}(T_1) \approx \text{shape}(T_2)
  $$
  $$
  \begin{aligned}
  \text{base} &\approx \text{base} \\
  \text{Pointer}\langle p_1, n \rangle &\approx \text{Pointer}\langle p_2, n \rangle && \text{if } p_1 \sim p_2 \\
  \text{aggregate}\langle f_1..f_k \rangle &\approx \text{aggregate}\langle g_1..g_k \rangle && \text{if } \text{Flags} \cap \{\text{Packed}, \text{Union}\} \text{ agree and } \text{TypeOf}(f_i) \sim \text{TypeOf}(g_i) \\
  (p_1..p_k) \to r &\approx (q_1..q_k) \to s && \text{if } \text{TypeOf}(p_i) \sim \text{TypeOf}(q_i) \text{ and } r \approx_\alpha s
  \end{aligned}
  $$
  where $r \approx_\alpha s$ holds when $r$ and $s$ refer to corresponding parameters $p_i$ and $q_i$ (identical parameter index, $\alpha$-equivalence), and otherwise when $r \sim s$.
  > **In Plain English:** DOIR uses structural typing. Two types are interchangeable ($T_1 \sim T_2$) if they occupy the same number of bits, share the same alignment and uniqueness tag, and have the same shape all the way down: pointers and arrays point at interchangeable types with the same length; aggregates have interchangeable fields in the same order with the same layout flags; function types have interchangeable parameters and returns. Parameter-dependent return types compare equal when they refer to the corresponding parameter index (such as `(T: type) -> T` and `(U: type) -> U`). Shapes of different kinds never match, so a pointer never converts to `std.pointer_sized`, and `{ a: u32, b: u32 }` is not `{ x: u64 }`. Field names and flags other than `Packed` and `Union` do not count. The relation is read coinductively, so a recursive type (`TF-Self`) compares equal to itself without triggering query cycle errors (`Q-Cycle`). Crossing between non-equivalent types is an explicit `std.reinterpret_bits`.
- **[S-Numeric] Signed and Float Base Types:**  
  $$
  \text{signed\_base\_type}(s, a) \rightsquigarrow \langle s, a, \nu_{\text{signed}} \rangle,\ \text{Signed} \qquad \text{float\_base\_type}(s, a) \rightsquigarrow \langle s, a, \nu_{\text{float}} \rangle,\ \text{Float}
  $$
  > **In Plain English:** Signedness and floating point are part of a type's identity: the two reserved discriminators keep `i64` apart from `u64` and `f64` from both under `S-Struct`, so `std.pointer_difference` is a distinct type from `std.pointer_sized` and converts to it only through `std.numbers.widen`, `truncate`, or `std.reinterpret_bits`. Operations that care (`std.is_less`, `std.divide`, `std.shift_right`, `std.numbers.widen`) read the `Signed` or `Float` flag of their operand type (§13).
- **[S-Field] Layout in Memory:**  
  $$
  \text{storage}(T) = \text{alignUp}(\text{size}(T), 8) \qquad \text{malign}(T) = \max(\text{align}(T), 8) \qquad \text{stride}(T) = \text{alignUp}(\text{storage}(T), \text{malign}(T))
  $$
  $$
  \frac{\text{Block}(T) = \langle f_1, \dots, f_n \rangle \quad \langle w_i, a_i \rangle = \begin{cases} \langle \text{size}(\text{TypeOf}(f_i)), 1 \rangle & \text{if Packed} \in \text{Flags}(T) \\ \langle \text{storage}(\text{TypeOf}(f_i)), \text{malign}(\text{TypeOf}(f_i)) \rangle & \text{otherwise} \end{cases} \quad o_1 = 0 \quad o_{i+1} = \text{alignUp}(o_i + w_i, a_{i+1})}{\text{offset}(f_i) = o_i \;(0 \text{ if Union}) \quad \text{align}(T) = \max(8, a_1, \dots, a_n) \quad \text{size}(T) = \begin{cases} \text{end} & \text{if Packed} \in \text{Flags}(T) \\ \text{alignUp}(\text{end}, \text{align}(T)) & \text{otherwise} \end{cases}}
  $$
  where $\text{end} = o_n + w_n$ for a struct, $\max_i w_i$ for a union, and $0$ for an aggregate with no fields.
  > **In Plain English:** The bit is the base unit of size: sizes, alignments and offsets are counted in bits.
  > Memory is addressed in bytes, so anything stored on its own occupies whole bytes: an unpacked `u1` field takes a byte and an array of `u1` has a stride of 8 bits.
  > Unpacked field offsets are calculated by taking where the previous field ended and rounding up to satisfy the alignment of the next field.
  > A packed aggregate is packed to the bit: each field takes exactly its `size` and starts where the previous one ended, with no padding between fields or at the end, so `{ a: u1, b: u2 }` packed has size 3 and `b` sits at bit offset 1.
  > Bit offsets count from the least significant bit of the aggregate read as an integer of its size, stored in `machine.byte_order`, so a field's offset means the same on either byte order.
  > Only the packed aggregate as a whole is rounded to bytes when it is stored, so an array of them still has a byte stride.
  > In a union, all fields overlap at offset 0.
  > An unpacked aggregate is aligned to its most-aligned field and padded at the end to a multiple of that alignment.
  > Layout is computed from the flags whenever it is read, which is what lets `packed` and `union` be ordinary flags.
  > A function type is never laid out (`TF-FnType`); its layout is $\langle 0, 0, 0 \rangle$.
- **[S-Assign] Assignment Destination Agreement:**  
  $$
  \frac{e \vdash f \Downarrow \phi \quad \rho = \text{FunctionReturn of the specialization of } \phi \text{ selected for } c \quad \text{TypeOf}(c) = \tau}{\langle c : \tau = f(\dots) \rangle \text{ well-typed} \iff \rho \sim \tau}
  $$
  > **In Plain English:** When assigning the result of a function call to a binding $c$ of type $\tau$, the type returned by the function ($\rho$) must be structurally equivalent to $\tau$.
- **[M-Flag] In-Place Modifier Application:**  
  $$
  \frac{e \vdash a \Downarrow t \quad t : \text{TypeDefinition} \quad \mu \text{ has flag } f_\mu}{\langle c : \text{type} = \mu(a) \rangle \rightsquigarrow \text{Flags}(t) := \text{Flags}(t) \cup \{f_\mu\}; \quad \text{Alias}(c) := t \ \text{(A-Bind)}}
  $$
  > **In Plain English:** When you apply a modifier function $\mu$ (like making a type packed or immutable), the compiler attaches that flag directly to the existing type entity. In the query engine, intra-level modifier applications are recorded in a declaration-ordered effect log ⟨position, effect⟩ (`C-Order`, `M-Lexical`), ensuring that on-demand queries evaluated at position $k$ stay pure and memoized. At level freeze (`M-Freeze`), the log is folded once into the static `Flags` component. The call is consumed and $c$ becomes nothing more than another name for the modified type. A modifier changes the entity, not which entity a name denotes, so a flag reaches every name of the type, including every use of a memoized former result (`TF-Memo`): inside `std`'s level, applying `std.pointers.read_only` to the result of `std.types.pointer(std.u8)` would make `std.byte_pointer` immutable, and above it the same call is ill-formed because the type is frozen (`M-Freeze`). Only `Packed` and `Union` take part in `S-Struct`. To flag a variant, make it distinct first: `ro : type = std.types.distinct_copy(std.byte_pointer)`, then `_ : type = std.pointers.read_only(ro)`; converting between the two is then an explicit `std.reinterpret_bits`.

  | Modifier                        | Flag $f_\mu$        |
  | ------------------------------- | ------------------- |
  | `std.types.always_comptime`     | `AlwaysComptime`    |
  | `std.types.never_comptime`      | `NeverComptime`     |
  | `std.types.share_body_across_values`    | `SharedBody`   |
  | `std.types.union`               | `Union`             |
  | `std.types.packed`              | `Packed`            |
  | `std.pointers.read_only`        | `ReadOnly`         |
  | `std.functions.always_inline`   | `Inline`            |
  | `std.functions.never_inline`    | `NeverInline`       |
  | `std.functions.always_inline_recursively`  | `Flatten`           |

  A type carrying both `AlwaysComptime` and `NeverComptime`, both `AlwaysComptime` and `SharedBody`, or both `Inline` and `NeverInline`, is ill-formed. Not flag modifiers: the constructors `std.types.pointer`, `std.types.array`, `std.types.function_pointer` (`M-Ctor`) and `std.types.distinct_copy` (`M-Distinct`), `std.types.set_attribute_id` (`AT-Id`), and `std.functions.set_symbol_name` (`M-SymbolName`).
- **[M-SymbolName] Renaming Is an In-Place Mutation:**  
  $$
  \frac{e \vdash a \Downarrow f \quad e \vdash n \Downarrow s}{\langle c : \_ = \mathrm{std.functions.set\_symbol\_name}(a, n) \rangle \rightsquigarrow \text{SymbolName}(f) := s; \quad \text{Alias}(c) := f}
  $$
  > **In Plain English:** Like every modifier, `set_symbol_name` mutates the function it is given (`M-Alias`) rather than making a renamed copy, and its result is only another name for that function. The new name replaces the `R-Mangle` symbol, which is how a `I-Extern` prototype inside a namespace binds to a C symbol such as `realloc`.
- **[M-Distinct] Uniqueness Is Constructed:**  
  $$
  \frac{e \vdash a \Downarrow t' \quad t = \alpha(t') \quad c, \nu \text{ fresh}}{\mathrm{std.types.distinct\_copy}(a) \rightsquigarrow \text{TypeDefinition}(c) := \langle \text{size}(t), \text{align}(t), \nu \rangle;\ \text{Pointer}(c) := \text{Pointer}(t);\ \text{Flags}(c) := \text{Flags}(t);\ \text{Block}(c) := \text{copies of } \text{Block}(t)}
  $$
  > **In Plain English:** `std.types.distinct_copy` is a type constructor. It reads through aliases to the real type $t$, leaves $t$ untouched, and returns a brand-new type with the same fields, flags and layout but its own discriminator ($\nu$), so `S-Struct` no longer considers it equivalent to $t$. For example, `id : type = std.types.distinct_copy(std.pointer_sized)` makes a distinct pointer-sized type without affecting `std.pointer_sized`. Producing a fresh type is the whole point, so `distinct_copy` is exempt from `TF-Memo`: two calls with the same argument give two distinct types. A former that wants one unique type per argument calls `distinct_copy` inside its own body, and `TF-Memo` on that former keeps it to one call per argument.
- **[M-Freeze] Level Freeze Invariant:**  
  $$
  \text{Once } \text{cmp}(n) \text{ terminates, } \text{Flags}(t) \text{ and the layout of every level-}n\text{ type } t\text{, and the members of every level-}n\text{ overload set (TF-Overload), are permanently frozen.}
  $$
  > **In Plain English:** Once the compile-time analysis of a level completes, type definitions are locked. No further flags or struct layout changes can be made, and no overload set gains members; a modifier or `add_overload` applied from a higher level to a frozen entity is ill-formed. An imported file's types freeze the same way once its comptime finishes, so its importer cannot modify them either (`I-Import`). New entities a higher level creates — specializations, former results — belong to that higher level (`L-Tower`), so they are not frozen yet.
- **[M-Ctor] Type Constructors:**  
  $$
  \frac{e \vdash a \Downarrow t' \quad t = \alpha(t') \quad t : \text{TypeDefinition} \quad c = \text{the former result for } t \text{ (TF-Memo)}}{\begin{aligned} \mathrm{std.types.pointer}(a) &\rightsquigarrow \text{Pointer}(c) = \langle t, 0 \rangle;\ \text{TypeDefinition}(c) = \langle \text{size}(\mathtt{std.pointer\_sized}), \text{align}(\mathtt{std.pointer\_sized}), 0 \rangle \\ \mathrm{std.types.array}(a, n) &\rightsquigarrow \text{Pointer}(c) = \langle t, n \rangle;\ \text{TypeDefinition}(c) = \langle n \cdot \text{stride}(t), \text{malign}(t), 0 \rangle \\ \mathrm{std.types.function\_pointer}(a) &\rightsquigarrow \text{Pointer}(c) = \langle t, 0 \rangle;\ \text{TypeDefinition}(c) = \langle \text{size}(\mathtt{std.pointer\_sized}), \text{align}(\mathtt{std.pointer\_sized}), \nu_{\text{fn}} \rangle \end{aligned}}
  $$
  > **In Plain English:** Type constructors do not modify the input type $t$; they return the type built from it, creating it on the first call and returning the same entity on every later call with the same arguments (`TF-Memo`). That type is an ordinary type definition with a pointer-sized layout (pointer) or $n$ strided elements (array), so pointers to pointers are legal and `S-Struct` can compare it. Because the result is shared, a modifier applied to it applies to every use of it (`M-Flag`). `function_pointer` takes a function type and carries the reserved discriminator $\nu_{\text{fn}}$ (`FP-Type`).
- **[M-Idempotent] Modifier Idempotence:**  
  $$
  \mu(\mu(t)) = \mu(t) \quad \text{for every flag modifier } \mu
  $$
  > **In Plain English:** Applying the same flag modifier multiple times has the exact same effect as applying it once.
- **[M-Lexical] Lexical Application Timing:**  
  $$
  \text{Flags}(t) \text{ expands in declaration order during comptime evaluation.}
  $$
  > **In Plain English:** Type modifiers take effect step-by-step from top to bottom. A compile-time query will only see the modifiers that were written above it in the source file (`L-Freeze`).
- **[M-Alias] Modifier Alias Transmission:**  
  $$
  \mu(a) \text{ where } \alpha(a) = t \rightsquigarrow \text{mutates } t\text{, not } a
  $$
  > **In Plain English:** If you modify an alias, you are actually modifying the underlying real type that the alias points to. This has no exceptions; `std.types.distinct_copy` is a constructor, not a modifier (`M-Distinct`).
- **[M-Commute] Modifier Commutativity:**  
  $$
  \mu_1 \circ \mu_2 = \mu_2 \circ \mu_1 \quad \text{for flag modifiers}
  $$
  > **In Plain English:** The order in which you apply flag modifiers does not matter: applying flag A then flag B produces the exact same result as applying flag B then flag A.
  > This includes the layout flags `Packed` and `Union`, because layout is derived from the final flag set (`S-Field`).
- **[M-Impure] Modifier Impurity:**  
  $$
  \text{Pure} \notin \text{Flags}(\mu) \quad \text{for every modifier } \mu
  $$
  > **In Plain English:** Modifiers produce store effects inside the compiler's declaration log. The compiler is never allowed to optimize them away as "dead code."

---

## 6. Values, Duplication & Type Formers

- **[V-Literal] Literal Typing:**  
  $$
  \frac{\langle c : \tau = k \rangle \quad k \text{ a constant}}{\tau \ne \_ \quad \text{and } k \text{ fits } \alpha(\tau) \text{ as below}}
  $$
  > **In Plain English:** A literal takes the type written on its declaration, which must be written (not `_`).
  > - An integer or character literal fits an integer type (any base type without `Float`) of $n$ bits if its value is below $2^n$. The value is the bit pattern, so a `Signed` type reads it as two's complement (`0xFF : i8` is −1); negative values are made with `std.negate`. A character's value is its Unicode code point.
  > - A float literal fits only a `Float` type and is rounded to the nearest representable value, ties to even.
  > - A string or raw string literal fits a pointer to an 8-bit type; its value is a pointer to its UTF-8 bytes followed by a zero byte (`MEM-String`). A raw string has no escapes.
  > - No literal fits a pointer otherwise, an aggregate, or a function type; the null pointer is `std.pointers.null`.
- **[V-NoImplicitCopy] Naming a Binding is Not Copying:**  
  $$
  \frac{T \not\equiv \text{alias} \quad v \text{ is a binding identifier}}{\langle x : T = v \rangle \rightsquigarrow \text{ill-formed}}
  $$
  > **In Plain English:** You cannot duplicate a value just by re-assigning it to another variable name (`x : i32 = y` is an error). If you just want an alternative name, use `x : alias = y`. If you want an actual copy in hardware, you must explicitly call `std.copy()` or `std.move()`.
- **[V-Copy / V-Move] Value Duplication:**  
  $$
  \mathrm{std.copy}(T, v) \rightsquigarrow \text{fresh binding } c \text{ with fresh } \text{VirtualReg}_\tau(c) \text{ per lowered target } \tau; \quad v \text{ remains live}
  $$
  $$
  \mathrm{std.move}(T, v) \rightsquigarrow \mathrm{std.copy}(T, v); \quad \text{any read of } v \text{ at a later lexical position is ill-formed}
  $$
  > **In Plain English:** 
  > - `std.copy`: Duplicates the value into a brand-new binding. The original variable $v$ remains valid and can still be used. A copy of a comptime value folds, so the new binding is comptime and gets no virtual register (`REG-Virt`); the fresh register is for an emitted copy.
  > - `std.move`: Copies the value and ends the original. Its body is a copy; ending $v$ is a check the compiler makes at every call to `std.move`, by position (`C-Order`), so a read of $v$ on any later line — in any branch — is an error.
- **[TF-Construct] Aggregate Type Callability:**  
  $$
  \frac{T : \text{TypeDefinition} \quad \text{Block}(T) = \langle f_1, \dots, f_n \rangle \quad \text{TypeOf}(a_i) \sim \text{TypeOf}(f_i)}{T(a_1, \dots, a_n) : T}
  $$
  > **In Plain English:** Every struct type automatically acts as a constructor function. If you call the type name and pass values matching its fields in order, it returns a new instance of that struct. A union is constructed from one value for its first field. An aggregate value is handled whole: it can be stored, loaded, copied, passed and returned, and it folds when all its fields are comptime. Its fields are reached only through memory (`RF-FieldPtr`): store it, then take a field pointer.
- **[TF-Name] A Type Position Names a Binding:**  
  $$
  \frac{\langle x : \tau = v \rangle \text{ is a declaration} \quad \tau \notin \{\text{Identifier}, \text{FunctionType}\}}{\text{ill-formed}}
  $$
  > **In Plain English:** A constructed type is produced by a comptime call and bound to a name before it is used: `u8_pointer : type = std.types.pointer(std.u8)`, then `p : u8_pointer = ...`.
  > A former call written in a type position is a second syntax for a call that is already an ordinary call, and a parameter line containing one names a type the reader cannot look up.
  > Anything the name cannot carry — a range, an alignment, "is an aggregate" — is asserted in the body (`DG-Assert`), and so is a parameter type built from another parameter, which deduction then reads (`D-Assert`).
- **[TF-FnType] Only Functions Have Function Types:**  
  $$
  \frac{\alpha(\text{TypeOf}(e)) \text{ is a function type}}{\text{val}(e) \supseteq \{\text{FunctionReturn}\} \text{ (a definition or prototype)} \;\lor\; e : \text{Alias}}
  $$
  > **In Plain English:** A function type is the type of function declarations and nothing else. A field, a literal, or a call result cannot have a function type; a function held as a value is a `std.types.function_pointer` (`FP-Type`). A call that hands back a function (`bind_arguments`, `set_symbol_name`, `from_entity`) binds its destination as an alias of that function (`A-Bind`), so it is still a function declaration. A parameter is bound the same way: a function passed to a deduced parameter (`std.functions.address(f)`, `set_symbol_name(f, n)`) is comptime (`C-FnType`), so the call folds, is inlined, or keys a specialization (`C-Specialize`), and in each case the parameter is another name for `f`. A function passed where it would have to be a runtime operand — to a bodyless machine primitive, or through a function pointer — is ill-formed.
- **[TF-Memo] Former Results Are Memoized:**  
  $$
  \frac{g \neq \mathrm{std.types.distinct\_copy}}{\text{former}(g, a_1, \dots, a_n) = \text{former}(g, a_1', \dots, a_n') \iff a_i = a_i' \text{ for every } i}
  $$
  > **In Plain English:** Two former calls with the same arguments give back the *same* type entity, not two structurally identical ones, so `a : type = list(std.u8)` and `b : type = list(std.u8)` name one type. This covers the builtin constructors (`pointer`, `array`, `function_pointer`) as well as formers written in DOIR. Without this, `S-Struct` comparisons, attribute lookup, and `C-Specialize` keys would disagree about which type a generic instantiation is.
- **[TF-Local] Body Declarations Belong to Their Specialization:**  
  $$
  \frac{d \in \text{Block}(f) \quad f_{\text{spec}} \text{ a specialization of } f \text{ (C-Specialize, FP-Bind, F-Specialize)}}{f_{\text{spec}} \text{ holds its own fresh copy } d' \text{ of } d, \text{ with every reference to } f\text{'s bound parameters resolved in } d'}
  $$
  > **In Plain English:** Every specialization of a function gets its own copy of everything declared in its body, types included. A struct declared inside a generic function is therefore a distinct type per specialization, with its fields typed by that specialization's arguments, and attributes set on it touch only that copy. This is how a former declares a fresh type per argument: `owned(T)` declares `handle : type = { p : Tptr }` in its body, each `T` gets its own `handle`, and `TF-Memo` makes that one type per `T`. A declaration in a non-generic body is copied once, so it is one entity, as anywhere else.
- **[TF-Self] Recursive Self-Type:**  
  $$
  \frac{t = \text{the type binding currently being constructed at the point of reference}}{e \vdash \mathrm{std.types.self} \Downarrow t}
  $$
  > **In Plain English:** Inside a struct declaration, `std.types.self` refers to the struct type itself. This allows you to define recursive data structures like linked lists and binary trees through pointers to `self`. A field of type `self` itself would make the layout depend on itself, which is a cycle (`Q-Cycle`). Referencing it outside a type definition is ill-formed.
- **[TF-Overload] Overload Sets:**  
  $$
  \langle c : \mathtt{std.functions.overload\_set} = \mathrm{std.functions.create\_overload\_set}() \rangle \rightsquigarrow S \text{ fresh};\ \text{Overloads}(S) := \emptyset;\ \text{Alias}(c) := S
  $$
  $$
  \frac{e \vdash s \Downarrow S \quad e \vdash f \Downarrow g \quad g \text{ a function}}{\langle c : \mathtt{std.functions.overload\_set} = \mathrm{std.functions.add\_overload}(s, f) \rangle \rightsquigarrow \text{Overloads}(S) := \text{Overloads}(S) \cup \{g\};\ \text{Alias}(c) := S}
  $$
  $$
  \frac{e \vdash s \Downarrow S \quad V = \{g \in \text{Overloads}(S) \text{ at the call's position} \mid g \text{ is viable for } a_1, \dots, a_n\} \quad V_{\text{exact}} = \{g \in V \mid \text{no } p_i \text{ of } g \text{ bound to an argument has a type naming a parameter of } g\}}{s(a_1, \dots, a_n) \rightsquigarrow g(a_1, \dots, a_n) \text{ for the one } g \in V_{\text{exact}} \text{, or, if } V_{\text{exact}} = \emptyset\text{, the one } g \in V}
  $$
  > **In Plain English:** An overload set bundles several functions under one name. `std.functions.create_overload_set()` makes an empty set, and the declaration receiving it becomes its name (`A-Bind`): `print : std.functions.overload_set = std.functions.create_overload_set()`. `std.functions.add_overload(print, print_u8)` adds a function to it in place, like a modifier (`M-Flag`), and hands the set back. Adding one function twice adds it once. That name is what gets called: `print(x)` becomes a call to one member, and from then on every rule that reads the call's callee (`C-Call`, `C-Specialize`, `C-Inline`, `S-Assign`) reads that member.
  >
  > A member is **viable** when its written parameters take the call's arguments and, once `D-Deduce` has solved its deduced parameters from the arguments, each argument's type is equivalent to its parameter's (`S-Struct`). Only the arguments select; the destination then deduces the chosen member's return as usual. A member is **exact** for the call when every parameter an argument binds has a fixed type, one that names none of its parameters: `(v: std.u8) -> void` is exact, while `(T: deduced type, v: T) -> void` and `(T: type, v: T) -> void` are generic, and a `pack` parameter (`F-Pack`) counts as generic. An exact viable member beats every generic one, so a set can hold a catch-all `print_any` and a `print_u8` and send a `std.u8` to the latter. The call is ill-formed if no member is viable, or if two members tie for the best tier; a tie is reported at the call, not when the second is added.
  >
  > Additions take effect in declaration order: a call sees the members added above it (`M-Lexical`), and the members freeze with the set's level (`M-Freeze`), so a higher level cannot add to a set; it makes a set of its own whose members include the lower one's functions. A set is a name, not a function: it has no address, specialization or symbol, so `std.functions.address`, `bind_arguments`, `set_symbol_name` and the function modifiers take a member, never the set, and its type is always-comptime.

---

## 7. Blocks, Control Flow, and Block Results

- **[B-Inline] Blocks as Values:**  
  $$
  \frac{c : \text{Call} \quad a \in \text{FunctionInputs}(c) \quad \text{TypeOf}(a) = \mathtt{block}}{c \text{ is inlined (C-Inline), and } B(a) \text{ runs in the caller's frame, its names resolved where } a \text{ was written}}
  $$
  > **In Plain English:** Control flow is a function call whose arguments are blocks bound to names. A block is not a closure and captures nothing: it names the bindings around the line where it was written, so it can run only where those exist. Every call that passes a block is therefore spliced into its caller, along with whatever it passes the block to. An indirect call cannot pass a block (`FP-Call`), and a block cannot be stored.
- **[B-Scope] Block Scope:**  
  $$
  \frac{e \in \text{Block}(B)}{e \text{ is visible in } B \text{ and its children, and not in the block enclosing } B}
  $$
  > **In Plain English:** Names declared inside a block belong to that block. A branch passed to `std.if` or a body passed to `std.while` may declare its own temporaries, and they disappear when the block ends.
- **[B-Result] `block_result` Is a Block's Value:**  
  $$
  \langle c : \tau = B \rangle \quad \mathrm{std.block\_result}(v) \in B \implies \text{Value}(c) = v
  $$
  > **In Plain English:** A block used as an expression produces the value given to `std.block_result`. A block used only for its effects yields `std.nothing` (`WF-Void`). `x : T = { ... }` is the same as `x : T = std.run_block(b)` with the block named `b`.
- **[B-Return] Early Return from a Spliced Block:**  
  $$
  \frac{B \text{ spliced by } \mathrm{ctrl} \quad \mathrm{std.return}(v) \in B}{\text{the enclosing function returns } v \text{ there; the rest of the splice is not executed}}
  $$
  > **In Plain English:** `std.return` inside a branch of `std.if` exits the whole function, not just the branch. This is what makes guard clauses readable: `_ : void = std.if(bad, return_case, skip_case)` at the top of a function is a precondition written as code.
- **[B-If] Selection:**  
  $$
  \mathrm{std.if}(c, t, f) \rightsquigarrow \begin{cases} \text{the value } t \text{ yields} & c = 1 \\ \text{the value } f \text{ yields} & c = 0 \end{cases}
  $$
  > **In Plain English:** Both blocks yield values of the type the destination declares (`D-Return`); an `std.if` run for its effects is `_ : void = std.if(...)` with both blocks yielding `std.nothing`.
- **[B-Loop] Iteration Primitives:**  
  $$
  \mathrm{std.while}(\text{condition}, \text{body}) \rightsquigarrow \text{repeat: run condition; stop if it yields 0; run body}
  $$
  $$
  \mathrm{std.for}(\text{init}, \text{condition}, \text{step}, \text{body}) \rightsquigarrow \text{run init; repeat: run condition; stop if it yields 0; run body; run step}
  $$
  $$
  \text{body yields } \tau \neq \mathtt{std.nothing},\ n \text{ runs} \implies \text{Value}(\text{loop}) = \begin{cases} \text{a value of } \mathrm{std.types.array}(\tau, n) & \text{destination } \mathrm{array}(\tau, n),\ n \text{ comptime} \\ p : \mathrm{pointer}(\tau) \text{ into the heap},\ \mathrm{load}(p - h) = n & \text{destination } \mathrm{pointer}(\tau) \end{cases}
  $$
  > **In Plain English:** Loops take blocks, not inline expressions. `condition` yields a `std.u1`, and `init` and `step` yield `std.nothing`. A body that yields `std.nothing` makes the loop return `void`. A body that yields a value of any other type $\tau$ makes the loop return the values of its runs, in order, and the destination's declared type says which of two forms it gets (`D-Return`):
  >
  > - **`array(τ, n)`:** the values as one array value, an ordinary binding like any other aggregate, so nothing is freed. It is ill-formed unless the count is comptime and equal to $n$. The count is comptime when running `init`, then `condition` and `step` alone without the body, folds (`C-Interpret`, in comptime memory, `MEM-Comptime`) and the body stores to none of the memory they read; so `std.while`, which has no `step`, has a comptime count only when it is zero.
  > - **`pointer(τ)`:** element 0 of a heap allocation (`MEM-Heap`) that the loop grows as it runs, whatever the count. The allocation begins $h$ bytes before element 0, where $h$ is the size of `std.pointer_sized` rounded up to the alignment of $\tau$, and holds the count there as a `std.pointer_sized`. `std.loop_length(p)` reads it and `std.free_loop_result(p)` frees the allocation; the caller must free it. If the heap refuses, the loop still runs every iteration and returns null. A `std.return` out of the body (`B-Return`) frees what the loop had allocated.
  >
  > Each run of a block binds its declarations afresh (`SSA`), so nothing carries from one iteration to the next except memory: a loop mutates its counter through a stack cell (`std.stack.allocate` plus `std.pointers.store`), allocated before the loop (`MEM-Stack`).
- **[B-Defer] Deferred Blocks:**  
  $$
  \mathrm{std.defer}(b) \rightsquigarrow b \text{ runs when the enclosing function returns, after every later-deferred block}
  $$
  > **In Plain English:** A deferred block runs at every exit of the function it is written in, in reverse order of the `defer` calls that were reached; for an inlined function, at the end of its splice. It yields `std.nothing`. A `defer` that is never reached defers nothing.
- **[B-Label] Labels and Jumps:**  
  $$
  \langle n : \mathtt{std.label} = \mathrm{std.place\_label}() \rangle \text{ marks its position as label } n; \quad \mathrm{std.jump\_to}(n),\ \mathrm{std.jump\_to\_if}(c, n) \text{ transfer to label } n \text{ in the same function}
  $$
  > **In Plain English:** Labels and jumps are the primitives backends build `std.if` and `std.while` from; programs above the machine use those instead. A label is a declaration: `after : std.label = std.place_label()` marks its own position, and its name is the binding's name, so there is no separate name to pass and duplicates are ordinary duplicate declarations. A jump takes the label itself, not an address: it may name a label before the line that places it (`WF-Order`), but only a label in its own function. A label has no address at the `std` level; jumping through a computed address, such as a reloaded return address, is a backend's own instruction. `std.label` is always comptime, so a label is consumed when the instruction is selected and never converted to runtime (`WF-ToRuntime`); labels, jumps and `std.halt` are `never_comptime`, so they are emitted even when every operand is constant (`C-Call`). `jump_relative` and `jump_relative_if` count machine instructions, so only a backend can use them meaningfully. A binding read after a label must be bound on every path that reaches the read (`WF-Order`). The values the jumps return have no meaning at the `std` level.
- **[B-Tail] Tail Calls:**  
  $$
  \frac{\langle c : \tau = \mathtt{tail}\ f(\dots) \rangle \text{ in the body of } g}{c \text{ is a terminator (WF-Term): it is the last declaration of its block, } f\text{'s return type is equivalent to } g\text{'s (S-Struct), and it returns } f\text{'s result from } g}
  $$
  > **In Plain English:** A `tail` call ends its block the way `std.return` does: `_ : _ = tail g(v)` returns `g(v)`'s result from the enclosing function, so the call can reuse the caller's frame and jump instead of call. Nothing may follow it in its block, and the callee must return the type the caller does. Written in a spliced block, it leaves the function like an early `std.return` (`B-Return`); in an inlined function it ends the splice, whose value is the call's (`C-Inline`). Outside a function body there is nothing to return from, so a `tail` call there is ill-formed.

---

## 8. Variadic and Defaulted Parameters

- **[F-Pack] A Pack Parameter Takes the Remaining Arguments:**  
  $$
  \frac{f : (p_1 : \tau_1, \dots, p_k : \tau_k, r : \mathtt{pack}) \to \rho \quad c = f(a_1, \dots, a_k, b_1, \dots, b_m)}{r \text{ binds the pack } \langle b_1, \dots, b_m \rangle \text{ at } c, \quad m \ge 0}
  $$
  > **In Plain English:** A function whose last parameter has type `pack` is variadic. The arguments after the fixed ones form the pack, in order, and may have any types; each is still a named binding (`WF-Arg`). The pack itself is always comptime — its length and its element types are known at every call site — while each element keeps its own stage, so a pack may carry runtime values.
- **[F-Access] Reading a Pack:**  
  $$
  \mathrm{std.packs.count}(r) = m \qquad \mathrm{std.packs.type\_of}(r, i) = \text{TypeOf}(b_i) \qquad \mathrm{std.packs.get}(r, i) \rightsquigarrow b_i, \quad i < m \text{ comptime}
  $$
  > **In Plain English:** All three are host hooks and fold. `get` hands back element `i` itself — no copy (`V-NoImplicitCopy`) — so its destination becomes another name for that element, keeping the element's stage (`A-Bind`), and the index must be comptime. A walk over a pack is therefore an inline recursion over a comptime index that unrolls (`C-Inline`, `C-Splice`), dispatching on `std.packs.type_of` per element.
- **[F-Specialize] Variadic Functions Specialize per Pack Shape:**  
  $$
  f \text{ is generated once per distinct } \langle m, \text{TypeOf}(b_1), \dots, \text{TypeOf}(b_m) \rangle \text{ and comptime levels' values (C-Specialize)}
  $$
  > **In Plain English:** A pack's length and types are part of the call's type, so each shape gets its own body, as each type does under specialization; the elements are otherwise ordinary arguments, so comptime ones key the specialization and runtime ones are passed. An indirect call cannot take a pack (`FP-Call`): a function pointer has one fixed shape.
- **[F-Forward] Forwarding a Pack:**  
  $$
  \frac{r : \mathtt{pack} \quad g \text{ variadic}}{g(a_1, \dots, a_j, r) \text{ passes } b_1, \dots, b_m \text{ as } g\text{'s remaining arguments}}
  $$
  > **In Plain English:** Handing a pack as the last argument of a call to another variadic function spreads it, so a wrapper can pass its extra arguments through unchanged. A pack in any other position is an ordinary always-comptime value, which is how `std.functions.bind_arguments` and `std.meta.functions.bind_arguments` receive the arguments they bind.
- **[F-Default] Default Arguments:**  
  $$
  \frac{f : (\dots, p_i : \tau_i = k_i, \dots, p_n : \tau_n = k_n[, r : \mathtt{pack}]) \quad c \text{ passes only } p_1..p_{i-1}}{c \text{ behaves as if } k_i, \dots, k_n \text{ were declared as } \tau_i, \dots, \tau_n \text{ constants just above } c \text{ and passed}}
  $$
  > **In Plain English:** Only a run of trailing parameters (before a pack, if any) may have defaults, and a call omits a suffix of them. A deduced parameter is never written at a call site, so the grammar gives it no default. An omitted argument is exactly the literal or named constant, written out: comptime (`C-Constant`), typed by `V-Literal` (or the named constant's type), and treated like any constant: it keys the specialization of an emitted call (`C-Specialize`), and an unkeyed one must be converted to runtime, so a default on a primitive's parameter or a `SharedBody` parameter is only usable by calls that fold (`WF-ToRuntime`). A function with both defaults and a pack cannot omit a default and still pass pack levels.

---

## 9. Function Pointers and Indirect Calls

- **[FP-Type] A Function Pointer Is Its Own Type:**  
  $$
  \mathrm{std.types.function\_pointer}(\textit{ft}) \rightsquigarrow p \quad \text{Pointer}(p) = \langle \textit{ft}, 0 \rangle \quad \text{unique}(p) = \nu_{\text{fn}} \quad \text{(M-Ctor)}
  $$
  > **In Plain English:** `std.types.function_pointer(ft)` builds a pointer-sized type that carries the function type it points at, under a discriminator no other pointer type uses. Without the discriminator, `S-Struct` would treat a function pointer and a `byte_pointer` as the same field type. Two function pointer types are equivalent exactly when their function types are (`S-Struct`). It is the only runtime form of a function (`TF-FnType`).
- **[FP-Address] Taking a Function's Address:**  
  $$
  \mathrm{std.functions.address}(f) \rightsquigarrow v \quad \text{Flags}(v) \supseteq \{\text{Comptime}\} \quad \text{TypeOf}(v) = \mathrm{function\_pointer}(\text{TypeOf}(f))
  $$
  > **In Plain English:** A function is only callable by name. To put it in a table, a struct field, or a variable, you take its address, which is a comptime value because the compiler already knows where the function lands. Like any comptime value of an ordinary type, it is converted to runtime before an emitted call uses it.
- **[FP-Call] Indirect Calls Never Fold:**  
  $$
  \frac{c = \alpha(\text{Call}(e)) \quad \text{TypeOf}(c) = \mathrm{function\_pointer}(\textit{ft})}{\text{the call is emitted against } \textit{ft} \text{, with no specialization}}
  $$
  $$
  \frac{\text{the callee traces to } \mathrm{std.functions.address}(g)}{\text{the call is devirtualized to a direct call of } g}
  $$
  > **In Plain English:** A call names its callee with an identifier; when that identifier names a function pointer rather than a function, the call is indirect: a load and an indirect branch. At an emitted call site it cannot be folded, because the target is a runtime address. Inside a body the interpreter is already running (`C-Interpret`), a pointer whose comptime value is a function address is simply called. The pointee's function type is fixed, so an indirect call specializes on nothing: it may not pass a pack (`F-Specialize`), a block (`B-Inline`), or any argument of an always-comptime type. When the pointer provably came from `std.functions.address(g)`, the load is removed and the call becomes a direct one. An indirect call is also the only way a lower level can still read an entity that `L-Erase` has retired, so the verifier must reject a call whose pointee entity has $\tau$ in its `Lowered` set for that target.
- **[FP-Bind] Naming One Specialization:**  
  $$
  \frac{f : (p_1 : \tau_1, \dots, p_k : \tau_k, q_1 : \sigma_1, \dots) \to \rho \quad a_i : \tau_i \text{ comptime}}{\mathrm{std.functions.bind\_arguments}(f, a_1, \dots, a_k) \rightsquigarrow f' : (q_1 : \sigma_1[p := a], \dots) \to \rho[p := a]}
  $$
  > **In Plain English:** `bind_arguments` binds the leading parameters of a function to comptime arguments — usually types, deduced ones included, since there is no call site to deduce them from, but values of any type may be bound — and gives back the specialization as an ordinary function entity: callable by name, and addressable by `std.functions.address`, which is how a type-erased container stores "end the lifetime of a `T`" as a hook. The bound parameters disappear from its type. Results are memoized like a former (`TF-Memo`), so specializing twice with the same arguments names one function, and the function `C-Specialize` would generate for a call with those arguments is that same entity. The destination becomes an alias of it (`A-Bind`). The arguments are a pack (`F-Pack`); `std.meta.functions.bind_arguments` is the entity form.

---

## 10. Comptime & Deduction

- **[C-Constant] Literals Are Comptime Values:**  
  $$
  \frac{e : \text{ConstantVal}}{\text{Flags}(e) := \text{Flags}(e) \cup \{\text{Comptime}\}}
  $$
  > **In Plain English:** A literal bound to a name is known at compile time by definition, so it carries `Comptime` like any other binding. It is not special in any other way: `WF-Arg` requires it to be named before it is passed anywhere, and `WF-ToRuntime` requires it to be converted to runtime before an emitted call can use it.
- **[C-Call] Comptime Bubbling:**  
  $$
  \frac{e : \text{Call} \quad e \text{ not inlined (C-Inline)} \quad c = \alpha(\text{Call}(e)) \quad c : \text{FunctionReturn} \quad \textit{ft} = \alpha(\text{TypeOf}(c)) \quad \text{NeverComptime} \notin \text{Flags}(\textit{ft}) \quad \big(\text{AlwaysComptime} \in \text{Flags}(\textit{ft}) \lor \forall a \in \text{FunctionInputs}(e).\ \text{Comptime} \in \text{Flags}(a)\big)}{\text{Flags}(e) := \text{Flags}(e) \cup \{\text{Comptime}\}}
  $$
  $$
  \frac{e : \text{Call} \quad c = \alpha(\text{Call}(e)) \quad c : \text{TypeDefinition} \text{ an aggregate (TF-Construct)} \quad \forall a \in \text{FunctionInputs}(e).\ \text{Comptime} \in \text{Flags}(a)}{\text{Flags}(e) := \text{Flags}(e) \cup \{\text{Comptime}\}}
  $$
  > **In Plain English:** A call folds only if the callee resolves to a function entity, or to an aggregate type it constructs (`TF-Construct`), which folds exactly when every field value is comptime; a constructor's own type is `type`, so `AlwaysComptime` on it says nothing about its calls. Its function type is marked `std.types.always_comptime`, or everything passed to it is known at compile time (types always are, by `C-Type`). A function type marked `std.types.never_comptime` is never folded, even with all-constant arguments; its comptime arguments must be converted to runtime (`std.comptime_to_runtime`). An indirect call through a function pointer never folds, because `c` carries no `FunctionReturn` value (`FP-Call`). An inlined call is not folded as a whole; its body is spliced and each call in it is judged on its own (`C-Inline`). A call with a runtime argument that is not folded is emitted, specialized on its comptime arguments (`C-Specialize`).
- **[C-Valid] Comptime Boundary:**  
  $$
  \frac{\text{Comptime} \in \text{Flags}(e) \quad \alpha(\text{Call}(e)) : \text{Block} \quad a \in \text{FunctionInputs}(e) \quad \text{Comptime} \notin \text{Flags}(a)}{\text{ill-formed}}
  $$
  > **In Plain English:** You cannot feed a runtime variable into a compile-time computation the interpreter runs. A host hook (`H-Hook`) or a level-0 builtin is different: it is handed each argument as a binding, not as a value, so it may take a runtime binding and read its identity — its entity, type, register, or attributes. That is what `std.meta.entity_of`, `std.attributes.*`, `std.unsafe.share_register`, `std.diagnostics.assert` and `compiler.assembler.register_for` do. A hook that needs the *value* of a runtime argument is ill-formed.
- **[C-Order] Lexical Effect Ordering:**  
  $$
  \text{Within a level, store mutations take effect in lexical declaration order.}
  $$
  > **In Plain English:** Compile-time side effects (like adding an attribute or modifying a type) execute in strict order from top to bottom of the file.
- **[C-Type] Comptime Propagation from Type:**  
  $$
  \frac{e : \text{TypeOf} \quad t = \alpha(\text{TypeOf}(e)) \quad \text{AlwaysComptime} \in \text{Flags}(t)}{\text{Flags}(e) := \text{Flags}(e) \cup \{\text{Comptime}\}}
  $$
  > **In Plain English:** Any variable whose type carries `AlwaysComptime` is automatically marked as `Comptime`. The builtins `type`, `block`, `deduced type`, `pack`, `compiler.entity` and `compiler.level` carry it, as does any type passed to `std.types.always_comptime`. Every type is a value of type `type`, so every type is comptime.
- **[C-FnType] A Function Is Comptime:**  
  $$
  \frac{e : \text{TypeOf} \quad \alpha(\text{TypeOf}(e)) \text{ is a function type}}{\text{Flags}(e) := \text{Flags}(e) \cup \{\text{Comptime}\}}
  $$
  > **In Plain English:** Only functions have function types (`TF-FnType`), and the compiler always knows which code a function declaration names, so every function is comptime. A function's comptime-ness says nothing about its calls: whether a call folds is `C-Call`'s question, answered by the arguments and by the function type's flags. A function held at runtime is a function pointer, which is an ordinary runtime value (`FP-Type`).
- **[C-SharedBody] Parameters That Are Not Keys:**  
  $$
  \frac{e \text{ a call to } f \quad a_i \in \text{FunctionInputs}(e) \quad p_i \text{ the parameter of } f \text{ it binds} \quad \text{SharedBody} \in \text{Flags}(\alpha(\text{TypeOf}(p_i)))}{a_i \text{ is not a specialization key of } e \text{ (C-Specialize)}}
  $$
  > **In Plain English:** `std.types.share_body_across_values` marks a value type whose arguments should share one body rather than get a copy per constant: messages, sizes, anything a helper only passes along. It is decided per parameter, so a generic `log(T: type, value: T, text: message)` still specializes on `T` and shares its body across every `text`. A comptime argument to such a parameter of an emitted call is a runtime operand and must be converted to runtime (`WF-ToRuntime`); one of a call that folds is passed as is. A function with one body for every call — for a stable symbol or a small binary — marks every parameter's type. The type of `p_i` is read after deduction, so a deduced parameter `v: T` is unkeyed when the argument's type carries the flag. On a function type the flag has no effect, since a function argument has no runtime form and is always a key (`TF-FnType`).
- **[D-Deduce] Bidirectional Deduction:**  
  $$
  \frac{f : (T_r : \text{deduced type}, T : \text{deduced type}, v : T) \to T_r \quad \text{TypeOf}(x) = \tau \quad \text{expected}(c) = \rho}{\langle c : \rho = f(x) \rangle \rightsquigarrow f(\rho, \tau, x)}
  $$
  > **In Plain English:** When a function uses `deduced type`, the compiler solves the missing types from both directions: looking forward from the argument types passed in ($\tau$), and looking backward from the return type expected by the left-hand side assignment ($\rho$). Deduced parameters are never written at the call site. A deduced type neither direction solves — typically a `_` destination receiving a `_` return — is ill-formed, so such a destination names its type (`_ : void = std.if(...)`).
- **[D-Return] A `_` Return Is a Deduced Parameter:**  
  $$
  (p_1, \dots, p_n) \to \_ \;\equiv\; (T_{\text{ret}} : \text{deduced type}, p_1, \dots, p_n) \to T_{\text{ret}}
  $$
  > **In Plain English:** `(...) -> _` does not mean "returns nothing"; it means the return type is solved at each call site from the type the destination declares (`D-Deduce`), exactly as if the function had a leading deduced parameter.
  > A body cannot name that hidden parameter, so a function whose body must name its own return type declares `Tret: deduced type` explicitly instead.
  > A body that returns a value of another type is ill-formed in that specialization (`S-Assign`).
- **[D-Assert] A Leading Assertion Solves a Constructed Parameter Type:**  
  $$
  \frac{T \text{ deduced, unsolved by D-Deduce} \quad \text{the body opens with } \mathrm{std.diagnostics.assert}(\mathrm{std.types.is\_same\_type}(P, g(\dots T \dots)), m) \quad P \text{ solved} \quad P = g(\dots \tau \dots) \text{ (M-Ctor)}}{T := \tau}
  $$
  > **In Plain English:** A parameter line cannot write `std.types.pointer(T)` (`TF-Name`), so a function taking a pointer to its deduced `T` takes a deduced `Tptr` and opens its body by asserting `std.types.is_same_type(Tptr, std.types.pointer(T))`.
  > Deduction reads those opening assertions: once `Tptr` is solved, the assertion runs as a match rather than a test, and if `Tptr` was built by the same type constructor (`std.types.pointer`, `std.types.array` or `std.types.function_pointer`), `T` is solved from what it was built from (its `Pointer` component), recursively for a constructor applied to a constructor.
  > A `Tptr` the constructor did not build, a `distinct_copy` of one included (`M-Distinct`), solves nothing, and `T` is left to `D-Deduce`'s error; once every parameter is solved the assertion is an ordinary one (`DG-Assert`).
  > The opening is the body's leading run of such assertions and the bindings they name (the constructed type, the condition, the message); deduction reads nothing after it, so a caller's deduction depends on the callee's signature and those lines alone.
- **[C-Splice] Comptime Block Selection:**  
  $$
  \frac{\mathrm{std.if}(c, t, f) : \text{Call} \quad \text{Comptime} \in \text{Flags}(c)}{\text{only the block whose condition holds is spliced; the other is parsed but never resolved, typed, or evaluated}}
  $$
  > **In Plain English:** When the condition of an `std.if` is known at compile time, only the taken branch survives into the program. The other branch contributes no instructions, no names, and no errors, so it may use an optional name the machine lacks (`T-Optional`). A comptime recursion over a comptime index therefore unrolls a whole computation into straight-line code.
- **[C-Inline] Inlining Splices the Body Before the Stage Is Decided:**  
  $$
  \frac{e : \text{Call} \quad c = \alpha(\text{Call}(e)) \quad \text{Inline} \in \text{Flags}(\text{TypeOf}(c)) \cup \text{Flags}(e) \;\lor\; e \text{ passes a block (B-Inline)}}{\text{the body of } c \text{ is spliced into the caller's block as a fresh scope, and the stage of the splice is the caller's}}
  $$
  > **In Plain English:** An inlined function has no call site of its own: its body is written into the caller as a block, so `B-Scope` applies to it — the names it declares are local to the splice and invisible to the caller, and the value it yields is the value of the call (`C-Term`). Inlining is decided before folding: an inlined call is never folded as a whole, and each call in the splice is judged on its own. A `std.return(v)` of the inlined function transfers control directly to the exit of the splice (yielding $v$ as the value of the splice), terminating any enclosing `std.if` or loop blocks within the splice without exiting the caller (`B-Return` applies to the caller's own returns only). Each splice gets its own scope, so the same helper can be spliced twenty times in one block without the names colliding. What does cross the boundary is the stage: `std.is_comptime_evaluation()` inside the splice reports the *caller's* stage, which is what makes `std.comptime_to_runtime_if_needed` possible. A call is inlined when its function type carries `Inline`, when it is written `inline f(...)`, or when it passes a block.
- **[C-Term] What a Terminator Hands Back:**  
  $$
  \frac{t = \mathrm{std.return}(v) \text{ or } \mathrm{std.block\_result}(v) \text{ ending body or block } B}{t \text{ is emitted} \iff B \text{ is the body of an emitted function, or a block spliced by a control-flow call whose choice is made at runtime}}
  $$
  > **In Plain English:** A terminator is not folded or emitted by `C-Call`; it follows what it ends. Where the value has to meet other values at runtime — the return of an emitted function, the yield of an `std.if` branch whose condition is runtime — the terminator is emitted, so its value must be runtime (`WF-ToRuntime`). Everywhere else — a folded body, an inlined function, a block used as a value, a branch `C-Splice` chose — the terminator hands back the binding itself, stage unchanged, and the receiving declaration becomes another name for it (`A-Bind`). That is why `std.types.size_bits(T)` can be used in emitted code without converting to runtime: the splice hands back the comptime result as is.
- **[C-Specialize] Specialization by Comptime Parameters:**  
  $$
  \frac{e \text{ an emitted call to } f \quad f \text{ has a body} \quad K = \langle (i, v_i) \mid a_i \in \text{FunctionInputs}(e),\ \text{Comptime} \in \text{Flags}(a_i),\ a_i \text{ not unkeyed by C-SharedBody},\ v_i = \text{value of } a_i \rangle}{e \text{ calls } f_K \text{, one specialization per distinct } K \text{, in which each such } p_i \text{ is bound to } v_i \text{ and is comptime}}
  $$
  > **In Plain English:** A call that cannot fold because some argument is runtime gets its own copy of the callee for the arguments that are comptime: types, deduced types, blocks, packs (`F-Specialize`), and comptime values of any type, literals included. In that copy those parameters are comptime bindings, so every call in the body whose inputs are all comptime folds (`C-Call`), a `std.if` on one of them keeps one branch (`C-Splice`), and only what depends on the runtime arguments is emitted. Values are compared by their bytes, types and other entities by identity. So `scale(x, 3)` with runtime `x` emits a body with `3` built in, and a walk over a type's fields by a comptime index unrolls with no special index type. The key is part of the call, not of the function: the same `f` may fold at one call and be specialized at another (`C-Stage` tells the body which). A parameter that should share one body across constants gets a `std.types.share_body_across_values` type (`C-SharedBody`); a caller can also convert an argument to runtime itself, since runtime arguments are not keyed. Specializations are memoized like formers (`TF-Memo`) and belong to the level that creates them (`L-Tower`). Nothing is specialized for a bodyless prototype or an indirect call (`FP-Call`); their comptime operands are converted to runtime instead (`WF-ToRuntime`).
- **[C-ToRuntime] Bridging a Comptime Value to Runtime:**  
  $$
  \mathrm{std.comptime\_to\_runtime}(v) \rightsquigarrow v' \quad \text{Flags}(v') := \text{Flags}(v) \setminus \{\text{Comptime}\}
  $$
  > **In Plain English:** The primitive emits a load of the constant, so the binding it lands in is an ordinary runtime value that no later comptime computation can see. It is the only way across the boundary: nothing is converted implicitly. The argument must be comptime — handing the primitive a value that is already runtime is ill-formed, since there is nothing to convert — and its type must not be always-comptime, since such values have no runtime form.
- **[C-Stage] Querying the Current Evaluation Stage:**  
  $$
  \text{Comptime} \in \text{Flags}(\mathrm{std.is\_comptime\_evaluation}()) \quad \text{always}
  $$
  $$
  \mathrm{std.is\_comptime\_evaluation}() = \begin{cases} 1 & \text{the enclosing evaluation is folding this code} \\ 0 & \text{the enclosing evaluation is emitting it} \end{cases}
  $$
  > **In Plain English:** A function that is sometimes folded and sometimes emitted (one called with all-comptime arguments in one place and a runtime one in another, `C-Specialize`) can ask which it is and branch on the answer. The answer is itself always known at compile time, so it can drive an `std.if`, and `C-Splice` keeps only the branch that applies. There is no implicit bridging between the two worlds: the program states the transition with `std.comptime_to_runtime` where it needs one.
- **[C-Interpret] Interpretation Executes Every Call:**  
  $$
  \frac{\text{a call } e \text{ is folded} \quad e' \text{ is a call in the body of } \alpha(\text{Call}(e))}{e' \text{ is executed by the comptime interpreter, whatever the flags of its callee's type}}
  $$
  > **In Plain English:** `NeverComptime` is a statement about call sites the compiler would otherwise emit: such a call is never folded *there*.
  > Inside a body the interpreter is already running, there is nothing to emit, so every call is executed — including memory primitives (`MEM-Comptime`), indirect calls through a comptime function address (`FP-Call`), and `std.comptime_to_runtime`, which is the identity there, since there is no runtime to cross to.
  > Behavior that would be undefined at runtime (`UB`) is a compile error when the interpreter meets it.
  > This is what lets a comptime metaprogram use the same containers the program uses at runtime.
  > A prototype the machine supplies (`I-Extern`) is never run by interpreting the body bound to it, which may be machine code or a software body from `standard.emulated.doir`, and differs per target: the host runs it with the semantics this specification gives it (§14, §13, `N-Convert`, `N-FloatConvert`, `N-Overflow`, `std.reinterpret_bits`, `std.copy`), at the target's widths (`H-Target`), so the answer depends on neither host nor machine (`H-Det`).
- **[Q-Cycle] Cycles Are Errors:**  
  $$
  \frac{\text{answering query } q \text{ requires the answer to } q}{\text{ill-formed, reported with the chain of queries that closes the cycle}}
  $$
  > **In Plain English:** Every question the compiler answers — what a name or alias resolves to, a type's layout, a deduced type, the value of a comptime call — is a query, and a query that needs its own answer is an error naming the loop: an alias chain back to itself, a struct that contains itself by value, a comptime call whose argument is its own result. A comptime evaluation that never terminates does not compile; an implementation may stop it at a limit with a diagnostic.

---

## 11. The Comptime Host

- **[H-Hook] Host Hooks:**  
  $$
  \frac{f \text{ a bodyless prototype} \quad \text{Rank}(f) \ge 1 \quad \text{AlwaysComptime} \in \text{Flags}(\alpha(\text{TypeOf}(f)))}{f \text{ is supplied by the comptime host, at every level, for every target}}
  $$
  > **In Plain English:** A prototype whose type is marked `std.types.always_comptime` only ever runs inside the compiler, so the compiler's host supplies it: `std.meta.*`, `std.import`, `std.attributes.*`, `std.packs.*`, `std.diagnostics.*`, `std.functions.address` and `bind_arguments`, `std.static.allocate`, `std.pointers.read_only`, and the rest listed in [`reference/host.doir`](reference/host.doir). Every other prototype is supplied by a lower level or the linker (`I-Extern`). The bodyless builtins of level 0 are not hooks: they are the bootstrap, which the compiler implements itself (`H-Boot`). A hook is neither DOIR source nor machine code: it is one entry in the `HostServices` table (`H-Services`), which a mizu backend reaches through an instruction of the comptime machine and a native JIT through a direct call.
- **[H-Services] The HostServices Table:**  
  $$
  \text{HostServices} = \langle h_1, \dots, h_n \rangle \quad \text{one C-ABI function pointer per host hook listed in } \texttt{reference/host.doir}\text{, looked up by name (H-ABI)}
  $$
  > **In Plain English:** Jitted comptime code reaches the compiler through one table of C-callable function pointers, one entry per host hook. An argument of an always-comptime type crosses as a `compiler.entity` naming the binding; any other argument crosses as its value in the host's C representation of the target layout (`H-Target`). Memory allocation for comptime memory (`MEM-Comptime`) and the comptime bodies of machine primitives (`C-Interpret`) are reached the same way. The hooks the table must provide are listed in `reference/host.doir`.
- **[H-ABI] The HostServices Table Is Versioned and Handle-Disciplined:**  
  $$
  \text{HostServices} = \langle \text{version}, \langle h_1, \dots, h_n \rangle \rangle, \quad \text{a hook is addressed by name and version, not by position}
  $$
  > **In Plain English:** A host has to say which revision of `reference/host.doir` it implements, and a hook is looked up by name rather than by its slot in the array, so adding a hook does not break a host written against an older one. Entity handles cross the boundary only as `compiler.entity` values (`MEM-Escape`). An id held by a host is not safe: a renumbering (`E-Remap`) runs between levels and rewrites every id the store knows, so a host that must remember something across one holds a handle the store issued, not an id it read.
- **[H-Boot] Bootstrap Names versus Hook Names:**  
  $$
  \frac{n \text{ is a name a comptime program needs}}{n \text{ is a host hook (H-Hook)} \quad \text{unless } n \text{ is required before level } 1 \text{ can run, or by code that cannot name } \mathtt{std}}
  $$
  > **In Plain English:** Two sets of names answer the same question — what may metaprogramming call? — from opposite ends. `compiler` is the **bootstrap**: its functions are walked and executed by the compiler itself, in the compiler's own process, before any target code exists. Host hooks are the **boundary**: they are not code, and a mizu backend or a JIT supplies them (`H-Hook`). Hooks over entities live in `std.meta`; hooks over source values (`std.import`, `std.attributes.*`) live beside the `std` names they serve. Neither is interpreted, and `H-Det` guarantees both give the same answer.
  >
  > `compiler` holds two kinds of name, and nothing else. The **bootstrap** is what gets a first implementation off the ground before level 1 can run: enough to build primitive types and emit bytes. The **floor** is what code that cannot name `std` needs: the levels below `std` (level 0 and the backends of level 1, which `L-Mono` keeps from naming it) and builds that do not include `standard.doir` at all, since DOIR does not depend on `std` existing. Every other name is a host hook or `std`: a name that can be written in DOIR over hooks belongs in `std` (`RF-Wrapper`), and a name the host must supply is a host hook.
  >
  > A build without `std` keeps the floor and loses `std`'s unification: the portable `std.*` contract every machine implements (`I-Extern`), the optional-feature checks (`T-Optional`), and every hook over entities and source values — reflection, attributes, packs, diagnostics, and per-declaration targeting (`std.targets.compile_for`). It can still paste in files (`compiler.paste_file`), build types, and emit bytes.
  >
  > The test for a new name: *does code that cannot name `std` need it?* If yes, it is `compiler`. Otherwise, *could a JIT target implement it?* If yes, it is a host hook. If it only makes sense while the compiler is still building itself, it is `compiler`, as bootstrap debt.

  |     | `compiler` | host hooks |
  | --- | --- | --- |
  | How it runs | treewalk-interpreted by the compiler | a `HostServices` entry, reached by a mizu instruction or a JIT call |
  | Available from | level 0: before level 1 can run, and without `std` | the level that declares the prototype |
  | Goal | as small as possible | the whole metaprogramming interface |
  | Examples | `compiler.emit`, `compiler.base_type`, `compiler.levels.lower_to`, `compiler.levels.check`, `compiler.assembler.*`, `compiler.paste_file` | `std.meta.entity_of`, `std.meta.types.field_offset_bits`, `std.import` |

  Some names are floor rather than debt.
  `compiler.entity` lives at level 0 because the `compiler_impl` hooks need it below `std`, and `compiler.argument_count` and `compiler.argument` let `compiler_impl.pass_arguments` and bridge calls (`T-Bridge`) inspect call arguments without violating `L-Mono`; `compiler.paste_file` is how a build without `std` brings in files, by pasting them; `std.import`, which compiles a file separately, is not its twin but a different operation above level 0.
  One debt is visible: `compiler.entity` pins the entity type to the host word the bootstrap invented.
  And every name in Part I §7 is still called, by this repository or by the Mizu level Phase 5 ports (`mizu.doir`, `tree/D`); the legacy names nothing called (`always_comptime`, `indicate_yield`, `debug_print`, `current_entity`, `assembler.yield_register`) are retired, and a port that meets one replaces it with its `std` counterpart.
- **[H-Host] Comptime Host Selection:**  
  $$
  \frac{\text{cmp}(E) \text{ for target } \tau}{\text{executes in the compiler's process on its comptime host } h\text{, never on a target of the build}}
  $$
  > **In Plain English:** Compile-time metaprogramming runs inside the compiler. The bootstrap (`H-Boot`) is walked by the compiler itself; every other body runs on a host the compiler embeds, the Mizu VM or a native JIT, which reaches hooks through `HostServices` (`H-Services`). The host belongs to the compiler, not to the tower: a build whose targets are x86 and SPIR-V still evaluates its comptime on the compiler's host, computing with $\tau$'s layouts (`H-Target`), and which host runs it never changes an answer (`H-Det`).
- **[H-Target] Target Layout on Host Machine:**  
  $$
  \text{Comptime blocks execute on host } h\text{, but evaluate layouts and byte order calculated against target } \tau.
  $$
  > **In Plain English:** Even if your compiler runs on a 64-bit x86 laptop, if you are compiling for a 32-bit ARM chip, compile-time evaluations will use the struct padding, alignment, pointer sizes and byte order of the 32-bit ARM target.
- **[H-Det] Host Determinism:**  
  $$
  \text{answer}(c, h_1) = \text{answer}(c, h_2) \quad \text{for any valid hosts } h_1, h_2
  $$
  > **In Plain English:** Compiling the exact same DOIR code on Windows, Linux, or macOS will always produce the identical compile-time results.

---

## 12. Attributes and Meta-Reflection

- **[AT-Type] Attributes Are Types:**  
  $$
  \frac{A : \text{TypeDefinition}}{\text{A} \text{ is an attribute id, and } C_A(v) \text{ is a component any entity may hold}}
  $$
  $$
  \mathrm{std.attributes.has}(v, A) \iff C_A(v) \text{ is defined}
  $$
  > **In Plain English:** Custom metadata is not a bag of string keys; it is a set of types. Declaring a type registers the component named after it, and any entity in the database can then hold that component. Asking whether a type "has the `aligned` attribute" means asking whether the `aligned` component is present on it. Identity is the declaration: two types with identical bodies are two attributes.
- **[AT-Set] Attributes Hold Values of Their Own Type:**  
  $$
  \frac{\mathrm{std.attributes.set}(v, A, x) \quad \text{TypeOf}(x) \sim A \quad \text{Comptime} \in \text{Flags}(x)}{C_A(v) := \text{val}(x)}
  $$
  $$
  \mathrm{std.attributes.get}(v, A) \rightsquigarrow e \quad \text{TypeOf}(e) := A, \quad \text{val}(e) := C_A(v)
  $$
  $$
  \frac{\text{Block}(A) = \langle\rangle}{\mathrm{std.attributes.mark}(v, A) \rightsquigarrow C_A(v) := A()}
  $$
  > **In Plain English:** Once a type exists as an attribute, entities can be stamped with comptime values of that type, and reading the attribute back gives a binding of that type. `mark` is the presence-only form, for an attribute type with no fields: it stores the one value of that type. A hook attribute is a type whose field is a function pointer, so `get` returns something callable. An attribute value outlives the level that set it, so it may not hold a pointer into comptime memory (`MEM-Escape`).
- **[AT-Id] Numeric Attribute Ids:**  
  $$
  \mathrm{std.attributes.id\_of\_type}(A) = \text{id}(A) \qquad \mathrm{std.types.set\_attribute\_id}(A, n) \rightsquigarrow \text{id}(A) := n
  $$
  > **In Plain English:** Every attribute type has a numeric id, the host's handle for its component. `set_attribute_id` pins it to a known number so the host can recognize a core attribute it must fill in (`std.meta.source_location.location` is 1); pinning an id another type already holds is ill-formed. `id_of_name` returns the id of the attribute type with that fully qualified name. Ids are for the host; programs name attributes by their types.
- **[AT-Source] Source Locations:**  
  $$
  \mathrm{std.meta.source\_location.get}(e) = C_{\text{location}}(e)
  $$
  > **In Plain English:** The host stamps every declaration with a `location` attribute: its file and byte range. A source annotation at the end of a declaration (`<file:line:column>`, `<"file":l1-l2:c1-c2>`) replaces the parsed range with the one written, converting lines and columns to bytes in the named file; this is how generated DOIR points diagnostics back at the source it came from. `start_line` and its siblings convert back.
- **[RF-Entity] Reflection Retraction:**  
  $$
  \mathrm{std.meta.from\_entity}(\mathrm{std.meta.entity\_of}(v)) = v \qquad \mathrm{std.meta.entity\_of}(\mathrm{std.meta.from\_entity}(e)) = e
  $$
  > **In Plain English:** Converting a binding into a meta-handle (reflection) and back returns the exact same object without data loss. `from_entity` hands back the entity itself, so its destination becomes an alias of it (`A-Bind`), with whatever stage the entity has.
- **[RF-Args] Call Site Introspection:**  
  $$
  \mathrm{std.meta.argument\_count}(c) = |\text{args}(c)| \qquad \mathrm{std.meta.argument}(c, i) = \text{args}(c)_i \qquad \mathrm{std.meta.call\_being\_inlined}() = \text{the call being inlined or folded}
  $$
  > **In Plain English:** A macro or compiler primitive can inspect how many arguments were passed to it and read each argument identifier individually. It gets its own call from `call_being_inlined`, which is defined only in a splice or a folded evaluation, where there is exactly one call; in an emitted body, which many calls share, it is ill-formed.
- **[RF-Square] Reflection-Modifier Commutation:**  
  $$
  \mathrm{std.meta.types}.\mu(\mathrm{std.meta.entity\_of}(T)) = \mathrm{std.meta.entity\_of}(\mathrm{std.types}.\mu(T)) \quad \text{for every modifier } \mu \text{ in } \mathtt{std.types}
  $$
  > **In Plain English:** Mutating a type using a reflection handle has the exact same effect as mutating it directly in the source program.
- **[RF-Wrapper] Value Primitives Wrap Entity Primitives:**  
  $$
  \mathrm{std.types}.\mu(T) = \mathrm{std.meta.from\_entity}(\mathrm{std.meta.types}.\mu(\mathrm{std.meta.entity\_of}(T))) \quad \text{for every } \mu \in \mathtt{std.types}
  $$
  $$
  \mathrm{std.functions}.\mu(f) = \mathrm{std.meta.from\_entity}(\mathrm{std.meta.functions}.\mu(\mathrm{std.meta.entity\_of}(f))) \quad \text{for every } \mu \in \mathtt{std.functions}
  $$
  > **In Plain English:** Every `std.types` and `std.functions` entry is an always-inline wrapper written in DOIR over its `std.meta` twin, so each primitive exists twice: once taking source values, once taking stored entities. A metaprogram holding an entity from `std.meta.entity_of`, `std.meta.member`, or `std.types.field` can only continue through the `std.meta` versions, because the wrappers need a binding to take the entity of. Results that are types are turned back into names with `std.meta.from_entity`; `std.types.field` returns the field's entity as is, since a field is named by its entity (`RF-Fields`). `std.numbers` wraps `std.meta.numbers` the same way. Exceptions: `std.numbers.integer_available` and `std.numbers.float_available` take no type, so they are hooks with no entity form (`T-Optional`); `std.types.self` has no entity form (`TF-Self`); `std.functions.address` and `bind_arguments` are hooks in both namespaces, because their results are values or functions rather than types (`FP-Address`, `FP-Bind`); `std.pointers.read_only` is a hook with no entity form; `std.functions.create_overload_set` takes nothing, so its wrapper only calls `from_entity` on the new set (`TF-Overload`).
- **[RF-Fields] Field Enumeration:**  
  $$
  \frac{T : \text{TypeDefinition} \quad \text{Block}(T) = \langle f_1, \dots, f_n \rangle}{\mathrm{std.types.field\_count}(T) = n \quad \mathrm{std.types.field}(T, i) = \mathrm{std.meta.entity\_of}(f_i) \quad \mathrm{std.types.field\_type}(T, i) = \text{TypeOf}(f_i)}
  $$
  $$
  \frac{\mathrm{std.meta.entity\_of}(f) \in \{\mathrm{std.types.field}(T, i)\}_i}{\mathrm{std.types.field\_offset\_bits}(T, \mathrm{std.meta.entity\_of}(f)) = \text{offset}(f)}
  $$
  $$
  \mathrm{std.types.stride\_bits}(T) = \text{stride}(T) \qquad \frac{\text{Pointer}(T) = \langle t, n \rangle}{\mathrm{std.types.element}(T) = t} \qquad \mathrm{std.types.is\_union}(T) \iff \text{Union} \in \text{Flags}(T) \qquad \mathrm{std.types.is\_packed}(T) \iff \text{Packed} \in \text{Flags}(T)
  $$
  > **In Plain English:** A type's fields are readable as an ordered list, so metaprograms can walk a struct's layout. Every declaration in an aggregate's body is a field. A field is always named by its entity: `field(T, i)` gives the i-th, and `std.meta.entity_of(T.f)` gives a named one. That entity is what `field_offset_bits` and `field_pointer` take. `stride_bits` is the distance between consecutive elements, as `std.types.array` and `std.pointers.element_pointer` lay them out (`S-Field`); `element` is the element type of an array (and the pointee of a pointer, like `pointed_to_type`); `is_union` and `is_packed` expose the layout flags of `S-Field`, so a walk over the fields can tell overlapping members and absent padding apart.
- **[RF-FieldPtr] Field Pointers:**  
  $$
  \frac{o : \text{pointer to } T \quad f \in \text{Block}(T) \quad 8 \mid \text{offset}(f)}{\mathrm{std.types.field\_pointer}(o, \mathrm{std.meta.entity\_of}(f)) = o + \text{offset}(f) / 8 \text{ bytes, typed as a pointer to } \text{TypeOf}(f)} \qquad \frac{8 \nmid \text{offset}(f)}{\mathrm{std.types.field\_pointer}(o, \mathrm{std.meta.entity\_of}(f)) \text{ is ill-formed}}
  $$
  > **In Plain English:** There is no member-access syntax. A field is reached by taking a pointer to the object and asking for a pointer to the field, then reading or writing it with `std.pointers.load` and `std.pointers.store`. The field is named by its entity: `f : std.meta.entity = std.meta.entity_of(vec2.x)` (the path resolves by `R-Qual` descending into the type's block), or `std.types.field(vec2, 0)` when iterating. The destination names the result type, `pointer(TypeOf(f))` (`D-Return`). Memory is addressed in bytes, so a field of a packed aggregate that does not start on a byte boundary has no pointer; it is read and written through the object pointer with `std.pointers.load_field` and `store_field` (`MEM-Field`).

---

## 13. Arithmetic, Comparison, and Conversion

- **[N-Operand] Operand Types:**  
  $$
  \text{arithmetic, bitwise and } \mathtt{max}/\mathtt{min} \text{ take base types}; \quad \text{comparisons also take pointers}; \quad \text{logical operations take } \mathtt{std.u1}
  $$
  > **In Plain English:** `add`, `subtract`, `multiply`, `divide`, `remainder`, `negate`, `max` and `min` work on integer and `Float` types; the bitwise operations and shifts on integer types only; `square_root`, `is_not_a_number` and `is_infinite` on `Float` types only.
  > The six comparisons work on base types and on pointers, comparing pointer addresses as unsigned integers.
  > Nothing applies to aggregates: compare them field by field.
- **[N-Kind] One Prototype per Kind:**  
  $$
  \mathtt{std}.\omega(a, \dots) = \begin{cases} \mathtt{std.float}.\omega(a, \dots) & \text{Float} \in \text{Flags}(T) \\ \mathtt{std.integer}.\omega(a, \dots) & \text{otherwise} \end{cases} \qquad \omega \in \{\mathtt{add}, \mathtt{subtract}, \mathtt{multiply}, \mathtt{divide}, \mathtt{remainder}, \mathtt{negate}, \mathtt{max}, \mathtt{min}, \mathtt{is\_negative}, \mathtt{is\_positive}\} \cup \text{the six comparisons}
  $$
  > **In Plain English:** The operations that take both integers and floats are inline wrappers in `std`, each handing its operands to the prototype of the same name in `std.integer` or `std.float`, by the kind of their type.
  > Callers name only the wrapper; the split is for backends, because a prototype binds per operation, not per type (`I-Extern`).
  > A machine with integer instructions and no float unit defines `std.integer.add` and leaves `std.float` to the software bodies of `standard.emulated.doir`, so every float operation still works there.
  > `std.integer` takes pointers too, for the comparisons (`N-Operand`), and each family has the semantics this section gives the operation on its kind.
- **[N-Wrap] Integer Arithmetic Wraps:**  
  $$
  \omega(a, b) = \text{exact}(\omega(a, b)) \bmod 2^{n} \quad \text{for } \omega \in \{\mathtt{add}, \mathtt{subtract}, \mathtt{multiply}, \mathtt{negate}, \mathtt{shift\_left}\}
  $$
  > **In Plain English:** Unchecked integer arithmetic keeps the low $n$ bits of the exact result, read as two's complement for a `Signed` type; `std.would_overflow` asks beforehand whether that loses anything (`N-Overflow`). `divide` truncates toward zero and `remainder` takes the dividend's sign; the most negative value divided by −1 is the most negative value, with remainder 0. `shift_right` is arithmetic on a `Signed` type and logical otherwise. `is_negative` and `is_positive` compare with zero, so `is_negative` is always 0 on an unsigned type.
- **[N-Undefined] Undefined Integer Operations:**  
  $$
  \text{divide or remainder by } 0, \text{ and a shift by a negative amount or by at least the width, are undefined (UB)}
  $$
  > **In Plain English:** These have no result, so they are undefined at runtime and a compile error when folded.
- **[N-Float] Floating Point:**  
  $$
  \text{operations on a Float type follow IEEE 754 binary arithmetic, rounding to nearest, ties to even}
  $$
  > **In Plain English:** Division by zero gives an infinity and invalid operations give NaN, as IEEE 754 says; nothing on a `Float` type is undefined. Every comparison with a NaN is 0 except `is_not_equal`, which is 1. `remainder` is the remainder truncated toward zero (C's `fmod`). `max` and `min` return NaN if either operand is NaN.
- **[N-Limits] Number Classification and Range:**  
  $$
  \mathrm{std.numbers.is\_integer}(T),\ \mathrm{std.numbers.is\_float}(T),\ \mathrm{std.numbers.is\_signed}(T),\ \mathrm{std.numbers.is\_unsigned}(T) \in \{0,1\}
  $$
  $$
  \mathrm{std.numbers.min\_value}(T) = \min T \qquad \mathrm{std.numbers.max\_value}(T) = \max T \qquad \mathrm{std.numbers.not\_a\_number}(T) = \text{NaN} \qquad \mathrm{std.numbers.infinity}(T) = +\infty
  $$
  $$
  \mathrm{std.numbers.bits\_excluding\_sign}(T) = \begin{cases} \text{size\_bits}(T) & \text{unsigned} \\ \text{size\_bits}(T) - 1 & \text{signed} \end{cases} \qquad \mathrm{std.numbers.integer\_available}(b, s) \iff \text{the target provides the } b\text{-bit integer of signedness } s \qquad \mathrm{std.numbers.float\_available}(b) \iff \text{the target provides the } b\text{-bit float (T-Optional)}
  $$
  > **In Plain English:** A checked-arithmetic library needs the range of a type, and a parameter line can only name a type, not constrain it.
  > These are the `std::numeric_limits` and `std::is_signed_v` equivalents: `min_value` and `max_value` return values of the queried type, and `bits_excluding_sign` counts value bits, excluding the sign bit of a signed type.
  > `is_integer` is true for every machine integer type including `std.u1`; code that must exclude the bool says so with an assertion (`DG-Assert`).
  > `is_float` is true exactly for the `Float` types; `min_value`, `max_value` and `bits_excluding_sign` are ill-formed on them, while `not_a_number` and `infinity` are defined on them.
  > The queries live in `std.numbers` with the number types themselves, while `std.types` keeps the layout questions every type answers.
- **[N-Convert] Integer Extension and Truncation:**  
  $$
  \frac{\text{size}(T_{in}) \le \text{size}(T_{out})}{\mathrm{std.numbers.widen}(v) : T_{out} = \begin{cases} \text{sign-extend}(v) & \text{Signed} \in \text{Flags}(T_{in}) \\ \text{zero-extend}(v) & \text{otherwise} \end{cases}} \qquad \frac{\text{size}(T_{in}) \ge \text{size}(T_{out})}{\mathrm{std.numbers.truncate}(v) : T_{out} = v \bmod 2^{\text{size}(T_{out})}}
  $$
  > **In Plain English:** `std.reinterpret_bits` relabels the bits of a value as another type of the same size, and is ill-formed between types of different sizes. Changing width is a real operation: `widen` widens by the source type's signedness, `truncate` keeps the low bits. Both take their destination type from the binding they are assigned to (`D-Deduce`), accept equal widths (where they relabel signedness), and are ill-formed in the wrong direction or on a `Float` type. `compiler.truncate_to_byte` is the bootstrap residue they replace.
- **[N-FloatConvert] Numeric Conversion Through Floats:**  
  $$
  \frac{\text{Float} \in \text{Flags}(T_{in}) \cup \text{Flags}(T_{out})}{\mathrm{std.numbers.float\_convert}(v) : T_{out} = \begin{cases} \text{round-to-nearest-even}(v) & T_{out} \text{ is Float} \\ \text{truncate toward zero}(v) & T_{out} \text{ is an integer} \end{cases}}
  $$
  > **In Plain English:** One primitive converts integer to float, float to integer, and between float widths; the destination type comes from the binding it is assigned to. A float whose truncated value does not fit the integer type, or a NaN or infinity converted to an integer, is undefined (`UB`). Between two integers use `widen` or `truncate`.
- **[N-Overflow] Overflow Tests:**  
  $$
  \mathrm{std.would\_overflow}.\omega(a, b) = 1 \iff \text{the mathematically exact result of } \omega(a, b) \notin [\mathrm{min\_value}(T), \mathrm{max\_value}(T)]
  $$
  > **In Plain English:** Every arithmetic primitive that can leave its type's range has a twin in `std.would_overflow` that answers only "would this overflow?": `add`, `subtract`, `multiply`, `divide` (a zero divisor, or the most negative value over −1), `remainder`, `negate`, `shift_left` (bits shifted out, or a shift at least the width), and `truncate` (the value does not fit the destination). They read the operand type's signedness, fold like any call, and pair with the unchecked primitive (§13), which a backend fuses into one flag-setting instruction.

---

## 14. Memory: Stack, Heap, and Static Storage

- **[UB] Undefined Behavior:**  
  $$
  \text{A program whose run performs an operation this specification calls undefined has no meaning.}
  $$
  > **In Plain English:** The compiler need not diagnose undefined behavior and may assume it never happens; when it happens during comptime evaluation, it is a compile error (`C-Interpret`). The undefined operations are listed where they arise; the memory ones are `MEM-Access`.
- **[MEM-Access] Loads and Stores:**  
  $$
  \mathrm{std.pointers.load}(p) : T, \quad \mathrm{std.pointers.store}(p, v : T) \quad \text{require } \text{TypeOf}(p) \sim \mathrm{pointer}(T') \text{ with } T' \sim T
  $$
  > **In Plain English:** A load or store moves one whole value of the pointee type; to read a struct from a `byte_pointer`, reinterpret the pointer with `std.reinterpret_bits` first. Storing through a type carrying `ReadOnly` is a diagnostic. Undefined (`UB`): accessing through a null, dangling, or misaligned pointer; reading memory never written; reading bytes as a type other than the one last stored there, except through an 8-bit type; writing a string literal's storage; and `offset` or `element_pointer` leaving the allocation the pointer points into (one past the end is allowed, but not accessed). There is no bulk-copy primitive: copying a whole aggregate is one load and one store, and copying a run of bytes is a loop.
- **[MEM-Field] Field Loads and Stores:**  
  $$
  \frac{o : \text{pointer to } T \quad f \in \text{Block}(T) \quad \text{TypeOf}(f) \sim \tau}{\mathrm{std.pointers.load\_field}(o, \mathrm{std.meta.entity\_of}(f)) : \tau \text{ reads bits } [\text{offset}(f), \text{offset}(f) + \text{size}(\text{TypeOf}(f))) \text{ of } {*o}} \qquad \frac{\text{same premises} \quad v : \tau}{\mathrm{std.pointers.store\_field}(o, \mathrm{std.meta.entity\_of}(f), v) \text{ writes those bits and no others}}
  $$
  > **In Plain English:** These are the machine's hooks for fields that `std.types.field_pointer` cannot point at: a field of a packed aggregate that starts or ends inside a byte (`S-Field`, `RF-FieldPtr`). They take the pointer to the whole object and the field's entity, which is comptime, so the offset and width are known when the call is lowered and the backend picks the access, typically a load of the bytes covering the field followed by a shift and mask, and for a store a read-modify-write of those bytes. Every other bit of the object, including the other fields sharing those bytes, is left as it was. They work on any field, byte-aligned or not, and like `load` and `store` the destination names the result type (`D-Return`). `MEM-Access` applies to the object pointer: it must be non-null, live and aligned for `T`, and the bits read must have been written.
- **[MEM-Stack] Stack Memory Lives as Long as Its Frame:**  
  $$
  \mathrm{std.stack.allocate}(T) : \_ \quad \text{yielding a pointer to } T \text{ (D-Return)} \qquad \mathrm{std.stack.push}(n, a) : \mathtt{byte\_pointer},\ a \mid \text{address} \qquad \mathrm{std.stack.pop}(n)
  $$
  > **In Plain English:** Stack memory belongs to the frame of the function it was allocated in and lives until that function returns, not until the enclosing block ends. A splice (`C-Inline`, `B-Inline`) has no frame of its own, so an inlined allocation belongs to the caller, which is what lets a helper hand back stack memory. `allocate` aligns to `T` and yields a pointer to `T` (`TF-Name` cannot write `pointer(T)` in a type position, so `D-Return` solves it from the destination binding's declared type); `push` reserves `n` bytes aligned to `a`, a power of two, and `pop(n)` releases the most recent push of `n` bytes, which must be the last one not yet popped. `top` is the current top of the stack, and `std.stack.load` and `store` access a value at a byte offset from it. An allocation inside a loop body allocates on every iteration, so cells a loop reuses are allocated before it.
- **[MEM-Heap] The Heap:**  
  $$
  \mathrm{std.heap.allocate}(n, a),\ \mathrm{std.heap.reallocate}(p, n, a) : \mathtt{byte\_pointer} \cup \{\text{null}\} \qquad \mathrm{std.heap.free}(p)
  $$
  > **In Plain English:** `allocate` returns `n` bytes aligned to `a`, or null when refused. `reallocate` resizes `p`, keeping the first `min(old, n)` bytes, and returns null when refused, leaving `p` valid; a null `p` allocates. `free` releases `p`; null is a no-op. The machine supplies the runtime bodies (`I-Extern`); the comptime host supplies the comptime ones (`MEM-Comptime`).
- **[MEM-Static] Static Storage:**  
  $$
  \mathrm{std.static.allocate}(T) \rightsquigarrow v \quad \text{Flags}(v) \supseteq \{\text{Comptime}\} \quad v \text{ points to zero-initialized storage for one } T \text{ that lives as long as the program}
  $$
  > **In Plain English:** Each `std.static.allocate` call owns one slot of static storage, so a module can hold mutable state — a pluggable allocator, a counter. A slot belongs to the call entity and `T`: a splice or a specialization copies the call (`C-Inline`, `TF-Local`), so each copy has a slot of its own, while every folded run of one body with the same `T` shares one. Its address is known before the program runs, like a function's (`FP-Address`), so the pointer is comptime and may be converted to runtime freely. Stores to it during comptime write its initial contents; stores at runtime change it from there.
- **[MEM-String] String Literal Storage:**  
  $$
  \langle c : \tau = \texttt{"..."} \rangle \rightsquigarrow c \text{ points to read-only static storage holding the UTF-8 bytes and a zero byte}
  $$
  > **In Plain English:** A string literal is a pointer into static storage, like `std.static.allocate`'s, so it is comptime and may be converted to runtime. Two identical literals may share storage. Writing through it is undefined (`MEM-Access`).
- **[MEM-Comptime] Comptime Memory:**  
  $$
  \frac{\text{a memory primitive executes during } \text{cmp}(n) \text{ (C-Interpret)}}{\text{it acts on the host's comptime memory, laid out for the target (H-Target), and its pointer results are Comptime}}
  $$
  > **In Plain English:** The comptime interpreter has a stack and a heap of its own, provided through the `HostServices` table (`H-Services`): `std.stack`, `std.heap`, `std.pointers.load`, `store`, `load_field`, `store_field`, `offset`, `element_pointer` and `difference` all work there, with target sizes, alignments and byte order, so a metaprogram can build a dynarray or a hash table. Comptime stack memory lives as long as the interpreted frame; comptime heap memory not freed by the time `cmp(n)` terminates is released then (`L-Freeze`).
- **[MEM-Escape] Comptime Pointers Stay in Comptime:**  
  $$
  \frac{v \text{ points into comptime stack or heap memory}}{\mathrm{std.comptime\_to\_runtime}(v),\ \text{a store of } v \text{ into static storage, and } \mathrm{std.attributes.set}(\_, \_, v) \text{ are ill-formed}} \qquad \frac{\text{AlwaysComptime} \in \text{Flags}(\text{TypeOf}(v))}{\mathrm{std.comptime\_to\_runtime}(v) \text{ and a store of } v \text{ through any pointer are ill-formed}}
  $$
  > **In Plain English:** Comptime memory does not exist when the program runs or after its level finishes, so a pointer into it cannot be converted to runtime, written into a static slot's initial contents, or kept in an attribute. Values with no runtime form at all — entities, types, blocks — never enter memory: they cannot be converted to runtime or stored through a pointer, comptime memory included, which is what keeps every entity id where `E-Remap` can find it. They live in bindings and attributes, which are part of the store. Static storage is the exception that crosses: its address is real at runtime (`MEM-Static`).

---

## 15. Diagnostics and Assertions

- **[DG-Assert] Assertions Fold or Emit a Check:**  
  $$
  \mathrm{std.diagnostics.assert}(c, m) \rightsquigarrow \begin{cases} \text{compile error naming } m & \text{Comptime} \in \text{Flags}(c) \land c = 0 \\ \text{nothing} & \text{Comptime} \in \text{Flags}(c) \land c = 1 \\ \text{emit a check that halts the program when } c = 0 & \text{otherwise} \end{cases}
  $$
  > **In Plain English:** An assertion is checked at compile time when its condition is known then, and compiled into a runtime check otherwise. It is a host hook (`H-Hook`): it receives its condition as a binding (`C-Valid`), and its message `m` must be comptime, so no conversion to runtime is needed. How a failed runtime check reports `m` before halting is the machine's choice. A parameter line can only name a type (`Type <- FunctionType / Identifier`), so conditions such as "this pointer points to an aggregate" or "this index is in range" cannot be written in the declaration; they are stated as assertions at the top of the function body instead, and they hold in both worlds.
- **[DG-Contract] Preconditions and Postconditions Are Asserted:**  
  $$
  \frac{f : (a_1, \dots, a_n) \to r \quad P \text{ a condition on } a_i \text{ no type expresses}}{\text{body states } P \text{ as } \mathrm{std.diagnostics.assert}(p, m)}
  $$
  > **In Plain English:** The way to write a contract in DOIR is an assertion line, not a decorator, not a parameter type, not a comment. Preconditions go at the top of the body, postconditions immediately before each `std.return`. Both arguments are named bindings like any other call, so a contract is three lines: compute the condition, name the message, assert it. That is the whole idiom, and it is the same idiom everywhere in the language.

  ```rust
  element_t : type = (base: std.byte_pointer, count: std.pointer_sized, index: std.pointer_sized) -> std.byte_pointer
  _ : type = std.types.never_comptime(element_t)
  export element : element_t = {
      in_range : std.u1 = std.is_less(index, count)
      message  : std.c_string = "index out of range"
      _ : _ = std.diagnostics.assert(in_range, message)
      out : std.byte_pointer = std.pointers.element_pointer(base, index)
      _ : _ = std.return(out)
  }
  ```

  The condition and message lines are the price of having no exceptions. They are also the only place a constraint can be written at all, and they hold in both stages: folded away when the condition is comptime, emitted as a check when it is not. `assert` is a host hook (`H-Hook`), so its comptime message needs no conversion to runtime.
- **[DG-Report] Reported Diagnostics:**  
  $$
  \mathrm{std.diagnostics.info},\ \mathrm{warning},\ \mathrm{error}(m, h, \ell) \rightsquigarrow \text{a compiler diagnostic with message } m \text{, help } h \text{, at location } \ell
  $$
  > **In Plain English:** These are host hooks a metaprogram calls to report problems in the code it inspects, typically at a location from `std.meta.source_location.get`. All three are emitted in order as they run (`C-Order`); an `error` makes the build fail once the current level's comptime has finished, so later errors are still reported. An empty help string means no help.

---

## 16. Levels, Ascent, and Descent

- **[L-Tower] A Build Is a Tower of Levels:**  
  $$
  \text{levels} = \{\text{the root of each file the build names}\} \cup \{N \mid N \text{ is passed to } \mathrm{compiler.levels.make}\} \cup \{\varepsilon\}, \qquad \varepsilon = \mathtt{compiler.levels.builtin} \text{, the builtin block}
  $$
  $$
  \text{LevelOf}(e) = \text{the innermost level enclosing } e; \qquad \text{Below}(E) = \{E' \mid E \to^{+} E'\} \text{ over the edges of L-Lower}; \qquad \text{rank}(\varepsilon) = 0, \quad \text{rank}(E) = 1 + \max_{E \to E'} \text{rank}(E')
  $$
  $$
  \text{Rank}(e) = \begin{cases} \text{rank}(\text{LevelOf}(e)) & e \text{ is declared in source} \\ \text{rank}(E) & e \text{ is created during } \text{cmp}(E) \text{ (a specialization, a former result, a copy)} \end{cases}
  $$
  > **In Plain English:** A build is a set of files, one of which the build names as the program (`L-Entry`); the order the files are named in means nothing.
  > The tower is read from the files themselves (`L-Scan`).
  > Its levels are each file's root, each namespace made into a level by `compiler.levels.make`, and the builtin block, which is the level `compiler.levels.builtin`; its edges say what lowers onto what (`L-Lower`).
  > The tower is a directed acyclic graph, not a chain: `std` may lower onto x86 and SPIR-V at once, and a slang level onto SPIR-V alone.
  > A declaration belongs to the innermost level around it, so a backend namespace inside a file is a level of its own, apart from the file root that holds it.
  > A level's rank, the longest path from it down to `builtin`, is the $\text{Rank}$ every rule that compares levels reads.
  > The conventional build ranks the builtin block 0, each backend and the backends file's root 1 (the root names nothing but the builtin block, since the arguments the scan reads do not count, `L-Lower`), `std` 2, and the program 3.
  > A file brought in by `std.import` joins the level that imports it, once in each level that does (`I-Import`); one pasted by `compiler.paste_file` becomes part of the block it is pasted into (`I-Paste`).
  > Neither starts a level.
  > An entity the compiler makes while running $E$'s comptime belongs to $E$, even if it specializes a function of a lower level, so it is not caught by that level's freeze (`M-Freeze`).
  > How a build names its files is the driver's business; [`reference/compiler.doir`](reference/compiler.doir) is the builtin block, and [`reference/backends.doir`](reference/backends.doir) makes a level of [`reference/machine.doir`](reference/machine.doir) and lowers `std` onto it.
- **[L-Scan] The Tower Is Found Before Ascent:**  
  $$
  \text{before any } \text{sema}(E)\text{, the scan reads every call written } \mathrm{compiler.levels.make}(b),\ \mathrm{compiler.levels.this\_file}() \text{ or } \mathrm{compiler.levels.lower\_to}(f, t, s) \text{ and resolves } b, f, t \text{ by name alone}
  $$
  $$
  \text{ill-formed if such a call is not at level scope (L-Freeze) or is in an imported file;}\ b \text{ names nothing the scan can resolve;}\ f \text{ or } t \text{ names no declaration whose value is such a call } (t \text{ may be } \mathtt{compiler.levels.builtin});\ \text{a name resolves twice; or the edges form a cycle}
  $$
  > **In Plain English:** Ascent needs the tower before it can analyse anything: which levels a name may be found in (`R-Unqual`), what freezes before what (`L-Freeze`), and which targets a level is evaluated for (`T-Split`). The tower cannot come out of comptime, which needs all of that to run, so a scan reads it from the source first. `make`, `this_file` and `lower_to` are ordinary comptime calls, but the scan reads them before anything is evaluated, so they are held to what the scan can see:
  >
  > - They are written at level scope, in a file's root or a namespace, never in a function body, a block or an `std.if` branch, and with the callee spelled out: a wrapper or alias of `compiler.levels.make` is not recognised.
  > - Every argument the shape of the tower depends on is a name that leads, through declarations alone, to a namespace or to one of these calls. The scan resolves these names across the root namespaces of every file in the build, ignoring levels, since levels are what it is computing. A name it finds twice is an error, not a choice.
  > - An imported file arrives finished (`I-Import`), so it cannot shape its importer's tower. A file pasted by `compiler.paste_file` is read as if written in place (`I-Paste`), so it can.
  >
  > These arguments are read by the scan, not referenced by the level they are written in, so a backends file may name `std.level` without breaking `L-Mono`. The `passes` argument does not shape the tower; it is ordinary comptime, read by descent, as a `check` call is read by semantic analysis (`L-Sema`). A cycle among the edges, explicit or implicit (`L-Lower`), is reported by the scan, naming the levels on it, rather than surfacing later as a query cycle (`Q-Cycle`). The price is that a level cannot be computed: none is made in a loop or behind `std.numbers.integer_available`. Within the tower, `T-Optional` and `C-Splice` answer "use it if it is there" instead.
- **[L-Lower] Edges Lower One Level onto Another:**  
  $$
  \frac{e \vdash s \Downarrow \pi}{\langle c : \mathtt{compiler.level} = \mathrm{compiler.levels.lower\_to}(f, t, s) \rangle \rightsquigarrow \text{an explicit edge } F \xrightarrow{\pi} T \quad (F, T \text{ the levels } f, t \text{ name};\ F \ne \varepsilon;\ \text{Alias}(c) := f)}
  $$
  $$
  E \text{ has no explicit edge} \implies E \to E' \text{ with no passes for each level } E' \ne E \text{ holding a declaration } E \text{ names}, \text{ and } E \to \varepsilon \text{ if there is none}
  $$
  $$
  \text{targets} = \{\sigma \mid \sigma \xrightarrow{\pi} \varepsilon \text{ is explicit}\}; \qquad \text{Targets}(E) = \{\sigma \in \text{targets} \mid \sigma = E \lor \sigma \in \text{Below}(E)\}
  $$
  $$
  \text{for } \sigma \in \text{Targets}(E) \setminus \{E\}\text{: } \text{next}_\sigma(E) = \begin{cases} \text{the head of } E\text{'s one explicit edge whose head reaches } \sigma & E \text{ has explicit edges} \\ \text{the highest-ranked head of its edges that reaches } \sigma & \text{otherwise} \end{cases} \qquad \text{two candidates} \implies \text{ill-formed}
  $$
  > **In Plain English:** `lower_to(f, t, passes)` says that level `f` is lowered onto level `t` by `passes`. It may be written in any file at level scope, so neither end has to write it: a portable `std` never names a backend, and the backends file, or a file of the build's own, says how `std` lowers onto each backend. A backend lowers onto `builtin`, the builtin block, with its own passes, such as register allocation and encoding. The levels that do are the build's **targets**, the levels descent emits code for (`T-Value`).
  >
  > Most levels write no edge. One with no explicit edge lowers, with no passes, onto every level it names something in: a program onto `std`, a library onto `std`. If it names nothing outside itself and the builtin block, it lowers onto `builtin`. Names in a file it imports count too (the scan follows an import whose path is bound at level scope to a string literal). The arguments of `make`, `this_file` and `lower_to` do not count. A name that two levels both answer, such as `machine` in a build with two backends, cannot give an implicit edge (`L-Scan`); write the edges explicitly instead.
  >
  > Lowered for target $\sigma$, a level has one way down, $\text{next}_\sigma$. An edge with passes runs them, rewriting the level's entities into its head's (`L-Erase`). An edge with no passes hands the level's entities to its head as they are, to be lowered by the head's own edge: a program over `std` is already written in `std`'s terms. An edge whose head reaches no target only makes the head visible (`R-Unqual`, `L-Mono`); nothing descends along it, so a backend that names a shared helper level writes `lower_to(x86, helpers, "")` beside its edge onto `builtin`. Two explicit edges with the same ends are ill-formed, and so are two explicit edges of one level that both reach the same target.
- **[L-Sema] A Level Checks Its Own Entities:**  
  $$
  \frac{e \vdash s \Downarrow \kappa}{\langle c : \mathtt{compiler.level} = \mathrm{compiler.levels.check}(t, s) \rangle \rightsquigarrow \kappa \in \text{checks}(T) \quad (T \text{ the level } t \text{ names};\ T \ne \varepsilon;\ \text{Alias}(c) := t)}
  $$
  $$
  \text{sema}(T) \text{ demands } \text{check}(\kappa, x) \text{ for each } \kappa \in \text{checks}(T) \text{ and each entity } x \text{ of } T \text{ carrying } \kappa\text{'s components}
  $$
  $$
  \text{ill-formed if such a call is not at level scope or is in an imported file, or if } \kappa \text{ names no check (L-Bind)}
  $$
  > **In Plain English:** The two halves of a level's compilation are both declared. `check(t, name)` adds one check to the semantic analysis level `t` runs over its own entities during ascent, beyond the rules of this specification, which every level obeys; `lower_to(t, u, passes)` says how `t` is lowered onto `u` during descent (`L-Lower`). A level that wants its code checked — a teaching language that forbids recursion, a shading level that forbids heap allocation — says so with checks rather than by editing the compiler.
  >
  > A check is a query, not a pass. $\text{checks}(T)$ is itself a query, collecting the `check` calls that name $T$, and $\text{sema}(T)$ demands it when it starts. It then demands $\text{check}(\kappa, x)$ for each entity $x$ of $T$ that carries $\kappa$'s component set, so each result is memoized per entity and re-runs only when what it read changes. Its diagnostics are the level's. A level may be given several checks; they run in no order, so one that needs another's result demands it. Since the calls are not read by the scan (`L-Scan`), the list of checks never shapes the tower, but it must still be found without running anything: each call is written at level scope, with the callee spelled out, and not in an imported file, which arrives finished (`I-Import`). Its name must fold without $T$'s own comptime; one that needs it is a cycle (`Q-Cycle`). The builtin block's analysis is the compiler's own, so `builtin` cannot be given a check.
  >
  > Checks are named by string because a backend sits directly on `builtin`, so there is no level below it whose code could implement one. A name is one the compiler provides (`H-Boot`) or one `compiler.levels.bind_pass` binds (`L-Bind`).
- **[L-Bind] A Function Can Be a Check or a Pass:**  
  $$
  \frac{e \vdash s \Downarrow \nu}{\langle c = \mathrm{compiler.levels.bind\_pass}(f, s) \rangle \rightsquigarrow \nu \text{ names the function } f \text{ as a check (L-Sema) or pass (L-Lower) build-wide} \quad (\text{Alias}(c) := f)}
  $$
  $$
  \text{ill-formed if such a call is not at level scope or is in an imported file; if } f \text{ is not a function; if } \nu \text{ is a name the compiler provides or another bound function's; or if } \nu \text{ is named by a check on } T \text{ with } \text{LevelOf}(f) \notin \text{Below}(T)\text{, or in the passes of an edge } F \to T \text{ with } \text{LevelOf}(f) \notin \{T\} \cup \text{Below}(T)
  $$
  > **In Plain English:** `bind_pass(f, name)`, whose first parameter `T` is deduced from `f` and so never written (`D-Deduce`), binds `name` the way the compiler binds the checks and passes it provides: a `check` or `lower_to` may name it in any file, and cannot tell it from a builtin one. A bound function is comptime of its own level, so that level must already be frozen when it runs (`L-Freeze`): below the level a check analyses, and at or below the head of the edge a pass lowers along. A backend that lowers `std` onto itself writes the pass in its own level, which cannot name `std.meta` (`L-Mono`), so `bind_pass` is a floor name (`H-Boot`). Like a `check` call, it is found without running anything: written at level scope, with the callee spelled out, not in an imported file, and with a name that folds without its level's own comptime. Because it runs once per entity or over the whole store, the compiler is expected to compile a bound function for the machine it runs on and call it directly rather than interpret it (`H-Hook`); that changes its speed, never its result.
- **[L-Mono] Downward References Only:**  
  $$
  \forall e' \in \text{refs}(e), \quad \text{LevelOf}(e') \in \{\text{LevelOf}(e), \varepsilon\} \cup \text{Below}(\text{LevelOf}(e)) \qquad (\text{so } \text{Rank}(e') \le \text{Rank}(e))
  $$
  > **In Plain English:** Code in a level can use what is in it or below it, never what is above it or beside it. A level with no explicit edge lowers onto whatever it names (`L-Lower`), so for it the rule only rules out cycles (`L-Scan`). It bites in a level whose edges are written out, such as a backend that names `std`. The arguments the scan reads are not references (`L-Scan`). Two backends do not see each other's helpers unless an edge says so; within one level, what keeps targets apart is liveness (`T-Live`), not naming.
- **[L-Stage] Stratified Ascent:**  
  $$
  \text{Semantic analysis (this specification's rules and the checks of L-Sema) and comptime run up the tower: } \text{sema}(E); \text{cmp}(E) \text{ starts only once } \text{cmp}(E') \text{ has terminated for every } E' \in \text{Below}(E)
  $$
  > **In Plain English:** Compilation proceeds from the ground up: a level is analysed and evaluated only once everything below it has frozen. Two levels neither of which is below the other are independent, and may be evaluated in either order or at once. Descent then lowers from the top down, once per target, along the edges and passes of `L-Lower`.
- **[L-Freeze] Query Readiness:**  
  $$
  \text{Inside } \text{cmp}(n)\text{: an evaluation started by the level-scope declaration at lexical position } k \text{ sees exactly the level-}n \text{ store effects written before } k \text{ (}\text{C-Order}, \text{M-Lexical).}
  $$
  $$
  \text{Outside level } n\text{: a query against level } n \text{ is defined} \iff \text{cmp}(n) \text{ has terminated.}
  $$
  > **In Plain English:** Within a level, modifiers and other comptime effects are computed top to bottom, and each comptime read sees the level as it stands at that line. A level-scope declaration is one in a file's root or in a namespace at any depth, as every modifier line in `standard.doir` is; a line inside a function body or block is not one. A comptime evaluation keeps the position of the level-scope line that started it, even while it runs function bodies written elsewhere. Every other reader (higher levels, descent, the host) waits until the level has finished and frozen, then sees one final answer. In-level reads are therefore keyed by $\langle e, k \rangle$; queries against a frozen level by $e$ alone. A level over more than one target adds the target to both keys (`T-Split`).
- **[L-Erase] Lowering Retires a Level:**  
  $$
  \text{After lowering level } E \text{ for target } \tau: \quad \text{LevelOf}(e) = E \implies \tau \in \text{Lowered}(e) \;\land\; \text{no rewrite, allocation, or emission for } \tau \text{ in a level of Below}(E) \text{ reads } e
  $$
  > **In Plain English:** Lowering rewrites a level's program into entities of the level below it on the way to a target $\tau$ (`L-Lower`). The original entities are not deleted: they keep their ids and level and still answer queries (types, flags, source locations, attributes). They are retired under $\tau$, which adds $\tau$ to their `Lowered` relation: `L-Mono` already forbids lower entities from referencing them, and from now on nothing that runs below the level for $\tau$ reads them, so they can no longer affect lower levels on that target. Because retirement is tracked per target, lowering for $\tau_1$ leaves entities unretired and readable for $\tau_2$'s descent. A level handed down by an edge with no passes is retired with the head it was handed to.
- **[L-Entry] A Program Is a Script:**  
  $$
  \text{The root block of the program file (the file the build names as the program, L-Tower) runs in lexical order from its first declaration to its terminator on the build's host target (T-Value).}
  $$
  > **In Plain English:** A DOIR program needs no `main`. On the build's host target (`compiler.levels.set_host`), its outermost block is executed like any other block, so it ends with `std.halt()` (`WF-Term`). Its comptime lines fold as they are reached (`C-Order`); the rest is the program's entry code. For every other target (such as SPIR-V or shader targets, `T-Device`), the program file contributes exported functions and entry points (`compiler_impl.export_entry`, `T-Bridge`) rather than an executable top-level script, so their roots need no terminator (`WF-Term`). Files below the program and files it imports contribute names, not code: every top-level line in them must fold or be a declaration, and their roots are never executed.

---

## 17. Targets

- **[T-Value] Levels Are Values:**  
  $$
  \frac{e \vdash b \Downarrow N \quad \text{Namespace} \in \text{Flags}(N)}{\langle t : \mathtt{compiler.level} = \mathrm{compiler.levels.make}(b) \rangle \rightsquigarrow t \text{ names the level } N} \qquad \frac{}{\langle t : \mathtt{compiler.level} = \mathrm{compiler.levels.this\_file}() \rangle \rightsquigarrow t \text{ names the root of the file it is written in}}
  $$
  $$
  \tau_1, \dots, \tau_n = \text{the targets (L-Lower)} \quad (n \ge 0); \qquad n = 0 \implies \text{the compiler adds its default backend } D \text{ with } D \xrightarrow{\pi_D} \varepsilon\text{, and every edge onto } \varepsilon \text{ goes onto } D \text{ instead}
  $$
  $$
  \text{host} = \begin{cases} \tau_1 & n \le 1 \\ \text{the one target passed to } \mathrm{compiler.levels.set\_host} & n > 1 \end{cases} \qquad n > 1 \land \text{no or several targets passed to } \mathrm{compiler.levels.set\_host} \implies \text{ill-formed}
  $$
  > **In Plain English:** A `compiler.level` is a value naming a level of the tower: `compiler.levels.make` makes a namespace one, `this_file` names the root of its own file, and `lower_to` joins levels with edges. A backend's namespace provides the `machine` types, `compiler_impl` hooks and `std` bodies; it becomes a target by lowering onto `compiler.levels.builtin` with its passes, and descent and emission run once per target. There is no build-wide fallback schedule: every pass belongs to an edge. One build can have x86 and SPIR-V targets at once. With one target it is the host; with several, `compiler.levels.set_host` marks the one that runs the program's root (`L-Entry`), and leaving it out or marking two is an error. The host mark is read by descent, not by the scan, so it may be written in any level. A build with no target gets one by default, supplied by the compiler with that backend's own passes: the backend native to the machine the compiler runs on, or Mizu if the compiler cannot tell what that is. Whatever would have lowered straight onto `builtin` lowers onto it instead, and it is the host. Where this specification indexes descent by $\tau$ (`Lowered`, `VirtualReg`$_\tau$, `T-Live`, `T-Bridge`), $\tau$ ranges over the targets.
- **[T-Live] Declarations Are Live for a Target Set:**  
  $$
  \frac{e \vdash a \Downarrow d \quad e \vdash s \Downarrow \sigma}{\langle c : \_ = \mathrm{std.targets.compile\_for}(a, s) \rangle \rightsquigarrow \text{On}(d) := \text{On}(d) \cup \{\sigma\}; \quad \text{Alias}(c) := d}
  $$
  $$
  \text{Live}(e) = \begin{cases} \text{Targets}(E) & e \text{ is the root of level } E \\ \text{On}(e) \cap \text{Live}(\text{Parent}(e)) & \text{On}(e) \ne \varnothing \\ \text{Live}(\text{Parent}(e)) & \text{otherwise} \end{cases}
  $$
  $$
  e \text{ is lowered for every } \tau \in \text{Live}(e); \qquad \text{Live}(e) = \varnothing \land e \text{ is not always-comptime} \implies e \text{ is dead, and reported}
  $$
  > **In Plain English:** $\text{On}(e)$ is the set of targets passed to `std.targets.compile_for` with $e$. A level is live for the targets below it, and a target for itself, so x86's bodies are never lowered for SPIR-V. A level that reaches no target, such as a file root holding only level declarations, is live for none: only always-comptime declarations, which are never lowered, may live there. Like `set_symbol_name` (`M-SymbolName`), `compile_for` mutates the declaration it is given rather than making a copy: it goes through aliases (`M-Alias`), takes effect at its lexical position (`C-Order`) and is folded at freeze, is idempotent and order-independent (`M-Idempotent`, `M-Commute`), is never removed as dead code (`M-Impure`), and cannot touch a frozen declaration, one from a lower level or an imported file (`M-Freeze`). `compile_for(kernel, targets.spirv)` says a declaration is lowered only for that target, and a second call adds a second target; a declaration never passed to it is lowered for every target its enclosing declaration is, so everything inside a spirv-only function is spirv-only too. A namespace has no type to deduce, so it cannot be passed; restrict its members instead. A declaration live for no target in the build — the targets passed for it exclude every target its parent is live for — is dead and reported as such. A reference to a declaration that is not live for the target currently being lowered is not automatically an error: if the callee is live for some other target of the build, the call crosses targets and is lowered as a bridge (`T-Bridge`); if it is live for none, it is an error naming the declaration and the target.
- **[T-Split] Shared Levels Are Evaluated per Target:**  
  $$
  \text{key}(\text{cmp}(e)) = \begin{cases} \langle \kappa, \tau \rangle,\ \tau \in \text{Targets}(\text{LevelOf}(e)) & |\text{Targets}(\text{LevelOf}(e))| > 1 \\ \kappa & \text{otherwise} \end{cases} \qquad \kappa = \langle e, k \rangle \text{ in level, } e \text{ once frozen (L-Freeze)}
  $$
  > **In Plain English:** A level over several targets is parsed once, but its compile-time answers depend on the target's widths and byte order (`H-Target`), so its comptime evaluation is keyed by target as well as by entity and position, and lookup sees a different set of levels under each (`R-Unqual`). An evaluation whose recorded dependencies include no entity of a target cannot depend on which one it runs for, so one memo answers every target's key and the evaluation runs once; only evaluations that read a target run per target. Source declarations are never copied per target: one entity serves them all, with one `Parent` (`WF-Par`) and one name (`WF-Unique`), and what differs per target is its comptime answers (keyed above), whether it is lowered (`T-Live`) and its descent components (`VirtualReg`$_\tau$, `PhysicalReg`$_\tau$, and whether $\tau \in$ `Lowered`). Layout-dependent type constructors (`pointer`, `array`, `function_pointer`) are memoized per layout equivalence class under `TF-Memo`, sharing type entities among targets with identical pointer widths and alignments. An entity created while running `cmp` belongs to the level and the target that created it.
- **[T-Device] A Target Is a Backend, Not a Device Class:**  
  $$
  \text{each target } \tau_i \text{ (L-Lower) is a backend in its own right, with its own signature } \text{sig}(\tau_i) \text{ (T-Sig)}
  $$
  > **In Plain English:** The language knows nothing about CPUs and GPUs. A build's targets are whatever lowers onto `builtin` — x86, wasm, SPIR-V — and each is just a level with its own passes. Two targets are interchangeable only to the extent their signatures agree on calling convention, register classes and memory; the compiler never assumes they do. A dialect of another target, slang over SPIR-V say, need not be a target at all: it can be a level that lowers onto SPIR-V with passes of its own, so the tower, not a hardware category, says what reaches what. Two targets share encoder code by both lowering onto a level that holds it (`L-Lower`). Whether any two targets can call each other is declared by the levels (`T-Bridge`), not guessed.
- **[T-Bridge] Calls Across Targets Are Lowered as Bridges:**  
  $$
  \frac{c : \text{Call} \quad \tau = \text{the target being lowered} \quad \tau \notin \text{Live}(f) \quad \text{Live}(f) = \{\sigma\} \quad f = \alpha(\text{Call}(c))}{\tau \text{ lowers } c \text{ through its hook } \mathtt{compiler\_impl.bridges.}\sigma\mathtt{.call}(f, c) \text{, and } \sigma \text{ emits } f \text{ through its hook } \mathtt{compiler\_impl.export\_entry}(f)}
  $$
  $$
  \tau \notin \text{Live}(f) \;\land\; |\text{Live}(f)| > 1 \implies \text{ill-formed}
  $$
  > **In Plain English:** Calling code that lives on another target is not a branch. Each backend declares its own half of every crossing. The callee's backend supplies `compiler_impl.export_entry`, which emits a function as an entry point other targets can reach. The caller's backend supplies, for each target $\sigma$ it can call, a namespace `compiler_impl.bridges.`$\sigma$ whose `call` hook marshals the arguments and the result — a register shuffle, a copy to a buffer, a kernel launch — and invokes that entry point; the compiler uses it in place of `compiler_impl.call`. The hook inspects call arguments using the level-0 builtins `compiler.argument_count` and `compiler.argument`, since a backend cannot reference `std.meta` (`L-Mono`). The namespace is named after the declaration that holds $\sigma$ (`targets.spirv` gives `bridges.spirv`), so a backend needs no reference to its peer to declare it. A pair with no such namespace cannot call across: the hook is a name resolved where it is used, so the absent one is reported there, naming both targets (`A-Res`). An argument the hook cannot marshal makes the hook ill-formed for that call, and that diagnostic names both targets too. A callee live for several targets other than the caller's is ill-formed to call across, rather than the compiler picking one: restrict it with `std.targets.compile_for`, or call a wrapper that is.
- **[T-Order] Effects Across Targets Have No Implicit Order:**  
  $$
  \text{order}(a, b) \text{ defined} \iff \tau(a) = \tau(b) \;\lor\; \text{a bridge call (T-Bridge) establishes a synchronization edge from } a \text{ to } b
  $$
  > **In Plain English:** Within one target, lexical order still decides which effect runs first (`C-Order`). Across targets it does not: a store emitted for x86 and a write emitted for SPIR-V have no defined order unless synchronized across a bridge call (`T-Bridge`). A bridge call acts as an explicit barrier: caller effects preceding the bridge call are sequenced before the callee entry, and callee effects are sequenced before the bridge returns.
- **[T-Legal] Lowering Legality Is Checkable:**  
  $$
  \frac{\text{descent lowers level } E \text{ onto } H = \text{next}_\tau(E) \text{ for target } \tau}{\forall e \text{ read by an entity of } H \text{ or of a level in } \text{Below}(H):\; \text{LevelOf}(e) \in \{H, \varepsilon\} \cup \text{View}_\tau(H) \;\land\; \big(\tau \in \text{Live}(e) \lor e \text{ is always-comptime}\big) \;\land\; \tau \notin \text{Lowered}(e)}
  $$
  > **In Plain English:** After a lowering for target $\tau$, a verifier checks the result against the level it landed in: every reference names something that level, the builtin block or a level it sees under $\tau$ provides (`R-Unqual`, `L-Mono`), everything referenced that will be lowered is live for $\tau$ (`T-Live`), and nothing retired under $\tau$ by `L-Erase` is still being read. A level's signature is therefore what its own declarations and the levels below it supply; `T-Sig` states the part of it `std` requires of a backend. A lowering that fails this check is a compiler bug, and the verifier reports it as one instead of going on to emit bytes. This is what turns "levels behave like dialects" from a convention into a property that can be tested.
- **[T-Sig] Target Signature Satisfaction:**  
  $$
  \frac{\text{Level } L \text{ stacked over target } S}{\forall n \in \text{sig}(L), \quad S \text{ provides } n}
  $$
  > **In Plain English:** When a level sits on top of a lower target (such as a hardware platform or an OS runtime), the target must provide every name required by the higher level's interface. If any are missing, compilation fails. Here $S$ is a target's backend namespace, and the check is made once per target: a name one backend lacks makes the level above ill-formed for that target alone, and the level is still lowered for the others (`T-Live`).

  The minimum every backend namespace must provide for `std` to sit over it, which is $\text{sig}(\mathtt{std})$; names are relative to the namespace (`x86_backend.machine.u1`). A backend may provide more, and a build without `std` makes a level of a namespace that provides exactly what its program names.

  | Name                                 | Requirement                                                                                          |
  | ------------------------------------ | ---------------------------------------------------------------------------------------------------- |
  | `machine.u1`                         | 1-bit unsigned type; the result of comparisons and logical operations.                               |
  | `machine.u8`                         | 8-bit unsigned type; `std.byte`.                                                                     |
  | `machine.u32` or `machine.u64`       | Unsigned type as wide as a target pointer: `u32` on 32-bit targets, `u64` on 64-bit targets.         |
  | `machine.pointer_sized`              | Alias of that pointer-width type; the layout of every pointer (`M-Ctor`).                            |
  | `machine.pointer_difference`         | Signed type as wide as a target pointer (`compiler.signed_base_type`, `S-Numeric`), distinct from `machine.pointer_sized`; the operand of pointer offsets and the result of differences. |
  | `machine.byte_order`                 | `compiler.pointer_sized` constant: `0` little-endian, `1` big-endian; the byte order of every value in memory, comptime memory included (`H-Target`). |
  | `compiler_impl.prologue`, `epilogue`, `pass_arguments`, `call`, `emit_return` | The calling-convention hooks below, declared as the root `compiler_impl` namespace.                  |

  Functions that are not inlined or evaluated away at comptime are emitted through five hooks in the `compiler_impl` namespace. The contract is written out in [`reference/machine.doir`](reference/machine.doir). `function` and `call` are `compiler.entity` handles; deduced parameters are omitted at call sites (`D-Deduce`).

  | Primitive                       | Signature                                                     | Semantics                                                                                                                         |
  | ------------------------------- | ------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
  | `compiler_impl.prologue`        | `(function: compiler.entity)`                                 | Frame setup immediately below `function`'s entry label, including saving the return address if the machine keeps it in a register. |
  | `compiler_impl.epilogue`        | `(function: compiler.entity)`                                 | Frame teardown below `function`'s exit label, ending in the return to the caller.                                                 |
  | `compiler_impl.pass_arguments`  | `(call: compiler.entity, i: machine.pointer_sized)`           | Places argument `i` of `call` where the calling convention assigns it.                                                            |
  | `compiler_impl.call`            | `(function: compiler.entity, call: compiler.entity)`          | Passes every argument of `call`, then transfers to `function`'s entry label, recording the return address.                        |
  | `compiler_impl.emit_return`     | `(T: deduced type, value: T, function: compiler.entity)`      | Jumps to `function`'s exit label, routing all exit paths through a single epilogue, with `value` in the return register.          |

  A backend in a build with more than one target also supplies the bridge hooks of `T-Bridge`: `compiler_impl.export_entry(function)`, with the signature of `prologue`, which emits a function other targets can call, if any other target calls into it, and `compiler_impl.bridges.`$\sigma$`.call(function, call)`, with the signature of `call`, which replaces `compiler_impl.call` for a callee that lives only on target $\sigma$, for each target $\sigma$ it calls into. A pair that declares nothing cannot call across, and no special rule is needed to catch that: the hook is resolved where it is used, so an absent one fails there (`A-Res`, `T-Optional`).

  Types are reached through the `machine` namespace (`R-Unqual`). The compiler calls the `compiler_impl` hooks itself while lowering a function. Their signatures name only `compiler` and `machine` entities, so `L-Mono` holds: the entity handle they take is `compiler.entity`, which `std.meta.entity` aliases.

  Beyond the table a backend supplies the body of every `standard.doir` prototype that is neither a host hook (`H-Hook`) nor given a software body by `standard.emulated.doir` (`I-Extern`), including the runtime heap behind `std.heap` (`MEM-Heap`), and its physical register classes (`REG-Phys`, Part I §7), which are calls into the builtin block.
  It may define an emulated one too, and its definition then replaces the software body for every operand type that operation takes; the operations over both integers and floats have one prototype per kind (`N-Kind`), so a backend replaces the integer and float bodies separately.
  Its descent passes are not in the namespace: they are the passes of its edge onto `compiler.levels.builtin` (`L-Lower`).
  `reference/machine.doir` states the whole contract as declarations.
- **[T-Optional] Optional Target Features:**  
  $$
  \frac{n \in \text{opt}(\mathtt{std}) \quad S \text{ does not provide } n}{\text{every alias of } n \text{ is absent: declaring it is well-formed, using it is ill-formed (A-Res)}}
  $$
  > **In Plain English:** Some names are optional: a machine may provide them or not, and `std` aliases them either way. This needs no special rule: an alias is only resolved where it is used (`A-Res`), so code that names an absent one fails where it uses it, with a diagnostic naming the missing feature. Code that wants to adapt asks first with `std.numbers.integer_available` or `std.numbers.float_available`, which fold, and puts the use in a branch `C-Splice` discards. `reference/machine.doir` gives the exact shape each optional name must have when it is provided.

  | Optional name | Shape |
  | ------------- | ----- |
  | `machine.u16`, `machine.u32`, `machine.u64` (those not required above) | `compiler.base_type(n, n)` |
  | `machine.i8`, `machine.i16`, `machine.i32`, `machine.i64` | `compiler.signed_base_type(n, n)`; the one as wide as a pointer is `machine.pointer_difference` |
  | `machine.f32`, `machine.f64` | `compiler.float_base_type(n, n)`; `std.square_root`, `std.is_not_a_number`, `std.is_infinite`, `std.numbers.float_convert` apply to them |

---

## 18. Internal Register Management: Virtual to Physical

Both registers are components on the binding's own entity, indexed per target $\tau$ during descent (`T-Value`): `VirtualReg`$_\tau(e)$ and `PhysicalReg`$_\tau(e)$.

- **[REG-Virt] Internal Virtual Register Assignment:**  
  $$
  \frac{e : \text{TypeOf} \quad \tau \in \text{Live}(e) \quad \text{Valueless} \notin \text{Flags}(e) \quad \text{Comptime} \notin \text{Flags}(e) \quad \text{size}_\tau(\text{TypeOf}(e)) > 0 \quad \text{VirtualReg}_\tau(e) = \bot}{\text{VirtualReg}_\tau(e) := \text{freshVReg}_\tau()}
  $$
  > **In Plain English:** If a value is needed at runtime under target $\tau$ (meaning it is not completely calculated and thrown away during compilation) and occupies any bits, the compiler automatically assigns it a unique virtual register for that target. In a multi-target build, virtual registers are allocated independently per target, so x86 and SPIR-V temporaries never collide. Aliases never receive one of their own (they have no `TypeOf`); they share their referent's (`A-Transparent`).
- **[REG-Share] Virtual Register Sharing (`std.unsafe.share_register`):**  
  $$
  \frac{e \vdash a \Downarrow e_1 \quad e \vdash b \Downarrow e_2 \quad v_1 = \text{VirtualReg}_\tau(e_1) \quad v_2 = \text{VirtualReg}_\tau(e_2)}{\mathrm{std.unsafe.share\_register}(a, b) \rightsquigarrow \forall e' : \text{VirtualReg}_\tau(e') = v_1 \Rightarrow \text{VirtualReg}_\tau(e') := v_2}
  $$
  > **In Plain English:** This unsafe intrinsic forces two distinct runtime values of one type to share the exact same virtual register within target $\tau$. Everything already sharing either register joins the merged one, so sharing is transitive. It is unsafe because nothing checks that the two values are never live with different contents at once; if they are, the behavior is undefined (`UB`).
- **[REG-Phys] Physical Register Mapping:**  
  $$
  \frac{e : \text{VirtualReg}_\tau \quad v = \text{VirtualReg}_\tau(e)}{\text{PhysicalReg}_\tau(e) := \text{allocate}_\tau(v) \in \mathcal{R}_{\text{phys},\tau} \cup \text{SpillSlots}_\tau}
  $$
  > **In Plain English:** The register allocator for target $\tau$ maps each virtual register to a real target register (like `RAX` on x86 or `R0` on ARM), or to a stack spill slot when registers run out, and records the result on every entity holding that virtual register under target $\tau$. Because `allocate` depends only on $v$, values joined by `REG-Share` share the exact same CPU register. A runtime aggregate is one virtual register of its storage size; how the machine holds it is the machine's choice.

---

# Part III: Divergences

Implementation behavior that deliberately contradicts this specification is recorded here, with the rule tag it breaks and the reason. Anything not listed is a bug in the implementation. The entries below describe the legacy compiler (`tree/D`) and the references extracted from it; they are not licence for the query-driven compiler to copy them.

| Rule | Divergence | Reason |
| ---- | ---------- | ------ |
| [AT-Set] | `std.attributes.mark` stores a fresh opaque marker and offers no way to store a chosen entity. | Hook attributes must name a function, so attributes were redesigned as types (`AT-Type`, `AT-Set`). |
| [C-Specialize] | Specialization is keyed on argument types only, so comptime value arguments share one body and are not bound in it. | The waterfall had no partial evaluation of a call with mixed arguments; a comptime walk over a type's fields cannot be unrolled without it. |
| [C-Valid] | `compiler.assembler.register_for` is declared `(T: pointer_sized, value: pointer_sized) -> register` in [`reference/compiler.doir`](reference/compiler.doir), as the legacy builtin block built it, not `(T: type, value: T)`. | The legacy builder only ever needed the register number, so the type was carried as a word. |
