#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""A model of the software floats in `standard.emulated.doir`, step for step, checked against IEEE 754 (rule N-Float).
Nothing runs the DOIR bodies yet, so this is what shows their algorithms are right: each function here is named after the body it mirrors (`add_bits` also holds `add_finite`, and the other `_bits` functions their `_finite` halves) and uses only what that body does, on unsigned integers of the float's width that wrap.
binary16, which the DOIR bodies do not offer, stresses the narrowest guard bits; it and binary32 are checked against the host's arithmetic (Python's binary64, which rounds them correctly, since 53 >= 2 * 24 + 2), and binary64 against exact rational arithmetic.

    uv run tests/software_float.py [cases per operation]

Exits 1 at the first disagreement, printing the operation and operands.
"""

import fractions
import math
import random
import struct
import sys


class Twin:
	"""An unsigned integer type of `width` bits and the operations the bodies use on it, all wrapping."""

	def __init__(self, width):
		self.width = width
		self.mask = (1 << width) - 1
		self.sign = 1 << (width - 1)

	def add(self, a, b):
		"""`std.add` on the twin."""
		return (a + b) & self.mask

	def subtract(self, a, b):
		"""`std.subtract` on the twin."""
		return (a - b) & self.mask

	def shift_left(self, a, n):
		"""`std.shift_left`; a shift of at least the width is undefined (rule N-Undefined)."""
		assert 0 <= n < self.width, n
		return (a << n) & self.mask

	def shift_right(self, a, n):
		"""`std.shift_right` on an unsigned type."""
		assert 0 <= n < self.width, n
		return a >> n

	def multiply(self, a, b):
		"""`std.multiply` on the twin."""
		return (a * b) & self.mask

	def is_negative(self, v):
		"""Whether `v` read as two's complement is negative, which is how the bodies keep exponents."""
		return v >= self.sign


class Format(Twin):
	"""An IEEE 754 binary format, over its unsigned twin."""

	def __init__(self, width, exponent_bits):
		super().__init__(width)
		self.exponent_bits = exponent_bits
		self.fraction_bits = width - exponent_bits - 1
		self.guard_bits = exponent_bits - 1
		self.bias = (1 << (exponent_bits - 1)) - 1
		self.exponent_mask = ((1 << exponent_bits) - 1) << self.fraction_bits
		self.fraction_mask = (1 << self.fraction_bits) - 1
		self.implicit = 1 << self.fraction_bits
		self.quiet = 1 << (self.fraction_bits - 1)
		self.default_nan = self.exponent_mask | self.quiet


def shift_right_sticky(f, v, count):
	"""`v` shifted right by `count`, any width, with 1 in the low bit if a set bit was shifted out."""
	if count < f.width:
		lost = v & f.subtract(f.shift_left(1, count), 1)
		return f.shift_right(v, count) | (lost != 0)
	return int(v != 0)


def leading_zeros(f, v):
	"""The zero bits above the highest set bit of `v`, which is not 0."""
	count = 0
	while v & f.sign == 0:
		v = f.add(v, v)
		count += 1
	return count


def round_pack(f, sign, d, sig):
	"""The float nearest `sig * 2^(d + 1 - bias - (width - 2))`, ties to even: `sig` is below `2^(width - 1)` with its top bit at `width - 2` unless `d` is negative, and `d` is two's complement."""
	half = f.shift_left(1, f.guard_bits - 1)
	low_mask = f.subtract(f.shift_left(1, f.guard_bits), 1)
	if f.is_negative(d):
		sig = shift_right_sticky(f, sig, f.subtract(0, d))
		d = 0
	else:
		overflow_at = (1 << f.exponent_bits) - 3
		if overflow_at < d or (d == overflow_at and f.sign <= f.add(sig, half)):
			return f.shift_left(sign, f.width - 1) | f.exponent_mask
	round_bits = sig & low_mask
	rounded = f.shift_right(f.add(sig, half), f.guard_bits)
	if round_bits == half:
		rounded &= ~1 & f.mask
	return f.add(f.add(f.shift_left(sign, f.width - 1), f.shift_left(d, f.fraction_bits)), rounded)


