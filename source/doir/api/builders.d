/// The builders that write the parser's components (`doir.api.components`) into the libECRS store, one call per declaration form of `doir.peg`. The parser resolves no names: a name it reads becomes a `Lookup*` component holding the interned path, which name resolution replaces with the entity-valued component it stands for.
///
/// A refused allocation is reported through each builder's result: `false`, `invalidEntity`, or a `BlockBuilder` whose `block` is `invalidEntity`. The entity being built may then hold some of its components, but no block gains a declaration that `pushDeclaration` could not finish.
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


// --- builders ----------------------------------------------------------------

/// A cursor over one block being filled: every `push` call appends a declaration to it.
struct BlockBuilder {
	ecrs.context.Context* store = null; /// The store the block lives in.
	EntityId block = invalidEntity; /// The block entity.
}

private bool put(C)(ref ecrs.context.Context store, EntityId e, C value) {
	auto component = ecrs.context.addComponent!C(store, e);
	if (component is null) return false;
	*component = value;
	return true;
}


/// Adds `flags` to entity `e`'s flag set, adding the set if it has none. The parser uses it for `export` and the `inline`, `flatten` and `tail` call prefixes. Returns false if the store refused the set, leaving `e` as it was.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// assert(addFlags(store, e, doir.api.components.Flags.Export));
/// assert(addFlags(store, e, doir.api.components.Flags.Tail));
/// assert(ecrs.context.getComponent!(doir.api.components.Flags)(store, e).flags == (doir.api.components.Flags.Export | doir.api.components.Flags.Tail));
/// ---
bool addFlags(ref ecrs.context.Context store, EntityId e, uint flags) {
	auto set = ecrs.context.getOrAddComponent!(doir.api.components.Flags)(store, e);
	if (set is null) return false;
	set.flags |= flags;
	return true;
}

/// Starts a file's root block, a fresh entity with an empty `Block` and no `Parent`. On a refused allocation its `block` is `invalidEntity`, and `store` gains no entity with a `Block`: at most an orphan with no components, if its removal is refused too.
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
	immutable e = ecrs.context.addEntity(store);
	if (e == invalidEntity) return BlockBuilder.init;
	if (ecrs.context.addComponent!(doir.api.components.Block)(store, e) !is null) return BlockBuilder(&store, e);
	cast(void) ecrs.context.removeEntity(store, e); // if refused, an orphan nothing reaches
	return BlockBuilder.init;
}

/// Appends a fresh declaration to `b`'s block, with `Name` unless `name` is `noName` (a `_` declaration) and `Parent` set to the block (`WF-Par`). Every `pushX` is this followed by `attachX`. On a refused allocation returns `invalidEntity`, leaving the block as it was.
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
	if (e == invalidEntity) return invalidEntity;
	if ((name == noName || put(*store, e, doir.api.components.Name(name)))
		&& put(*store, e, doir.api.components.Parent([b.block]))
		&& fp.dynarray.pushBack(ecrs.context.getComponent!(doir.api.components.Block)(*store, b.block).related, e))
		return e;
	cast(void) ecrs.context.removeEntity(*store, e); // if refused, an orphan nothing reaches
	return invalidEntity;
}

/// Gives `e` its declared type: a name to resolve, or an entity already known, such as a function type written in place. Returns false if the store refused it, leaving `e` as it was.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// assert(setType(store, e, StringId(0)));
/// assert(ecrs.context.getComponent!(doir.api.components.LookupTypeOf)(store, e).name == StringId(0));
/// ---
bool setType(ref ecrs.context.Context store, EntityId e, StringId type) {
	return put(store, e, doir.api.components.LookupTypeOf(type));
}

/// Ditto
bool setType(ref ecrs.context.Context store, EntityId e, EntityId type) {
	return put(store, e, doir.api.components.TypeOf([type]));
}


// --- values ------------------------------------------------------------------

