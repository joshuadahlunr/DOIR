/// What the language server's features ask of the store (`roadmap.md` Phase 3): the declarations at a position, found through each block's `SourceSpan`s, and what a name read there resolves to.
module doir.lsp.store;

static import fp.algorithms;
static import fp.dynarray;

static import ecrs.context;

static import doir.components.ast;
static import doir.components.source;
static import doir.lsp.session;
static import doir.source;

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
