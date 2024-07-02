#include <cstddef>
#include <cstdint>
#include <span>
#include <string>
#include <string_view>

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
	struct fnv1a_64<std::span<std::byte>> {
		inline uint64_t operator()(std::span<std::byte> bytes) {
			uint64_t hash = FNV_OFFSET_BASIS;

			for (size_t i = 0; i < bytes.size(); ++i) {
				hash ^= uint64_t(bytes[i]);	// XOR the current byte into the hash
				hash *= FNV_PRIME;			// Multiply by the FNV prime number
			}

			return hash;
		}
	};
	template<>
	struct fnv1a_64<std::string> {
		inline uint64_t operator()(const std::string& bytes) {
			return fnv1a_64<std::span<std::byte>>{}({(std::byte*)bytes.data(), bytes.size()});
		}
	};
	template<>
	struct fnv1a_64<std::string_view> {
		inline uint64_t operator()(std::string_view bytes) {
			return fnv1a_64<std::span<std::byte>>{}({(std::byte*)bytes.data(), bytes.size()});
		}
	};
}