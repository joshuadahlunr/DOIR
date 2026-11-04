/// Interned strings: each distinct text gets one `StringId`, so a `Name` or `SymbolName` compares and hashes as a number (`doir.spec.md` Part II §1).
///
/// Examples:
/// ---
/// Strings strings;
/// scope(exit) free(strings);
/// immutable a = intern(strings, "add");
/// assert(a != noName && intern(strings, "add") == a);
/// assert(text(strings, a) == "add");
/// ---
module doir.strings;

version(unittest) static import fp.testing;

static import bc.interner;

@nogc nothrow:


// --- types and layout --------------------------------------------------------

/// The id of an interned string, dense from 0 in interning order. A struct rather than an integer, so an overload taking a name never accepts an `EntityId`.
struct StringId {
	uint value = uint.max; /// The index of the string's text.
}

/// The id no string has, and a `StringId`'s initial value: what the parser passes for the name of a `_` declaration, which gets no `Name` component.
enum StringId noName = StringId.init;

/// The interning table: one copy of each text, NUL-terminated, indexed by id. Any thread may intern or look up at once (`bc.interner`); `free` it from one thread once no other uses it.
struct Strings {
	private bc.interner.Interner!char table;
}


// --- queries -----------------------------------------------------------------

/// The text of `id`, which must be a valid id. The slice stays valid until `free`, and is followed by a NUL.
///
/// Examples:
/// ---
/// Strings strings;
/// scope(exit) free(strings);
/// assert(text(strings, intern(strings, "std.add")) == "std.add");
/// ---
const(char)[] text(ref const Strings strings, StringId id) {
	return bc.interner.content(strings.table, id.value);
}

/// The id of `s`, or `noName` if it was never interned.
///
/// Examples:
/// ---
/// Strings strings;
/// scope(exit) free(strings);
/// assert(find(strings, "x") == noName);
/// immutable x = intern(strings, "x");
/// assert(find(strings, "x") == x);
/// ---
StringId find(ref Strings strings, const(char)[] s) {
	return StringId(bc.interner.find(strings.table, s));
}


// --- creation and freeing ----------------------------------------------------

/// The id of `s`, interning a copy of it if it is new. Any thread may call it at once with any other.
///
/// Returns `noName` if allocation fails, leaving the strings as they were.
///
/// Examples:
/// ---
/// Strings strings;
/// scope(exit) free(strings);
/// immutable a = intern(strings, "a");
/// assert(intern(strings, "a") == a && intern(strings, "b") != a);
/// ---
StringId intern(ref Strings strings, const(char)[] s) {
	return StringId(bc.interner.intern(strings.table, s));
}

/// The number of strings interned.
///
/// Examples:
/// ---
/// Strings strings;
/// scope(exit) free(strings);
/// cast(void) intern(strings, "a");
/// assert(count(strings) == 1);
/// ---
size_t count(ref const Strings strings) {
	return bc.interner.count(strings.table);
}

/// Releases every string, leaving `strings` empty and reusable.
///
/// Examples:
/// ---
/// Strings strings;
/// cast(void) intern(strings, "a");
/// free(strings);
/// ---
void free(ref Strings strings) {
	bc.interner.free(strings.table);
}


version(unittest) {
	static import core.stdc.stdio;
}

unittest {
	Strings strings;
	scope(exit) free(strings);
	assert(find(strings, "") == noName);
	immutable empty = intern(strings, "");
	assert(empty != noName && text(strings, empty) == "");
	foreach (i; 0 .. 100) {
		char[8] buffer;
		immutable n = cast(size_t) core.stdc.stdio.snprintf(buffer.ptr, buffer.length, "n%d", i);
		immutable id = intern(strings, buffer[0 .. n]);
		assert(id.value == i + 1 && text(strings, id) == buffer[0 .. n]);
	}
	assert(intern(strings, "n42").value == 43);
	assert(count(strings) == 101);

	// A refused allocation at any step leaves the strings as they were; budgets cover every step at every table size.
	Strings rationed;
	scope(exit) free(rationed);
	foreach (i; 0 .. 100) {
		char[8] buffer;
		immutable n = cast(size_t) core.stdc.stdio.snprintf(buffer.ptr, buffer.length, "n%d", i);
		for (size_t budget = 0;; ++budget) {
			auto previous = fp.testing.beginRationedAllocator(budget);
			immutable id = intern(rationed, buffer[0 .. n]);
			fp.testing.endRationedAllocator(previous);
			if (id != noName) {
				assert(id.value == i && text(rationed, id) == buffer[0 .. n]);
				break;
			}
			assert(count(rationed) == i && find(rationed, buffer[0 .. n]) == noName);
		}
	}
}
