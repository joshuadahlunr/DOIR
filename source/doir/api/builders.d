/// The builders that write the parser's components (`doir.api.components`) into the libECRS store, one call per declaration form of `doir.peg`. The parser resolves no names: a name it reads becomes a `Lookup*` component holding the interned path, which name resolution replaces with the entity-valued component it stands for.
///
/// Allocation failure is a fatal assert, as in `doir.api.query`: a parse that runs out of memory has no state worth keeping.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.strings;
/// static import doir.api.components;
/// doir.strings.Strings strings;
/// scope(exit) doir.strings.free(strings);
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// auto six = pushConstant(root, doir.strings.intern(strings, "six"), doir.strings.intern(strings, "std.u8"), doir.api.components.ConstantVal.integer(6));
/// assert(ecrs.context.getComponent!(doir.api.components.ConstantVal)(store, six).integerValue == 6);
/// assert(ecrs.context.getComponent!(doir.api.components.Parent)(store, six).parent == root.block);
/// ---
module doir.api.builders;

static import fp.dynarray;

static import ecrs.context;

static import doir.api.components;

public import ecrs.context : EntityId, invalidEntity;
public import doir.strings : StringId, noName;

@nogc nothrow:


// --- helpers -----------------------------------------------------------------

private void append(T)(ref T* list, T value) {
	immutable pushed = fp.dynarray.pushBack(list, value);
	assert(pushed, "doir.api.builders: allocation refused");
}


// --- builders ----------------------------------------------------------------

