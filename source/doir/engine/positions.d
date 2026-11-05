/// Lexical positions as order keys (`C-Order`, `M-Lexical`, `L-Freeze`): every declaration of a file gets a `Position`, and positions totally order a file's declarations in preorder, a block's contents after the block and before its next sibling.
///
/// A position is not an ordinal.
/// A new one can always be made between two neighbours, so inserting a declaration gives it a key between theirs and leaves every other key, and every log entry positioned by one, as it was (`roadmap.md` Phase 1).
///
/// A key is a sequence of digit segments, one per nesting level, each segment ending in a 0 digit; the other digits are at least 1, and a segment never ends in digit 1, so there is always room below it.
/// Keys are interned, so equal keys have equal `Position`s and a position compares and hashes as a number inside a query key.
///
/// Examples:
/// ---
/// Positions positions;
/// scope(exit) free(positions);
/// immutable a = between(positions, root, end, end);
/// immutable c = between(positions, root, a, end);
/// immutable b = between(positions, root, a, c);
/// immutable inA = between(positions, a, end, end);
/// assert(precedes(positions, a, inA) && precedes(positions, inA, b) && precedes(positions, b, c));
/// ---
module doir.engine.positions;

static import fp.pointer;
version(unittest) static import fp.testing;

static import bc.interner;


@nogc nothrow:


// --- types and layout --------------------------------------------------------

/// An interned order key.
/// Compare two with `compare` or `precedes`, never by `value`.
struct Position {
	uint value = uint.max; /// The key's index in its `Positions` table.
}

/// The empty key: the position of a file's root block, before every declaration in it and the parent of its top-level declarations.
enum Position root = Position(0);

/// The greatest position, after every declaration: an open bound to `between`, and where an unpositioned effect applies.
/// A read at `end` sees every effect.
enum Position end = Position.init;

/// What `between` gives when an allocation is refused; no key has it.
enum Position refused = Position(uint.max - 1);

// Digits are 1 .. maxDigit; maxDigit + 1 still fits, so a midpoint never overflows.
private enum ulong maxDigit = ulong.max - 1;

/// The interning table of order keys.
/// Any thread may make positions at once (`bc.interner`); `free` it from one thread.
/// It holds no entity ids, so `E-Remap` leaves it alone.
struct Positions {
	private bc.interner.Interner!ulong keys; // the key of Position(i + 1) is id i; root has no storage
}


// --- queries -----------------------------------------------------------------

private const(ulong)[] digitsOf(ref const Positions positions, Position p) @trusted {
	if (p == root) return null;
	assert(p != end);
	return bc.interner.items(positions.keys, p.value - 1);
}

