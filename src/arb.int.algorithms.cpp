#include <assert.h>
#include <cstdint>
#include <type_traits>
#include <utility>
#include <iostream>

constexpr bool is_power_of_two(std::size_t n) {
	return !(n & (n - 1));
}
constexpr bool is_implemented_power_of_two(std::size_t n) {
	switch(n) {
	case 8: return true;
	case 16: return true;
	case 32: return true;
	case 64: return true;
	default: return n > 64 ? is_power_of_two(n) : false;
	}
}

// From: https://stackoverflow.com/a/466278
constexpr std::size_t ceil_power_of_two(std::size_t v) {
	v--;
	v |= v >> 1;
	v |= v >> 2;
	v |= v >> 4;
	v |= v >> 8;
	v |= v >> 16;
	v++;
	return v;
}
constexpr std::size_t ceil_implemented_power_of_two(std::size_t v) {
	auto tmp = ceil_power_of_two(v);
	if(!is_implemented_power_of_two(tmp)) return ceil_implemented_power_of_two(tmp + 1);
	return tmp;
}
constexpr std::size_t floor_power_of_two(std::size_t v) {
	auto res = ceil_power_of_two(v) / 2;
	return res > 1 ? res : 1;
}
constexpr std::size_t floor_implemented_power_of_two(std::size_t v) {
	if(v < 8) return 8;
	return floor_power_of_two(v);
}




template<uint32_t size, bool signedness>
requires(size > 0)
struct integer_impl;

template<typename A, typename B>
struct promote { using type = void; };

template<uint32_t sizeA, bool signedA, uint32_t sizeB, bool signedB>
struct promote<integer_impl<sizeA, signedA>, integer_impl<sizeB, signedB>> {
	static constexpr bool signedness = signedA || signedB;
	using type = std::conditional_t<(sizeA > sizeB), integer_impl<sizeA, signedness>, integer_impl<sizeB, signedness>>;
};

template<uint32_t size, bool signedness>
requires(size > 0)
using integer = std::conditional_t<size == 1, bool,
	std::conditional_t<size == 8, std::conditional_t<signedness, int8_t, uint8_t>,
	std::conditional_t<size == 16, std::conditional_t<signedness, int16_t, uint16_t>,
	std::conditional_t<size == 32, std::conditional_t<signedness, int32_t, uint32_t>,
	std::conditional_t<size == 64, std::conditional_t<signedness, int64_t, uint64_t>,
	integer_impl<size, signedness>>>>>>;



template<uint32_t Size, bool Signed>
requires(Size > 0)
struct integer_impl {
	constexpr static auto size = Size;
	constexpr static auto signedness = Signed;
	// Either one larger integer which we modulus or two smaller integers (first = high order, second = low order) which we modulus
	// Unless size is less than 8 in which case it is backed by a single char
	std::conditional_t<!is_implemented_power_of_two(Size), integer<ceil_implemented_power_of_two(Size), Signed>,
		std::conditional_t<Size <= 8, integer<8, Signed>,
		std::pair<integer<floor_implemented_power_of_two(Size), Signed>, integer<floor_implemented_power_of_two(Size), Signed>>>> storage;

	static constexpr integer_impl zero() {
		if constexpr(std::is_integral_v<decltype(integer_impl::storage)>)
			return integer_impl{0};
		else if constexpr(is_implemented_power_of_two(Size))
			return integer_impl{decltype(integer_impl::storage.first)::zero(), decltype(integer_impl::storage.second)::zero()};
		else return integer_impl{decltype(integer_impl::storage)::zero()};
	}

	static constexpr integer_impl max() {
		if constexpr (Size == 1) return integer_impl{ 1 };
		else if constexpr (Size == 2) return Signed ? integer_impl{ 2 } : integer_impl{ 4 };
		else {
			auto two = convert(integer_impl<7, false>{ 2 }, true);
			auto count = two;
			uint32_t realSize = Size;
			if constexpr(Signed) realSize--;
			for(uint32_t i = Size; --i; )
				count = count.multiply(two).first;
			// if constexpr(Signed) count = count.subtract(convert(integer_impl<7, false>{ 1 }, true)).first;
			return count;
		}
	}

	static constexpr integer_impl min() {
		if constexpr(!Signed) return convert(integer_impl<7, false>{ 0 }, true);
		// else return max().divide(convert(integer_impl<7, false>{ 2 }, true))
			//.add(convert(integer_impl<7, false>{ 1 }, true))).negate();
	}

