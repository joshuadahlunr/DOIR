/// The builders that write the parser's components (`doir.components.ast`) into the libECRS store, one call per declaration form of `doir.peg`.
/// The parser resolves no names: a name it reads becomes a `Lookup*` component holding the interned path, which name resolution replaces with the entity-valued component it stands for.
///
/// A refused allocation is reported through each builder's result: `false`, `invalidEntity`, or a `BlockBuilder` whose `block` is `invalidEntity`.
/// The entity being built may then hold some of its components, but no block gains a declaration that `pushDeclaration` could not finish.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.strings;
/// static import doir.components.ast;
/// doir.strings.Strings strings;
/// scope(exit) doir.strings.free(strings);
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// auto six = pushConstant(root, doir.strings.intern(strings, "six"), doir.strings.intern(strings, "std.u8"), doir.components.ast.ConstantVal.integer(6));
/// assert(ecrs.context.getComponent!(doir.components.ast.ConstantVal)(store, six).integerValue == 6);
/// assert(ecrs.context.getComponent!(doir.components.ast.Parent)(store, six).parent == root.block);
/// ---
module doir.builders;

static import fp.dynarray;
version(unittest) static import fp.testing;

static import ecrs.context;

static import doir.components.ast;

public import ecrs.context : EntityId, invalidEntity;
public import doir.strings : StringId, unnamed;

@nogc nothrow:


// --- builders ----------------------------------------------------------------

/// A cursor over one block being filled: every `push` call appends a declaration to it.
struct BlockBuilder {
	ecrs.context.Context* store = null; /// The store the block lives in.
	EntityId block = invalidEntity; /// The block entity.
}


/// Adds `flags` to entity `e`'s flag set, adding the set if it has none.
/// The parser uses it for `export` and the `inline`, `flatten` and `tail` call prefixes.
/// Returns false if the store refused the set, leaving `e` as it was.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.components.ast;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// assert(addFlags(store, e, doir.components.ast.Flags.Export));
/// assert(addFlags(store, e, doir.components.ast.Flags.Tail));
/// assert(ecrs.context.getComponent!(doir.components.ast.Flags)(store, e).flags == (doir.components.ast.Flags.Export | doir.components.ast.Flags.Tail));
/// ---
bool addFlags(ref ecrs.context.Context store, EntityId e, uint flags) {
	assert(e != invalidEntity, "doir.builders: building on no entity");
	auto set = ecrs.context.ensureComponent!(doir.components.ast.Flags)(store, e);
	if (set is null) return false;
	set.flags |= flags;
	assert((ecrs.context.getComponent!(doir.components.ast.Flags)(store, e).flags & flags) == flags, "doir.builders: flags that did not stick");
	return true;
}

/// Starts a file's root block, a fresh entity with an empty `Block` and no `Parent`.
/// On a refused allocation its `block` is `invalidEntity`, and `store` gains no entity with a `Block`: at most an orphan with no components, if its removal is refused too.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.components.ast;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// assert(ecrs.context.hasComponent!(doir.components.ast.Block)(store, root.block));
/// ---
BlockBuilder createRoot(ref ecrs.context.Context store) {
	immutable e = ecrs.context.addEntity(store);
	if (e == invalidEntity) return BlockBuilder.init;
	if (ecrs.context.addComponent!(doir.components.ast.Block)(store, e) !is null) {
		assert(!ecrs.context.hasComponent!(doir.components.ast.Parent)(store, e), "doir.builders: a root with a parent (WF-Par)");
		return BlockBuilder(&store, e);
	}
	cast(void) ecrs.context.removeEntity(store, e); // if refused, an orphan nothing reaches
	return BlockBuilder.init;
}

/// Appends a fresh declaration to `b`'s block, with `Name` unless `name` is `unnamed` (a `_` declaration) and `Parent` set to the block (`WF-Par`).
/// Every `pushX` is this followed by `attachX`.
/// On a refused allocation returns `invalidEntity`, leaving the block as it was.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.components.ast;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// auto e = pushDeclaration(root, unnamed);
/// assert(!ecrs.context.hasComponent!(doir.components.ast.Name)(store, e));
/// assert(ecrs.context.getComponent!(doir.components.ast.Block)(store, root.block).related[0] == e);
/// ---
EntityId pushDeclaration(ref BlockBuilder b, StringId name) {
	assert(b.store !is null && b.block != invalidEntity && ecrs.context.hasComponent!(doir.components.ast.Block)(*b.store, b.block), "doir.builders: pushing onto something that is not a block");
	auto store = b.store;
	immutable e = ecrs.context.addEntity(*store);
	if (e == invalidEntity) return invalidEntity;
	if ((name == unnamed || ecrs.context.setComponent!(doir.components.ast.Name)(*store, e, doir.components.ast.Name(name)))
		&& ecrs.context.setComponent!(doir.components.ast.Parent)(*store, e, doir.components.ast.Parent([b.block]))
		&& fp.dynarray.pushBack(ecrs.context.getForWriting!(doir.components.ast.Block)(*store, b.block).related, e)) {
		assert(*fp.dynarray.back(ecrs.context.getComponent!(doir.components.ast.Block)(*store, b.block).related) == e, "doir.builders: a declaration missing from the end of its block");
		assert(ecrs.context.getComponent!(doir.components.ast.Parent)(*store, e).parent == b.block, "doir.builders: a declaration under another parent (WF-Par)");
		return e;
	}
	cast(void) ecrs.context.removeEntity(*store, e); // if refused, an orphan nothing reaches
	return invalidEntity;
}

