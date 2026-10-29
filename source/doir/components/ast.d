/// The binding components of `doir.spec.md` Part II §1 that the parser writes through `doir.builders`, and the `Lookup*` components it writes in place of the names it does not resolve. Every one holding an entity id mixes in `ecrs.relation.Relates` (`E-Remap`).
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// immutable t = ecrs.context.addEntity(store), e = ecrs.context.addEntity(store);
/// ecrs.context.addComponent!TypeOf(store, e).type = t;
/// assert(ecrs.context.getComponent!TypeOf(store, e).type == t);
/// ---
module doir.components.ast;

static import fp.dynarray;
static import fp.fnv1a;

static import ecrs.context;
static import ecrs.relation;
static import ecrs.registry;

public import ecrs.registry : EntityId, invalidEntity;
public import doir.strings : StringId;

@nogc nothrow:


// --- bindings ----------------------------------------------------------------

/// The interned declaration name; absent for `_` declarations.
struct Name {
	StringId value;
}

/// The enclosing entity: the block that lists this declaration, the function type that lists this parameter (`R-Param`), or the declaration whose type is this function type written in place (`WF-Par`).
struct Parent {
	mixin ecrs.relation.Relates!"parent";
}

/// The ordered child declarations of a block, function body, aggregate type or namespace.
struct Block {
	mixin ecrs.relation.Relates;
}

/// The type binding of a value; `type` for a type entity.
struct TypeOf {
	mixin ecrs.relation.Relates!"type";
}

/// The layout ⟨size, align, unique⟩ in bits. The parser writes it zeroed on an aggregate or function type; layout queries fill in size and alignment.
struct TypeDefinition {
	size_t size = 0;
	size_t alignment = 0;
	size_t unique = ReservedUnique.structural;
}

/// The discriminators the builtin types reserve, so `S-Struct` keeps them apart from every structural type of the same layout (`M-Distinct`, `S-Numeric`, `FP-Type`). `std.types.distinct_copy` and `compiler.comptime_base_type` hand out fresh ones from `firstFresh` up.
enum ReservedUnique : size_t {
	structural = 0, /// Every type the program defines without `std.types.distinct_copy`.
	type = 1, /// `type`.
	deducedType = 2, /// `deduced type`, a type distinct from `type` (Part I §7).
	block = 3, /// `block`.
	pack = 4, /// `pack`, a variadic parameter's type (`F-Pack`).
	signed = 5, /// Every `compiler.signed_base_type` (`S-Numeric`).
	float_ = 6, /// Every `compiler.float_base_type` (`S-Numeric`).
	functionPointer = 7, /// Every `std.types.function_pointer` (`FP-Type`).
	firstFresh = 8, /// The first discriminator a fresh type may take.
}

/// Makes this entity another name for a binding (`A-Res`). Written by resolution or by evaluation (`A-Bind`), never by the parser.
struct Alias {
	mixin ecrs.relation.Relates!"target";
}

/// The parameter bindings of a function type (`R-Param`), or the argument bindings of a call (`WF-Arg`).
struct FunctionInputs {
	mixin ecrs.relation.Relates;
}

/// The return type binding of a function type; absent means `void`. Copied onto the functions declared with it.
struct FunctionReturn {
	mixin ecrs.relation.Relates!"type";
}

/// The callee binding of a call.
struct Call {
	mixin ecrs.relation.Relates!"callee";
}

/// A literal's payload (`V-Literal`): an integer or character code point, a float, or a byte string. The reference holds integer literals to 64 bits.
struct ConstantVal {
	/// Which payload the literal has.
	enum Kind : ubyte { integer, float_, bytes }

	Kind kind = Kind.integer; /// Which of the fields below is meaningful.
	ulong integerValue = 0; /// An integer literal's bit pattern, or a character literal's code point.
	double floatValue = 0; /// A float literal, rounded to its declared type later (`V-Literal`).
	StringId bytesValue; /// A string literal's bytes after escapes, interned.

	/// An integer or character literal.
	///
	/// Examples:
	/// ---
	/// assert(ConstantVal.integer(0xFF).integerValue == 255);
	/// ---
	static ConstantVal integer(ulong value) @nogc nothrow { ConstantVal c; c.kind = Kind.integer; c.integerValue = value; return c; }

	/// A float literal.
	///
	/// Examples:
	/// ---
	/// assert(ConstantVal.float_(0.5).kind == ConstantVal.Kind.float_);
	/// ---
	static ConstantVal float_(double value) @nogc nothrow { ConstantVal c; c.kind = Kind.float_; c.floatValue = value; return c; }

	/// A string literal, its bytes already interned.
	///
	/// Examples:
	/// ---
	/// assert(ConstantVal.bytes(StringId(3)).bytesValue == StringId(3));
	/// ---
	static ConstantVal bytes(StringId value) @nogc nothrow { ConstantVal c; c.kind = Kind.bytes; c.bytesValue = value; return c; }
}

