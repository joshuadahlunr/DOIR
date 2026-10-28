/// The binding components of `doir.spec.md` Part II §1, and the `Lookup*` components the parser writes in place of the names it does not resolve (`doir.api.builders` writes them). Every one holding an entity id mixes in `ecrs.relation.Relates` (`E-Remap`).
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
module doir.api.components;

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

/// The discriminators the builtin types reserve, so `S-Struct` keeps them apart from every structural type of the same layout (`M-Unique`, `S-Numeric`, `FP-Type`). `std.types.unique` and `compiler.comptime_base_type` hand out fresh ones from `firstFresh` up.
enum ReservedUnique : size_t {
	structural = 0, /// Every type the program defines without `std.types.unique`.
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
		Immutable = 1 << 6,
		Union = 1 << 7,
		Pure = 1 << 8,
		Inline = 1 << 9,
		Flatten = 1 << 10,
		Tail = 1 << 11,
		NeverSpecialize = 1 << 12,
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

/// The ABI symbol of a function or static: the `R-Mangle` name unless `M-Rename` set one.
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

/// The targets `std.targets.live_on` gave a declaration, folded from its positioned log at freeze (`T-Live`); absent means live wherever its parent is.
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
	immutable a = ecrs.context.addEntity(store), b = ecrs.context.addEntity(store);
	assert(ecrs.context.addComponent!LookupFunctionInputs(store, a) !is null && ecrs.context.addComponent!LookupFunctionInputs(store, b) !is null);
	auto x = &ecrs.context.getComponent!LookupFunctionInputs(store, a), y = &ecrs.context.getComponent!LookupFunctionInputs(store, b);
	assert(fp.dynarray.pushBack(x.names, StringId(1)) && fp.dynarray.pushBack(y.names, StringId(1)));
	assert(x.names !is y.names && LookupFunctionInputs.contentHash(*x) == LookupFunctionInputs.contentHash(*y));
	assert(fp.dynarray.pushBack(y.names, StringId(2)));
	assert(LookupFunctionInputs.contentHash(*x) != LookupFunctionInputs.contentHash(*y));
	ecrs.context.removeComponent!LookupFunctionInputs(store, a);
	assert(!ecrs.context.hasComponent!LookupFunctionInputs(store, a));
}


// --- per-target components ---------------------------------------------------

private size_t perTarget(C)(size_t target) @trusted {
	auto name = fp.string.format("%s@target%llu", ecrs.registry.componentName!C.ptr, cast(ulong) target);
	assert(name !is null, "doir.api.components: allocation refused");
	scope(exit) fp.string.free(name);
	immutable existing = ecrs.registry.lookupId(name);
	if (existing != fp.pointer.notFound) return existing;
	immutable id = ecrs.registry.registerType(fp.string.slice(name), ecrs.registry.nextId(), C.sizeof, ecrs.registry.hooksFor!C());
	assert(id != fp.pointer.notFound, "doir.api.components: allocation refused");
	return id;
}

/// The libECRS component id of `VirtualReg_τ` for target index `target`, registered on first use.
///
/// Examples:
/// ---
/// assert(virtualRegComponent(0) == virtualRegComponent(0));
/// assert(virtualRegComponent(0) != virtualRegComponent(1));
/// ---
size_t virtualRegComponent(size_t target) { return perTarget!VirtualReg(target); }

/// The libECRS component id of `PhysicalReg_τ` for target index `target`, registered on first use.
///
/// Examples:
/// ---
/// assert(physicalRegComponent(0) != virtualRegComponent(0));
/// ---
size_t physicalRegComponent(size_t target) { return perTarget!PhysicalReg(target); }

/// `e`'s virtual register for target index `target`, or null if it has none.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// assert(virtualReg(store, ecrs.context.addEntity(store), 0) is null);
/// ---
const(VirtualReg)* virtualReg(ref const ecrs.context.Context store, EntityId e, size_t target) @trusted {
	immutable id = virtualRegComponent(target);
	return cast(const(VirtualReg)*) ecrs.context.findComponent(store, e, id, VirtualReg.sizeof);
}