// wrapper: picks the component a type named or given by entity sets, for callers generic over both
/// Gives `e` its declared type: a name to resolve, or an entity already known, such as a function type written in place.
/// Returns false if the store refused it, leaving `e` as it was.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.components.ast;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// assert(setType(store, e, StringId(0)));
/// assert(ecrs.context.getComponent!(doir.components.ast.LookupTypeOf)(store, e).name == StringId(0));
/// ---
bool setType(ref ecrs.context.Context store, EntityId e, StringId type) {
	assert(e != invalidEntity, "doir.builders: building on no entity");
	immutable set = ecrs.context.setComponent!(doir.components.ast.LookupTypeOf)(store, e, doir.components.ast.LookupTypeOf(type));
	assert(!set || ecrs.context.getComponent!(doir.components.ast.LookupTypeOf)(store, e).name == type, "doir.builders: a type name that did not stick");
	return set;
}

// wrapper: as above
/// Ditto
bool setType(ref ecrs.context.Context store, EntityId e, EntityId type) {
	assert(e != invalidEntity && type != invalidEntity, "doir.builders: a type that is no entity");
	immutable set = ecrs.context.setComponent!(doir.components.ast.TypeOf)(store, e, doir.components.ast.TypeOf([type]));
	assert(!set || ecrs.context.getComponent!(doir.components.ast.TypeOf)(store, e).related[0] == type, "doir.builders: a type that did not stick");
	return set;
}


// --- values ------------------------------------------------------------------

/// Makes `e` the literal `six : std.u8 = 6`, `Comptime` from the start (`C-Constant`).
/// Returns false on a refused allocation, `e` then holding some of its components.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.components.ast;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// assert(attachConstant(store, e, StringId(0), doir.components.ast.ConstantVal.integer(6)));
/// assert(ecrs.context.getComponent!(doir.components.ast.ConstantVal)(store, e).integerValue == 6);
/// ---
bool attachConstant(T)(ref ecrs.context.Context store, EntityId e, T type, doir.components.ast.ConstantVal value) {
	immutable attached = setType(store, e, type) && ecrs.context.setComponent!(doir.components.ast.ConstantVal)(store, e, value) && addFlags(store, e, doir.components.ast.Flags.Comptime);
	assert(!attached || ecrs.context.hasComponent!(doir.components.ast.ConstantVal)(store, e), "doir.builders: a constant without its value");
	return attached;
}

/// Appends the literal `six : std.u8 = 6` to `b`'s block; see `attachConstant`.
/// Returns `invalidEntity` on a refused allocation.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.components.ast;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// auto e = pushConstant(root, StringId(0), StringId(1), doir.components.ast.ConstantVal.integer(6));
/// assert(ecrs.context.getComponent!(doir.components.ast.Flags)(store, e).flags == doir.components.ast.Flags.Comptime);
/// ---
EntityId pushConstant(T)(ref BlockBuilder b, StringId name, T type, doir.components.ast.ConstantVal value) {
	immutable e = pushDeclaration(b, name);
	return e != invalidEntity && attachConstant(*b.store, e, type, value) ? e : invalidEntity;
}

/// Makes `e` the declaration `x : std.u8` with no value, such as a field, a prototype or a parameter.
/// Returns false on a refused allocation, `e` then holding some of its components.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.components.ast;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// assert(attachValueless(store, e, StringId(0)));
/// assert(ecrs.context.getComponent!(doir.components.ast.Flags)(store, e).flags == doir.components.ast.Flags.Valueless);
/// ---
bool attachValueless(T)(ref ecrs.context.Context store, EntityId e, T type) {
	immutable attached = setType(store, e, type) && addFlags(store, e, doir.components.ast.Flags.Valueless);
	assert(!attached || !ecrs.context.hasComponent!(doir.components.ast.ConstantVal)(store, e), "doir.builders: a valueless declaration with a value");
	return attached;
}

