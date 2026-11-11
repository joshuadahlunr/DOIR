/// What the language server's features ask of the store (`roadmap.md` Phase 3): the declarations at a position, found through each block's `SourceSpan`s, and what a name read there resolves to.
module doir.lsp.store;

static import fp.algorithms;
static import fp.dynarray;
static import fp.pointer;
static import fp.rope;
static import fp.string;

static import ecrs.context;

static import doir.components.ast;
static import doir.components.source;
static import doir.lsp.session;
static import doir.names;
static import doir.source;
static import doir.strings;
static import doir.syntax.lexer;

public import ecrs.registry : EntityId, invalidEntity;

@nogc nothrow:


// --- the tree ----------------------------------------------------------------

/// A declaration found in the tree, with its absolute span; `e` is `invalidEntity` when none was.
package(doir) struct Found {
	EntityId e; ///
	size_t start, end; ///
}

/// The children of block `e`, or none if it is not a block.
///
/// Examples:
/// ---
/// doir.lsp.session.Fixture f;
/// assert(doir.lsp.session.open(f, "x : T = 1\ny : T = 2\n"));
/// scope(exit) doir.lsp.session.free(f);
/// assert(childrenOf(f.s, doir.source.rootOf(f.engine, f.s.opened[0].file)).length == 2);
/// ---
package(doir) const(EntityId)[] childrenOf(ref doir.lsp.session.Session s, EntityId e) {
	auto block = ecrs.context.findComponent!(doir.components.ast.Block)(*s.engine.store, e);
	return block is null ? null : fp.dynarray.slice(block.related);
}

/// How many of `children`, whose parent starts at `base`, start at or before byte `at`.
///
/// Examples:
/// ---
/// doir.lsp.session.Fixture f;
/// assert(doir.lsp.session.open(f, "x : T = 1\ny : T = 2\n"));
/// scope(exit) doir.lsp.session.free(f);
/// auto children = childrenOf(f.s, doir.source.rootOf(f.engine, f.s.opened[0].file));
/// assert(childrenBefore(f.s, children, 0, 12) == 2);
/// ---
package(doir) size_t childrenBefore(ref doir.lsp.session.Session s, const(EntityId)[] children, size_t base, size_t at) {
	return fp.algorithms.upperBound!((offset, child) => offset < base + ecrs.context.getComponent!(doir.components.source.SourceSpan)(*s.engine.store, child).offset)(children, at);
}

/// The last child of `parent`, which starts at `base`, starting at or before byte `at`, or a null `Found`.
///
/// Examples:
/// ---
/// doir.lsp.session.Fixture f;
/// assert(doir.lsp.session.open(f, "x : T = 1\ny : T = 2\n"));
/// scope(exit) doir.lsp.session.free(f);
/// auto y = childAt(f.s, doir.source.rootOf(f.engine, f.s.opened[0].file), 0, 12);
/// assert(y.start == 10 && y.end == 19);
/// ---
package(doir) Found childAt(ref doir.lsp.session.Session s, EntityId parent, size_t base, size_t at) {
	auto children = childrenOf(s, parent);
	immutable n = childrenBefore(s, children, base, at);
	if (n == 0) return Found(invalidEntity);
	immutable span = ecrs.context.getComponent!(doir.components.source.SourceSpan)(*s.engine.store, children[n - 1]);
	return Found(children[n - 1], base + span.offset, base + span.offset + span.length);
}

/// The declarations enclosing byte `at` of `file`, outermost first, each containing it, as an fp dynarray; `boundary` is where the last declaration starting at or before `at` starts, a place the whole file's tokens begin at, or 0. On refusal the chain stops short and `s.refused` is set.
///
/// Examples:
/// ---
/// static import fp.dynarray;
/// doir.lsp.session.Fixture f;
/// assert(doir.lsp.session.open(f, "n : namespace = {\n\tx : T = 1\n}\n"));
/// scope(exit) doir.lsp.session.free(f);
/// size_t boundary;
/// Found* chain = enclosingAt(f.s, f.s.opened[0].file, 20, boundary);
/// scope(exit) fp.dynarray.free(chain);
/// assert(fp.dynarray.length(chain) == 2 && boundary == 19);
/// ---
package(doir) Found* enclosingAt(ref doir.lsp.session.Session s, EntityId file, size_t at, out size_t boundary) {
	Found* chain = null;
	auto parent = doir.source.rootOf(*s.engine, file);
	size_t base = 0;
	for (;;) {
		immutable child = childAt(s, parent, base, at);
		if (child.e == invalidEntity) return chain;
		boundary = child.start;
		if (at >= child.end) return chain;
		if (!fp.dynarray.pushBack(chain, child)) {
			s.refused = true;
			return chain;
		}
		parent = child.e;
		base = child.start;
	}
}

