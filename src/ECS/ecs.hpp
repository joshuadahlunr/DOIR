#pragma once

#include "component_id.hpp"

#include <fp/dynarray.h>

#include <algorithm>
#include <limits>
#include <utility>

#include "../utility/profile.hpp"

namespace doir::ecs {

	using entity_t = size_t;
	static constexpr size_t invalid_entity = 0;

	struct Storage {
		static constexpr size_t invalid = std::numeric_limits<size_t>::max();
		size_t element_size = invalid;
		fp_dynarray(uint8_t) raw = nullptr;
		bool should_leak = false; // Useful when shutting down, if we are closing we can just leave memory cleanup to the operating system for a bit of added performance!


		inline Storage() noexcept : element_size(invalid), raw(nullptr) {}
		inline Storage(size_t element_size, size_t reserved_element_count = 64) noexcept : element_size(element_size), raw(nullptr) { fpda_reserve(raw, reserved_element_count * element_size); }

		template<typename Tcomponent>
		inline Storage(Tcomponent reference = {}, size_t reserved_element_count = 64) noexcept : Storage(sizeof(Tcomponent), reserved_element_count) {}
		Storage(const Storage& o) = delete;
		inline Storage(Storage&& o) { *this = std::move(o); }

		Storage& operator=(const Storage& o) = delete;
		inline Storage& operator=(Storage&& o) {
			DOIR_ZONE_SCOPED_AGRO;
			element_size = o.element_size;
			if(raw) fpda_free_and_null(raw);
			raw = std::exchange(o.raw, nullptr);
			should_leak = o.should_leak;
			return *this;
		}

		inline ~Storage() noexcept { DOIR_ZONE_SCOPED_AGRO; if(!should_leak && raw) fpda_free_and_null(raw); }

		template<typename T>
		inline T* data() noexcept {
			DOIR_ZONE_SCOPED_AGRO;
			assert(sizeof(T) == element_size); // Implies element_size != invalid (since no type should ever be that big!)
			return (T*)raw;
		}
		template<typename T>
		inline const T* data() const noexcept {
			DOIR_ZONE_SCOPED_AGRO;
			assert(sizeof(T) == element_size); // Implies element_size != invalid (since no type should ever be that big!)
			return (const T*)raw;
		}

		inline size_t size() const noexcept { DOIR_ZONE_SCOPED_AGRO; return fpda_size(raw) / element_size; }
		inline bool empty() const noexcept { DOIR_ZONE_SCOPED_AGRO; return size() == 0; }

		inline void* get(entity_t e) noexcept {
			DOIR_ZONE_SCOPED_AGRO;
			assert(e < size());
			return raw + e * element_size;
		}
		inline const void* get(entity_t e) const noexcept {
			DOIR_ZONE_SCOPED_AGRO;
			assert(e < size());
			return raw + e * element_size;
		}
		template<typename T>
		inline T& get(entity_t e) noexcept {
			DOIR_ZONE_SCOPED_AGRO;
			assert(e < size());
			return *(data<T>() + e);
		}
		template<typename T>
		inline const T& get(entity_t e) const noexcept {
			DOIR_ZONE_SCOPED_AGRO;
			assert(e < size());
			return *(data<T>() + e);
		}

		template<typename T>
		void allocate(size_t count = 1) noexcept {
			DOIR_ZONE_SCOPED_AGRO;
			auto data = this->data<T>();
			auto originalEnd = size();
			fpda_grow(raw, element_size * count);
			for (size_t i = 0; i < count; i++)
				new(data + originalEnd + i) T();
		}
		inline void allocate(size_t count = 1) noexcept {
			DOIR_ZONE_SCOPED_AGRO;
			fpda_grow_and_initialize(raw, element_size * count, 0);
		}

		template<typename T>
		inline T& get_or_allocate(entity_t e) noexcept {
			DOIR_ZONE_SCOPED_AGRO;
			size_t size = this->size();
			if(size <= e)
				allocate<T>(std::max<int64_t>(int64_t(e) - size + 1, 1));
			return get<T>(e);
		}
		inline void* get_or_allocate(entity_t e) noexcept {
			DOIR_ZONE_SCOPED_AGRO;
			size_t size = this->size();
			if(size <= e)
				allocate(std::max<int64_t>(int64_t(e) - size + 1, 1));
			return get(e);
		}
	};