def normalize_round_pack(f, sign, d, sig):
	"""`round_pack` for a `sig` that is not 0, with its top bit anywhere."""
	zeros = leading_zeros(f, sig)
	if zeros == 0:
		return round_pack(f, sign, f.add(d, 1), shift_right_sticky(f, sig, 1))
	return round_pack(f, sign, f.subtract(d, zeros - 1), f.shift_left(sig, zeros - 1))


def field_of(f, x):
	"""The biased exponent field of `x`."""
	return f.shift_right(x, f.fraction_bits) & ((1 << f.exponent_bits) - 1)


def subnormal_shift(f, x):
	"""How far a subnormal `x`'s fraction moves left to put its top bit at the implicit bit; 0 for a normal `x`."""
	if field_of(f, x) != 0:
		return 0
	return leading_zeros(f, x & f.fraction_mask) - f.exponent_bits


def significand(f, x):
	"""The significand of the finite nonzero `x`, its top bit at `fraction_bits`."""
	implicit = f.implicit if field_of(f, x) != 0 else 0
	return f.shift_left((x & f.fraction_mask) | implicit, subnormal_shift(f, x))


def exponent_of(f, x):
	"""The biased exponent matching `significand`, two's complement, below 1 for a subnormal."""
	field = field_of(f, x)
	return f.subtract(f.add(field, int(field == 0)), subnormal_shift(f, x))


def is_nan_bits(f, x):
	"""`x` is a NaN."""
	return f.exponent_mask < (x & ~f.sign & f.mask)


def propagate_nan(f, a, b):
	"""The quiet form of the first NaN operand."""
	return (a if is_nan_bits(f, a) else b) | f.quiet


def add_bits(f, a, b):
	"""`std.float.add`."""
	a_magnitude, b_magnitude = a & ~f.sign & f.mask, b & ~f.sign & f.mask
	if f.exponent_mask < a_magnitude or f.exponent_mask < b_magnitude:
		return propagate_nan(f, a, b)
	if a_magnitude == f.exponent_mask:
		if b_magnitude == f.exponent_mask and (a ^ b) & f.sign:
			return f.default_nan
		return a
	if b_magnitude == f.exponent_mask:
		return b
	big, small = (b, a) if a_magnitude < b_magnitude else (a, b)
	big_sign = f.shift_right(big, f.width - 1)
	same_sign = (a ^ b) & f.sign == 0
	big_field, small_field = field_of(f, big), field_of(f, small)
	big_sig = f.shift_left((big & f.fraction_mask) | (f.implicit if big_field else 0), f.guard_bits)
	small_sig = f.shift_left((small & f.fraction_mask) | (f.implicit if small_field else 0), f.guard_bits)
	big_exponent = f.add(big_field, int(big_field == 0))
	small_exponent = f.add(small_field, int(small_field == 0))
	small_sig = shift_right_sticky(f, small_sig, f.subtract(big_exponent, small_exponent))
	sig = f.add(big_sig, small_sig) if same_sign else f.subtract(big_sig, small_sig)
	if sig == 0:
		return f.shift_left(big_sign if same_sign else 0, f.width - 1)
	return normalize_round_pack(f, big_sign, f.subtract(big_exponent, 1), sig)


def multiply_high(f, x, y):
	"""The high half of the double-width product of `x` and `y`, with 1 in its low bit if the low half is not 0."""
	half = f.width // 2
	low_mask = (1 << half) - 1
	x0, x1, y0, y1 = x & low_mask, f.shift_right(x, half), y & low_mask, f.shift_right(y, half)
	p00, p01, p10, p11 = f.multiply(x0, y0), f.multiply(x0, y1), f.multiply(x1, y0), f.multiply(x1, y1)
	middle = f.add(f.add(f.shift_right(p00, half), p01 & low_mask), p10 & low_mask)
	low = f.shift_left(middle, half) | (p00 & low_mask)
	high = f.add(f.add(f.add(p11, f.shift_right(p01, half)), f.shift_right(p10, half)), f.shift_right(middle, half))
	return high | (low != 0)


