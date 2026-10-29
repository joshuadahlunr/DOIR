/// The binding components of `doir.spec.md` Part II §1, and the `Lookup*` components the parser writes in place of the names it does not resolve (`doir.builders` writes them). Every one holding an entity id mixes in `ecrs.relation.Relates` (`E-Remap`).
///
/// The internal register components are indexed by target (`VirtualReg_τ`, `PhysicalReg_τ`): one libECRS component per target index, so each target's lowering owns its own and independent targets never clobber each other. A single-target build uses index 0.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// immutable e = ecrs.context.addEntity(store);
/// ecrs.context.addComponent!Rank(store, e).value = 2;
/// assert(ecrs.context.getComponent!Rank(store, e).value == 2);
/// ---
module doir.components;

static import std.typecons;

static import fp.dynarray;
static import fp.fnv1a;
static import fp.pointer;
static import fp.string;

static import ecrs.context;
static import ecrs.relation;
static import ecrs.registry;

static import doir.engine.logs;
static import doir.engine.positions;
static import doir.engine.query;

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


// --- types and layout --------------------------------------------------------

/// The ABI symbol of a function or static: the `R-Mangle` name unless `M-SymbolName` set one.
struct SymbolName {
	StringId value; /// The interned symbol.
}

/// A pointer or array type: ⟨pointee, length⟩, a length of 0 being a pointer and any other an array of that many elements.
struct Pointer {
	mixin ecrs.relation.Relates!"pointee";
	ulong length = 0; /// 0 for a pointer, the element count for an array.
}

/// The rank of the entity's level in the tower (`L-Tower`).
struct Rank {
	ushort value; /// The rank.
}

/// The targets `std.targets.compile_for` gave a declaration, folded from its positioned log at freeze (`T-Live`); absent means live wherever its parent is.
struct On {
	mixin ecrs.relation.Relates;
}

/// The member functions of an overload set, folded from its positioned log at freeze (`TF-Overload`).
struct Overloads {
	mixin ecrs.relation.Relates;
}

/// The targets whose lowering has retired the entity (`L-Erase`); absent means retired under none. Each target's entry is owned by that target's lowering query.
struct Lowered {
	mixin doir.engine.logs.Log!(ecrs.relation.Relation!1);
}

/// A binding's internal virtual register for one target (`REG-Virt`).
struct VirtualReg {
	uint id; /// The `VRegId`.
}

/// A binding's assigned hardware register or spill slot for one target (`REG-Phys`).
struct PhysicalReg {
	/// Which of the two the binding was given.
	enum Kind : ubyte { register, spill }

	Kind kind = Kind.register; /// A register or a spill slot.
	uint value; /// The `PRegId`, or the spill slot's offset.
}

unittest { // libECRS silently skips a holder whose hook is not `@nogc nothrow`; every holder of an entity id must pass (E-Remap)
	static assert(ecrs.registry.hasRemapEntities!Parent && ecrs.registry.hasRemapEntities!Block && ecrs.registry.hasRemapEntities!TypeOf && ecrs.registry.hasRemapEntities!Alias && ecrs.registry.hasRemapEntities!FunctionInputs && ecrs.registry.hasRemapEntities!FunctionReturn && ecrs.registry.hasRemapEntities!Call && ecrs.registry.hasRemapEntities!Pointer && ecrs.registry.hasRemapEntities!On && ecrs.registry.hasRemapEntities!Overloads && ecrs.registry.hasRemapEntities!Lowered);
}

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


// --- per-target components ---------------------------------------------------

private enum isPerTarget(C) = is(C == VirtualReg) || is(C == PhysicalReg);

/// The libECRS component id of per-target component `C` (`VirtualReg_τ` or `PhysicalReg_τ`) for target index `target`, registered on first use. Returns `fp.pointer.notFound` if the registration was refused; no entity can then have the component.
///
/// Examples:
/// ---
/// assert(perTargetComponent!VirtualReg(0) == perTargetComponent!VirtualReg(0));
/// assert(perTargetComponent!VirtualReg(0) != perTargetComponent!VirtualReg(1));
/// assert(perTargetComponent!PhysicalReg(0) != perTargetComponent!VirtualReg(0));
/// ---
size_t perTargetComponent(C)(size_t target) @trusted if (isPerTarget!C) {
	// The name is built on the stack, so a lookup of a registered id never allocates and cannot fail.
	enum prefix = ecrs.registry.componentName!C ~ "@target";
	char[20] digits = void; // a 64-bit target has at most 20
	size_t first = digits.length;
	do digits[--first] = cast(char)('0' + target % 10);
	while ((target /= 10) != 0);
	char[prefix.length + digits.length + 1] name = void;
	immutable length = prefix.length + digits.length - first;
	foreach (i, c; prefix) name[i] = c; // slice copies need druntime under -betterC
	foreach (i, c; digits[first .. $]) name[prefix.length + i] = c;
	name[length] = '\0';
	immutable existing = ecrs.registry.lookupId(name.ptr);
	if (existing != fp.pointer.notFound) return existing;
	return ecrs.registry.registerType(name[0 .. length], ecrs.registry.nextId(), C.sizeof, ecrs.registry.hooksFor!C());
}

