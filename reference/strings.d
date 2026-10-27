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

static import fp.dynarray;
static import fp.fnv1a;
static import fp.hashtable;
static import fp.string;

@nogc nothrow:


// --- types and layout --------------------------------------------------------

/// The id of an interned string, dense from 0 in interning order. A struct rather than an integer, so an overload taking a name never accepts an `EntityId`.
struct StringId {
	uint value = uint.max; /// The index of the string's text.
}

/// The id no string has, and a `StringId`'s initial value: what the parser passes for the name of a `_` declaration, which gets no `Name` component.
enum StringId noName = StringId.init;

private struct Entry {
	const(char)[] text;
	StringId id;
}

// Keys hash and compare by their text, so a lookup key needs no id and the padding after `id` is never read.
private size_t hashEntry(inout(ubyte)[] bytes) @trusted {
	return fp.fnv1a.hash(cast(const(ubyte)[]) (cast(const(Entry)*) bytes.ptr).text);
}

private bool equalEntry(inout(ubyte)[] a, inout(ubyte)[] b) @trusted {
	return (cast(const(Entry)*) a.ptr).text == (cast(const(Entry)*) b.ptr).text;
}

/// The interning table: one owned copy of each text, indexed by id, and a hash set over them. Plain data, released only by `free`.
struct Strings {
	private Entry* table = null;
	private char** texts = null;
}


// --- queries -----------------------------------------------------------------

/// The number of strings interned so far; every id below it is valid.
///
/// Examples:
/// ---
/// Strings strings;
/// scope(exit) free(strings);
/// assert(count(strings) == 0);
/// cast(void) intern(strings, "x");
/// assert(count(strings) == 1);
/// ---
size_t count(ref const Strings strings) {
	return fp.dynarray.length(strings.texts);
}

/// The text of `id`, which must be a valid id. The slice stays valid until `free`.
///
/// Examples:
/// ---
/// Strings strings;
/// scope(exit) free(strings);
/// assert(text(strings, intern(strings, "std.add")) == "std.add");
/// ---
const(char)[] text(ref const Strings strings, StringId id) @trusted {
	assert(id.value < count(strings));
	return fp.string.slice(strings.texts[id.value]);
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
	if (strings.table is null) return noName;
	auto found = fp.hashtable.find(strings.table, Entry(s, noName));
	return found is null ? noName : found.id;
}


// --- creation and freeing ----------------------------------------------------

/// The id of `s`, interning a copy of it first if it is new.
///
/// Returns `noName` if allocation fails, leaving `strings` as it was.
///
/// Examples:
/// ---
/// Strings strings;
/// scope(exit) free(strings);
/// immutable a = intern(strings, "a"), b = intern(strings, "b");
/// assert(a != b && intern(strings, "a") == a);
/// ---
StringId intern(ref Strings strings, const(char)[] s) @trusted {
	immutable existing = find(strings, s);
	if (existing != noName) return existing;
	if (strings.table is null) {
		fp.hashtable.Config config;
		config.hashFunction = &hashEntry;
		config.equalFunction = &equalEntry;
		strings.table = fp.hashtable.create!Entry(config);
		if (strings.table is null) return noName;
	}
	assert(count(strings) < uint.max, "doir.strings: id space exhausted");
	immutable id = StringId(cast(uint) count(strings));
	// The empty text is a null fp string, so null means refusal only for a non-empty one.
	char* copy = fp.string.makeDynamic(s);
	if (copy is null && s.length) return noName;
	if (!fp.dynarray.pushBack(strings.texts, copy)) {
		fp.string.free(copy);
		return noName;
	}
	if (fp.hashtable.insert(strings.table, Entry(fp.string.slice(copy), id)) is null) {
		cast(void) fp.dynarray.popBack(strings.texts);
		fp.string.free(copy);
		return noName;
	}
	return id;
}

/// Releases every text and the table, leaving `strings` empty and reusable.
///
/// Examples:
/// ---
/// Strings strings;
/// cast(void) intern(strings, "x");
/// free(strings);
/// assert(count(strings) == 0);
/// ---
void free(ref Strings strings) @trusted {
	foreach (t; fp.dynarray.slice(strings.texts)) fp.string.free(t);
	fp.dynarray.free(strings.texts);
	strings.texts = null;
	fp.hashtable.free(strings.table);
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
}

version(unittest) static import core.stdc.stdio;