	// template<uint32_t sizeA, bool signedA>
	// requires(sizeA >= Size)
	// static auto truncate(const integer_impl<sizeA, signedA>& other, bool knowWillFit = false) {
	//     if constexpr(std::is_integral_v<decltype(other.storage)>) {
	//         return other.storage;
	//     } else if constexpr(requires{other.storage.second; std::is_integral_v<decltype(other.storage.second)> == true;}) {
	//         return other.storage.second;
	//     } else if constexpr(sizeA > ceil_power_of_two(Size) && is_power_of_two(sizeA))
	//         return truncate(other.storage.second);
	//     else if constexpr(is_power_of_two(sizeA))
	//         return other.storage.second;
	//     else if(knowWillFit) return other.storage;
	//     else return other.storage.modulus(decltype(other.storage)::convert(max())).first;
	// }

	// template<uint32_t sizeA, bool signedA>
	// requires(sizeA <= Size)
	// static auto untruncate(const integer_impl<sizeA, signedA>& other) {
	//     // static_assert(!is_implemented_power_of_two(sizeA))
	//     if constexpr(sizeA <= 64) {
	//         using Bigger = integer_impl<ceil_implemented_power_of_two(65), signedA>;
	//         using BiggerStorageFirst = decltype(Bigger::storage.first);
	//         if constexpr(requires{other.storage.first;}) {
	//             auto bigger = integer_impl<ceil_implemented_power_of_two(sizeA + 1), signedA>{{other.storage.first, other.storage.second}};
	//             if constexpr(ceil_implemented_power_of_two(sizeA + 1) < Size) return untruncate(bigger);
	//             else return truncate(bigger, true);
	//         } else {
	//             auto bigger = Bigger{{BiggerStorageFirst{}, other.storage}}; // TODO: If this is signed we should probably be sign extending!
	//             if constexpr(ceil_implemented_power_of_two(65) < Size) return untruncate(bigger);
	//             else return truncate(bigger, true);
	//         }
	//     } else {
	//         using Bigger = integer_impl<ceil_implemented_power_of_two(sizeA + 1), signedA>;
	//         using BiggerStorage = decltype(Bigger::storage);
	//         using BiggerStorageFirst = decltype(Bigger::storage.first);
	//         Bigger bigger;
	//         if constexpr(is_power_of_two(sizeA)) {
	//             if constexpr(std::is_integral_v<BiggerStorageFirst>)
	//                 bigger = Bigger{BiggerStorage{{}, BiggerStorageFirst{other.storage}}}; // TODO: If this is signed we should probably be sign extending!
	//             else bigger = Bigger{BiggerStorage{{}, other}}; // TODO: If this is signed we should probably be sign extending!
	//         } else if constexpr(requires{other.storage.storage;}) {
	//             bigger = Bigger{BiggerStorage{other.storage.storage.first, other.storage.storage.second}}; // TODO: If this is signed we should probably be sign extending!
	//         } else bigger = Bigger{BiggerStorage{other.storage.first, other.storage.second}}; // TODO: If this is signed we should probably be sign extending!

	//         if constexpr(ceil_implemented_power_of_two(sizeA + 1) < Size) return untruncate(bigger);
	//         else return truncate(bigger, true);
	//     }
	// }