/// The flag set of Part II §1. The parser writes `Valueless`, `Namespace`, `Export`, `Comptime` on literals (`C-Constant`) and the call prefixes; every other flag is a comptime effect, positioned by `C-Order`.
struct Flags {
	enum : uint {
		None = 0,
		// Bits 0–12 keep the legacy values, which the legacy `mizu.doir` (`tools/mizu_gen.d`) wrote as constants.
		Valueless = 1 << 0,
		Namespace = 1 << 1,
		Export = 1 << 2,
		Comptime = 1 << 3,
		AlwaysComptime = 1 << 4,
		NeverComptime = 1 << 5,
		ReadOnly = 1 << 6,
		Union = 1 << 7,
		Pure = 1 << 8,
		Inline = 1 << 9,
		Flatten = 1 << 10,
		Tail = 1 << 11,
		SharedBody = 1 << 12,
		Packed = 1 << 13,
		Signed = 1 << 14,
		Float = 1 << 15,
		NeverInline = 1 << 16,
	}

	uint flags = None; /// The set, one bit per flag.
}

/// The two-word type `deduced type`, as a parameter's `LookupTypeOf` spells it: no declaration can shadow a name with a space in it, so resolution maps it straight to the builtin `deduced_type` (`D-Deduce`).
enum deducedTypeName = "deduced type";


// --- lookups -----------------------------------------------------------------

/// An unresolved type: the interned path written in type position, stood in for by `TypeOf` once resolved.
struct LookupTypeOf {
	StringId name;
}

/// An unresolved return type of a function type, stood in for by `FunctionReturn`.
struct LookupFunctionReturn {
	StringId name;
}

/// An unresolved callee, stood in for by `Call`.
struct LookupCall {
	StringId name;
}

/// The unresolved arguments of a call, every one a name (`WF-Arg`), stood in for by `FunctionInputs`.
struct LookupFunctionInputs {
	StringId* names = null;

	/// Hashes the names rather than the list's pointer, for early cutoff when a query produces one.
	///
	/// Examples:
	/// ---
	/// LookupFunctionInputs a, b;
	/// assert(LookupFunctionInputs.contentHash(a) == LookupFunctionInputs.contentHash(b));
	/// ---
	static size_t contentHash(ref const LookupFunctionInputs self) @nogc nothrow {
		return fp.fnv1a.hash(fp.dynarray.slice(self.names));
	}

	/// Releases the list when the component is removed.
	///
	/// Examples:
	/// ---
	/// static import fp.dynarray;
	/// LookupFunctionInputs inputs;
	/// assert(fp.dynarray.pushBack(inputs.names, StringId(0)));
	/// inputs.finalize();
	/// assert(inputs.names is null);
	/// ---
	void finalize() @nogc nothrow {
		fp.dynarray.free(names);
		names = null;
	}
}

/// The target of `x : alias = y`, stood in for by `Alias` (`A-Res`).
struct LookupAlias {
	StringId name;
}

/// A declaration's value or a parameter's default written as a bare name (`x : T = y`), which evaluation binds as an alias or a copy (`A-Bind`).
struct LookupValue {
	StringId name;
}

unittest { // libECRS silently skips a holder whose hook is not `@nogc nothrow`; every holder of an entity id must pass (E-Remap)
	static assert(ecrs.registry.hasRemapEntities!Parent && ecrs.registry.hasRemapEntities!Block && ecrs.registry.hasRemapEntities!TypeOf && ecrs.registry.hasRemapEntities!Alias && ecrs.registry.hasRemapEntities!FunctionInputs && ecrs.registry.hasRemapEntities!FunctionReturn && ecrs.registry.hasRemapEntities!Call);
}

version(unittest) static import doir.testing;

unittest { // literal payloads, and unresolved arguments hashed by content and released with their component
	assert(ConstantVal.integer(7).kind == ConstantVal.Kind.integer && ConstantVal.integer(7).integerValue == 7);
	assert(ConstantVal.float_(0.5).kind == ConstantVal.Kind.float_ && ConstantVal.float_(0.5).floatValue == 0.5);
	assert(ConstantVal.bytes(StringId(3)).kind == ConstantVal.Kind.bytes && ConstantVal.bytes(StringId(3)).bytesValue == StringId(3));

	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	immutable a = doir.testing.addEntity(store), b = doir.testing.addEntity(store);
	assert(ecrs.context.addComponent!LookupFunctionInputs(store, a) !is null && ecrs.context.addComponent!LookupFunctionInputs(store, b) !is null);
	auto x = &ecrs.context.getComponent!LookupFunctionInputs(store, a), y = &ecrs.context.getComponent!LookupFunctionInputs(store, b);
	assert(fp.dynarray.pushBack(x.names, StringId(1)) && fp.dynarray.pushBack(y.names, StringId(1)));
	assert(x.names !is y.names && LookupFunctionInputs.contentHash(*x) == LookupFunctionInputs.contentHash(*y));
	assert(fp.dynarray.pushBack(y.names, StringId(2)));
	assert(LookupFunctionInputs.contentHash(*x) != LookupFunctionInputs.contentHash(*y));
	assert(ecrs.context.removeComponent!LookupFunctionInputs(store, a));
	assert(!ecrs.context.hasComponent!LookupFunctionInputs(store, a));
}