/// Appends `x : std.u8`, a declaration with no value, to `b`'s block; see `attachValueless`.
/// Returns `invalidEntity` on a refused allocation.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.components.ast;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// auto e = pushValueless(root, StringId(0), StringId(1));
/// assert(ecrs.context.getComponent!(doir.components.ast.Flags)(store, e).flags == doir.components.ast.Flags.Valueless);
/// ---
EntityId pushValueless(T)(ref BlockBuilder b, StringId name, T type) {
	immutable e = pushDeclaration(b, name);
	return e != invalidEntity && attachValueless(*b.store, e, type) ? e : invalidEntity;
}

/// Makes `e` the declaration `x : T = y`, a value written as a bare name (`A-Bind`).
/// Returns false on a refused allocation, `e` then holding some of its components.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.components.ast;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// assert(attachReference(store, e, StringId(0), StringId(1)));
/// assert(ecrs.context.getComponent!(doir.components.ast.LookupValue)(store, e).name == StringId(1));
/// ---
bool attachReference(T)(ref ecrs.context.Context store, EntityId e, T type, StringId target) {
	assert(target != unnamed, "doir.builders: a reference to no name");
	immutable attached = setType(store, e, type) && ecrs.context.setComponent!(doir.components.ast.LookupValue)(store, e, doir.components.ast.LookupValue(target));
	assert(!attached || ecrs.context.getComponent!(doir.components.ast.LookupValue)(store, e).name == target, "doir.builders: a reference that lost its target");
	return attached;
}

/// Appends `x : T = y` to `b`'s block; see `attachReference`.
/// Returns `invalidEntity` on a refused allocation.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.components.ast;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// auto e = pushReference(root, StringId(0), StringId(1), StringId(2));
/// assert(ecrs.context.getComponent!(doir.components.ast.LookupValue)(store, e).name == StringId(2));
/// ---
EntityId pushReference(T)(ref BlockBuilder b, StringId name, T type, StringId target) {
	immutable e = pushDeclaration(b, name);
	return e != invalidEntity && attachReference(*b.store, e, type, target) ? e : invalidEntity;
}

/// Makes `e` the call `sum : std.u8 = std.add(a, b)`, its callee and arguments all names (`WF-Arg`).
/// A prefix (`inline`, `flatten`, `tail`) is added with `addFlags`.
/// Returns false on a refused allocation, `e` then holding some of its components.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.components.ast;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// immutable StringId[2] arguments = [StringId(2), StringId(3)];
/// assert(attachCall(store, e, StringId(0), StringId(1), arguments[]));
/// assert(ecrs.context.getComponent!(doir.components.ast.LookupCall)(store, e).name == StringId(1));
/// ---
bool attachCall(T)(ref ecrs.context.Context store, EntityId e, T type, StringId callee, const(StringId)[] arguments) {
	if (!setType(store, e, type) || !ecrs.context.setComponent!(doir.components.ast.LookupCall)(store, e, doir.components.ast.LookupCall(callee))) return false;
	auto inputs = ecrs.context.addComponent!(doir.components.ast.LookupFunctionInputs)(store, e);
	if (inputs is null) return false;
	foreach (a; arguments)
		if (!fp.dynarray.pushBack(inputs.names.p, a)) return false;
	assert(fp.dynarray.length(inputs.names.p) == arguments.length, "doir.builders: a call with another number of arguments");
	return true;
}

/// Appends the call `sum : std.u8 = std.add(a, b)` to `b`'s block; see `attachCall`.
/// Returns `invalidEntity` on a refused allocation.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.components.ast;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// immutable StringId[2] arguments = [StringId(3), StringId(4)];
/// auto e = pushCall(root, StringId(0), StringId(1), StringId(2), arguments[]);
/// assert(ecrs.context.getComponent!(doir.components.ast.LookupFunctionInputs)(store, e).names[1] == StringId(4));
/// ---
EntityId pushCall(T)(ref BlockBuilder b, StringId name, T type, StringId callee, const(StringId)[] arguments) {
	immutable e = pushDeclaration(b, name);
	return e != invalidEntity && attachCall(*b.store, e, type, callee, arguments) ? e : invalidEntity;
}

/// Makes `e` the block-valued declaration `then : block = { ... }` or `add : add_t = { ... }`, a block binding or a function body by its resolved type.
/// Returns a builder for its contents.
/// On a refused allocation its `block` is `invalidEntity`, `e` then holding some of its components.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.components.ast;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// auto body_ = attachBlock(store, e, StringId(0));
/// assert(body_.block == e && ecrs.context.hasComponent!(doir.components.ast.Block)(store, e));
/// ---
BlockBuilder attachBlock(T)(ref ecrs.context.Context store, EntityId e, T type) {
	assert(!ecrs.context.hasComponent!(doir.components.ast.Block)(store, e), "doir.builders: a second block on one declaration");
	return setType(store, e, type) && ecrs.context.addComponent!(doir.components.ast.Block)(store, e) !is null ? BlockBuilder(&store, e) : BlockBuilder.init;
}