/// `e`'s physical register for target index `target`, or null if it has none.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// assert(physicalReg(store, ecrs.context.addEntity(store), 0) is null);
/// ---
const(PhysicalReg)* physicalReg(ref const ecrs.context.Context store, EntityId e, size_t target) @trusted {
	immutable id = physicalRegComponent(target);
	return cast(const(PhysicalReg)*) ecrs.context.findComponent(store, e, id, PhysicalReg.sizeof);
}

private ref C producePerTarget(C)(ref doir.engine.query.QueryEngine engine, EntityId e, size_t id) @trusted {
	doir.engine.query.recordProduced(engine, doir.engine.query.Produced([e], id, &doir.engine.query.stripComponent, &doir.engine.query.hashComponent!C), true);
	auto c = cast(C*) ecrs.context.addComponent(*engine.store, e, id, C.sizeof);
	assert(c !is null, "doir.api.components: allocation refused");
	return *c;
}

/// Gives `e` a virtual register for target index `target` on behalf of the running query, the target's lowering, which owns it. `e` must not already have one for that target.
///
/// Examples:
/// ---
/// static import ecrs.relation;
/// static import ecrs.context;
/// static import doir.api.query;
/// struct Assign {
/// 	alias Key = ecrs.relation.Relation!1;
/// 	alias Value = bool;
/// 	static bool compute(ref doir.api.query.QueryEngine engine, Key key) @nogc nothrow {
/// 		immutable e = key.related[0];
/// 		produceVirtualReg(engine, e, 1).id = 9;
/// 		return true;
/// 	}
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.api.query.create(store);
/// scope(exit) doir.api.query.free(engine);
/// immutable e = ecrs.context.addEntity(store);
/// assert(*doir.api.query.query!Assign(engine, Assign.Key([e])));
/// assert(virtualReg(store, e, 1).id == 9 && virtualReg(store, e, 0) is null);
/// ---
ref VirtualReg produceVirtualReg(ref doir.engine.query.QueryEngine engine, EntityId e, size_t target) {
	return producePerTarget!VirtualReg(engine, e, virtualRegComponent(target));
}

/// Gives `e` a physical register or spill slot for target index `target` on behalf of the running query, which owns it. `e` must not already have one for that target.
///
/// Examples:
/// ---
/// static import ecrs.relation;
/// static import ecrs.context;
/// static import doir.api.query;
/// struct Allocate {
/// 	alias Key = ecrs.relation.Relation!1;
/// 	alias Value = bool;
/// 	static bool compute(ref doir.api.query.QueryEngine engine, Key key) @nogc nothrow {
/// 		immutable e = key.related[0];
/// 		producePhysicalReg(engine, e, 0) = PhysicalReg(PhysicalReg.Kind.spill, 16);
/// 		return true;
/// 	}
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.api.query.create(store);
/// scope(exit) doir.api.query.free(engine);
/// immutable e = ecrs.context.addEntity(store);
/// assert(*doir.api.query.query!Allocate(engine, Allocate.Key([e])));
/// assert(physicalReg(store, e, 0).kind == PhysicalReg.Kind.spill);
/// ---
ref PhysicalReg producePhysicalReg(ref doir.engine.query.QueryEngine engine, EntityId e, size_t target) {
	return producePerTarget!PhysicalReg(engine, e, physicalRegComponent(target));
}


// --- retirement --------------------------------------------------------------

/// Records that the running query, `target`'s lowering, retired `e` for `target` (`L-Erase`). The entry is its own, removed when it runs again or is evicted, so the targets of a build retire entities independently.
///
/// Examples:
/// ---
/// static import ecrs.relation;
/// static import ecrs.context;
/// static import doir.api.query;
/// struct Lower {
/// 	alias Key = ecrs.relation.Relation!1;
/// 	alias Value = bool;
/// 	static bool compute(ref doir.api.query.QueryEngine engine, Key key) @nogc nothrow {
/// 		immutable e = key.related[0];
/// 		retire(engine, e, e);
/// 		return true;
/// 	}
/// }
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.api.query.create(store);
/// scope(exit) doir.api.query.free(engine);
/// immutable e = ecrs.context.addEntity(store);
/// assert(*doir.api.query.query!Lower(engine, Lower.Key([e])));
/// assert(retiredFor(engine, e, e));
/// ---
void retire(ref doir.engine.query.QueryEngine engine, EntityId e, EntityId target) {
	doir.engine.logs.append!(Lowered, ecrs.relation.Relation!1)(engine, e, doir.engine.positions.none, ecrs.relation.Relation!1([target]));
}

