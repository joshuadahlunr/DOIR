/// The components the parser writes (`doir.spec.md` Part II §1) and the builders that write them into the libECRS store, one call per declaration form of `doir.peg`. The parser resolves no names: a name it reads becomes a `Lookup*` component holding the interned path, which name resolution replaces with the entity-valued component it stands for.
///
/// Allocation failure is a fatal assert, as in `doir.query`: a parse that runs out of memory has no state worth keeping.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.strings;
/// doir.strings.Strings strings;
/// scope(exit) doir.strings.free(strings);
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// auto six = pushConstant(root, doir.strings.intern(strings, "six"), doir.strings.intern(strings, "std.u8"), ConstantVal.integer(6));
/// assert(ecrs.context.getComponent!ConstantVal(store, six).integerValue == 6);
/// assert(ecrs.context.getComponent!Parent(store, six).related == root.block);
/// ---
module doir.builders;

static import fp.dynarray;

static import ecrs.context;

public import ecrs.context : EntityId, invalidEntity;
public import doir.strings : StringId, noName;

@nogc nothrow:


// --- relations ---------------------------------------------------------------

private void remapId(ref EntityId e, const(EntityId)[] remap) {
	if (e < remap.length) e = remap[e];
}

private void append(T)(ref T* list, T value) {
	immutable pushed = fp.dynarray.pushBack(list, value);
	assert(pushed, "doir.builders: allocation refused");
}

// One related entity, with the E-Remap hook libECRS finds by name. A mixin does not inherit the module's attribute label, so it repeats it.
private mixin template OneEntity() {
	@nogc nothrow:
	EntityId related = invalidEntity;

	static void remapEntities(ref typeof(this) self, const(EntityId)[] remap) {
		remapId(self.related, remap);
	}
}

// An ordered list of related entities as an fp dynarray, with the E-Remap and lifetime hooks libECRS finds by name.
private mixin template EntityList() {
	@nogc nothrow:
	EntityId* related = null;

	static void remapEntities(ref typeof(this) self, const(EntityId)[] remap) {
		foreach (ref e; fp.dynarray.slice(self.related)) remapId(e, remap);
	}

	void finalize() {
		fp.dynarray.free(related);
		related = null;
	}
}


// --- components --------------------------------------------------------------

/// The interned declaration name; absent for `_` declarations.
struct Name {
	StringId value;
}

/// The enclosing entity: the block that lists this declaration, the function type that lists this parameter (`R-Param`), or the declaration whose type is this function type written in place (`WF-Par`).
struct Parent {
	mixin OneEntity;
}

/// The ordered child declarations of a block, function body, aggregate type or namespace.
struct Block {
	mixin EntityList;
}

/// The type binding of a value; `type` for a type entity.
struct TypeOf {
	mixin OneEntity;
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
	mixin OneEntity;
}

/// The parameter bindings of a function type (`R-Param`), or the argument bindings of a call (`WF-Arg`).
struct FunctionInputs {
	mixin EntityList;
}

/// The return type binding of a function type; absent means `void`. Copied onto the functions declared with it.
struct FunctionReturn {
	mixin OneEntity;
}