/// Appends a block-valued declaration to `b`'s block and returns a builder for its contents; see `attachBlock`.
/// On a refused allocation its `block` is `invalidEntity`.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.components.ast;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// auto body_ = pushBlock(root, StringId(0), StringId(1));
/// auto inner = pushValueless(body_, StringId(2), StringId(3));
/// assert(ecrs.context.getComponent!(doir.components.ast.Parent)(store, inner).parent == body_.block);
/// ---
BlockBuilder pushBlock(T)(ref BlockBuilder b, StringId name, T type) {
	immutable e = pushDeclaration(b, name);
	return e == invalidEntity ? BlockBuilder.init : attachBlock(*b.store, e, type);
}


// --- types -------------------------------------------------------------------

/// Makes `e` the aggregate type `vec3 : type = { x : f32 ; ... }`, its layout left for the layout queries.
/// Returns a builder for its fields.
/// On a refused allocation its `block` is `invalidEntity`, `e` then holding some of its components.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.components.ast;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// cast(void) attachAggregate(store, e, StringId(0));
/// assert(ecrs.context.getComponent!(doir.components.ast.TypeDefinition)(store, e).unique == doir.components.ast.ReservedUnique.structural);
/// ---
BlockBuilder attachAggregate(T)(ref ecrs.context.Context store, EntityId e, T type) {
	return attachBlock(store, e, type).block != invalidEntity && ecrs.context.addComponent!(doir.components.ast.TypeDefinition)(store, e) !is null ? BlockBuilder(&store, e) : BlockBuilder.init;
}

/// Appends an aggregate type to `b`'s block and returns a builder for its fields; see `attachAggregate`.
/// On a refused allocation its `block` is `invalidEntity`.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.components.ast;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// auto vec = pushAggregate(root, StringId(0), StringId(1));
/// assert(ecrs.context.getComponent!(doir.components.ast.TypeDefinition)(store, vec.block).unique == doir.components.ast.ReservedUnique.structural);
/// ---
BlockBuilder pushAggregate(T)(ref BlockBuilder b, StringId name, T type) {
	immutable e = pushDeclaration(b, name);
	return e == invalidEntity ? BlockBuilder.init : attachAggregate(*b.store, e, type);
}

/// Makes `e` a builtin type, `type : type = {}` in the builtin block: an empty aggregate carrying its reserved discriminator and `Comptime | AlwaysComptime` (Part I §7, `M-Distinct`).
/// Returns false on a refused allocation, `e` then holding some of its components.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.components.ast;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// assert(attachBuiltinType(store, e, e, doir.components.ast.ReservedUnique.type));
/// assert(ecrs.context.getComponent!(doir.components.ast.TypeOf)(store, e).type == e);
/// ---
bool attachBuiltinType(T)(ref ecrs.context.Context store, EntityId e, T type, doir.components.ast.ReservedUnique unique) {
	assert(unique != doir.components.ast.ReservedUnique.structural && unique < doir.components.ast.ReservedUnique.firstFresh, "doir.builders: a builtin type's identity outside the reserved ones");
	if (attachAggregate(store, e, type).block == invalidEntity) return false;
	ecrs.context.getForWriting!(doir.components.ast.TypeDefinition)(store, e).unique = unique;
	assert(ecrs.context.getComponent!(doir.components.ast.TypeDefinition)(store, e).unique == unique, "doir.builders: a builtin type that lost its identity");
	return addFlags(store, e, doir.components.ast.Flags.Comptime | doir.components.ast.Flags.AlwaysComptime);
}

/// Appends a builtin type to `b`'s block; see `attachBuiltinType`.
/// Returns `invalidEntity` on a refused allocation.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.components.ast;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// auto t = pushBuiltinType(root, StringId(0), StringId(0), doir.components.ast.ReservedUnique.deducedType);
/// assert(ecrs.context.getComponent!(doir.components.ast.TypeDefinition)(store, t).unique == doir.components.ast.ReservedUnique.deducedType);
/// ---
EntityId pushBuiltinType(T)(ref BlockBuilder b, StringId name, T type, doir.components.ast.ReservedUnique unique) {
	immutable e = pushDeclaration(b, name);
	return e != invalidEntity && attachBuiltinType(*b.store, e, type, unique) ? e : invalidEntity;
}

/// Makes `e` a function type such as `(a: std.u8, b: std.u8) -> std.u8`, with no parameters and no return type yet, for `pushParameter` and `setReturnType` to fill in.
/// Returns false on a refused allocation, `e` then holding some of its components.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.components.ast;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// assert(attachFunctionType(store, e, StringId(0)));
/// assert(ecrs.context.hasComponent!(doir.components.ast.FunctionInputs)(store, e));
/// ---
bool attachFunctionType(T)(ref ecrs.context.Context store, EntityId e, T type) {
	assert(!ecrs.context.hasComponent!(doir.components.ast.FunctionInputs)(store, e), "doir.builders: a second function type on one entity");
	return setType(store, e, type) && ecrs.context.addComponent!(doir.components.ast.TypeDefinition)(store, e) !is null && ecrs.context.addComponent!(doir.components.ast.FunctionInputs)(store, e) !is null;
}

