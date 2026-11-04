/// Lexical positions as order keys (`C-Order`, `M-Lexical`, `L-Freeze`): every declaration of a file gets a `Position`, and positions totally order a file's declarations in preorder, a block's contents after the block and before its next sibling.
///
/// A position is not an ordinal. A new one can always be made between two neighbours, so inserting a declaration gives it a key between theirs and leaves every other key, and every log entry positioned by one, as it was (`roadmap.md` Phase 1).
///
/// A key is a sequence of digit segments, one per nesting level, each segment ending in a 0 digit; the other digits are at least 1, and a segment never ends in digit 1, so there is always room below it. Keys are interned, so equal keys have equal `Position`s and a position compares and hashes as a number inside a query key.
///
/// Examples:
/// ---
/// Positions positions;
/// scope(exit) free(positions);
/// immutable a = between(positions, root, none, none);
/// immutable c = between(positions, root, a, none);
/// immutable b = between(positions, root, a, c);
/// immutable inA = between(positions, a, none, none);
/// assert(precedes(positions, a, inA) && precedes(positions, inA, b) && precedes(positions, b, c));
/// ---
module doir.engine.positions;

static import fp.pointer;
version(unittest) static import fp.testing;

static import bc.interner;


@nogc nothrow:


// --- types and layout --------------------------------------------------------

/// An interned order key. Compare two with `compare` or `precedes`, never by `value`.
struct Position {
	uint value = uint.max; /// The key's index in its `Positions` table.
}

/// The empty key: the position of a file's root block, before every declaration in it and the parent of its top-level declarations.
enum Position root = Position(0);

/// No position: an open bound to `between`, and the greatest position, after every declaration. A read at `none` sees every effect.
enum Position none = Position.init;

// Digits are 1 .. maxDigit; maxDigit + 1 still fits, so a midpoint never overflows.
private enum ulong maxDigit = ulong.max - 1;

/// The interning table of order keys. Any thread may make positions at once (`bc.interner`); `free` it from one thread. It holds no entity ids, so `E-Remap` leaves it alone.
struct Positions {
	private bc.interner.Interner!ulong keys; // the key of Position(i + 1) is id i; root has no storage
}


// --- queries -----------------------------------------------------------------

private const(ulong)[] digitsOf(ref const Positions positions, Position p) @trusted {
	if (p == root) return null;
	assert(p != none);
	return bc.interner.content(positions.keys, p.value - 1);
}

/// Orders `a` and `b`: negative if `a` comes first, zero if they are the same position, positive otherwise. `none` comes after every other position.
///
/// Examples:
/// ---
/// Positions positions;
/// scope(exit) free(positions);
/// immutable a = between(positions, root, none, none);
/// assert(compare(positions, root, a) < 0 && compare(positions, a, none) < 0 && compare(positions, a, a) == 0);
/// ---
int compare(ref const Positions positions, Position a, Position b) {
	if (a == b) return 0;
	if (a == none) return 1;
	if (b == none) return -1;
	auto x = digitsOf(positions, a), y = digitsOf(positions, b);
	foreach (i; 0 .. x.length < y.length ? x.length : y.length)
		if (x[i] != y[i]) return x[i] < y[i] ? -1 : 1;
	return x.length < y.length ? -1 : 1;
}

/// Whether `a` comes strictly before `b`: whether an effect at `a` is visible to a read at `b` (`C-Order`, `L-Freeze`).
///
/// Examples:
/// ---
/// Positions positions;
/// scope(exit) free(positions);
/// immutable a = between(positions, root, none, none);
/// assert(precedes(positions, a, none) && !precedes(positions, a, a));
/// ---
bool precedes(ref const Positions positions, Position a, Position b) {
	return compare(positions, a, b) < 0;
}


// --- creation and freeing ----------------------------------------------------

private Position intern(ref Positions positions, ulong* digits) {
	immutable id = bc.interner.intern(positions.keys, fp.dynarray.slice(digits));
	return id == bc.interner.none ? none : Position(id + 1);
}

// The segment of `child`'s key below `parent`, without its terminating 0.
private const(ulong)[] localOf(ref const Positions positions, Position parent, Position child) {
	auto p = digitsOf(positions, parent), c = digitsOf(positions, child);
	assert(c.length > p.length && c[0 .. p.length] == p && c[$ - 1] == 0, "doir.engine.positions: sibling is not a child of parent");
	return c[p.length .. $ - 1];
}