	struct TrivialModule {
		fp_dynarray(fp_dynarray(size_t)) entity_component_indices = nullptr;
		fp_dynarray(Storage) storages = nullptr;
		fp_dynarray(entity_t) freelist = nullptr;

		inline void free() {
			DOIR_ZONE_SCOPED_AGRO;
			if(entity_component_indices) {
				fpda_iterate(entity_component_indices)
					if(*i) fpda_free_and_null(*i);
				fpda_free_and_null(entity_component_indices);
			}
			if(storages) {
				fpda_iterate(storages)
					i->~Storage();
				fpda_free_and_null(storages);
			}
			if(freelist) fpda_free_and_null(freelist);
		}

		Storage& get_storage(size_t componentID, size_t element_size = Storage::invalid) noexcept {
			DOIR_ZONE_SCOPED_AGRO;
			if(!storages || fpda_size(storages) <= componentID) {
				size_t old = fpda_size(storages);
				fpda_grow_to_size(storages, componentID + 1);
				for(size_t i = old, size = fpda_size(storages); i < size; ++i)
					new(storages + i) Storage();
			}
			if(storages[componentID].element_size == Storage::invalid) {
				assert(element_size != Storage::invalid);
				storages[componentID] = Storage(element_size);
			}
			return storages[componentID];
		}
		inline const Storage& get_storage(size_t componentID, size_t element_size = Storage::invalid) const noexcept {
			DOIR_ZONE_SCOPED_AGRO;
			assert(fpda_size(storages) > componentID);
			assert(storages[componentID].element_size != Storage::invalid);
			return storages[componentID];
		}

		template<typename T, size_t Unique = 0>
		inline Storage& get_storage() noexcept { DOIR_ZONE_SCOPED_AGRO; return get_storage(get_global_component_id<T, Unique>(), sizeof(T)); }
		template<typename T, size_t Unique = 0>
		inline const Storage& get_storage() const noexcept { DOIR_ZONE_SCOPED_AGRO; return get_storage(get_global_component_id<T, Unique>(), sizeof(T)); }

		bool release_storage(size_t componentID) noexcept {
			DOIR_ZONE_SCOPED_AGRO;
			if(fpda_size(storages) <= componentID) return false;
			if(storages[componentID].element_size == Storage::invalid) return false;
			storages[componentID] = Storage();
			return true;
		}
		template<typename T, size_t Unique = 0>
		inline bool release_storage() noexcept { DOIR_ZONE_SCOPED_AGRO; return release_storage(get_global_component_id<T, Unique>()); }

		entity_t create_entity() noexcept {
			DOIR_ZONE_SCOPED_AGRO;
			if(!freelist || fpda_empty(freelist)) {
				entity_t e = entity_component_indices ? fpda_size(entity_component_indices) : 0;
				if(e == 0) fpda_reserve(entity_component_indices, 16);
				fpda_push_back(entity_component_indices, nullptr);
				if(e == 0) return create_entity(); // Skip entity zero!
				return e;
			}

			entity_t e = *fpda_pop_back(freelist);
			if(entity_component_indices[e])
				fpda_free_and_null(entity_component_indices[e]);
			fpda_push_back(entity_component_indices[e], Storage::invalid);
			return e;
		}

		bool release_entity(entity_t e, bool clearMemory = true) noexcept {
			DOIR_ZONE_SCOPED_AGRO;
			if(e >= fpda_size(entity_component_indices)) return false;

			// if(clearMemory && storages && !fpda_empty(storages))
			// 	for(size_t i = 0, size = fpda_size(storages); i < size; ++i)
			// 		storages[i].remove(*this, e, i);

			if(entity_component_indices[e])
				fpda_free_and_null(entity_component_indices[e]);

			fpda_push_back(freelist, e);
			return true;
		}