	// template<uint32_t sizeA, bool signedA>
	// static integer_impl convert(const integer_impl<sizeA, signedA>& other, bool knowWillFit = false) {
	//     using Other = integer_impl<sizeA, signedA>;
	//     if constexpr(Size == sizeA && Signed == signedA) return other;
	//     else if constexpr(Size > sizeA) {
	//         if constexpr(std::is_integral_v<decltype(integer_impl::storage)>)
	//             return {(decltype(integer_impl::storage)) untruncate(other)}; // Have to cast real integer types
	//         else if constexpr(std::is_integral_v<decltype(untruncate(other))> && std::is_integral_v<decltype(integer_impl::storage)>)
	//             return {(decltype(integer_impl::storage)) untruncate(other)}; // Have to cast real integer types
	//         else if constexpr(is_power_of_two(Size))
	//             return {{{}, untruncate(other)}}; // TODO: If this is signed we should probably be sign extending!
	//         else if constexpr(std::is_integral_v<decltype(untruncate(other))>)
	//             return {std::make_pair(decltype(untruncate(other)){}, untruncate(other))}; // Have to cast real integer types
	//         else return {untruncate(other)};
	//     } else if constexpr(Size == sizeA && Signed != signedA) {
	//         // static_assert(false, "Signed conversions are not well tested!");
	//         if(knowWillFit) return other;
	//         return {other.modulus({max().storage}).storage}; // TODO: I think this fails
	//     } else if constexpr(is_implemented_power_of_two(sizeA)) {
	//         auto larger = integer_impl<Size + 1, Signed>::truncate(other, knowWillFit);
	//         if constexpr(std::is_integral_v<decltype(larger)>) {
	//             auto res = integer_impl<65, Signed>{integer_impl<128, Signed>{{{}, larger}}};
	//         } else if constexpr(requires{larger.storage.storage;})
	//             return {larger.storage.storage.first, larger.storage.storage.second};
	//         else return {larger.storage};
	//     // If smaller, and not a power of two, storage is just the truncation result
	//     } else if constexpr(!is_implemented_power_of_two(sizeA)){
	//         if constexpr(std::is_integral_v<decltype(integer_impl::storage)>)
	//             return {(decltype(integer_impl::storage)) truncate(other, knowWillFit)}; // Have to cast real integer types
	//         else if constexpr(std::is_integral_v<decltype(truncate(other))>)
	//             return {truncate(other, knowWillFit)}; // Have to cast real integer types
	//         else {
	//             auto res = truncate(other, knowWillFit);
	//             return {{res.storage.first, res.storage.second}};
	//         }
	//     }
	// }

	template<uint32_t sizeA, bool signedA>
	requires(is_implemented_power_of_two(Size) && is_implemented_power_of_two(sizeA))
	static auto wrap(const integer_impl<sizeA, signedA>& other) {
		if constexpr(Size == sizeA) return other;
		else return wrap(integer_impl<ceil_implemented_power_of_two(sizeA + 1), signedA>{{{}, other.convert_to_int()}}); // TODO: Should this be sign extending?
	}

	template<uint32_t sizeA, bool signedA>
	static integer_impl convert(const integer_impl<sizeA, signedA>& other, bool knowWillFit = false) {
		using Other = integer_impl<sizeA, signedA>;
		if constexpr(Size == sizeA && Signed == signedA) return other;
		else if constexpr(Size == sizeA) {} // TODO: Sign conversion
		// If both are powers of two... we jump long size differences
		else if constexpr(is_implemented_power_of_two(Size) && is_implemented_power_of_two(sizeA)) {
			constexpr auto unwrap = [](auto other, auto unwrap) {
				if constexpr(Size == decltype(other)::size) return other;
				if constexpr(std::is_integral_v<decltype(other.storage.second)>) return other.storage.second;
				else return unwrap(other.storage.second, unwrap);
			};
			if constexpr(Size > sizeA)
				return convert(wrap(other));
			else return convert(unwrap(other, unwrap));

		// If the target is close we should share the same storage (the next highest power of two), but modulus to maintain proper size
		} else if constexpr(floor_implemented_power_of_two(Size) < sizeA && sizeA <= ceil_implemented_power_of_two(Size)){
			constexpr auto maybeMod = [](auto intimpl, bool knowWillFit) {
				if(knowWillFit) return intimpl;
				return intimpl.modulus(decltype(intimpl)::max()).first;
			};
			if constexpr(std::is_integral_v<decltype(other.convert_to_int())>) return convert(maybeMod(integer_impl<Size, signedA>{other.convert_to_int()}, knowWillFit));
			else if constexpr(requires{integer_impl{}.storage.first;}) {
				auto store = other.convert_to_int().storage;
				constexpr auto size = sizeof(store) * 8;
				return convert(maybeMod(integer_impl<Size, signedA>{ {store >> (size / 2), store} }, knowWillFit));
			} else return convert(maybeMod(integer_impl<Size, signedA>{other.convert_to_int().storage}, knowWillFit));

		// If the target is more than a power of two away, we need to make it a power of two, then long distance jump, then drop in from above
		} else {
			auto pow = integer_impl<ceil_implemented_power_of_two(sizeA), signedA>::convert(other, knowWillFit);
			auto close = integer_impl<ceil_implemented_power_of_two(Size), signedA>::convert(pow, knowWillFit);
			return convert(close);
		}

		throw "Should be unreachable?";
	}