/// The LSP SymbolKind of declaration `e`.
///
/// Examples:
/// ---
/// doir.lsp.session.Fixture f;
/// assert(doir.lsp.session.open(f, "n : namespace = {}\n"));
/// scope(exit) doir.lsp.session.free(f);
/// assert(symbolKind(f.s, childrenOf(f.s, doir.source.rootOf(f.engine, f.s.opened[0].file))[0]) == 3);
/// ---
package(doir) long symbolKind(ref doir.lsp.session.Session s, EntityId e) {
	auto store = s.engine.store;
	auto flags = ecrs.context.findComponent!(doir.components.ast.Flags)(*store, e);
	if (flags !is null && (flags.flags & doir.components.ast.Flags.Namespace)) return 3; // Namespace
	immutable block = ecrs.context.hasComponent!(doir.components.ast.Block)(*store, e);
	if (block && ecrs.context.hasComponent!(doir.components.ast.TypeDefinition)(*store, e)) return 23; // Struct
	if (auto type = ecrs.context.findComponent!(doir.components.ast.TypeOf)(*store, e))
		if (ecrs.context.hasComponent!(doir.components.ast.FunctionInputs)(*store, type.type)) return 12; // Function
	if (block) return 19; // Object
	if (ecrs.context.hasComponent!(doir.components.ast.ConstantVal)(*store, e)) return 14; // Constant
	return 13; // Variable
}


// --- names -------------------------------------------------------------------

// The entry of `block`, starting at `base`, named `id`, or a null `Found`.
private Found entryNamed(ref doir.lsp.session.Session s, EntityId block, size_t base, doir.strings.StringId id) {
	immutable child = doir.names.entryNamed(*s.engine, block, id);
	if (child == invalidEntity) return Found(invalidEntity);
	immutable span = ecrs.context.getComponent!(doir.components.source.SourceSpan)(*s.engine.store, child);
	return Found(child, base + span.offset, base + span.offset + span.length);
}

/// The declaration named `name` that a read at byte `at` of `file` finds: the first segment looked up outward through the enclosing blocks, the rest through each found block's own entries.
/// A null `Found` if none is.
///
/// Examples:
/// ---
/// doir.lsp.session.Fixture f;
/// assert(doir.lsp.session.open(f, "n : namespace = {\n\tx : T = 1\n}\ny : T = n.x\n"));
/// scope(exit) doir.lsp.session.free(f);
/// assert(resolve(f.s, f.s.opened[0].file, 40, "n.x").start == 19);
/// ---
package(doir) Found resolve(ref doir.lsp.session.Session s, EntityId file, size_t at, const(char)[] name) {
	size_t boundary;
	Found* chain = enclosingAt(s, file, at, boundary);
	scope(exit) fp.dynarray.free(chain);
	size_t dot = fp.string.find(name, '.');
	if (dot == fp.pointer.notFound) dot = name.length;
	immutable first = doir.strings.find(*s.strings, name[0 .. dot]);
	if (first == doir.strings.unnamed) return Found(invalidEntity);
	Found found = Found(invalidEntity);
	for (size_t level = fp.dynarray.length(chain) + 1; level-- > 0 && found.e == invalidEntity;)
		found = level == 0 ? entryNamed(s, doir.source.rootOf(*s.engine, file), 0, first) : entryNamed(s, chain[level - 1].e, chain[level - 1].start, first);
	while (found.e != invalidEntity && dot < name.length) {
		name = name[dot + 1 .. $];
		dot = fp.string.find(name, '.');
		if (dot == fp.pointer.notFound) dot = name.length;
		immutable next = doir.strings.find(*s.strings, name[0 .. dot]);
		found = next == doir.strings.unnamed ? Found(invalidEntity) : entryNamed(s, found.e, found.start, next);
	}
	return found;
}

/// The identifier, dotted names included, that byte `at` of `text` is in, as a new fp string, and where it starts; null if there is none, or on refusal.
///
/// Examples:
/// ---
/// static import fp.string;
/// doir.lsp.session.Fixture f;
/// assert(doir.lsp.session.open(f, "y : T = n.x\n"));
/// scope(exit) doir.lsp.session.free(f);
/// size_t start;
/// char* name = identifierAt(doir.source.textOf(f.engine, f.s.opened[0].file), 9, start);
/// scope(exit) fp.string.free(name);
/// assert(fp.string.slice(name) == "n.x" && start == 8);
/// ---
package(doir) char* identifierAt(const fp.rope.Rope text, size_t at, out size_t start) {
	immutable lineStart = fp.rope.lineStart(text, fp.rope.lineOf(text, at));
	immutable lineEnd = fp.rope.lineEnd(text, at);
	char* bytes = fp.rope.text(text, lineStart, lineEnd).get(null);
	scope(exit) fp.string.free(bytes);
	if (bytes is null) return null;
	auto source = bytes[0 .. lineEnd - lineStart];
	auto cursor = doir.syntax.lexer.Cursor(source);
	while (cursor.at < source.length) {
		immutable t = doir.syntax.lexer.next(cursor);
		if (t.kind != doir.syntax.lexer.TokenKind.identifier || lineStart + t.start > at || lineStart + t.start + t.length < at) continue;
		start = lineStart + t.start;
		return fp.string.clone(doir.syntax.lexer.text(t, source)).get(null);
	}
	return null;
}