def multiply_bits(f, a, b):
	"""`std.float.multiply`."""
	sign = f.shift_right(a ^ b, f.width - 1)
	a_magnitude, b_magnitude = a & ~f.sign & f.mask, b & ~f.sign & f.mask
	signed_zero = f.shift_left(sign, f.width - 1)
	if f.exponent_mask < a_magnitude or f.exponent_mask < b_magnitude:
		return propagate_nan(f, a, b)
	if a_magnitude == f.exponent_mask or b_magnitude == f.exponent_mask:
		if a_magnitude == 0 or b_magnitude == 0:
			return f.default_nan
		return signed_zero | f.exponent_mask
	if a_magnitude == 0 or b_magnitude == 0:
		return signed_zero
	a_sig = f.shift_left(significand(f, a), f.guard_bits)
	b_sig = f.shift_left(significand(f, b), f.guard_bits + 1)
	d = f.subtract(f.add(exponent_of(f, a), exponent_of(f, b)), f.bias)
	return normalize_round_pack(f, sign, d, multiply_high(f, a_sig, b_sig))


def quotient_bits(f, dividend, divisor):
	"""`dividend / divisor` to `width - 1` bits, with 1 in the low bit if inexact; `divisor <= dividend < 2 * divisor`."""
	remainder = f.subtract(dividend, divisor)
	bits = 1
	for _ in range(f.width - 2):
		remainder = f.add(remainder, remainder)
		bits = f.add(bits, bits)
		if divisor <= remainder:
			remainder = f.subtract(remainder, divisor)
			bits = f.add(bits, 1)
	return bits | (remainder != 0)


def divide_bits(f, a, b):
	"""`std.float.divide`."""
	sign = f.shift_right(a ^ b, f.width - 1)
	a_magnitude, b_magnitude = a & ~f.sign & f.mask, b & ~f.sign & f.mask
	signed_zero = f.shift_left(sign, f.width - 1)
	if f.exponent_mask < a_magnitude or f.exponent_mask < b_magnitude:
		return propagate_nan(f, a, b)
	if a_magnitude == f.exponent_mask:
		return f.default_nan if b_magnitude == f.exponent_mask else signed_zero | f.exponent_mask
	if b_magnitude == f.exponent_mask:
		return signed_zero
	if b_magnitude == 0:
		return f.default_nan if a_magnitude == 0 else signed_zero | f.exponent_mask
	if a_magnitude == 0:
		return signed_zero
	a_sig, b_sig = significand(f, a), significand(f, b)
	smaller = int(a_sig < b_sig)
	a_sig = f.shift_left(a_sig, smaller)
	d = f.subtract(f.add(f.subtract(f.subtract(exponent_of(f, a), smaller), exponent_of(f, b)), f.bias), 1)
	return normalize_round_pack(f, sign, d, quotient_bits(f, a_sig, b_sig))


def remainder_bits(f, a, b):
	"""`std.float.remainder`, truncated toward zero like C's `fmod`, which is always exact."""
	a_magnitude, b_magnitude = a & ~f.sign & f.mask, b & ~f.sign & f.mask
	if f.exponent_mask < a_magnitude or f.exponent_mask < b_magnitude:
		return propagate_nan(f, a, b)
	if a_magnitude == f.exponent_mask or b_magnitude == 0:
		return f.default_nan
	if a_magnitude < b_magnitude:
		return a
	a_sig, b_sig = significand(f, a), significand(f, b)
	count = f.subtract(exponent_of(f, a), exponent_of(f, b))
	rest = a_sig
	while count != 0:
		if b_sig <= rest:
			rest = f.subtract(rest, b_sig)
		rest = f.add(rest, rest)
		count = f.subtract(count, 1)
	if b_sig <= rest:
		rest = f.subtract(rest, b_sig)
	sign = f.shift_right(a, f.width - 1)
	if rest == 0:
		return f.shift_left(sign, f.width - 1)
	return normalize_round_pack(f, sign, f.subtract(exponent_of(f, b), 1), f.shift_left(rest, f.guard_bits))


