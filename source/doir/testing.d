/// Test-only helpers shared by this repository's unittests. Compiled only under `-unittest`.
module doir.testing;

version(unittest):

static import fp.pointer;

@nogc nothrow:


// --- refused allocations -----------------------------------------------------

private __gshared fp.pointer.AllocFunction rationedUnderlying;
private __gshared size_t rationedRemaining;

private void* rationedAlloc(void* p, size_t size) {
	// Frees are always forwarded, or a test could not clean up after itself.
	if (size == 0) return rationedUnderlying(p, 0);
	if (rationedRemaining == 0) return null;
	--rationedRemaining;
	return rationedUnderlying(p, size);
}

/// For tests of refused allocations, as libfp's own: `beginRationedAllocator` makes `fp.pointer.allocFunction` grant only the next `n` allocations and refuse the rest, while still freeing; `endRationedAllocator` restores the allocator it returned.
///
/// Examples:
/// ---
/// static import fp.dynarray;
/// int* list = null;
/// auto previous = beginRationedAllocator(0);
/// assert(!fp.dynarray.pushBack(list, 1));
/// endRationedAllocator(previous);
/// assert(fp.dynarray.pushBack(list, 1));
/// fp.dynarray.free(list);
/// ---
package(doir) fp.pointer.AllocFunction beginRationedAllocator(size_t n) {
	fp.pointer.AllocFunction previous = fp.pointer.allocFunction;
	rationedUnderlying = previous;
	rationedRemaining = n;
	fp.pointer.allocFunction = &rationedAlloc;
	return previous;
}

/// Ditto
package(doir) void endRationedAllocator(fp.pointer.AllocFunction previous) {
	fp.pointer.allocFunction = previous;
}