/// A new position for a child of `parent`, after sibling `previous` and before sibling `next`; pass `none` for either to leave that side open. `previous` must come before `next`, and both must be children of `parent`. The same arguments give the same position.
///
/// Returns `none` if allocation fails, leaving `positions` as it was.
///
/// Examples:
/// ---
/// Positions positions;
/// scope(exit) free(positions);
/// immutable first = between(positions, root, none, none);
/// immutable before = between(positions, root, none, first);
/// assert(precedes(positions, before, first));
/// assert(between(positions, root, none, first) == before);
/// ---
Position between(ref Positions positions, Position parent, Position previous, Position next) @trusted {
	auto lo = previous == none ? null : localOf(positions, parent, previous);
	auto hi = next == none ? null : localOf(positions, parent, next);
	assert(previous == none || next == none || precedes(positions, previous, next));

	ulong* digits = null;
	scope(exit) fp.dynarray.free(digits);
	if (!fp.dynarray.concatenate(digits, digitsOf(positions, parent))) return none;
	bool bounded = next != none;
	for (size_t i = 0;; ++i) {
		// Past the end of `lo`, a virtual 0 sits below every digit.
		immutable ulong a = i < lo.length ? lo[i] : 0;
		assert(!bounded || i < hi.length);
		immutable ulong b = bounded ? hi[i] : maxDigit + 1;
		ulong mid = a + (b - a) / 2;
		if (mid < 2) mid = 2; // a key never ends in digit 1
		ulong digit;
		bool done = false;
		if (a == b) digit = a;
		else if (mid > a && mid < b) {
			digit = mid;
			done = true;
		} else if (a == 0) {
			// `lo` has ended and `b` is 1 or 2: take 1, which leaves `hi` behind only if `b` is 2.
			digit = 1;
			if (b > 1) bounded = false;
		} else {
			digit = a;
			bounded = false;
		}
		if (!fp.dynarray.pushBack(digits, digit)) return none;
		if (done) break;
	}
	if (!fp.dynarray.pushBack(digits, 0UL)) return none;
	return intern(positions, digits);
}

/// Releases every key and the table, leaving `positions` empty and reusable.
///
/// Examples:
/// ---
/// Positions positions;
/// cast(void) between(positions, root, none, none);
/// free(positions);
/// ---
void free(ref Positions positions) {
	bc.interner.free(positions.keys);
}



unittest {
	Positions positions;
	scope(exit) free(positions);

	// Repeated insertion at the front, at the back and in one gap keeps a strict order.
	enum n = 200;
	Position[n * 3] order;
	size_t count = 0;
	Position first = between(positions, root, none, none), last = first;
	order[count++] = first;
	foreach (i; 0 .. n) {
		first = between(positions, root, none, first);
		last = between(positions, root, last, none);
		order[count++] = first;
		order[count++] = last;
	}
	Position lo = first, hi = between(positions, root, first, none);
	foreach (i; 0 .. n) {
		immutable mid = between(positions, root, lo, hi);
		assert(precedes(positions, lo, mid) && precedes(positions, mid, hi));
		if (i % 2) lo = mid; else hi = mid;
	}
	foreach (i; 0 .. count)
		foreach (j; 0 .. count)
			assert((compare(positions, order[i], order[j]) == 0) == (order[i] == order[j]));

	// Children sort after their parent and before its next sibling, at any depth.
	immutable a = between(positions, root, none, none);
	immutable b = between(positions, root, a, none);
	immutable ab = between(positions, root, a, b);
	immutable inA = between(positions, a, none, none);
	immutable deep = between(positions, inA, none, none);
	immutable inAb = between(positions, ab, none, none);
	assert(precedes(positions, a, inA) && precedes(positions, inA, deep) && precedes(positions, deep, ab));
	assert(precedes(positions, ab, inAb) && precedes(positions, inAb, b));
	assert(precedes(positions, root, a) && precedes(positions, b, none));

	// A refused allocation at any step leaves the positions as they were; budgets cover every step at every table size.
	Positions rationed;
	scope(exit) free(rationed);
	Position previous = none;
	foreach (i; 0 .. 100) {
		for (size_t budget = 0;; ++budget) {
			auto allocator = fp.testing.beginRationedAllocator(budget);
			immutable next = between(rationed, root, previous, none);
			fp.testing.endRationedAllocator(allocator);
			if (next != none) {
				assert(next.value == i + 1 && (previous == none || precedes(rationed, previous, next)));
				previous = next;
				break;
			}
			assert(bc.interner.count(rationed.keys) == i);
		}
	}
}