/// A declaration `declarationAt` found, and the identifier naming it: bytes `start` to `end`.
package(doir) struct Named {
	Found declaration; ///
	size_t start, end; ///
}

/// The declaration the whole identifier at byte `at` of `file` names, as `resolve` finds it, and where that identifier is; a null `declaration` if there is none there, or on refusal.
///
/// Examples:
/// ---
/// doir.lsp.session.Fixture f;
/// assert(doir.lsp.session.open(f, "x : T = 1\ny : T = x\n"));
/// scope(exit) doir.lsp.session.free(f);
/// immutable named = declarationAt(f.s, f.s.opened[0].file, 18);
/// assert(named.declaration.start == 0 && named.start == 18 && named.end == 19);
/// ---
package(doir) Named declarationAt(ref doir.lsp.session.Session s, EntityId file, size_t at) {
	size_t start;
	char* name = identifierAt(doir.source.textOf(*s.engine, file), at, start);
	scope(exit) fp.string.free(name);
	if (name is null) return Named(Found(invalidEntity));
	return Named(resolve(s, file, at, fp.string.slice(name)), start, start + fp.string.length(name));
}


// --- functions ---------------------------------------------------------------

/// The function type declaration `found` of `file` is declared with: written in place as its type, its value, or the one its type names (`WF-Par`); `invalidEntity` if none.
///
/// Examples:
/// ---
/// doir.lsp.session.Fixture f;
/// assert(doir.lsp.session.open(f, "g : (a: T) -> T\n"));
/// scope(exit) doir.lsp.session.free(f);
/// assert(functionTypeOf(f.s, f.s.opened[0].file, resolve(f.s, f.s.opened[0].file, 0, "g")) != invalidEntity);
/// ---
package(doir) EntityId functionTypeOf(ref doir.lsp.session.Session s, EntityId file, Found found) {
	auto store = s.engine.store;
	foreach (step; 0 .. 2) {
		if (auto t = ecrs.context.findComponent!(doir.components.ast.TypeOf)(*store, found.e))
			if (ecrs.context.hasComponent!(doir.components.ast.FunctionInputs)(*store, t.type)) return t.type;
		if (ecrs.context.hasComponent!(doir.components.ast.FunctionInputs)(*store, found.e)) return found.e;
		auto named = ecrs.context.findComponent!(doir.components.ast.LookupTypeOf)(*store, found.e);
		if (step == 1 || named is null) break;
		found = resolve(s, file, found.start, doir.strings.text(*s.strings, named.name));
		if (found.e == invalidEntity) break;
	}
	return invalidEntity;
}

/// The index among `inputs`, a function type's parameters, of the one a call's argument `argument` binds: deduced parameters are never written at a call (`D-Deduce`), so it is the `argument`th of the rest.
/// `inputs.length` if there is none.
///
/// Examples:
/// ---
/// static import ecrs.context;
/// static import fp.dynarray;
/// doir.lsp.session.Fixture f;
/// assert(doir.lsp.session.open(f, "g : (T: deduced type, a: T) -> T\n"));
/// scope(exit) doir.lsp.session.free(f);
/// immutable type = functionTypeOf(f.s, f.s.opened[0].file, resolve(f.s, f.s.opened[0].file, 0, "g"));
/// auto inputs = fp.dynarray.slice(ecrs.context.getComponent!(doir.components.ast.FunctionInputs)(f.store, type).related);
/// assert(parameterOf(f.s, inputs, 0) == 1 && parameterOf(f.s, inputs, 1) == 2);
/// ---
package(doir) size_t parameterOf(ref doir.lsp.session.Session s, const(EntityId)[] inputs, size_t argument) {
	foreach (i, p; inputs) {
		auto type = ecrs.context.findComponent!(doir.components.ast.LookupTypeOf)(*s.engine.store, p);
		if (type !is null && doir.strings.text(*s.strings, type.name) == doir.components.ast.deducedTypeName) continue;
		if (argument-- == 0) return i;
	}
	return inputs.length;
}