/// `e`'s per-target component `C` (a `VirtualReg` or `PhysicalReg`) for target index `target`, or null if it has none.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// assert(findPerTarget!VirtualReg(store, ecrs.context.addEntity(store), 0) is null);
/// ---
const(C)* findPerTarget(C)(ref const ecrs.context.Context store, EntityId e, size_t target) @trusted if (isPerTarget!C) {
	immutable id = perTargetComponent!C(target);
	return id == fp.pointer.notFound ? null : cast(const(C)*) ecrs.context.findComponent(store, e, id, C.sizeof);
}

/// Gives `e` per-target component `C` for target index `target` on behalf of the running query, the target's lowering, which owns it: a virtual register, or a physical register or spill slot. `e` must not already have one for that target. Returns null on a refused allocation, which fails the running queries (`doir.query.fail`).
///
/// Examples:
/// ---
/// static import ecrs.relation;
/// static import ecrs.context;
/// static import doir.query;
/// struct Assign {
/// 	alias Key = ecrs.relation.Relation!1;
/// 	alias Value = bool;
/// 	static bool compute(ref doir.query.QueryEngine engine, Key key) @nogc nothrow {
/// 		immutable e = key.related[0];
/// 		auto reg = producePerTarget!VirtualReg(engine, e, 1);
/// 		auto slot = producePerTarget!PhysicalReg(engine, e, 0);
/// 		if (reg is null || slot is null) return false;
/// 		reg.id = 9;
/// 		*slot = PhysicalReg(PhysicalReg.Kind.spill, 16);
/// 		return true;
/// 	}
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.query.create(store);
/// scope(exit) doir.query.free(engine);
/// immutable e = ecrs.context.addEntity(store);
/// assert(*doir.query.query!Assign(engine, Assign.Key([e])));
/// assert(findPerTarget!VirtualReg(store, e, 1).id == 9 && findPerTarget!VirtualReg(store, e, 0) is null);
/// assert(findPerTarget!PhysicalReg(store, e, 0).kind == PhysicalReg.Kind.spill);
/// ---
C* producePerTarget(C)(ref doir.engine.query.QueryEngine engine, EntityId e, size_t target) @trusted if (isPerTarget!C) {
	immutable id = perTargetComponent!C(target);
	if (id == fp.pointer.notFound) {
		doir.engine.query.fail(engine);
		return null;
	}
	if (!doir.engine.query.recordProduced(engine, doir.engine.query.Produced([e], id, &doir.engine.query.stripComponent, &doir.engine.query.hashComponent!C), true)) return null;
	auto c = cast(C*) ecrs.context.addComponent(*engine.store, e, id, C.sizeof);
	if (c is null) doir.engine.query.fail(engine);
	return c;
}

// --- retirement --------------------------------------------------------------

/// Records that the running query, `target`'s lowering, retired `e` for `target` (`L-Erase`). The entry is its own, removed when it runs again or is evicted, so the targets of a build retire entities independently. Returns false on a refused allocation, which fails the running queries (`doir.query.fail`).
///
/// Examples:
/// ---
/// static import ecrs.relation;
/// static import ecrs.context;
/// static import doir.query;
/// struct Lower {
/// 	alias Key = ecrs.relation.Relation!1;
/// 	alias Value = bool;
/// 	static bool compute(ref doir.query.QueryEngine engine, Key key) @nogc nothrow {
/// 		immutable e = key.related[0];
/// 		return retire(engine, e, e);
/// 	}
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.query.create(store);
/// scope(exit) doir.query.free(engine);
/// immutable e = ecrs.context.addEntity(store);
/// assert(*doir.query.query!Lower(engine, Lower.Key([e])));
/// assert(retiredFor(engine, e, e).get);
/// ---
bool retire(ref doir.engine.query.QueryEngine engine, EntityId e, EntityId target) {
	return doir.engine.logs.append!(Lowered, ecrs.relation.Relation!1)(engine, e, doir.engine.positions.none, ecrs.relation.Relation!1([target]));
}

