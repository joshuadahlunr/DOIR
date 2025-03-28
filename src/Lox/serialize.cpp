#include "fp/dynarray.h"
#include "fp/dynarray.hpp"
#include "lox.hpp"
#include <cstdint>

namespace doir::Lox {
	// Root : uint64_t
	// BufferSize : uint64_t
	// BufferString : char[BufferSize]
	// EntityCount : uint64_t
	// [EntityCount] {
	//		ComponentCount : uint64_t
	//		Components : uint64_t[ComponentCount]
	// }
	// StorageCount : uint64_t
	// [StorageCount] {
	//		ElementSize : uint64_t
	//		ElementCount : uint64_t
	//		Data : char[ElementSize * ElementCount]
	// }

	fp_dynarray(std::byte) to_binary(TrivialModule& module, ecs::entity_t root) {
		uint64_t offset = 0;
		fp::dynarray<std::byte> out;
		
		// Pre meditated size
		uint64_t string_len = fp_string_length(module.buffer);
		out.resize(string_len + 3 * sizeof(uint64_t)); // 3 uint64_t's: 1 for string length 1 for entity count 1 for root
		// Copy root
		*(uint64_t*)(out.raw + offset) = root; offset += sizeof(uint64_t);
		// Copy buffer string
		*(uint64_t*)(out.raw + offset) = string_len; offset += sizeof(uint64_t);
		memcpy(out.raw + offset, module.buffer, string_len); offset += string_len;

		// Copy entity count
		*(uint64_t*)(out.raw + offset) = module.entity_count(); offset += sizeof(uint64_t);
		// Copy each entity's component count and components
		auto entities = (fp::pointer<fp::pointer<size_t>>&)(module.entity_component_indices);
		for(auto& entity: entities) {
			size_t size = entity.size();
			out.resize(offset + (size + 1) * sizeof(uint64_t));
			*(uint64_t*)(out.raw + offset) = size; offset += sizeof(uint64_t);
			if constexpr(sizeof(uint64_t) == sizeof(size_t)) 
				memcpy(out.raw + offset, entity.raw, size * sizeof(uint64_t)), offset += size * sizeof(uint64_t);	
			else for(size_t i = 0; i < size; ++i) // If size_t is not a u64 we have to copy components across manually
				*(uint64_t*)(out.raw + offset) = entity[i], offset += sizeof(uint64_t);	
		}

		// Copy storage count
		auto storages = fp::pointer<ecs::Storage>{module.storages};
		out.resize(offset + sizeof(uint64_t));
		*(uint64_t*)(out.raw + offset) = storages.size(); offset += sizeof(uint64_t);
		// Copy each storage's size, element_size, and data
		for(auto& storage: storages) {
			uint64_t element_size = storage.element_size;
			uint64_t size = storage.size();
			uint64_t byte_size = element_size != ecs::Storage::invalid ? element_size * size : 0;
			out.resize(offset + 2 * sizeof(uint64_t) + byte_size);

			*(uint64_t*)(out.raw + offset) = element_size; offset += sizeof(uint64_t);
			*(uint64_t*)(out.raw + offset) = byte_size; offset += sizeof(uint64_t);
			if(byte_size > 0) memcpy(out.raw + offset, storage.raw, byte_size); offset += byte_size;
		}

		return out.data();
	}

	std::pair<TrivialModule, ecs::entity_t> from_binary(fp_dynarray(std::byte) binary) {
		size_t offset = 0, binary_size = fp_size(binary);
		TrivialModule module;
		// Load root
		ecs::entity_t root = *(uint64_t*)(binary + offset); assert_with_side_effects((offset += sizeof(uint64_t)) <= binary_size);

		// Load buffer string
		size_t string_len = *(uint64_t*)(binary + offset); assert_with_side_effects((offset += sizeof(uint64_t)) <= binary_size);
		module.buffer = fp_string_view_make_dynamic(fp_string_view_literal((char*)binary + offset, string_len)); assert_with_side_effects((offset += string_len) <= binary_size);

		// Load entity count
		size_t entity_count = *(uint64_t*)(binary + offset); assert_with_side_effects((offset += sizeof(uint64_t)) <= binary_size);
		module.entity_component_indices = fp::dynarray<size_t*>{module.entity_component_indices}.resize(entity_count).fill(nullptr).data();
		// Load entity component count and indicies
		auto entities = (fp::pointer<fp::dynarray<size_t>>&)module.entity_component_indices;
		for(auto& entity: entities) {
			size_t component_count = *(uint64_t*)(binary + offset); assert_with_side_effects((offset += sizeof(uint64_t)) <= binary_size);
			entity = entity.resize(component_count);
			if constexpr(sizeof(uint64_t) == sizeof(size_t)) {
				memcpy(entity.raw, binary + offset, component_count * sizeof(uint64_t)); assert_with_side_effects((offset += component_count * sizeof(uint64_t)) <= binary_size);
			} else for(size_t i = 0; i < component_count; ++i) { // If size_t is not a u64 we have to copy components across manually
				*(entity.raw + i) = *(uint64_t*)(binary + offset); assert_with_side_effects((offset += sizeof(uint64_t)) <= binary_size);
			}
		}

		// Load storage count
		size_t storage_count = *(uint64_t*)(binary + offset); assert_with_side_effects((offset += sizeof(uint64_t)) <= binary_size);
		module.storages = fp::dynarray<ecs::Storage>{module.storages}.resize(storage_count).data();
		// Load each storage's size, element_size, and data
		auto storages = fp::pointer<ecs::Storage>{module.storages};
		for(auto& storage: storages) {
			storage.element_size = *(uint64_t*)(binary + offset); assert_with_side_effects((offset += sizeof(uint64_t)) <= binary_size);
			size_t byte_size = *(uint64_t*)(binary + offset); assert_with_side_effects((offset += sizeof(uint64_t)) <= binary_size);
			if(storage.element_size != ecs::Storage::invalid) {
				storage.raw = fp::dynarray<uint8_t>{}.grow_to_size(byte_size).data();
				memcpy(storage.raw, binary + offset, byte_size); assert_with_side_effects((offset += byte_size) <= binary_size);
			}
		}

		assert(offset == binary_size);
		return {module, root};
	}
}