		#define DOIR_ECS_ADD_COMPONENT_COMMON(componentID, element_size)\
			assert(fpda_size(entity_component_indices) > e);\
			if(!entity_component_indices[e] || fpda_empty(entity_component_indices[e]) || fpda_size(entity_component_indices[e]) <= componentID)\
				fpda_grow_to_size_and_initialize(entity_component_indices[e], componentID + 1, Storage::invalid);\
			auto& storage = get_storage(componentID, element_size);\
			entity_component_indices[e][componentID] = storage.size()
		void* add_component(entity_t e, size_t componentID, size_t element_size) noexcept {
			DOIR_ZONE_SCOPED_AGRO;
			DOIR_ECS_ADD_COMPONENT_COMMON(componentID, element_size);
			return storage.get_or_allocate(e);
		}
		template<typename T, size_t Unique = 0>
		T& add_component(entity_t e) noexcept {
			DOIR_ZONE_SCOPED_AGRO;
			size_t componentID = get_global_component_id<T, Unique>();
			{ DOIR_ZONE_SCOPED_NAMED_AGRO("Rest");
				DOIR_ECS_ADD_COMPONENT_COMMON(componentID, sizeof(T));
				auto& res = storage.template get_or_allocate<T>(entity_component_indices[e][componentID]);

				// if constexpr(detail::is_with_entity_v<Tcomponent>)
				// 	res.entity = e;
				return res;
			}
		}
		#undef DOIR_ECS_ADD_COMPONENT_COMMON

		// template<typename Tcomponent, size_t Unique = 0>
		// bool remove_component(entity e) { return get_storage<Tcomponent, Unique>()->template remove<Tcomponent>(*this, e); }

		#define DOIR_ECS_GET_COMPONENT_COMMON(componentID)\
			assert(entity_component_indices);\
			assert(e < fpda_size(entity_component_indices));\
			assert(entity_component_indices[e]);\
			assert(fpda_size(entity_component_indices[e]) > componentID);\
			assert(entity_component_indices[e][componentID] != Storage::invalid);
		void* get_component(entity_t e, size_t componentID) noexcept {
			DOIR_ZONE_SCOPED_AGRO;
			DOIR_ECS_GET_COMPONENT_COMMON(componentID);
			return get_storage(componentID).get(entity_component_indices[e][componentID]);
		}
		const void* get_component(entity_t e, size_t componentID) const noexcept {
			DOIR_ZONE_SCOPED_AGRO;
			DOIR_ECS_GET_COMPONENT_COMMON(componentID);
			return get_storage(componentID).get(entity_component_indices[e][componentID]);
		}
		template<typename T, size_t Unique = 0>
		T& get_component(entity_t e) noexcept {
			DOIR_ZONE_SCOPED_AGRO;
			size_t componentID = get_global_component_id<T, Unique>();
			DOIR_ECS_GET_COMPONENT_COMMON(componentID);
			return get_storage(componentID).template get<T>(entity_component_indices[e][componentID]);
		}
		template<typename T, size_t Unique = 0>
		const T& get_component(entity_t e) const noexcept {
			DOIR_ZONE_SCOPED_AGRO;
			size_t componentID = get_global_component_id<T, Unique>();
			DOIR_ECS_GET_COMPONENT_COMMON(componentID);
			return get_storage(componentID).template get<T>(entity_component_indices[e][componentID]);
		}
		#undef DOIR_ECS_GET_COMPONENT_COMMON

		inline bool has_component(entity_t e, size_t componentID) const noexcept {
			DOIR_ZONE_SCOPED_AGRO;
			return entity_component_indices && fpda_size(entity_component_indices) > e
				&& entity_component_indices[e] && fpda_size(entity_component_indices[e]) > componentID
				&& entity_component_indices[e][componentID] != Storage::invalid;
		}
		template<typename T, size_t Unique = 0>
		inline bool has_component(entity_t e) const noexcept {
			DOIR_ZONE_SCOPED_AGRO;
			return has_component(e, get_global_component_id<T, Unique>());
		}
	};

	struct Module : public TrivialModule {
		bool should_leak = false; // Useful when shutting down, if we are closing we can just leave memory cleanup to the operating system for a bit of added performance!

		Module() = default;
		Module(const Module&) = delete; // Storages need to become copyable to change this...
		Module(Module&& o) { *this = std::move(o); }
		Module& operator=(const Module& o) = delete;
		Module& operator=(Module&& o) {
			DOIR_ZONE_SCOPED_AGRO;
			free();
			entity_component_indices = std::exchange(o.entity_component_indices, nullptr);
			storages = std::exchange(o.storages, nullptr);
			freelist = std::exchange(o.freelist, nullptr);
			return *this;
		}

		~Module() {
			if(!should_leak) free();
		}
	};

}