/// Whether some lowering retired `e` for `target` (`L-Erase`). Inside a query, records the read of `e` and of the lowering that retired it. Returns null if the answer may be incomplete, where `doir.engine.logs.fold` returns false.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.query;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.query.create(store);
/// scope(exit) doir.query.free(engine);
/// immutable e = ecrs.context.addEntity(store);
/// assert(!retiredFor(engine, e, e).get);
/// ---
std.typecons.Nullable!bool retiredFor(ref doir.engine.query.QueryEngine engine, EntityId e, EntityId target) {
	bool retired = false;
	immutable folded = doir.engine.logs.fold!(Lowered, ecrs.relation.Relation!1)(engine, e, doir.engine.positions.none, (ref const ecrs.relation.Relation!1 t) {
		if (t.related[0] == target) retired = true;
	});
	if (!folded) return typeof(return).init;
	return typeof(return)(retired);
}


version(unittest) {
	static import doir.testing;
	static import doir.query;

	private __gshared uint registerBase;

	// Target `key.target`'s lowering of `key.entity`: its registers and its retirement entry.
	private struct LowerFor {
		struct Key {
			mixin ecrs.relation.Relates!"entity";
			size_t target;
		}
		alias Value = bool;
		static bool compute(ref doir.query.QueryEngine engine, Key key) @nogc nothrow {
			auto virtual = producePerTarget!VirtualReg(engine, key.entity, key.target);
			auto physical = producePerTarget!PhysicalReg(engine, key.entity, key.target);
			if (virtual is null || physical is null) return false;
			virtual.id = registerBase + cast(uint) key.target;
			*physical = PhysicalReg(PhysicalReg.Kind.register, cast(uint) key.target);
			return retire(engine, key.entity, cast(EntityId) (key.target + 100));
		}
	}
}

unittest { // targets own their registers and retirement independently
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	auto engine = doir.query.create(store);
	scope(exit) doir.query.free(engine);

	immutable e = doir.testing.addEntity(store);
	registerBase = 10;
	assert(*doir.query.query!LowerFor(engine, LowerFor.Key([e], 0)));
	assert(*doir.query.query!LowerFor(engine, LowerFor.Key([e], 1)));
	assert(findPerTarget!VirtualReg(store, e, 0).id == 10 && findPerTarget!VirtualReg(store, e, 1).id == 11);
	assert(findPerTarget!PhysicalReg(store, e, 1).value == 1);
	assert(retiredFor(engine, e, 100).get && retiredFor(engine, e, 101).get && !retiredFor(engine, e, 102).get);

	// Evicting one target's lowering removes only that target's parts.
	doir.query.evict!LowerFor(engine, LowerFor.Key([e], 0));
	assert(findPerTarget!VirtualReg(store, e, 0) is null && findPerTarget!PhysicalReg(store, e, 0) is null);
	assert(findPerTarget!VirtualReg(store, e, 1).id == 11);
	assert(!retiredFor(engine, e, 100).get && retiredFor(engine, e, 101).get);
	registerBase = 20;
	assert(*doir.query.query!LowerFor(engine, LowerFor.Key([e], 0)));
	assert(findPerTarget!VirtualReg(store, e, 0).id == 20 && retiredFor(engine, e, 100).get);

	// A target whose component ids cannot be registered fails its lowering; each attempt names a fresh target.
	bool refused = true;
	for (size_t n = 0; refused; ++n) {
		assert(n < 100);
		auto previous = doir.testing.beginRationedAllocator(n);
		auto lowered = doir.query.query!LowerFor(engine, LowerFor.Key([e], 1000 + n));
		fp.pointer.allocFunction = previous;
		assert(lowered is null ? engine.refused : *lowered);
		refused = engine.refused;
		engine.refused = false;
	}

	// Pointer holds an entity id, which a compaction rewrites (E-Remap).
	immutable spare = doir.testing.addEntity(store);
	immutable pointee = doir.testing.addEntity(store);
	immutable ptr = doir.testing.addEntity(store);
	doir.testing.addComponent!Pointer(store, ptr) = Pointer([pointee], 0);
	assert(ecrs.context.removeEntity(store, spare));
	assert(doir.query.compact(engine));
	immutable moved = cast(EntityId) (ptr - 1);
	assert(ecrs.context.getComponent!Pointer(store, moved).pointee == pointee - 1);
	assert(ecrs.context.getComponent!Pointer(store, moved).length == 0);
}