/// The callee binding of a call.
struct Call {
	mixin OneEntity;
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


// --- builders ----------------------------------------------------------------

private ref C attach(C)(ref ecrs.context.Context store, EntityId e) {
	auto component = ecrs.context.addComponent!C(store, e);
	assert(component !is null, "doir.builders: allocation refused");
	return *component;
}

/// A cursor over one block being filled: every `push` call appends a declaration to it.
struct BlockBuilder {
	ecrs.context.Context* store = null; /// The store the block lives in.
	EntityId block = invalidEntity; /// The block entity.
}

/// Adds `flags` to entity `e`'s flag set, adding the set if it has none. The parser uses it for `export` and the `inline`, `flatten` and `tail` call prefixes.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// addFlags(store, e, Flags.Export);
/// addFlags(store, e, Flags.Tail);
/// assert(ecrs.context.getComponent!Flags(store, e).flags == (Flags.Export | Flags.Tail));
/// ---
void addFlags(ref ecrs.context.Context store, EntityId e, uint flags) {
	auto set = ecrs.context.getOrAddComponent!Flags(store, e);
	assert(set !is null, "doir.builders: allocation refused");
	set.flags |= flags;
}

/// Starts a file's root block, a fresh entity with an empty `Block` and no `Parent`.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// assert(ecrs.context.hasComponent!Block(store, root.block));
/// ---
BlockBuilder createRoot(ref ecrs.context.Context store) {
	BlockBuilder b = BlockBuilder(&store, ecrs.context.addEntity(store));
	cast(void) attach!Block(store, b.block);
	return b;
}

/// Appends a fresh declaration to `b`'s block, with `Name` unless `name` is `noName` (a `_` declaration) and `Parent` set to the block (`WF-Par`).
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// auto e = pushDeclaration(root, noName);
/// assert(!ecrs.context.hasComponent!Name(store, e));
/// assert(ecrs.context.getComponent!Block(store, root.block).related[0] == e);
/// ---
EntityId pushDeclaration(ref BlockBuilder b, StringId name) {
	auto store = b.store;
	immutable e = ecrs.context.addEntity(*store);
	if (name != noName) attach!Name(*store, e).value = name;
	attach!Parent(*store, e).related = b.block;
	append(ecrs.context.getComponent!Block(*store, b.block).related, e);
	return e;
}

/// Gives `e` its declared type: a name to resolve, or an entity already known, such as a function type written in place.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// setType(store, e, StringId(0));
/// assert(ecrs.context.getComponent!LookupTypeOf(store, e).name == StringId(0));
/// ---
void setType(ref ecrs.context.Context store, EntityId e, StringId type) {
	attach!LookupTypeOf(store, e).name = type;
}

/// Ditto
void setType(ref ecrs.context.Context store, EntityId e, EntityId type) {
	attach!TypeOf(store, e).related = type;
}


// --- values ------------------------------------------------------------------

/// `six : std.u8 = 6`: a literal, `Comptime` from the start (`C-Constant`).
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// auto e = pushConstant(root, StringId(0), StringId(1), ConstantVal.integer(6));
/// assert(ecrs.context.getComponent!Flags(store, e).flags == Flags.Comptime);
/// ---
EntityId pushConstant(T)(ref BlockBuilder b, StringId name, T type, ConstantVal value) {
	immutable e = pushDeclaration(b, name);
	setType(*b.store, e, type);
	attach!ConstantVal(*b.store, e) = value;
	addFlags(*b.store, e, Flags.Comptime);
	return e;
}

/// `x : std.u8`: a declaration with no value, such as a field or a prototype.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// auto e = pushValueless(root, StringId(0), StringId(1));
/// assert(ecrs.context.getComponent!Flags(store, e).flags == Flags.Valueless);
/// ---
EntityId pushValueless(T)(ref BlockBuilder b, StringId name, T type) {
	immutable e = pushDeclaration(b, name);
	setType(*b.store, e, type);
	addFlags(*b.store, e, Flags.Valueless);
	return e;
}

/// `x : T = y`: a value written as a bare name (`A-Bind`).
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// auto e = pushReference(root, StringId(0), StringId(1), StringId(2));
/// assert(ecrs.context.getComponent!LookupValue(store, e).name == StringId(2));
/// ---
EntityId pushReference(T)(ref BlockBuilder b, StringId name, T type, StringId target) {
	immutable e = pushDeclaration(b, name);
	setType(*b.store, e, type);
	attach!LookupValue(*b.store, e).name = target;
	return e;
}

/// `sum : std.u8 = std.add(a, b)`: a call, its callee and arguments all names (`WF-Arg`). A prefix (`inline`, `flatten`, `tail`) is added with `addFlags`.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// immutable StringId[2] arguments = [StringId(3), StringId(4)];
/// auto e = pushCall(root, StringId(0), StringId(1), StringId(2), arguments[]);
/// assert(ecrs.context.getComponent!LookupFunctionInputs(store, e).names[1] == StringId(4));
/// ---
EntityId pushCall(T)(ref BlockBuilder b, StringId name, T type, StringId callee, const(StringId)[] arguments) {
	immutable e = pushDeclaration(b, name);
	setType(*b.store, e, type);
	attach!LookupCall(*b.store, e).name = callee;
	auto inputs = &attach!LookupFunctionInputs(*b.store, e);
	foreach (a; arguments) append(inputs.names, a);
	return e;
}

/// `then : block = { ... }` or `add : add_t = { ... }`: a block-valued declaration, a block binding or a function body by its resolved type. Returns a builder for its contents.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// auto body_ = pushBlock(root, StringId(0), StringId(1));
/// auto inner = pushValueless(body_, StringId(2), StringId(3));
/// assert(ecrs.context.getComponent!Parent(store, inner).related == body_.block);
/// ---
BlockBuilder pushBlock(T)(ref BlockBuilder b, StringId name, T type) {
	immutable e = pushDeclaration(b, name);
	setType(*b.store, e, type);
	cast(void) attach!Block(*b.store, e);
	return BlockBuilder(b.store, e);
}


// --- types -------------------------------------------------------------------

/// `vec3 : type = { x : f32 ; ... }`: an aggregate type, its layout left for the layout queries. Returns a builder for its fields.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// auto vec = pushAggregate(root, StringId(0), StringId(1));
/// assert(ecrs.context.getComponent!TypeDefinition(store, vec.block).unique == ReservedUnique.structural);
/// ---
BlockBuilder pushAggregate(T)(ref BlockBuilder b, StringId name, T type) {
	auto out_ = pushBlock(b, name, type);
	cast(void) attach!TypeDefinition(*b.store, out_.block);
	return out_;
}

/// `type : type = {}` in the builtin block: an empty aggregate carrying its reserved discriminator and `Comptime | AlwaysComptime` (Part I §7, `M-Unique`).
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// auto t = pushBuiltinType(root, StringId(0), StringId(0), ReservedUnique.deducedType);
/// assert(ecrs.context.getComponent!TypeDefinition(store, t).unique == ReservedUnique.deducedType);
/// ---
EntityId pushBuiltinType(T)(ref BlockBuilder b, StringId name, T type, ReservedUnique unique) {
	assert(unique != ReservedUnique.structural && unique < ReservedUnique.firstFresh);
	auto out_ = pushAggregate(b, name, type);
	ecrs.context.getComponent!TypeDefinition(*b.store, out_.block).unique = unique;
	addFlags(*b.store, out_.block, Flags.Comptime | Flags.AlwaysComptime);
	return out_.block;
}

/// Makes `e` a function type with no parameters and no return type yet, for `pushParameter` and `setReturnType` to fill in.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// defineFunctionType(store, e);
/// assert(ecrs.context.hasComponent!FunctionInputs(store, e));
/// ---
void defineFunctionType(ref ecrs.context.Context store, EntityId e) {
	cast(void) attach!TypeDefinition(store, e);
	cast(void) attach!FunctionInputs(store, e);
}

/// `add_t : type = (a: std.u8, b: std.u8) -> std.u8`: a named function type.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// auto ft = pushFunctionType(root, StringId(0), StringId(1));
/// assert(ecrs.context.hasComponent!TypeDefinition(store, ft));
/// ---
EntityId pushFunctionType(T)(ref BlockBuilder b, StringId name, T type) {
	immutable e = pushDeclaration(b, name);
	setType(*b.store, e, type);
	defineFunctionType(*b.store, e);
	return e;
}

/// `x : (a: T) -> U = ...`: a function type written in place, the declared type of `owner`, which it takes as its `Parent` (`WF-Par`). Set it as `owner`'s type with `setType`.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// auto x = pushDeclaration(root, StringId(0));
/// auto ft = createFunctionType(store, x, StringId(1));
/// setType(store, x, ft);
/// assert(ecrs.context.getComponent!Parent(store, ft).related == x);
/// ---
EntityId createFunctionType(T)(ref ecrs.context.Context store, EntityId owner, T type) {
	immutable e = ecrs.context.addEntity(store);
	attach!Parent(store, e).related = owner;
	setType(store, e, type);
	defineFunctionType(store, e);
	return e;
}

/// Appends parameter `name : type` to function type `functionType` (`R-Param`) and returns it, valueless; give it a default with `setDefault`. A deduced parameter passes `deducedTypeName`, interned, as its type.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// defineFunctionType(store, e);
/// auto a = pushParameter(store, e, StringId(0), StringId(1));
/// assert(ecrs.context.getComponent!FunctionInputs(store, e).related[0] == a);
/// assert(ecrs.context.getComponent!Parent(store, a).related == e);
/// ---
EntityId pushParameter(T)(ref ecrs.context.Context store, EntityId functionType, StringId name, T type) {
	immutable e = ecrs.context.addEntity(store);
	if (name != noName) attach!Name(store, e).value = name;
	attach!Parent(store, e).related = functionType;
	setType(store, e, type);
	addFlags(store, e, Flags.Valueless);
	append(ecrs.context.getComponent!FunctionInputs(store, functionType).related, e);
	return e;
}

/// Gives parameter `p` the default `= 5` or `= y` (`F-Default`), replacing its `Valueless`.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto ft = ecrs.context.addEntity(store);
/// defineFunctionType(store, ft);
/// auto p = pushParameter(store, ft, StringId(0), StringId(1));
/// setDefault(store, p, ConstantVal.integer(5));
/// assert(ecrs.context.getComponent!Flags(store, p).flags == Flags.Comptime);
/// ---
void setDefault(ref ecrs.context.Context store, EntityId p, ConstantVal value) {
	ecrs.context.getComponent!Flags(store, p).flags &= ~Flags.Valueless;
	attach!ConstantVal(store, p) = value;
	addFlags(store, p, Flags.Comptime);
}

/// Ditto
void setDefault(ref ecrs.context.Context store, EntityId p, StringId value) {
	ecrs.context.getComponent!Flags(store, p).flags &= ~Flags.Valueless;
	attach!LookupValue(store, p).name = value;
}

/// Gives function type `functionType` the return type written after `->`; without one it returns `void`.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto ft = ecrs.context.addEntity(store);
/// defineFunctionType(store, ft);
/// setReturnType(store, ft, StringId(2));
/// assert(ecrs.context.getComponent!LookupFunctionReturn(store, ft).name == StringId(2));
/// ---
void setReturnType(ref ecrs.context.Context store, EntityId functionType, StringId type) {
	attach!LookupFunctionReturn(store, functionType).name = type;
}

/// Ditto
void setReturnType(ref ecrs.context.Context store, EntityId functionType, EntityId type) {
	attach!FunctionReturn(store, functionType).related = type;
}


// --- aliases and namespaces --------------------------------------------------

/// `color : alias = vec3`: an alias, which carries no type (`WF-Kind`).
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// auto e = pushAlias(root, StringId(0), StringId(1));
/// assert(!ecrs.context.hasComponent!LookupTypeOf(store, e));
/// ---
EntityId pushAlias(ref BlockBuilder b, StringId name, StringId target) {
	immutable e = pushDeclaration(b, name);
	attach!LookupAlias(*b.store, e).name = target;
	return e;
}

/// `math : namespace = { ... }`: a namespace, which carries no type (`WF-Kind`). Reopening one is another call with the same name (`R-Merge`). Returns a builder for its contents.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// auto math = pushNamespace(root, StringId(0));
/// assert(ecrs.context.getComponent!Flags(store, math.block).flags == Flags.Namespace);
/// ---
BlockBuilder pushNamespace(ref BlockBuilder b, StringId name) {
	immutable e = pushDeclaration(b, name);
	addFlags(*b.store, e, Flags.Namespace);
	cast(void) attach!Block(*b.store, e);
	return BlockBuilder(b.store, e);
}


unittest {
	static import doir.strings;
	doir.strings.Strings strings;
	scope(exit) doir.strings.free(strings);
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	StringId s(const(char)[] text) { return doir.strings.intern(strings, text); }

	// identity : type = (T: deduced type, value: T) -> T ; id : identity
	auto root = createRoot(store);
	auto ft = pushFunctionType(root, s("identity"), s("type"));
	auto t = pushParameter(store, ft, s("T"), s(deducedTypeName));
	auto value = pushParameter(store, ft, s("value"), s("T"));
	setReturnType(store, ft, s("T"));
	auto id = pushValueless(root, s("id"), s("identity"));
	assert(ecrs.context.getComponent!FunctionInputs(store, ft).related[0 .. 2] == [t, value]);
	assert(doir.strings.text(strings, ecrs.context.getComponent!LookupTypeOf(store, t).name) == "deduced type");
	assert(ecrs.context.getComponent!Block(store, root.block).related[0 .. 2] == [ft, id]);

	// Renumbering rewrites every entity-valued component (E-Remap).
	assert(ecrs.context.swapEntities(store, ft, value));
	assert(ecrs.context.getComponent!Parent(store, ft).related == value);
	assert(ecrs.context.getComponent!FunctionInputs(store, value).related[0 .. 2] == [t, ft]);
	assert(ecrs.context.getComponent!Block(store, root.block).related[0] == value);
	assert(ecrs.context.swapEntities(store, ft, value));

	// Builtin types are distinct by discriminator, deduced type included.
	auto builtin = createRoot(store);
	auto type = pushBuiltinType(builtin, s("type"), s("type"), ReservedUnique.type);
	auto deduced = pushBuiltinType(builtin, s("deduced_type"), s("type"), ReservedUnique.deducedType);
	assert(ecrs.context.getComponent!TypeDefinition(store, type).unique != ecrs.context.getComponent!TypeDefinition(store, deduced).unique);

	// A `_` parameter has no name; a default replaces Valueless.
	auto unnamed = pushParameter(store, ft, noName, s("std.u8"));
	assert(!ecrs.context.hasComponent!Name(store, unnamed));
	setDefault(store, unnamed, s("zero"));
	assert(ecrs.context.getComponent!Flags(store, unnamed).flags == Flags.None);
}