def square_root_bits(f, a):
	"""`std.square_root` on a float, one root bit per step, correctly rounded."""
	if is_nan_bits(f, a):
		return a | f.quiet
	if a & ~f.sign & f.mask == 0 or a == f.exponent_mask:
		return a
	if a & f.sign:
		return f.default_nan
	sig = significand(f, a)
	scaled = f.add(f.add(exponent_of(f, a), f.bias), f.fraction_bits)
	odd = scaled & 1
	sig = f.shift_left(sig, odd)
	scaled = f.subtract(scaled, odd)
	# With an odd fraction width the top pair of `sig` can be 0, so one more step keeps three bits below the result.
	root_bits = f.fraction_bits + 3 + (f.fraction_bits & 1)
	pairs = (f.fraction_bits + 3) // 2
	window = (1 << (2 * pairs)) - 1
	cursor, root, rest = sig, 0, 0
	for _ in range(root_bits):
		pair = f.shift_right(cursor, 2 * pairs - 2)
		cursor = f.shift_left(cursor, 2) & window
		rest = f.add(f.shift_left(rest, 2), pair)
		trial = f.add(f.shift_left(root, 2), 1)
		root = f.add(root, root)
		if trial <= rest:
			rest = f.subtract(rest, trial)
			root = f.add(root, 1)
	root |= rest != 0
	d = f.add(f.subtract(f.shift_right(scaled, 1), f.fraction_bits + root_bits - pairs), f.width - 3)
	return normalize_round_pack(f, 0, d, root)


def resize(to, v):
	"""`v` on `to`'s twin: `widen` when that is wider, `truncate` otherwise."""
	return v & to.mask


def float_to_float_bits(source, out, x):
	"""`std.numbers.float_convert` between float widths."""
	sign = source.shift_right(x, source.width - 1)
	magnitude = x & ~source.sign & source.mask
	out_sign = out.shift_left(sign, out.width - 1)
	if source.exponent_mask < magnitude:
		return out_sign | out.default_nan
	if magnitude == source.exponent_mask:
		return out_sign | out.exponent_mask
	if magnitude == 0:
		return out_sign
	field = field_of(source, x)
	sig = source.shift_left((x & source.fraction_mask) | (source.implicit if field else 0), source.guard_bits)
	unbiased_field = source.add(field, int(field == 0))
	if source.width < out.width:
		out_sig = out.shift_left(resize(out, sig), out.width - source.width)
		d = out.subtract(out.add(resize(out, unbiased_field), out.bias - 1), source.bias)
	else:
		out_sig = resize(out, shift_right_sticky(source, sig, source.width - out.width))
		d = resize(out, source.subtract(source.add(unbiased_field, out.bias - 1), source.bias))
	return normalize_round_pack(out, sign, d, out_sig)


def integer_to_float_bits(width, signed, out, v):
	"""`std.numbers.float_convert` from a `width`-bit integer whose bits are `v`."""
	source = Twin(width)
	mask = source.mask
	negative = int(signed and v >> (width - 1))
	magnitude = ((v ^ (mask if negative else 0)) + negative) & mask
	if magnitude == 0:
		return 0
	zeros = leading_zeros(source, magnitude)
	top = source.shift_left(magnitude, zeros)
	if out.width <= width:
		sig = resize(out, shift_right_sticky(source, top, width - out.width + 1))
	else:
		sig = out.shift_left(resize(out, top), out.width - width - 1)
	d = out.subtract(out.bias + width - 2, resize(out, zeros))
	return round_pack(out, negative, d, sig)