/// Makes `e` the literal `six : std.u8 = 6`, `Comptime` from the start (`C-Constant`). Returns false on a refused allocation, `e` then holding some of its components.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// assert(attachConstant(store, e, StringId(0), doir.api.components.ConstantVal.integer(6)));
/// assert(ecrs.context.getComponent!(doir.api.components.ConstantVal)(store, e).integerValue == 6);
/// ---
bool attachConstant(T)(ref ecrs.context.Context store, EntityId e, T type, doir.api.components.ConstantVal value) {
	return setType(store, e, type) && put(store, e, value) && addFlags(store, e, doir.api.components.Flags.Comptime);
}

/// Appends the literal `six : std.u8 = 6` to `b`'s block; see `attachConstant`. Returns `invalidEntity` on a refused allocation.
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
	return e != invalidEntity && attachConstant(*b.store, e, type, value) ? e : invalidEntity;
}

/// Makes `e` the declaration `x : std.u8` with no value, such as a field, a prototype or a parameter. Returns false on a refused allocation, `e` then holding some of its components.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// assert(attachValueless(store, e, StringId(0)));
/// assert(ecrs.context.getComponent!(doir.api.components.Flags)(store, e).flags == doir.api.components.Flags.Valueless);
/// ---
bool attachValueless(T)(ref ecrs.context.Context store, EntityId e, T type) {
	return setType(store, e, type) && addFlags(store, e, doir.api.components.Flags.Valueless);
}

/// Appends `x : std.u8`, a declaration with no value, to `b`'s block; see `attachValueless`. Returns `invalidEntity` on a refused allocation.
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
	return e != invalidEntity && attachValueless(*b.store, e, type) ? e : invalidEntity;
}

/// Makes `e` the declaration `x : T = y`, a value written as a bare name (`A-Bind`). Returns false on a refused allocation, `e` then holding some of its components.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// assert(attachReference(store, e, StringId(0), StringId(1)));
/// assert(ecrs.context.getComponent!(doir.api.components.LookupValue)(store, e).name == StringId(1));
/// ---
bool attachReference(T)(ref ecrs.context.Context store, EntityId e, T type, StringId target) {
	return setType(store, e, type) && put(store, e, doir.api.components.LookupValue(target));
}

/// Appends `x : T = y` to `b`'s block; see `attachReference`. Returns `invalidEntity` on a refused allocation.
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
	return e != invalidEntity && attachReference(*b.store, e, type, target) ? e : invalidEntity;
}

/// Makes `e` the call `sum : std.u8 = std.add(a, b)`, its callee and arguments all names (`WF-Arg`). A prefix (`inline`, `flatten`, `tail`) is added with `addFlags`. Returns false on a refused allocation, `e` then holding some of its components.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// immutable StringId[2] arguments = [StringId(2), StringId(3)];
/// assert(attachCall(store, e, StringId(0), StringId(1), arguments[]));
/// assert(ecrs.context.getComponent!(doir.api.components.LookupCall)(store, e).name == StringId(1));
/// ---
bool attachCall(T)(ref ecrs.context.Context store, EntityId e, T type, StringId callee, const(StringId)[] arguments) {
	if (!setType(store, e, type) || !put(store, e, doir.api.components.LookupCall(callee))) return false;
	auto inputs = ecrs.context.addComponent!(doir.api.components.LookupFunctionInputs)(store, e);
	if (inputs is null) return false;
	foreach (a; arguments)
		if (!fp.dynarray.pushBack(inputs.names, a)) return false;
	return true;
}

/// Appends the call `sum : std.u8 = std.add(a, b)` to `b`'s block; see `attachCall`. Returns `invalidEntity` on a refused allocation.
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
	return e != invalidEntity && attachCall(*b.store, e, type, callee, arguments) ? e : invalidEntity;
}

/// Makes `e` the block-valued declaration `then : block = { ... }` or `add : add_t = { ... }`, a block binding or a function body by its resolved type. Returns a builder for its contents. On a refused allocation its `block` is `invalidEntity`, `e` then holding some of its components.
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
	return setType(store, e, type) && ecrs.context.addComponent!(doir.api.components.Block)(store, e) !is null ? BlockBuilder(&store, e) : BlockBuilder.init;
}

