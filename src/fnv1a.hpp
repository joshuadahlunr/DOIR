#include <fp/string.h>

namespace fnv {
	constexpr uint64_t FNV_OFFSET_BASIS = 14695981039346656037u;
	constexpr uint64_t FNV_PRIME = 1099511628211u;

	// Function to compute FNV-1a 64-bit hash
	template<typename T>
	struct fnv1a_64 {
		inline uint64_t operator()(const T& data) {
			auto bytes = (std::byte*)&data;
			uint64_t hash = FNV_OFFSET_BASIS;

			for (size_t i = 0; i < sizeof(T); ++i) {
				hash ^= uint64_t(bytes[i]);	// XOR the current byte into the hash
				hash *= FNV_PRIME;				// Multiply by the FNV prime number
			}

			return hash;
		}
	};
	template<>
	struct fnv1a_64<fp_view(std::byte)> {
		inline uint64_t operator()(fp_view(std::byte) bytes) {
			uint64_t hash = FNV_OFFSET_BASIS;

			for (size_t i = 0; i < fp_view_size(bytes); ++i) {
				hash ^= (uint64_t)fp_view_access(std::byte, bytes, i);	// XOR the current byte into the hash
				hash *= FNV_PRIME;			// Multiply by the FNV prime number
			}

			return hash;
		}
	};
	template<>
	struct fnv1a_64<fp_string_view> {
		inline uint64_t operator()(fp_string_view view) {
			return fnv1a_64<fp_view(std::byte)>{}({fp_view_literal(std::byte, fp_view_data(std::byte, view), fp_view_size(view))});
		}
	};
	template<>
	struct fnv1a_64<fp_string> {
		inline uint64_t operator()(fp_string str) {
			return fnv1a_64<fp_string_view>{}(fp_string_to_view(str));
		}
	};
}