/// Whether some lowering retired `e` for `target` (`L-Erase`). Inside a query, records the read of `e` and of the lowering that retired it.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.query;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto engine = doir.api.query.create(store);
/// scope(exit) doir.api.query.free(engine);
/// immutable e = ecrs.context.addEntity(store);
/// assert(!retiredFor(engine, e, e));
/// ---
bool retiredFor(ref doir.engine.query.QueryEngine engine, EntityId e, EntityId target) {
	bool found = false;
	doir.engine.logs.fold!(Lowered, ecrs.relation.Relation!1)(engine, e, doir.engine.positions.none, (ref const ecrs.relation.Relation!1 t) {
		if (t.related[0] == target) found = true;
	});
	return found;
}


version(unittest) {
	static import doir.api.query;

	private __gshared uint registerBase;

	// Target `key.target`'s lowering of `key.entity`: its registers and its retirement entry.
	private struct LowerFor {
		struct Key {
			mixin ecrs.relation.Relates!"entity";
			size_t target;
		}
		alias Value = bool;
		static bool compute(ref doir.api.query.QueryEngine engine, Key key) @nogc nothrow {
			produceVirtualReg(engine, key.entity, key.target).id = registerBase + cast(uint) key.target;
			producePhysicalReg(engine, key.entity, key.target) = PhysicalReg(PhysicalReg.Kind.register, cast(uint) key.target);
			retire(engine, key.entity, cast(EntityId) (key.target + 100));
			return true;
		}
	}
}

unittest { // targets own their registers and retirement independently
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	auto engine = doir.api.query.create(store);
	scope(exit) doir.api.query.free(engine);

	immutable e = ecrs.context.addEntity(store);
	registerBase = 10;
	assert(*doir.api.query.query!LowerFor(engine, LowerFor.Key([e], 0)));
	assert(*doir.api.query.query!LowerFor(engine, LowerFor.Key([e], 1)));
	assert(virtualReg(store, e, 0).id == 10 && virtualReg(store, e, 1).id == 11);
	assert(physicalReg(store, e, 1).value == 1);
	assert(retiredFor(engine, e, 100) && retiredFor(engine, e, 101) && !retiredFor(engine, e, 102));

	// Evicting one target's lowering removes only that target's parts.
	doir.api.query.evict!LowerFor(engine, LowerFor.Key([e], 0));
	assert(virtualReg(store, e, 0) is null && physicalReg(store, e, 0) is null);
	assert(virtualReg(store, e, 1).id == 11);
	assert(!retiredFor(engine, e, 100) && retiredFor(engine, e, 101));
	registerBase = 20;
	assert(*doir.api.query.query!LowerFor(engine, LowerFor.Key([e], 0)));
	assert(virtualReg(store, e, 0).id == 20 && retiredFor(engine, e, 100));

	// Pointer holds an entity id, which a compaction rewrites (E-Remap).
	immutable spare = ecrs.context.addEntity(store);
	immutable pointee = ecrs.context.addEntity(store);
	immutable ptr = ecrs.context.addEntity(store);
	*ecrs.context.addComponent!Pointer(store, ptr) = Pointer([pointee], 0);
	assert(ecrs.context.removeEntity(store, spare));
	assert(doir.api.query.compact(engine));
	immutable moved = cast(EntityId) (ptr - 1);
	assert(ecrs.context.getComponent!Pointer(store, moved).pointee == pointee - 1);
	assert(ecrs.context.getComponent!Pointer(store, moved).length == 0);
}