/// Appends a block-valued declaration to `b`'s block and returns a builder for its contents; see `attachBlock`. On a refused allocation its `block` is `invalidEntity`.
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
	immutable e = pushDeclaration(b, name);
	return e == invalidEntity ? BlockBuilder.init : attachBlock(*b.store, e, type);
}


// --- types -------------------------------------------------------------------

/// Makes `e` the aggregate type `vec3 : type = { x : f32 ; ... }`, its layout left for the layout queries. Returns a builder for its fields. On a refused allocation its `block` is `invalidEntity`, `e` then holding some of its components.
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
	return attachBlock(store, e, type).block != invalidEntity && ecrs.context.addComponent!(doir.api.components.TypeDefinition)(store, e) !is null ? BlockBuilder(&store, e) : BlockBuilder.init;
}

/// Appends an aggregate type to `b`'s block and returns a builder for its fields; see `attachAggregate`. On a refused allocation its `block` is `invalidEntity`.
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
	immutable e = pushDeclaration(b, name);
	return e == invalidEntity ? BlockBuilder.init : attachAggregate(*b.store, e, type);
}

/// Makes `e` a builtin type, `type : type = {}` in the builtin block: an empty aggregate carrying its reserved discriminator and `Comptime | AlwaysComptime` (Part I §7, `M-Unique`). Returns false on a refused allocation, `e` then holding some of its components.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// assert(attachBuiltinType(store, e, e, doir.api.components.ReservedUnique.type));
/// assert(ecrs.context.getComponent!(doir.api.components.TypeOf)(store, e).type == e);
/// ---
bool attachBuiltinType(T)(ref ecrs.context.Context store, EntityId e, T type, doir.api.components.ReservedUnique unique) {
	assert(unique != doir.api.components.ReservedUnique.structural && unique < doir.api.components.ReservedUnique.firstFresh);
	if (attachAggregate(store, e, type).block == invalidEntity) return false;
	ecrs.context.getComponent!(doir.api.components.TypeDefinition)(store, e).unique = unique;
	return addFlags(store, e, doir.api.components.Flags.Comptime | doir.api.components.Flags.AlwaysComptime);
}

/// Appends a builtin type to `b`'s block; see `attachBuiltinType`. Returns `invalidEntity` on a refused allocation.
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
	return e != invalidEntity && attachBuiltinType(*b.store, e, type, unique) ? e : invalidEntity;
}

/// Makes `e` a function type such as `(a: std.u8, b: std.u8) -> std.u8`, with no parameters and no return type yet, for `pushParameter` and `setReturnType` to fill in. Returns false on a refused allocation, `e` then holding some of its components.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// assert(attachFunctionType(store, e, StringId(0)));
/// assert(ecrs.context.hasComponent!(doir.api.components.FunctionInputs)(store, e));
/// ---
bool attachFunctionType(T)(ref ecrs.context.Context store, EntityId e, T type) {
	return setType(store, e, type) && ecrs.context.addComponent!(doir.api.components.TypeDefinition)(store, e) !is null && ecrs.context.addComponent!(doir.api.components.FunctionInputs)(store, e) !is null;
}

/// Appends the named function type `add_t : type = (a: std.u8, b: std.u8) -> std.u8` to `b`'s block; see `attachFunctionType`. Returns `invalidEntity` on a refused allocation.
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
	return e != invalidEntity && attachFunctionType(*b.store, e, type) ? e : invalidEntity;
}

/// `x : (a: T) -> U = ...`: a function type written in place, the declared type of `owner`, which it takes as its `Parent` (`WF-Par`). Set it as `owner`'s type with `setType`. On a refused allocation returns `invalidEntity`.
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
/// assert(setType(store, x, ft));
/// assert(ecrs.context.getComponent!(doir.api.components.Parent)(store, ft).parent == x);
/// ---
EntityId createFunctionType(T)(ref ecrs.context.Context store, EntityId owner, T type) {
	immutable e = ecrs.context.addEntity(store);
	if (e == invalidEntity) return invalidEntity;
	if (put(store, e, doir.api.components.Parent([owner])) && attachFunctionType(store, e, type)) return e;
	cast(void) ecrs.context.removeEntity(store, e); // if refused, an orphan nothing reaches
	return invalidEntity;
}