def float_to_integer_bits(source, width, signed, x):
	"""`std.numbers.float_convert` to a `width`-bit integer, truncating toward zero; the result's bits."""
	mask = (1 << width) - 1
	field = field_of(source, x)
	if field < source.bias:
		return 0
	unbiased = source.subtract(field, source.bias)
	sig = (x & source.fraction_mask) | source.implicit
	if unbiased <= source.fraction_bits:
		magnitude = source.shift_right(sig, source.subtract(source.fraction_bits, unbiased)) & mask
	else:
		magnitude = ((sig & mask) << ((unbiased - source.fraction_bits) & mask)) & mask
	negative = source.shift_right(x, source.width - 1)
	return ((magnitude ^ (mask if negative else 0)) + negative) & mask


def is_equal_bits(f, a, b):
	"""`std.float.is_equal`."""
	if is_nan_bits(f, a) or is_nan_bits(f, b):
		return 0
	return int(a == b or (a | b) & ~f.sign & f.mask == 0)


def is_less_bits(f, a, b):
	"""`std.float.is_less`."""
	if is_nan_bits(f, a) or is_nan_bits(f, b):
		return 0
	a_sign, b_sign = f.shift_right(a, f.width - 1), f.shift_right(b, f.width - 1)
	if a_sign != b_sign:
		return int(a_sign == 1 and (a | b) & ~f.sign & f.mask != 0)
	return int(a != b and (a_sign ^ int(a < b)) == 1)


# The reference: the host's floats for binary16 and binary32, exact rationals for binary64.

PACK = {16: "e", 32: "f", 64: "d"}
UNSIGNED = {16: "H", 32: "I", 64: "Q"}


def to_host(f, bits):
	"""The float whose bits are `bits`, as a Python float."""
	return struct.unpack("<" + PACK[f.width], struct.pack("<" + UNSIGNED[f.width], bits))[0]


def from_host(f, value):
	"""The bits of `value` rounded to `f` (to nearest, ties to even); `struct` refuses a value that rounds to an infinity, which is the answer."""
	if math.isinf(value) or math.isnan(value):
		return (f.sign if math.copysign(1, value) < 0 else 0) | (f.default_nan if math.isnan(value) else f.exponent_mask)
	try:
		return struct.unpack("<" + UNSIGNED[f.width], struct.pack("<" + PACK[f.width], value))[0]
	except OverflowError:
		return (f.sign if value < 0 else 0) | f.exponent_mask
	return struct.unpack("<" + UNSIGNED[f.width], struct.pack("<" + PACK[f.width], value))[0]


def exact(f, bits):
	"""The finite float `bits` as a `Fraction`."""
	field, fraction = field_of(f, bits), bits & f.fraction_mask
	sig = fraction | (f.implicit if field else 0)
	value = fractions.Fraction(sig) * fractions.Fraction(2) ** (max(field, 1) - f.bias - f.fraction_bits)
	return -value if bits & f.sign else value


def round_exact(f, value, negative_zero=False):
	"""The bits of the rational `value` rounded to `f`, to nearest, ties to even; an independent rounding from `round_pack`."""
	if value == 0:
		return f.sign if negative_zero else 0
	sign = f.sign if value < 0 else 0
	value = abs(value)
	scale = max(math.floor(math.log2(value.numerator) - math.log2(value.denominator)) - 2, 1 - f.bias) - f.fraction_bits
	while value / fractions.Fraction(2) ** scale >= 2 * f.implicit:
		scale += 1
	while scale > 1 - f.bias - f.fraction_bits and value / fractions.Fraction(2) ** scale < f.implicit:
		scale -= 1
	units = value / fractions.Fraction(2) ** scale
	whole = math.floor(units)
	if units - whole > fractions.Fraction(1, 2) or (units - whole == fractions.Fraction(1, 2) and whole % 2):
		whole += 1
	if whole == 2 * f.implicit:
		whole //= 2
		scale += 1
	field = scale + f.bias + f.fraction_bits
	if whole < f.implicit:
		field = 0
	if field >= (1 << f.exponent_bits) - 1:
		return sign | f.exponent_mask
	return sign | (field << f.fraction_bits) | (whole & f.fraction_mask)


