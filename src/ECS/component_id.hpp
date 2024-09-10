#pragma once

#include <fp/string.h>
#include <fp/hash/map.h>
#include <stdexcept>
#include <utility>

#include "../utility/profile.hpp"

#include <typeinfo>
#ifdef __GNUC__
	#include <new>
	#include <cxxabi.h>
#endif

namespace doir::ecs {
#ifndef DOIR_DISABLE_STRING_COMPONENT_LOOKUP
	using ForwardPair = std::pair<fp_string, size_t>;
	using ReversePair = std::pair<size_t, fp_string>;

	fp_hashmap(ForwardPair)& doir_ecs_get_forward_map() noexcept
#ifdef DOIR_IMPLEMENTATION
	{ DOIR_ZONE_SCOPED_AGRO;
		static fp_hashmap(ForwardPair) map = [] {
			fp_hashmap(ForwardPair) map = nullptr;
			fp_hash_map_create_empty_table(ForwardPair, map, true);
			// Only hash and compare the first element in the pair (makes it a map!)
			fp_hash_map_set_hash_function(map, [](const fp_void_view key) noexcept -> uint64_t {
				assert(fp_view_size(key) == sizeof(ForwardPair));
				ForwardPair& pair = *fp_view_data(ForwardPair, key);
				{
					auto view = fp_string_to_view(pair.first);
					return FP_HASH_FUNCTION({fp_view_data_void(view), fp_view_size(view)});
				}
			});
			fp_hash_map_set_equal_function(map, [](const fp_void_view _a, const fp_void_view _b) noexcept -> bool {
				assert(fp_view_size(_a) == sizeof(ForwardPair)); assert(fp_view_size(_b) == sizeof(ForwardPair));
				ForwardPair& a = *fp_view_data(ForwardPair, _a);
				ForwardPair& b = *fp_view_data(ForwardPair, _b);
				return fp_string_compare(a.first, b.first) == 0;
			});
			fp_hash_map_set_finalize_function(map, [](fp_void_view _key) noexcept {
				assert(fp_view_size(_key) == sizeof(ForwardPair));
				ForwardPair& key = *fp_view_data(ForwardPair, _key);
				fp_string_free(key.first);
			});
			return map;
		}();
		return map;
	}
#else
		;
#endif

	fp_hashmap(ReversePair)& doir_ecs_get_reverse_map() noexcept
#ifdef DOIR_IMPLEMENTATION
	{ DOIR_ZONE_SCOPED_AGRO;
		static fp_hashmap(ReversePair) map = [] {
			fp_hashmap(ReversePair) map = nullptr;
			fp_hash_map_create_empty_table(ReversePair, map, false);
			// Only hash and compare the first element in the pair (makes it a map!)
			fp_hash_map_set_hash_function(map, [](const fp_void_view key) noexcept -> uint64_t {
				assert(fp_view_size(key) == sizeof(ReversePair));
				ReversePair& pair = *fp_view_data(ReversePair, key);
				return FP_HASH_FUNCTION(fp_void_view_literal(&pair.first, sizeof(pair.first)));
			});
			fp_hash_map_set_equal_function(map, [](const fp_void_view _a, const fp_void_view _b) noexcept -> bool{
				assert(fp_view_size(_a) == sizeof(ReversePair)); assert(fp_view_size(_b) == sizeof(ReversePair));
				ReversePair& a = *fp_view_data(ReversePair, _a);
				ReversePair& b = *fp_view_data(ReversePair, _b);
				return a.first == b.first;
			});
			// NOTE: Reverse map doesn't need a finalizer function, since both maps use the same string, they should all be freed by the forward map finalizer
			return map;
		}();
		return map;
	}
#else
		;
#endif
#endif // DOIR_DISABLE_STRING_COMPONENT_LOOKUP