/// Appends parameter `name : type` to function type `functionType` (`R-Param`) and returns it, valueless; give it a default with `setDefault`. A deduced parameter passes `deducedTypeName`, interned, as its type. On a refused allocation returns `invalidEntity`, leaving `functionType` as it was.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// assert(attachFunctionType(store, e, StringId(2)));
/// auto a = pushParameter(store, e, StringId(0), StringId(1));
/// assert(ecrs.context.getComponent!(doir.api.components.FunctionInputs)(store, e).related[0] == a);
/// assert(ecrs.context.getComponent!(doir.api.components.Parent)(store, a).parent == e);
/// ---
EntityId pushParameter(T)(ref ecrs.context.Context store, EntityId functionType, StringId name, T type) {
	immutable e = ecrs.context.addEntity(store);
	if (e == invalidEntity) return invalidEntity;
	if ((name == noName || put(store, e, doir.api.components.Name(name)))
		&& put(store, e, doir.api.components.Parent([functionType]))
		&& attachValueless(store, e, type)
		&& fp.dynarray.pushBack(ecrs.context.getComponent!(doir.api.components.FunctionInputs)(store, functionType).related, e))
		return e;
	cast(void) ecrs.context.removeEntity(store, e); // if refused, an orphan nothing reaches
	return invalidEntity;
}

/// Gives parameter `p` the default `= 5` or `= y` (`F-Default`), replacing its `Valueless`. Returns false if the store refused it, leaving `p` as it was.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto ft = ecrs.context.addEntity(store);
/// assert(attachFunctionType(store, ft, StringId(2)));
/// auto p = pushParameter(store, ft, StringId(0), StringId(1));
/// assert(setDefault(store, p, doir.api.components.ConstantVal.integer(5)));
/// assert(ecrs.context.getComponent!(doir.api.components.Flags)(store, p).flags == doir.api.components.Flags.Comptime);
/// ---
bool setDefault(ref ecrs.context.Context store, EntityId p, doir.api.components.ConstantVal value) {
	if (!put(store, p, value)) return false;
	auto set = &ecrs.context.getComponent!(doir.api.components.Flags)(store, p);
	set.flags = (set.flags & ~doir.api.components.Flags.Valueless) | doir.api.components.Flags.Comptime;
	return true;
}

/// Ditto
bool setDefault(ref ecrs.context.Context store, EntityId p, StringId value) {
	if (!put(store, p, doir.api.components.LookupValue(value))) return false;
	ecrs.context.getComponent!(doir.api.components.Flags)(store, p).flags &= ~doir.api.components.Flags.Valueless;
	return true;
}

/// Gives function type `functionType` the return type written after `->`; without one it returns `void`. Returns false if the store refused it, leaving `functionType` as it was.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto ft = ecrs.context.addEntity(store);
/// assert(attachFunctionType(store, ft, StringId(1)));
/// assert(setReturnType(store, ft, StringId(2)));
/// assert(ecrs.context.getComponent!(doir.api.components.LookupFunctionReturn)(store, ft).name == StringId(2));
/// ---
bool setReturnType(ref ecrs.context.Context store, EntityId functionType, StringId type) {
	return put(store, functionType, doir.api.components.LookupFunctionReturn(type));
}

/// Ditto
bool setReturnType(ref ecrs.context.Context store, EntityId functionType, EntityId type) {
	return put(store, functionType, doir.api.components.FunctionReturn([type]));
}


// --- aliases and namespaces --------------------------------------------------