def interesting(f, rng):
	"""A random operand, biased toward the edges: zeros, subnormals, the extremes, infinities, NaNs, and values near powers of two."""
	choice = rng.randrange(10)
	sign = f.sign * rng.randrange(2)
	if choice == 0:
		return sign | rng.choice([0, 1, f.fraction_mask, f.implicit, f.exponent_mask, f.exponent_mask | 1, f.default_nan, f.exponent_mask - 1])
	if choice == 1:
		return sign | rng.randrange(f.implicit)
	if choice == 2:
		return sign | (rng.randrange(1, (1 << f.exponent_bits) - 1) << f.fraction_bits) | rng.choice([0, 1, f.fraction_mask, f.fraction_mask - 1])
	if choice == 3:
		return sign | ((f.bias + rng.randrange(-4, 5)) << f.fraction_bits) | rng.randrange(f.implicit)
	return rng.randrange(1 << f.width)


def same(f, got, want):
	"""Whether two results agree: any NaN matches any NaN (the spec fixes no payload), everything else bit for bit."""
	if is_nan_bits(f, want):
		return is_nan_bits(f, got)
	return got == want


def reference_binary(f, name, a, b):
	"""The correct result of `name` on `a` and `b`."""
	if f.width < 64:
		x, y = to_host(f, a), to_host(f, b)
		if name == "add":
			return from_host(f, x + y)
		if name == "multiply":
			return from_host(f, x * y)
		if name == "divide":
			if y == 0:
				return f.default_nan if x == 0 or math.isnan(x) else ((a ^ b) & f.sign) | f.exponent_mask
			return from_host(f, x / y)
		if name == "remainder":
			if math.isnan(x) or math.isnan(y) or math.isinf(x) or y == 0:
				return f.default_nan
			return from_host(f, math.fmod(x, y))
	if is_nan_bits(f, a) or is_nan_bits(f, b):
		return f.default_nan
	infinite_a, infinite_b = a & ~f.sign & f.mask == f.exponent_mask, b & ~f.sign & f.mask == f.exponent_mask
	zero_a, zero_b = a & ~f.sign & f.mask == 0, b & ~f.sign & f.mask == 0
	sign = (a ^ b) & f.sign
	if name == "add":
		if infinite_a or infinite_b:
			if infinite_a and infinite_b and sign:
				return f.default_nan
			return a if infinite_a else b
		total = exact(f, a) + exact(f, b)
		return round_exact(f, total, total == 0 and a & b & f.sign != 0)
	if name == "multiply":
		if infinite_a or infinite_b:
			return f.default_nan if zero_a or zero_b else sign | f.exponent_mask
		return round_exact(f, exact(f, a) * exact(f, b), sign != 0)
	if name == "divide":
		if infinite_a:
			return f.default_nan if infinite_b else sign | f.exponent_mask
		if infinite_b:
			return sign
		if zero_b:
			return f.default_nan if zero_a else sign | f.exponent_mask
		return round_exact(f, exact(f, a) / exact(f, b), sign != 0)
	if infinite_a or zero_b:
		return f.default_nan
	if infinite_b or zero_a:
		return a
	x, y = exact(f, a), exact(f, b)
	quotient_toward_zero = math.trunc(x / y)
	return round_exact(f, x - quotient_toward_zero * y, a & f.sign != 0)