	extern "C" {
		size_t doir_ecs_get_next_component_id() noexcept
#ifdef DOIR_IMPLEMENTATION
		{ DOIR_ZONE_SCOPED_AGRO;
			static size_t id = 0;
			return id++;
		}
#else
		;
#endif

#ifndef DOIR_DISABLE_STRING_COMPONENT_LOOKUP
		size_t doir_ecs_component_id_from_name_view(const fp_string_view view, bool create_if_not_found = true) noexcept
#ifdef DOIR_IMPLEMENTATION
		{ DOIR_ZONE_SCOPED_AGRO;
			bool free = false;
			fp_string name = fp_string_view_make_dynamic(view); // TODO: Is there a way to skip the allocation here?
			ForwardPair lookup{name, 0};
			if(!fp_hash_map_contains(ForwardPair, doir_ecs_get_forward_map(), lookup)) {
				if(create_if_not_found) {
					size_t id = doir_ecs_get_next_component_id();
					lookup.second = id;
					fp_hash_map_insert(ForwardPair, doir_ecs_get_forward_map(), lookup);
					ReversePair reverse{id, name};
					fp_hash_map_insert(ReversePair, doir_ecs_get_reverse_map(), reverse);
					return id;
				} else {
					fp_string_free(name);
					return -1;
				}
			} else free = true;

			auto out = fp_hash_map_find(ForwardPair, doir_ecs_get_forward_map(), lookup)->second;
			if (free) fp_string_free(name);
			return out;
		}
#else
		;
#endif
		inline size_t doir_ecs_component_id_from_name(const fp_string str, bool create_if_not_found = true) noexcept {
			DOIR_ZONE_SCOPED_AGRO;
			return doir_ecs_component_id_from_name_view(fp_string_to_view_const(str), create_if_not_found);
		}

		const fp_string doir_ecs_component_id_name(size_t componentID) noexcept
#ifdef DOIR_IMPLEMENTATION
		{ DOIR_ZONE_SCOPED_AGRO;
			ReversePair lookup{componentID, nullptr};
			auto res = fp_hash_map_find(ReversePair, doir_ecs_get_reverse_map(), lookup);
			if(res == nullptr) return nullptr;
			return res->second;
		}
#else
		;
#endif

		void doir_ecs_component_id_free_maps() noexcept
#ifdef DOIR_IMPLEMENTATION
		{ DOIR_ZONE_SCOPED_AGRO;
			fp_hash_map_free_finalize_and_null(ForwardPair, doir_ecs_get_forward_map());
			fp_hash_map_free_finalize_and_null(ReversePair, doir_ecs_get_reverse_map());
		}
#else
		;
#endif
#endif // DOIR_DISABLE_STRING_COMPONENT_LOOKUP
	}

#ifndef DOIR_DISABLE_STRING_COMPONENT_LOOKUP
	inline void component_id_free_maps() noexcept { doir_ecs_component_id_free_maps(); }
#endif // DOIR_DISABLE_STRING_COMPONENT_LOOKUP

	template<typename T>
	fp_string get_type_name(T reference = {}) {
		DOIR_ZONE_SCOPED_AGRO;
#ifdef __GNUC__
		int status;
		char* name = abi::__cxa_demangle(typeid(T).name(), 0, 0, &status);
		fp_string out = fp_string_promote_literal(name);
		free(name);
		switch(status) {
		break; case -1: throw std::bad_alloc();
		break; case -2: throw std::invalid_argument("mangled_name is not a valid name under the C++ ABI mangling rules.");
		break; case -3: throw std::invalid_argument("Type demangling failed, an argument is invalid");
		break; default: return out;
		}
#else
		return fp_string_promote_literal(typeid(T).name());
#endif
	}

	template<typename T, size_t Unique = 0>
	size_t& get_global_component_id_private(T reference = {}) noexcept {
		DOIR_ZONE_SCOPED_AGRO;
		static size_t id = doir_ecs_get_next_component_id();
		return id;
	}

	// Warning: This function is very expensive (~5 microseconds vs ~350 nanoseconds) the first time it is called (for a new type)!
	template<typename T, size_t Unique = 0>
	size_t get_global_component_id(T reference = {}) noexcept {
		DOIR_ZONE_SCOPED_AGRO;
		auto id = get_global_component_id_private<T, Unique>();
#ifndef DOIR_DISABLE_STRING_COMPONENT_LOOKUP
		static bool once = [id]{
			auto name = get_type_name<T>();
			if constexpr(Unique > 0) {
				fp_string num = fp_string_format("%u", Unique);
				fp_string_concatenate_inplace(name, num);
				fp_string_free(num);
			}
			ForwardPair forward{name, id};
			fp_hash_map_insert(ForwardPair, doir_ecs_get_forward_map(), forward);
			ReversePair reverse{id, name};
			fp_hash_map_insert(ReversePair, doir_ecs_get_reverse_map(), reverse);
			return false;
		}();
#endif
		return id;
	}

} // doir::ecs