/// Makes `e` the alias `color : alias = vec3`, which carries no type (`WF-Kind`). Returns false on a refused allocation, `e` then holding some of its components.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.api.components;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// assert(attachAlias(store, e, StringId(0)));
/// assert(ecrs.context.getComponent!(doir.api.components.LookupAlias)(store, e).name == StringId(0));
/// ---
bool attachAlias(ref ecrs.context.Context store, EntityId e, StringId target) {
	return put(store, e, doir.api.components.LookupAlias(target));
}

/// Appends the alias `color : alias = vec3` to `b`'s block; see `attachAlias`. Returns `invalidEntity` on a refused allocation.
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
	return e != invalidEntity && attachAlias(*b.store, e, target) ? e : invalidEntity;
}

/// Makes `e` the namespace `math : namespace = { ... }`, which carries no type (`WF-Kind`). Returns a builder for its contents. On a refused allocation its `block` is `invalidEntity`, `e` then holding some of its components.
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
	return addFlags(store, e, doir.api.components.Flags.Namespace) && ecrs.context.addComponent!(doir.api.components.Block)(store, e) !is null ? BlockBuilder(&store, e) : BlockBuilder.init;
}

/// Appends a namespace to `b`'s block and returns a builder for its contents; see `attachNamespace`. Reopening one is another call with the same name (`R-Merge`). On a refused allocation its `block` is `invalidEntity`.
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
	immutable e = pushDeclaration(b, name);
	return e == invalidEntity ? BlockBuilder.init : attachNamespace(*b.store, e);
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
	assert(setReturnType(store, ft, s("T")));
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
	assert(setDefault(store, unnamed, s("zero")));
	assert(ecrs.context.getComponent!(doir.api.components.Flags)(store, unnamed).flags == doir.api.components.Flags.None);

	// Types may be given resolved, as entities; a literal default makes the parameter comptime (C-Constant, F-Default).
	auto typed = pushValueless(root, s("typed"), type);
	assert(ecrs.context.getComponent!(doir.api.components.TypeOf)(store, typed).type == type);
	assert(setReturnType(store, ft, type));
	assert(ecrs.context.getComponent!(doir.api.components.FunctionReturn)(store, ft).type == type);
	auto five = pushParameter(store, ft, s("five"), s("std.u8"));
	assert(setDefault(store, five, doir.api.components.ConstantVal.integer(5)));
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

	// A refused allocation is reported, and leaves the block or the function type without the declaration.
	static import fp.dynarray;
	static import doir.testing;
	bool refusedOnce = false;
	foreach (n; 0 .. 8) {
		immutable declarations = fp.dynarray.length(ecrs.context.getComponent!(doir.api.components.Block)(store, root.block).related);
		immutable parameters = fp.dynarray.length(ecrs.context.getComponent!(doir.api.components.FunctionInputs)(store, ft).related);
		auto previous = doir.testing.beginRationedAllocator(n);
		immutable d = pushDeclaration(root, s("refused"));
		immutable p = pushParameter(store, ft, s("refused"), s("std.u8"));
		doir.testing.endRationedAllocator(previous);
		assert(fp.dynarray.length(ecrs.context.getComponent!(doir.api.components.Block)(store, root.block).related) == declarations + (d != invalidEntity));
		assert(fp.dynarray.length(ecrs.context.getComponent!(doir.api.components.FunctionInputs)(store, ft).related) == parameters + (p != invalidEntity));
		refusedOnce |= d == invalidEntity || p == invalidEntity;
	}
	assert(refusedOnce);

	// A refused root leaves at most an orphan without a `Block`, when its removal is refused too.
	for (size_t n = 0;; ++n) {
		assert(n < 100);
		auto fresh = ecrs.context.create();
		scope(exit) ecrs.context.free(fresh);
		auto previous = doir.testing.beginRationedAllocator(n);
		auto made = createRoot(fresh);
		doir.testing.endRationedAllocator(previous);
		if (made.block != invalidEntity) break;
		assert(made.store is null);
		assert(ecrs.context.entityCount(fresh) <= 1 || !ecrs.context.hasComponent!(doir.api.components.Block)(fresh, 1));
	}
}