/// Appends the named function type `add_t : type = (a: std.u8, b: std.u8) -> std.u8` to `b`'s block; see `attachFunctionType`.
/// Returns `invalidEntity` on a refused allocation.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.components.ast;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// auto functionType = pushFunctionType(root, StringId(0), StringId(1));
/// assert(ecrs.context.hasComponent!(doir.components.ast.TypeDefinition)(store, functionType));
/// ---
EntityId pushFunctionType(T)(ref BlockBuilder b, StringId name, T type) {
	immutable e = pushDeclaration(b, name);
	return e != invalidEntity && attachFunctionType(*b.store, e, type) ? e : invalidEntity;
}

/// `x : (a: T) -> U = ...`: a function type written in place, the declared type of `owner`, which it takes as its `Parent` (`WF-Par`).
/// Set it as `owner`'s type with `setType`.
/// On a refused allocation returns `invalidEntity`.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.components.ast;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// auto x = pushDeclaration(root, StringId(0));
/// auto functionType = createFunctionType(store, x, StringId(1));
/// assert(setType(store, x, functionType));
/// assert(ecrs.context.getComponent!(doir.components.ast.Parent)(store, functionType).parent == x);
/// ---
EntityId createFunctionType(T)(ref ecrs.context.Context store, EntityId owner, T type) {
	assert(owner != invalidEntity, "doir.builders: a function type written in place of no declaration");
	immutable e = ecrs.context.addEntity(store);
	if (e == invalidEntity) return invalidEntity;
	if (attachInPlaceFunctionType(store, e, owner, type)) return e;
	cast(void) ecrs.context.removeEntity(store, e); // if refused, an orphan nothing reaches
	return invalidEntity;
}

/// Makes `e` a function type written in place as `owner`'s type; see `createFunctionType`, which is this on a fresh entity.
/// A reparse uses it to keep the entity's id.
/// Returns false if the store refused it, possibly leaving `e` with some of the components.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.components.ast;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto owner = ecrs.context.addEntity(store), functionType = ecrs.context.addEntity(store);
/// assert(attachInPlaceFunctionType(store, functionType, owner, StringId(1)));
/// assert(ecrs.context.getComponent!(doir.components.ast.Parent)(store, functionType).parent == owner);
/// ---
bool attachInPlaceFunctionType(T)(ref ecrs.context.Context store, EntityId e, EntityId owner, T type) {
	assert(e != invalidEntity && owner != invalidEntity && e != owner, "doir.builders: a function type that owns itself (WF-Par)");
	return ecrs.context.setComponent!(doir.components.ast.Parent)(store, e, doir.components.ast.Parent([owner])) && attachFunctionType(store, e, type);
}

/// Appends parameter `name : type` to function type `functionType` (`R-Param`) and returns it, valueless; give it a default with `setDefault`.
/// A deduced parameter passes `deducedTypeName`, interned, as its type.
/// On a refused allocation returns `invalidEntity`, leaving `functionType` as it was.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.components.ast;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// assert(attachFunctionType(store, e, StringId(2)));
/// auto a = pushParameter(store, e, StringId(0), StringId(1));
/// assert(ecrs.context.getComponent!(doir.components.ast.FunctionInputs)(store, e).related[0] == a);
/// assert(ecrs.context.getComponent!(doir.components.ast.Parent)(store, a).parent == e);
/// ---
EntityId pushParameter(T)(ref ecrs.context.Context store, EntityId functionType, StringId name, T type) {
	assert(ecrs.context.hasComponent!(doir.components.ast.FunctionInputs)(store, functionType), "doir.builders: a parameter of something that is not a function type (R-Param)");
	immutable e = ecrs.context.addEntity(store);
	if (e == invalidEntity) return invalidEntity;
	if (attachParameter(store, e, functionType, name, type)) return e;
	cast(void) ecrs.context.removeEntity(store, e); // if refused, an orphan nothing reaches
	return invalidEntity;
}