private ref C addComponent(C)(ref ecrs.context.Context store, EntityId e) {
	auto component = ecrs.context.addComponent!C(store, e);
	assert(component !is null, "doir.api.builders: allocation refused");
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
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// addFlags(store, e, doir.api.components.Flags.Export);
/// addFlags(store, e, doir.api.components.Flags.Tail);
/// assert(ecrs.context.getComponent!(doir.api.components.Flags)(store, e).flags == (doir.api.components.Flags.Export | doir.api.components.Flags.Tail));
/// ---
void addFlags(ref ecrs.context.Context store, EntityId e, uint flags) {
	auto set = ecrs.context.getOrAddComponent!(doir.api.components.Flags)(store, e);
	assert(set !is null, "doir.api.builders: allocation refused");
	set.flags |= flags;
}

/// Starts a file's root block, a fresh entity with an empty `Block` and no `Parent`.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// assert(ecrs.context.hasComponent!(doir.api.components.Block)(store, root.block));
/// ---
BlockBuilder createRoot(ref ecrs.context.Context store) {
	BlockBuilder b = BlockBuilder(&store, ecrs.context.addEntity(store));
	cast(void) addComponent!(doir.api.components.Block)(store, b.block);
	return b;
}

/// Appends a fresh declaration to `b`'s block, with `Name` unless `name` is `noName` (a `_` declaration) and `Parent` set to the block (`WF-Par`). Every `pushX` is this followed by `attachX`.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// auto e = pushDeclaration(root, noName);
/// assert(!ecrs.context.hasComponent!(doir.api.components.Name)(store, e));
/// assert(ecrs.context.getComponent!(doir.api.components.Block)(store, root.block).related[0] == e);
/// ---
EntityId pushDeclaration(ref BlockBuilder b, StringId name) {
	auto store = b.store;
	immutable e = ecrs.context.addEntity(*store);
	if (name != noName) addComponent!(doir.api.components.Name)(*store, e).value = name;
	addComponent!(doir.api.components.Parent)(*store, e).parent = b.block;
	append(ecrs.context.getComponent!(doir.api.components.Block)(*store, b.block).related, e);
	return e;
}

/// Gives `e` its declared type: a name to resolve, or an entity already known, such as a function type written in place.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// setType(store, e, StringId(0));
/// assert(ecrs.context.getComponent!(doir.api.components.LookupTypeOf)(store, e).name == StringId(0));
/// ---
void setType(ref ecrs.context.Context store, EntityId e, StringId type) {
	addComponent!(doir.api.components.LookupTypeOf)(store, e).name = type;
}

/// Ditto
void setType(ref ecrs.context.Context store, EntityId e, EntityId type) {
	addComponent!(doir.api.components.TypeOf)(store, e).type = type;
}


// --- values ------------------------------------------------------------------

/// Makes `e` the literal `six : std.u8 = 6`, `Comptime` from the start (`C-Constant`).
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// attachConstant(store, e, StringId(0), doir.api.components.ConstantVal.integer(6));
/// assert(ecrs.context.getComponent!(doir.api.components.ConstantVal)(store, e).integerValue == 6);
/// ---
void attachConstant(T)(ref ecrs.context.Context store, EntityId e, T type, doir.api.components.ConstantVal value) {
	setType(store, e, type);
	addComponent!(doir.api.components.ConstantVal)(store, e) = value;
	addFlags(store, e, doir.api.components.Flags.Comptime);
}

/// Appends the literal `six : std.u8 = 6` to `b`'s block; see `attachConstant`.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// auto e = pushConstant(root, StringId(0), StringId(1), doir.api.components.ConstantVal.integer(6));
/// assert(ecrs.context.getComponent!(doir.api.components.Flags)(store, e).flags == doir.api.components.Flags.Comptime);
/// ---
EntityId pushConstant(T)(ref BlockBuilder b, StringId name, T type, doir.api.components.ConstantVal value) {
	immutable e = pushDeclaration(b, name);
	attachConstant(*b.store, e, type, value);
	return e;
}

/// Makes `e` the declaration `x : std.u8` with no value, such as a field, a prototype or a parameter.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// attachValueless(store, e, StringId(0));
/// assert(ecrs.context.getComponent!(doir.api.components.Flags)(store, e).flags == doir.api.components.Flags.Valueless);
/// ---
void attachValueless(T)(ref ecrs.context.Context store, EntityId e, T type) {
	setType(store, e, type);
	addFlags(store, e, doir.api.components.Flags.Valueless);
}

/// Appends `x : std.u8`, a declaration with no value, to `b`'s block; see `attachValueless`.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// auto e = pushValueless(root, StringId(0), StringId(1));
/// assert(ecrs.context.getComponent!(doir.api.components.Flags)(store, e).flags == doir.api.components.Flags.Valueless);
/// ---
EntityId pushValueless(T)(ref BlockBuilder b, StringId name, T type) {
	immutable e = pushDeclaration(b, name);
	attachValueless(*b.store, e, type);
	return e;
}

/// Makes `e` the declaration `x : T = y`, a value written as a bare name (`A-Bind`).
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// attachReference(store, e, StringId(0), StringId(1));
/// assert(ecrs.context.getComponent!(doir.api.components.LookupValue)(store, e).name == StringId(1));
/// ---
void attachReference(T)(ref ecrs.context.Context store, EntityId e, T type, StringId target) {
	setType(store, e, type);
	addComponent!(doir.api.components.LookupValue)(store, e).name = target;
}

/// Appends `x : T = y` to `b`'s block; see `attachReference`.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// auto e = pushReference(root, StringId(0), StringId(1), StringId(2));
/// assert(ecrs.context.getComponent!(doir.api.components.LookupValue)(store, e).name == StringId(2));
/// ---
EntityId pushReference(T)(ref BlockBuilder b, StringId name, T type, StringId target) {
	immutable e = pushDeclaration(b, name);
	attachReference(*b.store, e, type, target);
	return e;
}

/// Makes `e` the call `sum : std.u8 = std.add(a, b)`, its callee and arguments all names (`WF-Arg`). A prefix (`inline`, `flatten`, `tail`) is added with `addFlags`.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// immutable StringId[2] arguments = [StringId(2), StringId(3)];
/// attachCall(store, e, StringId(0), StringId(1), arguments[]);
/// assert(ecrs.context.getComponent!(doir.api.components.LookupCall)(store, e).name == StringId(1));
/// ---
void attachCall(T)(ref ecrs.context.Context store, EntityId e, T type, StringId callee, const(StringId)[] arguments) {
	setType(store, e, type);
	addComponent!(doir.api.components.LookupCall)(store, e).name = callee;
	auto inputs = &addComponent!(doir.api.components.LookupFunctionInputs)(store, e);
	foreach (a; arguments) append(inputs.names, a);
}

/// Appends the call `sum : std.u8 = std.add(a, b)` to `b`'s block; see `attachCall`.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// immutable StringId[2] arguments = [StringId(3), StringId(4)];
/// auto e = pushCall(root, StringId(0), StringId(1), StringId(2), arguments[]);
/// assert(ecrs.context.getComponent!(doir.api.components.LookupFunctionInputs)(store, e).names[1] == StringId(4));
/// ---
EntityId pushCall(T)(ref BlockBuilder b, StringId name, T type, StringId callee, const(StringId)[] arguments) {
	immutable e = pushDeclaration(b, name);
	attachCall(*b.store, e, type, callee, arguments);
	return e;
}

/// Makes `e` the block-valued declaration `then : block = { ... }` or `add : add_t = { ... }`, a block binding or a function body by its resolved type. Returns a builder for its contents.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// auto body_ = attachBlock(store, e, StringId(0));
/// assert(body_.block == e && ecrs.context.hasComponent!(doir.api.components.Block)(store, e));
/// ---
BlockBuilder attachBlock(T)(ref ecrs.context.Context store, EntityId e, T type) {
	setType(store, e, type);
	cast(void) addComponent!(doir.api.components.Block)(store, e);
	return BlockBuilder(&store, e);
}

/// Appends a block-valued declaration to `b`'s block and returns a builder for its contents; see `attachBlock`.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// auto body_ = pushBlock(root, StringId(0), StringId(1));
/// auto inner = pushValueless(body_, StringId(2), StringId(3));
/// assert(ecrs.context.getComponent!(doir.api.components.Parent)(store, inner).parent == body_.block);
/// ---
BlockBuilder pushBlock(T)(ref BlockBuilder b, StringId name, T type) {
	return attachBlock(*b.store, pushDeclaration(b, name), type);
}


// --- types -------------------------------------------------------------------

/// Makes `e` the aggregate type `vec3 : type = { x : f32 ; ... }`, its layout left for the layout queries. Returns a builder for its fields.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// cast(void) attachAggregate(store, e, StringId(0));
/// assert(ecrs.context.getComponent!(doir.api.components.TypeDefinition)(store, e).unique == doir.api.components.ReservedUnique.structural);
/// ---
BlockBuilder attachAggregate(T)(ref ecrs.context.Context store, EntityId e, T type) {
	auto out_ = attachBlock(store, e, type);
	cast(void) addComponent!(doir.api.components.TypeDefinition)(store, e);
	return out_;
}

/// Appends an aggregate type to `b`'s block and returns a builder for its fields; see `attachAggregate`.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// auto vec = pushAggregate(root, StringId(0), StringId(1));
/// assert(ecrs.context.getComponent!(doir.api.components.TypeDefinition)(store, vec.block).unique == doir.api.components.ReservedUnique.structural);
/// ---
BlockBuilder pushAggregate(T)(ref BlockBuilder b, StringId name, T type) {
	return attachAggregate(*b.store, pushDeclaration(b, name), type);
}

/// Makes `e` a builtin type, `type : type = {}` in the builtin block: an empty aggregate carrying its reserved discriminator and `Comptime | AlwaysComptime` (Part I §7, `M-Unique`).
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// attachBuiltinType(store, e, e, doir.api.components.ReservedUnique.type);
/// assert(ecrs.context.getComponent!(doir.api.components.TypeOf)(store, e).type == e);
/// ---
void attachBuiltinType(T)(ref ecrs.context.Context store, EntityId e, T type, doir.api.components.ReservedUnique unique) {
	assert(unique != doir.api.components.ReservedUnique.structural && unique < doir.api.components.ReservedUnique.firstFresh);
	cast(void) attachAggregate(store, e, type);
	ecrs.context.getComponent!(doir.api.components.TypeDefinition)(store, e).unique = unique;
	addFlags(store, e, doir.api.components.Flags.Comptime | doir.api.components.Flags.AlwaysComptime);
}

/// Appends a builtin type to `b`'s block; see `attachBuiltinType`.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// auto t = pushBuiltinType(root, StringId(0), StringId(0), doir.api.components.ReservedUnique.deducedType);
/// assert(ecrs.context.getComponent!(doir.api.components.TypeDefinition)(store, t).unique == doir.api.components.ReservedUnique.deducedType);
/// ---
EntityId pushBuiltinType(T)(ref BlockBuilder b, StringId name, T type, doir.api.components.ReservedUnique unique) {
	immutable e = pushDeclaration(b, name);
	attachBuiltinType(*b.store, e, type, unique);
	return e;
}

/// Makes `e` a function type such as `(a: std.u8, b: std.u8) -> std.u8`, with no parameters and no return type yet, for `pushParameter` and `setReturnType` to fill in.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// attachFunctionType(store, e, StringId(0));
/// assert(ecrs.context.hasComponent!(doir.api.components.FunctionInputs)(store, e));
/// ---
void attachFunctionType(T)(ref ecrs.context.Context store, EntityId e, T type) {
	setType(store, e, type);
	cast(void) addComponent!(doir.api.components.TypeDefinition)(store, e);
	cast(void) addComponent!(doir.api.components.FunctionInputs)(store, e);
}

/// Appends the named function type `add_t : type = (a: std.u8, b: std.u8) -> std.u8` to `b`'s block; see `attachFunctionType`.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// auto ft = pushFunctionType(root, StringId(0), StringId(1));
/// assert(ecrs.context.hasComponent!(doir.api.components.TypeDefinition)(store, ft));
/// ---
EntityId pushFunctionType(T)(ref BlockBuilder b, StringId name, T type) {
	immutable e = pushDeclaration(b, name);
	attachFunctionType(*b.store, e, type);
	return e;
}

/// `x : (a: T) -> U = ...`: a function type written in place, the declared type of `owner`, which it takes as its `Parent` (`WF-Par`). Set it as `owner`'s type with `setType`.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// auto x = pushDeclaration(root, StringId(0));
/// auto ft = createFunctionType(store, x, StringId(1));
/// setType(store, x, ft);
/// assert(ecrs.context.getComponent!(doir.api.components.Parent)(store, ft).parent == x);
/// ---
EntityId createFunctionType(T)(ref ecrs.context.Context store, EntityId owner, T type) {
	immutable e = ecrs.context.addEntity(store);
	addComponent!(doir.api.components.Parent)(store, e).parent = owner;
	attachFunctionType(store, e, type);
	return e;
}

/// Appends parameter `name : type` to function type `functionType` (`R-Param`) and returns it, valueless; give it a default with `setDefault`. A deduced parameter passes `deducedTypeName`, interned, as its type.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// attachFunctionType(store, e, StringId(2));
/// auto a = pushParameter(store, e, StringId(0), StringId(1));
/// assert(ecrs.context.getComponent!(doir.api.components.FunctionInputs)(store, e).related[0] == a);
/// assert(ecrs.context.getComponent!(doir.api.components.Parent)(store, a).parent == e);
/// ---
EntityId pushParameter(T)(ref ecrs.context.Context store, EntityId functionType, StringId name, T type) {
	immutable e = ecrs.context.addEntity(store);
	if (name != noName) addComponent!(doir.api.components.Name)(store, e).value = name;
	addComponent!(doir.api.components.Parent)(store, e).parent = functionType;
	attachValueless(store, e, type);
	append(ecrs.context.getComponent!(doir.api.components.FunctionInputs)(store, functionType).related, e);
	return e;
}

/// Gives parameter `p` the default `= 5` or `= y` (`F-Default`), replacing its `Valueless`.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto ft = ecrs.context.addEntity(store);
/// attachFunctionType(store, ft, StringId(2));
/// auto p = pushParameter(store, ft, StringId(0), StringId(1));
/// setDefault(store, p, doir.api.components.ConstantVal.integer(5));
/// assert(ecrs.context.getComponent!(doir.api.components.Flags)(store, p).flags == doir.api.components.Flags.Comptime);
/// ---
void setDefault(ref ecrs.context.Context store, EntityId p, doir.api.components.ConstantVal value) {
	ecrs.context.getComponent!(doir.api.components.Flags)(store, p).flags &= ~doir.api.components.Flags.Valueless;
	addComponent!(doir.api.components.ConstantVal)(store, p) = value;
	addFlags(store, p, doir.api.components.Flags.Comptime);
}

/// Ditto
void setDefault(ref ecrs.context.Context store, EntityId p, StringId value) {
	ecrs.context.getComponent!(doir.api.components.Flags)(store, p).flags &= ~doir.api.components.Flags.Valueless;
	addComponent!(doir.api.components.LookupValue)(store, p).name = value;
}

/// Gives function type `functionType` the return type written after `->`; without one it returns `void`.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto ft = ecrs.context.addEntity(store);
/// attachFunctionType(store, ft, StringId(1));
/// setReturnType(store, ft, StringId(2));
/// assert(ecrs.context.getComponent!(doir.api.components.LookupFunctionReturn)(store, ft).name == StringId(2));
/// ---
void setReturnType(ref ecrs.context.Context store, EntityId functionType, StringId type) {
	addComponent!(doir.api.components.LookupFunctionReturn)(store, functionType).name = type;
}

/// Ditto
void setReturnType(ref ecrs.context.Context store, EntityId functionType, EntityId type) {
	addComponent!(doir.api.components.FunctionReturn)(store, functionType).type = type;
}


// --- aliases and namespaces --------------------------------------------------

/// Makes `e` the alias `color : alias = vec3`, which carries no type (`WF-Kind`).
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// attachAlias(store, e, StringId(0));
/// assert(ecrs.context.getComponent!(doir.api.components.LookupAlias)(store, e).name == StringId(0));
/// ---
void attachAlias(ref ecrs.context.Context store, EntityId e, StringId target) {
	addComponent!(doir.api.components.LookupAlias)(store, e).name = target;
}

/// Appends the alias `color : alias = vec3` to `b`'s block; see `attachAlias`.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// auto e = pushAlias(root, StringId(0), StringId(1));
/// assert(!ecrs.context.hasComponent!(doir.api.components.LookupTypeOf)(store, e));
/// ---
EntityId pushAlias(ref BlockBuilder b, StringId name, StringId target) {
	immutable e = pushDeclaration(b, name);
	attachAlias(*b.store, e, target);
	return e;
}

/// Makes `e` the namespace `math : namespace = { ... }`, which carries no type (`WF-Kind`). Returns a builder for its contents.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// auto math = attachNamespace(store, e);
/// assert(ecrs.context.getComponent!(doir.api.components.Flags)(store, math.block).flags == doir.api.components.Flags.Namespace);
/// ---
BlockBuilder attachNamespace(ref ecrs.context.Context store, EntityId e) {
	addFlags(store, e, doir.api.components.Flags.Namespace);
	cast(void) addComponent!(doir.api.components.Block)(store, e);
	return BlockBuilder(&store, e);
}

/// Appends a namespace to `b`'s block and returns a builder for its contents; see `attachNamespace`. Reopening one is another call with the same name (`R-Merge`).
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// auto math = pushNamespace(root, StringId(0));
/// assert(ecrs.context.getComponent!(doir.api.components.Parent)(store, math.block).parent == root.block);
/// ---
BlockBuilder pushNamespace(ref BlockBuilder b, StringId name) {
	return attachNamespace(*b.store, pushDeclaration(b, name));
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
	auto t = pushParameter(store, ft, s("T"), s(doir.api.components.deducedTypeName));
	auto value = pushParameter(store, ft, s("value"), s("T"));
	setReturnType(store, ft, s("T"));
	auto id = pushValueless(root, s("id"), s("identity"));
	assert(ecrs.context.getComponent!(doir.api.components.FunctionInputs)(store, ft).related[0 .. 2] == [t, value]);
	assert(doir.strings.text(strings, ecrs.context.getComponent!(doir.api.components.LookupTypeOf)(store, t).name) == "deduced type");
	assert(ecrs.context.getComponent!(doir.api.components.Block)(store, root.block).related[0 .. 2] == [ft, id]);

	// Attaching to a declared entity matches pushing the same form.
	auto later = pushDeclaration(root, s("later"));
	auto inner = attachBlock(store, later, s("block"));
	assert(inner.block == later && ecrs.context.getComponent!(doir.api.components.Block)(store, root.block).related[2] == later);
	assert(ecrs.context.getComponent!(doir.api.components.LookupTypeOf)(store, later).name == s("block"));

	// Renumbering rewrites every entity-valued component (E-Remap).
	assert(ecrs.context.swapEntities(store, ft, value));
	assert(ecrs.context.getComponent!(doir.api.components.Parent)(store, ft).parent == value);
	assert(ecrs.context.getComponent!(doir.api.components.FunctionInputs)(store, value).related[0 .. 2] == [t, ft]);
	assert(ecrs.context.getComponent!(doir.api.components.Block)(store, root.block).related[0] == value);
	assert(ecrs.context.swapEntities(store, ft, value));

	// Builtin types are distinct by discriminator, deduced type included.
	auto builtin = createRoot(store);
	auto type = pushBuiltinType(builtin, s("type"), s("type"), doir.api.components.ReservedUnique.type);
	auto deduced = pushBuiltinType(builtin, s("deduced_type"), s("type"), doir.api.components.ReservedUnique.deducedType);
	assert(ecrs.context.getComponent!(doir.api.components.TypeDefinition)(store, type).unique != ecrs.context.getComponent!(doir.api.components.TypeDefinition)(store, deduced).unique);

	// A `_` parameter has no name; a default replaces Valueless.
	auto unnamed = pushParameter(store, ft, noName, s("std.u8"));
	assert(!ecrs.context.hasComponent!(doir.api.components.Name)(store, unnamed));
	setDefault(store, unnamed, s("zero"));
	assert(ecrs.context.getComponent!(doir.api.components.Flags)(store, unnamed).flags == doir.api.components.Flags.None);

	// Types may be given resolved, as entities; a literal default makes the parameter comptime (C-Constant, F-Default).
	auto typed = pushValueless(root, s("typed"), type);
	assert(ecrs.context.getComponent!(doir.api.components.TypeOf)(store, typed).type == type);
	setReturnType(store, ft, type);
	assert(ecrs.context.getComponent!(doir.api.components.FunctionReturn)(store, ft).type == type);
	auto five = pushParameter(store, ft, s("five"), s("std.u8"));
	setDefault(store, five, doir.api.components.ConstantVal.integer(5));
	assert(ecrs.context.getComponent!(doir.api.components.Flags)(store, five).flags == doir.api.components.Flags.Comptime);
	assert(ecrs.context.getComponent!(doir.api.components.ConstantVal)(store, five).integerValue == 5);

	// Aliases and namespaces carry no type (WF-Kind); a namespace's contents go in its own block.
	auto color = pushAlias(root, s("color"), s("vec3"));
	assert(ecrs.context.getComponent!(doir.api.components.LookupAlias)(store, color).name == s("vec3"));
	assert(!ecrs.context.hasComponent!(doir.api.components.LookupTypeOf)(store, color));
	auto math = pushNamespace(root, s("math"));
	auto pi = pushValueless(math, s("pi"), s("std.f64"));
	assert(ecrs.context.getComponent!(doir.api.components.Flags)(store, math.block).flags == doir.api.components.Flags.Namespace);
	assert(ecrs.context.getComponent!(doir.api.components.Parent)(store, pi).parent == math.block);
	assert(!ecrs.context.hasComponent!(doir.api.components.LookupTypeOf)(store, math.block));
}