def reference_square_root(f, a):
	"""The correctly rounded square root of `a`."""
	if f.width < 64:
		x = to_host(f, a)
		return f.default_nan if x < 0 or math.isnan(x) else from_host(f, math.sqrt(x)) if x != 0 else a
	if is_nan_bits(f, a):
		return f.default_nan
	if a & ~f.sign & f.mask == 0 or a == f.exponent_mask:
		return a
	if a & f.sign:
		return f.default_nan
	value = exact(f, a)
	# Compare the candidate's neighbourhood exactly: the root lies between the two floats whose squares bracket `value`.
	guess = from_host(f, math.sqrt(float(value)))
	for candidate in (guess - 1, guess, guess + 1):
		low = (exact(f, candidate) + exact(f, candidate - 1)) / 2 if candidate > 0 else 0
		high = (exact(f, candidate) + exact(f, candidate + 1)) / 2
		if low * low < value < high * high or (low * low == value and candidate % 2 == 0) or (high * high == value and candidate % 2 == 0):
			return candidate
	raise AssertionError("no candidate brackets the root")


def check(label, got, want, f):
	"""Fails the run if `got` is not `want`."""
	if not same(f, got, want):
		print(f"{label}: got {got:#x}, want {want:#x}")
		sys.exit(1)


def main():
	"""Runs every operation on random and edge operands for binary16, binary32 and binary64."""
	cases = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
	rng = random.Random(754)
	formats = [Format(16, 5), Format(32, 8), Format(64, 11)]
	operations = {"add": add_bits, "multiply": multiply_bits, "divide": divide_bits, "remainder": remainder_bits}
	for f in formats:
		count = cases if f.width < 64 else cases // 10
		for name, operation in operations.items():
			for _ in range(count):
				a, b = interesting(f, rng), interesting(f, rng)
				check(f"binary{f.width} {name}({a:#x}, {b:#x})", operation(f, a, b), reference_binary(f, name, a, b), f)
		for _ in range(count):
			a = interesting(f, rng) & ~f.sign if rng.randrange(4) else interesting(f, rng)
			check(f"binary{f.width} square_root({a:#x})", square_root_bits(f, a), reference_square_root(f, a), f)
		for _ in range(count):
			a, b = interesting(f, rng), interesting(f, rng)
			if f.width < 64:
				x, y = to_host(f, a), to_host(f, b)
				check(f"binary{f.width} is_equal({a:#x}, {b:#x})", is_equal_bits(f, a, b), int(x == y), f)
				check(f"binary{f.width} is_less({a:#x}, {b:#x})", is_less_bits(f, a, b), int(x < y), f)
	for source in formats:
		for out in formats:
			if source.width == out.width:
				continue
			for _ in range(cases // 10):
				x = interesting(source, rng)
				if is_nan_bits(source, x):
					want = out.default_nan
				elif x & ~source.sign & source.mask == source.exponent_mask:
					want = (out.sign if x & source.sign else 0) | out.exponent_mask
				else:
					want = round_exact(out, exact(source, x), x & source.sign != 0)
				check(f"binary{source.width} to binary{out.width} ({x:#x})", float_to_float_bits(source, out, x), want, out)
	for out in formats:
		for width in (8, 16, 32, 64):
			for signed in (False, True):
				for _ in range(cases // 20):
					v = rng.randrange(1 << width) >> rng.randrange(width)
					value = v - (1 << width) if signed and v >> (width - 1) else v
					check(f"i{width}/u{width} {v:#x} to binary{out.width}", integer_to_float_bits(width, signed, out, v), round_exact(out, fractions.Fraction(value)), out)
	for source in formats:
		for width in (8, 16, 32, 64):
			for signed in (False, True):
				low, high = (-(1 << (width - 1)), (1 << (width - 1)) - 1) if signed else (0, (1 << width) - 1)
				for _ in range(cases // 20):
					x = interesting(source, rng)
					if is_nan_bits(source, x) or x & ~source.sign & source.mask == source.exponent_mask:
						continue
					value = math.trunc(exact(source, x))
					if not low <= value <= high:
						continue
					got = float_to_integer_bits(source, width, signed, x)
					want = value & ((1 << width) - 1)
					if got != want:
						print(f"binary{source.width} {x:#x} to {'i' if signed else 'u'}{width}: got {got:#x}, want {want:#x}")
						sys.exit(1)
	print(f"software_float: every operation agrees on {cases} cases per operation")
	return 0


if __name__ == "__main__":
	sys.exit(main())