/// Makes `e` the next parameter of `functionType`; see `pushParameter`, which is this on a fresh entity.
/// A reparse uses it to keep the entity's id.
/// Returns false if the store refused it, leaving `functionType`'s inputs as they were but possibly leaving `e` with some of the components.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.components.ast;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto functionType = ecrs.context.addEntity(store), p = ecrs.context.addEntity(store);
/// assert(attachFunctionType(store, functionType, StringId(0)));
/// assert(attachParameter(store, p, functionType, StringId(1), StringId(2)));
/// assert(ecrs.context.getComponent!(doir.components.ast.FunctionInputs)(store, functionType).related[0] == p);
/// ---
bool attachParameter(T)(ref ecrs.context.Context store, EntityId e, EntityId functionType, StringId name, T type) {
	assert(e != invalidEntity && e != functionType && ecrs.context.hasComponent!(doir.components.ast.FunctionInputs)(store, functionType), "doir.builders: a parameter of something that is not a function type (R-Param)");
	immutable attached = (name == unnamed || ecrs.context.setComponent!(doir.components.ast.Name)(store, e, doir.components.ast.Name(name)))
		&& ecrs.context.setComponent!(doir.components.ast.Parent)(store, e, doir.components.ast.Parent([functionType]))
		&& attachValueless(store, e, type)
		&& fp.dynarray.pushBack(ecrs.context.getForWriting!(doir.components.ast.FunctionInputs)(store, functionType).related, e);
	assert(!attached || *fp.dynarray.back(ecrs.context.getComponent!(doir.components.ast.FunctionInputs)(store, functionType).related) == e, "doir.builders: a parameter missing from the end of its inputs (R-Param)");
	return attached;
}

/// Gives parameter `p` the default `= 5` or `= y` (`F-Default`), replacing its `Valueless`.
/// Returns false if the store refused it, leaving `p` as it was.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.components.ast;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto functionType = ecrs.context.addEntity(store);
/// assert(attachFunctionType(store, functionType, StringId(2)));
/// auto p = pushParameter(store, functionType, StringId(0), StringId(1));
/// assert(setDefault(store, p, doir.components.ast.ConstantVal.integer(5)));
/// assert(ecrs.context.getComponent!(doir.components.ast.Flags)(store, p).flags == doir.components.ast.Flags.Comptime);
/// ---
bool setDefault(ref ecrs.context.Context store, EntityId p, doir.components.ast.ConstantVal value) {
	assert(ecrs.context.hasComponent!(doir.components.ast.Parent)(store, p) && ecrs.context.hasComponent!(doir.components.ast.Flags)(store, p), "doir.builders: a default for something that is not a parameter (F-Default)");
	if (!ecrs.context.setComponent!(doir.components.ast.ConstantVal)(store, p, value)) return false;
	auto set = &ecrs.context.getForWriting!(doir.components.ast.Flags)(store, p);
	set.flags = (set.flags & ~doir.components.ast.Flags.Valueless) | doir.components.ast.Flags.Comptime;
	assert(!(set.flags & doir.components.ast.Flags.Valueless), "doir.builders: a parameter with a default that is still valueless");
	return true;
}

/// Ditto
bool setDefault(ref ecrs.context.Context store, EntityId p, StringId value) {
	assert(ecrs.context.hasComponent!(doir.components.ast.Parent)(store, p) && ecrs.context.hasComponent!(doir.components.ast.Flags)(store, p), "doir.builders: a default for something that is not a parameter (F-Default)");
	if (!ecrs.context.setComponent!(doir.components.ast.LookupValue)(store, p, doir.components.ast.LookupValue(value))) return false;
	ecrs.context.getForWriting!(doir.components.ast.Flags)(store, p).flags &= ~doir.components.ast.Flags.Valueless;
	assert(!(ecrs.context.getComponent!(doir.components.ast.Flags)(store, p).flags & doir.components.ast.Flags.Valueless), "doir.builders: a parameter with a default that is still valueless");
	return true;
}

// wrapper: picks the component a type named or given by entity sets, for callers generic over both
/// Gives function type `functionType` the return type written after `->`; without one it returns `void`.
/// Returns false if the store refused it, leaving `functionType` as it was.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.components.ast;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto functionType = ecrs.context.addEntity(store);
/// assert(attachFunctionType(store, functionType, StringId(1)));
/// assert(setReturnType(store, functionType, StringId(2)));
/// assert(ecrs.context.getComponent!(doir.components.ast.LookupFunctionReturn)(store, functionType).name == StringId(2));
/// ---
bool setReturnType(ref ecrs.context.Context store, EntityId functionType, StringId type) {
	assert(ecrs.context.hasComponent!(doir.components.ast.FunctionInputs)(store, functionType), "doir.builders: a return type for something that is not a function type");
	return ecrs.context.setComponent!(doir.components.ast.LookupFunctionReturn)(store, functionType, doir.components.ast.LookupFunctionReturn(type));
}

// wrapper: as above
/// Ditto
bool setReturnType(ref ecrs.context.Context store, EntityId functionType, EntityId type) {
	assert(ecrs.context.hasComponent!(doir.components.ast.FunctionInputs)(store, functionType) && type != invalidEntity && type != functionType, "doir.builders: a return type for something that is not a function type");
	return ecrs.context.setComponent!(doir.components.ast.FunctionReturn)(store, functionType, doir.components.ast.FunctionReturn([type]));
}