	static integer_impl convert(const integer<8, Signed> other) { return convert(integer_impl<8, Signed>{ other }); }
	static integer_impl convert(const integer<16, Signed> other) { return convert(integer_impl<16, Signed>{ {other >> (16 / 2), other} }); }
	static integer_impl convert(const integer<32, Signed> other) { return convert(integer_impl<32, Signed>{ {other >> (32 / 2), other} }); }
	static integer_impl convert(const integer<64, Signed> other) { return convert(integer_impl<64, Signed>{ {other >> (64 / 2), other} }); }

	integer<Size, Signed> convert_to_int() const {
		if constexpr(Size != 8 && Size != 16 && Size != 32 && Size != 64) return *this;
		else if constexpr(Size == 8) { return storage; }
		else return (integer<Size, Signed>(storage.first) << (Size / 2)) + storage.second;
	}
	operator integer<Size, Signed>() const { return convert_to_int(); }



	std::pair<integer_impl, bool> modulus(integer_impl b) const {
		const integer_impl& a = *this;
		if constexpr (std::is_integral_v<decltype(storage)>) {
			// auto res = decltype(storage)(a.storage % b.storage);
			// constexpr auto size = sizeof(res) * 8;
			// if constexpr(requires{integer_impl{}.storage.first;})
			//     return { {{res >> (size / 2), res}}, false};
			// else return { {res}, false };
			return {convert(decltype(storage)(a.storage % b.storage)), false};
		} else if constexpr(is_power_of_two(Size)) {
			return {};
		} else {
			// return {convert(a.storage.modulus(b.storage).first.modulus(decltype(storage)::convert(max())).first), false};
		}
	}


	std::pair<integer_impl, bool> add(const integer_impl& b) const {
		const integer_impl& a = *this;
		if constexpr (std::is_integral_v<decltype(storage)>) {
			// auto res = decltype(storage)(a.storage + b.storage);
			// constexpr auto size = sizeof(res) * 8;
			// if constexpr(requires{integer_impl{}.storage.first;})
			//     return { {{res >> (size / 2), res}}, false};
			// else return { {res}, false };
			return {convert(decltype(storage)(a.storage + b.storage)), false};
		} else if constexpr(is_power_of_two(Size)) {
			// using Half = integer_impl<Size / 2, Signed>;
			// using Storage = decltype(integer_impl::storage.first);
			// auto as = Half::convert(a.storage.second);
			// auto bs = Half::convert(b.storage.second);
			// auto af = Half::convert(a.storage.first);
			// auto bf = Half::convert(b.storage.first);
			// auto [lower, lowerOverflow] = as.add(bs);
			// auto [tmp, tmpOverflow] = af.add(bf);
			// auto [upper, overflow] = tmp.add(Half::convert(int{lowerOverflow}));
			// return {integer_impl{{(Storage)upper, (Storage)lower}}, tmpOverflow | overflow};
		} else {
			// return {convert(a.storage.add(b.storage).first.modulus(decltype(storage)::convert(max())).first), false};
		}
	}

	template<uint32_t sizeA, bool signedA, uint32_t sizeB, bool signedB>
	static auto add(const integer_impl<sizeA, signedA>& a, const integer_impl<sizeB, signedB>& b) {
		using Promoted = promote<integer_impl<sizeA, signedA>, integer_impl<sizeB, signedB>>::type;
		return Promoted::convert(a).add(Promoted::convert(b));
	}

	std::pair<integer_impl, bool> multiply(integer_impl b) const {
		const integer_impl& a = *this;
		if constexpr (std::is_integral_v<decltype(storage)>) {
			// auto res = decltype(storage)(a.storage * b.storage);
			// constexpr auto size = sizeof(res) * 8;
			// if constexpr(requires{integer_impl{}.storage.first;})
			//     return { {{res >> (size / 2), res}}, false};
			// else return { {res}, false };
			return {convert(decltype(storage)(a.storage * b.storage)), false};
		} else if constexpr(is_power_of_two(Size)) {
			return {};
		} else {
			// return {convert(a.storage.multiply(b.storage).first.modulus(decltype(storage)::convert(max())).first), false};
		}
	}


};



template<uint32_t size>
using i = integer<size, true>;

template<uint32_t size>
using u = integer<size, false>;

int main() {
	auto x = i<10>::convert(50);
	auto y = i<69>::convert(6);
	auto x2 = promote<i<256>, i<10>>::type::convert(x);
	// auto x3 = i<128>::convert(x2);
	// auto [z, _] = i<2>::add(x, y);
	// auto tmp = x.add(y);
	// auto x = u<9>::max();
	int64_t dbg = x.storage;
}