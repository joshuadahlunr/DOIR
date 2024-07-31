#pragma once

#include <vector>
#include <string>

#ifdef _MSC_VER
    #define DOIR_INLINE __forceinline
#elif defined(__GNUC__) || defined(__clang__)  // GCC and Clang
    #define DOIR_INLINE inline __attribute__((always_inline))
#elif defined(__INTEL_COMPILER)  // Intel Compiler
    #define DOIR_INLINE inline __forceinline
#else
    #define DOIR_INLINE  // Default fallback
#endif

namespace doir {

	inline std::vector<std::string_view> split(std::string_view s, std::string delimiter) {
		size_t pos_start = 0, pos_end, delim_len = delimiter.length();
		std::string_view token;
		std::vector<std::string_view> res;

		while ((pos_end = s.find(delimiter, pos_start)) != std::string::npos) {
			token = s.substr (pos_start, pos_end - pos_start);
			pos_start = pos_end + delim_len;
			res.push_back (token);
		}

		res.push_back (s.substr (pos_start));
		return res;
	}

	template<std::floating_point T>
	bool float_equal(T a, T b, T epsilon = .00001) {
		return std::abs(a - b) < epsilon;
	}

}