// --- aliases and namespaces --------------------------------------------------

/// Appends the alias `color : alias = vec3` to `b`'s block; it carries no type (`WF-Kind`).
/// Returns `invalidEntity` on a refused allocation.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.components.ast;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// auto e = pushAlias(root, StringId(0), StringId(1));
/// assert(!ecrs.context.hasComponent!(doir.components.ast.LookupTypeOf)(store, e));
/// ---
EntityId pushAlias(ref BlockBuilder b, StringId name, StringId target) {
	assert(target != unnamed, "doir.builders: an alias of no name");
	immutable e = pushDeclaration(b, name);
	return e != invalidEntity && ecrs.context.setComponent!(doir.components.ast.LookupAlias)(*b.store, e, doir.components.ast.LookupAlias(target)) ? e : invalidEntity;
}

/// Makes `e` the namespace `math : namespace = { ... }`, which carries no type (`WF-Kind`).
/// Returns a builder for its contents.
/// On a refused allocation its `block` is `invalidEntity`, `e` then holding some of its components.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.components.ast;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto e = ecrs.context.addEntity(store);
/// auto math = attachNamespace(store, e);
/// assert(ecrs.context.getComponent!(doir.components.ast.Flags)(store, math.block).flags == doir.components.ast.Flags.Namespace);
/// ---
BlockBuilder attachNamespace(ref ecrs.context.Context store, EntityId e) {
	assert(e != invalidEntity, "doir.builders: building on no entity");
	assert(!ecrs.context.hasComponent!(doir.components.ast.Block)(store, e), "doir.builders: a namespace over a declaration that has a block");
	return addFlags(store, e, doir.components.ast.Flags.Namespace) && ecrs.context.addComponent!(doir.components.ast.Block)(store, e) !is null ? BlockBuilder(&store, e) : BlockBuilder.init;
}