/// Orders `a` and `b`: negative if `a` comes first, zero if they are the same position, positive otherwise.
/// `end` comes after every other position.
///
/// Examples:
/// ---
/// Positions positions;
/// scope(exit) free(positions);
/// immutable a = between(positions, root, end, end);
/// assert(compare(positions, root, a) < 0 && compare(positions, a, end) < 0 && compare(positions, a, a) == 0);
/// ---
int compare(ref const Positions positions, Position a, Position b) {
	if (a == b) return 0;
	if (a == end) return 1;
	if (b == end) return -1;
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
/// immutable a = between(positions, root, end, end);
/// assert(precedes(positions, a, end) && !precedes(positions, a, a));
/// ---
bool precedes(ref const Positions positions, Position a, Position b) {
	return compare(positions, a, b) < 0;
}


// --- creation and freeing ----------------------------------------------------

private Position intern(ref Positions positions, const(ulong)[] digits) {
	immutable id = bc.interner.intern(positions.keys, digits);
	if (id == bc.interner.refused) return refused;
	assert(id + 1 < refused.value, "doir.engine.positions: more keys than a Position can name");
	return Position(id + 1);
}

// The segment of `child`'s key below `parent`, without its terminating 0.
private const(ulong)[] localOf(ref const Positions positions, Position parent, Position child) {
	auto p = digitsOf(positions, parent), c = digitsOf(positions, child);
	assert(c.length > p.length && c[0 .. p.length] == p && c[$ - 1] == 0, "doir.engine.positions: sibling is not a child of parent");
	return c[p.length .. $ - 1];
}

/// A new position for a child of `parent`, after sibling `previous` and before sibling `next`; pass `end` for either to leave that side open.
/// `previous` must come before `next`, and both must be children of `parent`.
/// The same arguments give the same position.
///
/// Returns `refused` if allocation fails, leaving `positions` as it was.
///
/// Examples:
/// ---
/// Positions positions;
/// scope(exit) free(positions);
/// immutable first = between(positions, root, end, end);
/// immutable before = between(positions, root, end, first);
/// assert(precedes(positions, before, first));
/// assert(between(positions, root, end, first) == before);
/// ---
Position between(ref Positions positions, Position parent, Position previous, Position next) @trusted {
	auto low = previous == end ? null : localOf(positions, parent, previous);
	auto high = next == end ? null : localOf(positions, parent, next);
	assert(previous == end || next == end || precedes(positions, previous, next));

	auto prefix = digitsOf(positions, parent);
	// The loop ends at most two digits past the longer sibling's, and a 0 terminates the key.
	immutable capacity = prefix.length + (low.length > high.length ? low.length : high.length) + 3;
	mixin fp.pointer.allocateOnStack!(ulong, "digits", "capacity");
	fp.pointer.copy(digits[0 .. prefix.length], prefix);
	size_t count = prefix.length;
	bool bounded = next != end;
	for (size_t i = 0;; ++i) {
		// Past the end of `low`, a virtual 0 sits below every digit.
		immutable ulong a = i < low.length ? low[i] : 0;
		assert(!bounded || i < high.length);
		immutable ulong b = bounded ? high[i] : maxDigit + 1;
		ulong middle = a + (b - a) / 2;
		if (middle < 2) middle = 2; // a key never ends in digit 1
		ulong digit;
		bool done = false;
		if (a == b) digit = a;
		else if (middle > a && middle < b) {
			digit = middle;
			done = true;
		} else if (a == 0) {
			// `low` has ended and `b` is 1 or 2: take 1, which leaves `high` behind only if `b` is 2.
			digit = 1;
			if (b > 1) bounded = false;
		} else {
			digit = a;
			bounded = false;
		}
		assert(count < capacity - 1);
		digits[count++] = digit;
		if (done) break;
	}
	digits[count++] = 0;
	return intern(positions, digits[0 .. count]);
}

/// Releases every key and the table, leaving `positions` empty and reusable.
///
/// Examples:
/// ---
/// Positions positions;
/// cast(void) between(positions, root, end, end);
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
	Position first = between(positions, root, end, end), last = first;
	order[count++] = first;
	foreach (i; 0 .. n) {
		first = between(positions, root, end, first);
		last = between(positions, root, last, end);
		order[count++] = first;
		order[count++] = last;
	}
	Position low = first, high = between(positions, root, first, end);
	foreach (i; 0 .. n) {
		immutable middle = between(positions, root, low, high);
		assert(precedes(positions, low, middle) && precedes(positions, middle, high));
		if (i % 2) low = middle; else high = middle;
	}
	foreach (i; 0 .. count)
		foreach (j; 0 .. count)
			assert((compare(positions, order[i], order[j]) == 0) == (order[i] == order[j]));

	// Children sort after their parent and before its next sibling, at any depth.
	immutable a = between(positions, root, end, end);
	immutable b = between(positions, root, a, end);
	immutable ab = between(positions, root, a, b);
	immutable inA = between(positions, a, end, end);
	immutable deep = between(positions, inA, end, end);
	immutable inAb = between(positions, ab, end, end);
	assert(precedes(positions, a, inA) && precedes(positions, inA, deep) && precedes(positions, deep, ab));
	assert(precedes(positions, ab, inAb) && precedes(positions, inAb, b));
	assert(precedes(positions, root, a) && precedes(positions, b, end));

	// A refused allocation at any step leaves the positions as they were; budgets cover every step at every table size.
	Positions rationed;
	scope(exit) free(rationed);
	Position previous = end;
	foreach (i; 0 .. 100) {
		for (size_t budget = 0;; ++budget) {
			auto allocator = fp.testing.limitAllocations(budget);
			immutable next = between(rationed, root, previous, end);
			fp.testing.restoreAllocator(allocator);
			if (next != refused) {
				assert(next.value == i + 1 && (previous == end || precedes(rationed, previous, next)));
				previous = next;
				break;
			}
			assert(bc.interner.count(rationed.keys) == i);
		}
	}
}