/// Appends a namespace to `b`'s block and returns a builder for its contents; see `attachNamespace`.
/// Reopening one is another call with the same name (`R-Merge`).
/// On a refused allocation its `block` is `invalidEntity`.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import doir.components.ast;
/// auto store = ecrs.context.create();
/// scope(exit) ecrs.context.free(store);
/// auto root = createRoot(store);
/// auto math = pushNamespace(root, StringId(0));
/// assert(ecrs.context.getComponent!(doir.components.ast.Parent)(store, math.block).parent == root.block);
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

	// identity : type = (T: deduced type, value: T) -> T ; id : identity
	auto root = createRoot(store);
	auto functionType = pushFunctionType(root, doir.strings.intern(strings, "identity"), doir.strings.intern(strings, "type"));
	auto t = pushParameter(store, functionType, doir.strings.intern(strings, "T"), doir.strings.intern(strings, doir.components.ast.deducedTypeName));
	auto value = pushParameter(store, functionType, doir.strings.intern(strings, "value"), doir.strings.intern(strings, "T"));
	assert(setReturnType(store, functionType, doir.strings.intern(strings, "T")));
	auto id = pushValueless(root, doir.strings.intern(strings, "id"), doir.strings.intern(strings, "identity"));
	assert(ecrs.context.getComponent!(doir.components.ast.FunctionInputs)(store, functionType).related[0 .. 2] == [t, value]);
	assert(doir.strings.text(strings, ecrs.context.getComponent!(doir.components.ast.LookupTypeOf)(store, t).name) == "deduced type");
	assert(ecrs.context.getComponent!(doir.components.ast.Block)(store, root.block).related[0 .. 2] == [functionType, id]);

	// Attaching to a declared entity matches pushing the same form.
	auto later = pushDeclaration(root, doir.strings.intern(strings, "later"));
	auto inner = attachBlock(store, later, doir.strings.intern(strings, "block"));
	assert(inner.block == later && ecrs.context.getComponent!(doir.components.ast.Block)(store, root.block).related[2] == later);
	assert(ecrs.context.getComponent!(doir.components.ast.LookupTypeOf)(store, later).name == doir.strings.intern(strings, "block"));

	// Renumbering rewrites every entity-valued component (E-Remap).
	assert(ecrs.context.swapEntities(store, functionType, value));
	assert(ecrs.context.getComponent!(doir.components.ast.Parent)(store, functionType).parent == value);
	assert(ecrs.context.getComponent!(doir.components.ast.FunctionInputs)(store, value).related[0 .. 2] == [t, functionType]);
	assert(ecrs.context.getComponent!(doir.components.ast.Block)(store, root.block).related[0] == value);
	assert(ecrs.context.swapEntities(store, functionType, value));

	// Builtin types are distinct by discriminator, deduced type included.
	auto builtin = createRoot(store);
	auto type = pushBuiltinType(builtin, doir.strings.intern(strings, "type"), doir.strings.intern(strings, "type"), doir.components.ast.ReservedUnique.type);
	auto deduced = pushBuiltinType(builtin, doir.strings.intern(strings, "deduced_type"), doir.strings.intern(strings, "type"), doir.components.ast.ReservedUnique.deducedType);
	assert(ecrs.context.getComponent!(doir.components.ast.TypeDefinition)(store, type).unique != ecrs.context.getComponent!(doir.components.ast.TypeDefinition)(store, deduced).unique);

	// A `_` parameter has no name; a default replaces Valueless.
	auto anonymous = pushParameter(store, functionType, unnamed, doir.strings.intern(strings, "std.u8"));
	assert(!ecrs.context.hasComponent!(doir.components.ast.Name)(store, anonymous));
	assert(setDefault(store, anonymous, doir.strings.intern(strings, "zero")));
	assert(ecrs.context.getComponent!(doir.components.ast.Flags)(store, anonymous).flags == doir.components.ast.Flags.None);

	// Types may be given resolved, as entities; a literal default makes the parameter comptime (C-Constant, F-Default).
	auto typed = pushValueless(root, doir.strings.intern(strings, "typed"), type);
	assert(ecrs.context.getComponent!(doir.components.ast.TypeOf)(store, typed).type == type);
	assert(setReturnType(store, functionType, type));
	assert(ecrs.context.getComponent!(doir.components.ast.FunctionReturn)(store, functionType).type == type);
	auto five = pushParameter(store, functionType, doir.strings.intern(strings, "five"), doir.strings.intern(strings, "std.u8"));
	assert(setDefault(store, five, doir.components.ast.ConstantVal.integer(5)));
	assert(ecrs.context.getComponent!(doir.components.ast.Flags)(store, five).flags == doir.components.ast.Flags.Comptime);
	assert(ecrs.context.getComponent!(doir.components.ast.ConstantVal)(store, five).integerValue == 5);

	// Aliases and namespaces carry no type (WF-Kind); a namespace's contents go in its own block.
	auto color = pushAlias(root, doir.strings.intern(strings, "color"), doir.strings.intern(strings, "vec3"));
	assert(ecrs.context.getComponent!(doir.components.ast.LookupAlias)(store, color).name == doir.strings.intern(strings, "vec3"));
	assert(!ecrs.context.hasComponent!(doir.components.ast.LookupTypeOf)(store, color));
	auto math = pushNamespace(root, doir.strings.intern(strings, "math"));
	auto pi = pushValueless(math, doir.strings.intern(strings, "pi"), doir.strings.intern(strings, "std.f64"));
	assert(ecrs.context.getComponent!(doir.components.ast.Flags)(store, math.block).flags == doir.components.ast.Flags.Namespace);
	assert(ecrs.context.getComponent!(doir.components.ast.Parent)(store, pi).parent == math.block);
	assert(!ecrs.context.hasComponent!(doir.components.ast.LookupTypeOf)(store, math.block));

	// A refused allocation is reported, and leaves the block or the function type without the declaration.
	static import fp.dynarray;
	bool refusedOnce = false;
	foreach (n; 0 .. 8) {
		immutable declarations = fp.dynarray.length(ecrs.context.getComponent!(doir.components.ast.Block)(store, root.block).related);
		immutable parameters = fp.dynarray.length(ecrs.context.getComponent!(doir.components.ast.FunctionInputs)(store, functionType).related);
		auto previous = fp.testing.limitAllocations(n);
		immutable d = pushDeclaration(root, doir.strings.intern(strings, "refused"));
		immutable p = pushParameter(store, functionType, doir.strings.intern(strings, "refused"), doir.strings.intern(strings, "std.u8"));
		fp.testing.restoreAllocator(previous);
		assert(fp.dynarray.length(ecrs.context.getComponent!(doir.components.ast.Block)(store, root.block).related) == declarations + (d != invalidEntity));
		assert(fp.dynarray.length(ecrs.context.getComponent!(doir.components.ast.FunctionInputs)(store, functionType).related) == parameters + (p != invalidEntity));
		refusedOnce |= d == invalidEntity || p == invalidEntity;
	}
	assert(refusedOnce);

	// A refused root leaves at most an orphan without a `Block`, when its removal is refused too.
	for (size_t n = 0;; ++n) {
		assert(n < 100);
		auto fresh = ecrs.context.create();
		scope(exit) ecrs.context.free(fresh);
		auto previous = fp.testing.limitAllocations(n);
		auto made = createRoot(fresh);
		fp.testing.restoreAllocator(previous);
		if (made.block != invalidEntity) break;
		assert(made.store is null);
		assert(ecrs.context.entityCount(fresh) <= 1 || !ecrs.context.hasComponent!(doir.components.ast.Block)(fresh, 1));
	}
}
