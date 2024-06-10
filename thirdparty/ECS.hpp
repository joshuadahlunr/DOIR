// This is free and unencumbered software released into the public domain.

// Anyone is free to copy, modify, publish, use, compile, sell, or
// distribute this software, either in source code form or as a compiled
// binary, for any purpose, commercial or non-commercial, and by any
// means.

// In jurisdictions that recognize copyright laws, the author or authors
// of this software dedicate any and all copyright interest in the
// software to the public domain. We make this dedication for the benefit
// of the public at large and to the detriment of our heirs and
// successors. We intend this dedication to be an overt act of
// relinquishment in perpetuity of all present and future rights to this
// software under copyright law.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
// IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR
// OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
// ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.

// For more information, please refer to <https://unlicense.org>

#ifndef __ECS__HPP__
#define __ECS__HPP__

#include <cassert>
#include <cstring>
#include <limits>
#include <optional>
#include <queue>
#include <stdexcept>
#include <string>
#include <unordered_map>

#ifdef __GNUC__
	#include <new>
	#include <cxxabi.h>
#elifdef _MSC_VER
	#include <typeinfo>
#endif

#ifdef ECS_IMPLEMENTATION
/**
* @var ecs::globalComponentCounter
* Global component counter.
*/
size_t globalComponentCounter = 0;

/**
* @var ecs::globalComponentForwardLookup
* Forward lookup map for components by name to their IDs.
*/
std::unordered_map<std::string, size_t> globalComponentForwardLookup = {};

/**
* @var ecs::globalComponentReverseLookup
* Reverse lookup map for components by ID to their names.
*/
std::unordered_map<size_t, std::string> globalComponentReverseLookup = {};
#else
/**
* @var ecs::globalComponentCounter
* Global component counter.
*/
extern size_t globalComponentCounter;

/**
* @var ecs::globalComponentForwardLookup
* Forward lookup map for components by name to their IDs.
*/
extern std::unordered_map<std::string, size_t> globalComponentForwardLookup;

/**
* @var ecs::globalComponentReverseLookup
* Reverse lookup map for components by ID to their names.
*/
extern std::unordered_map<size_t, std::string> globalComponentReverseLookup;
#endif

namespace ecs {
	using std::optional;

	/**
	* @class optional_reference
	* @brief A wrapper around a reference_wrapper that provides optional-like behavior.
	*
	* This class is used to create references to entities and their components.
	*/
	template<typename T>
	class optional_reference: public std::optional<std::reference_wrapper<T>> {
		using Base = std::optional<std::reference_wrapper<T>>;
	public:
		inline constexpr std::reference_wrapper<T> reference_wrapper() { return Base::operator*(); }

		/**
		* @brief Get a const reference to the wrapped value.
		*
		* Returns a const reference to the wrapped value if it is valid, otherwise returns nullptr.
		*/
		inline constexpr const T* operator->() const noexcept { return &reference_wrapper().get(); }

		/**
		* @brief Get a non-const reference to the wrapped value.
		*
		* Returns a non-const reference to the wrapped value if it is valid, otherwise returns nullptr.
		*/
		inline constexpr T* operator->() noexcept { return &reference_wrapper().get(); }

		/**
		* @brief Get a const reference to the wrapped value.
		*
		* Returns a const reference to the wrapped value if it is valid, otherwise returns nullptr.
		*/
		inline constexpr T& operator*() /*&*/ noexcept { return reference_wrapper().get(); }

		/**
		* @brief Get a non-const reference to the wrapped value.
		*
		* Returns a non-const reference to the wrapped value if it is valid, otherwise returns nullptr.
		*/
		inline constexpr const T& operator*() const/*&*/ noexcept { return reference_wrapper().get(); }

		inline constexpr T& value() /*&*/ { return reference_wrapper().get(); }
		inline constexpr const T& value() const /*&*/ { return reference_wrapper().get(); }

		template< class U >
		inline constexpr T value_or( U&& default_value ) const& { return bool(*this) ? reference_wrapper().get() : static_cast<T>(std::forward<U>(default_value)); }

#if __cpp_lib_optional >= 202110L
		// TODO: Wrap and_then, transform, or_else
#endif
	};


	/**
	* @brief Get the name of a type.
	*
	* This function returns the name of the given type as a std::string.
	*/
	template<typename T>
	std::string get_type_name(T reference = {}) {
#ifdef __GNUC__
		int status;
		char* name = abi::__cxa_demangle(typeid(T).name(), 0, 0, &status);
		if(status == -1) throw std::bad_alloc();
		else if(status == -2) throw std::invalid_argument("mangled_name is not a valid name under the C++ ABI mangling rules.");
		else if(status == -3) throw std::invalid_argument("Type demangling failed, an argument is invalid");
		std::string out = name;
		free(name);
		return out;
#else
		return typeid(T).name();
#endif
	}

	/**
	* @brief Get the global component ID for an entity and its components.
	*
	* This function returns the global component ID for an entity and its components.
	*/
	template<typename T>
	size_t get_global_component_id(T reference = {}) {
		static size_t id = globalComponentCounter++;
		static bool run_once = []{
			std::string type_name = get_type_name<T>();
			globalComponentForwardLookup[type_name] = id;
			globalComponentReverseLookup[id] = type_name;
			return true;
		}();
		return id;
	}

	/**
	* @brief Get the global component ID by name.
	*
	* This function returns the global component ID for a given component type name.
	*/
	static size_t get_global_component_id_by_name(std::string_view _typename) {
		auto type_name = std::string(_typename);
		if(!globalComponentForwardLookup.contains(type_name)) {
			size_t id = globalComponentCounter++;
			globalComponentForwardLookup[type_name] = id;
			globalComponentReverseLookup[id] = type_name;
		}

		return globalComponentForwardLookup[type_name];
	}

	/**
	* @brief Get the global component name by ID.
	*
	* This function returns the global component name for a given component ID.
	*/
	static std::string_view get_global_component_name(size_t id) {
		if(!globalComponentReverseLookup.contains(id))
			return {nullptr, 0};

		return globalComponentReverseLookup[id];
	}



#ifndef ECS_ENTITY_TYPE
	#define ECS_ENTITY_TYPE size_t
#endif
	using entity = ECS_ENTITY_TYPE;


	/**
	* @brief Scene structure for storing and managing entities and components.
	*/
	struct scene {
		/**
		* @brief A structure for storing components of various types.
		*/
		struct component_storage {
			/**
			* @brief An invalid index value.
			*/
			static constexpr size_t invalid = std::numeric_limits<size_t>::max();
			/**
			 * @brief Size (in bytes) of the stored type
			 * @note this is one of the few points of validation we have
			 */
			size_t element_size = invalid;
			/**
			 * @brief types stored as a container of raw bytes
			 * @note the scene will track offsets indicating where certain elements begin
			 */
			std::vector<std::byte> data;

			/**
			* @brief Constructor for the component storage with a default element size and initialized data.
			*/
			component_storage() : element_size(invalid), data(1, std::byte{0}) {}

			/**
			* @brief Constructor for the component storage with a specified element size and reserved memory.
			*
			* @param element_size The size of each component.
			*/
			component_storage(size_t element_size, size_t element_count = 5) : element_size(element_size) { data.reserve(element_count * element_size); }

			/**
			* @brief Template constructor that initializes the component storage with a specified element size and type.
			*
			* @tparam Tcomponent The type of component.
			* @param reference A reference to the component (default is an empty object).
			*/
			template<typename Tcomponent>
			component_storage(Tcomponent reference = {}, size_t element_count = 5) : component_storage(sizeof(Tcomponent), element_count) {}

			/**
			* @brief Template function that retrieves a component by its entity index, if it exists and matches the expected type.
			*
			* @tparam Tcomponent The type of component.
			* @param e The entity index.
			* @return An optional reference to the retrieved component, or an empty optional if it doesn't exist or doesn't match the expected type.
			*/
			template<typename Tcomponent>
			optional_reference<const Tcomponent> get(entity e) const {
				if (!(sizeof(Tcomponent) == element_size)) return {};
				if (!(e < (data.size() / element_size))) return {};
				return {*(Tcomponent*)(data.data() + e * element_size)};
			}
			template<typename Tcomponent>
			optional_reference<Tcomponent> get(entity e) {
				if (auto got = ((const component_storage*)this)->get<Tcomponent>(e); got) return {const_cast<Tcomponent&>(*got)}; else return {};
			}

			/**
			* @brief Template function that allocates memory for a specified number of components.
			*
			* @tparam Tcomponent The type of component.
			* @param count The number of components to allocate.
			* @return An optional pair containing the allocated component and its entity index, or an empty optional if allocation fails.
			*/
			template<typename Tcomponent>
			std::optional<std::pair<Tcomponent&, size_t>> allocate(size_t count = 1) {
				if (!(sizeof(Tcomponent) == element_size)) return {};
				// if (!(count < 100)) return {};
				auto originalEnd = data.size();
				data.insert(data.end(), element_size * count, std::byte{0});
				for (size_t i = 0; i < count - 1; i++) // Skip the last one
					new(data.data() + originalEnd + i * element_size) Tcomponent();
				return {{
					*new(data.data() + data.size() - element_size) Tcomponent(),
					data.size() / element_size
				}};
			}

			/**
			* @brief Template function that retrieves or allocates a component by its entity index, if it doesn't exist.
			*
			* @tparam Tcomponent The type of component.
			* @param e The entity index.
			* @return An optional reference to the retrieved or allocated component, or an empty optional if allocation fails.
			*/
			template<typename Tcomponent>
			optional_reference<Tcomponent> get_or_allocate(entity e) {
				if (!(sizeof(Tcomponent) == element_size)) return {};
				size_t size = data.size() / element_size;
				if (size <= e)
					if ( !allocate<Tcomponent>(std::max<int64_t>(int64_t(e) - size + 1, 1)) ) return {};
				return get<Tcomponent>(e);
			}

			/**
			* @brief function which determines how many components are currently stored inside this storage.
			*
			* @return How many components are currently stored inside this storage.
			* @note Some of these components may be uninitialized!
			*/
			size_t size() const { return data.size() / element_size; }
			/**
			* @brief Template function that checks if the component storage is empty.
			*
			* @return True if the component storage is empty, false otherwise.
			*/
			bool empty() const {
				return size() == 0;
			}


			/**
			 * @brief Function which removes the value associated with the provided entity
			 * @note performs a swap with the last stored value thus needs to update offset information stored in the scene
			 * 
			 * @tparam Tcomponent The component type to remove (calculates the component_id automatically if provided)
			 * @param scene The scene storing offset information
			 * @param e The entity to remove
			 * @param component_id The component id to remove if a type is not automatically provided!
			 * @return true if the element was successfully removed, false if an error occured
			 */
			template<typename Tcomponent>
			bool remove(struct scene& scene, entity e) { return remove(scene, e, get_global_component_id<Tcomponent>()); }
			bool remove(struct scene&, entity, size_t component_id);
			

		friend struct scene;
		protected:
			/**
			* @brief Template function that swaps two components.
			*
			* @tparam Tcomponent The type of component.
			* @param a The index of the first component.
			* @param b The index of the second component.
			* @param buffer an optional buffer to store intermediates in
			* @note providing a buffer is useful for reuse when multiple swaps are performed in sequence
			* @return false if an error occured, true otherwise
			*/
			template<typename Tcomponent>
			bool swap(size_t a, std::optional<size_t> _b = {}) {
				size_t b = _b.value_or(size() - 1);
				if(a > size()) return false;
				if(b > size()) return false;

				Tcomponent* aPtr = data.data() + a * sizeof(Tcomponent);
				Tcomponent* bPtr = data.data() + b * sizeof(Tcomponent);
				std::swap(*aPtr, *bPtr);
				return true;
			}
			bool swap(size_t a, std::optional<size_t> _b = {}, std::vector<std::byte>& buffer = []() -> std::vector<std::byte>& { 
				static std::vector<std::byte> global;
				global.clear();
				return global; 
			}()) {
				if(buffer.empty()) buffer.resize(element_size);
				if(buffer.size() < element_size) return false;

				size_t b = _b.value_or(size() - 1);
				if(a > size()) return false;
				if(b > size()) return false;

				void* aPtr = data.data() + a * element_size;
				void* bPtr = data.data() + b * element_size;
				std::memcpy(buffer.data(), aPtr, element_size);
				std::memcpy(aPtr, bPtr, element_size);
				std::memcpy(bPtr, buffer.data(), element_size);
				return true;
			}
		};

		/**
		* @brief Vector of entity offsets, where each offsets represents an entity's component indices in the storage.
		*/
		std::vector<std::vector<entity>> entity_component_indices;

		/**
		* @brief Vector of storage objects for storing and retrieving components.
		*/
		std::vector<component_storage> storages = {component_storage()};

		/**
		* @brief Queue of available entities that can be reused.
		*/
		std::queue<entity> freelist;

		/**
		* @brief Get the size of the scene, excluding free entities if ignoreFree is false.
		*
		* @param ignoreFree Whether to include free entities in the count.
		* @return The size of the scene.
		*/
		template<bool ignoreFree = false>
		size_t size() const {
			size_t size = entity_component_indices.size();
			if constexpr(!ignoreFree) size -= freelist.size();
			return size;
		}

		/**
		* @brief Get a reference to a storage object for the given component type.
		*
		* @tparam Tcomponent The component type to retrieve.
		* @return An optional reference to the storage object, or an empty optional if the storage does not exist.
		*/
		template<typename Tcomponent>
		optional_reference<component_storage> get_storage() {
			size_t id = get_global_component_id<Tcomponent>();
			if(storages.size() <= id)
				storages.resize(id + 1, component_storage());
			if (storages[id].element_size == component_storage::invalid)
				storages[id] = component_storage(Tcomponent{});
			return {storages[id]};
		}
		template<typename Tcomponent>
		optional_reference<const component_storage> get_storage() const {
			size_t id = get_global_component_id<Tcomponent>();
			if(!(storages.size() > id)) return {};
			if(!(storages[id].element_size != component_storage::invalid)) return {};
			return {storages[id]};
		}

		/**
		* @brief Release a storage object for the given component type freeing all of the memory of the associated components
		*
		* @tparam Tcomponent The component type to release.
		* @return Whether the release was successful.
		*/
		template<typename Tcomponent>
		bool release_storage() {
			size_t id = get_global_component_id<Tcomponent>();
			if(storages.size() <= id) return false;
			if(storages[id].element_size == component_storage::invalid) return false;
			storages[id] = component_storage();
			return true;
		}

		/**
		* @brief Create a new entity and add it to the scene.
		*
		* @return The ID of the newly created entity.
		*/
		entity create_entity() {
			if(freelist.empty()) {
				entity e = entity_component_indices.size();
				entity_component_indices.emplace_back(std::vector<size_t>{component_storage::invalid});
				return e;
			}

			entity e = freelist.back();
			entity_component_indices[e] = std::vector<size_t>{component_storage::invalid};
			freelist.pop();
			return e;
		}

		/**
		* @brief Release an entity back to the free list.
		*
		* @param e The ID of the entity to release.
		* @param clearMemory Weather all of the components associated with the entity should be removed or not!
		* @return True if the entity was successfully released, false otherwise.
		*/
		bool release_entity(entity e, bool clearMemory = true) {
			if(e >= entity_component_indices.size()) return false;

			if(clearMemory && !storages.empty()) for(size_t i = storages.size() - 1; i--; )
				storages[i].remove(*this, e, i);

			entity_component_indices[e] = std::vector<size_t>{component_storage::invalid};
			freelist.emplace(e);
			return true;
		}

		/**
		* @brief Add a component to an entity and store it in the scene's storage.
		*
		* @tparam Tcomponent The component type to add.
		* @param e The ID of the entity to add the component to.
		* @return An optional reference to the added component, or an empty optional if the addition failed.
		*/
		template<typename Tcomponent>
		optional_reference<Tcomponent> add_component(entity e) {
			size_t id = get_global_component_id<Tcomponent>();
			auto& indices = entity_component_indices[e];
			if(indices.empty() || indices.size() <= id)
				indices.resize(id + 1, component_storage::invalid);
			indices[id] = get_storage<Tcomponent>()->size();
			return get_storage<Tcomponent>()->template get_or_allocate<Tcomponent>(indices[id]);
		}

		/**
		* @brief Remove a component from an entity and release the associated storage.
		* @note this function is named remove rather than release since the associated memory is deleted... rather than a "tombstone being placed"
		*
		* @tparam Tcomponent The component type to remove.
		* @param e The ID of the entity to remove the component from.
		* @return true if the removal was successful, false otherwise.
		*/
		template<typename Tcomponent>
		bool remove_component(entity e) { return get_storage<Tcomponent>()->template remove<Tcomponent>(*this, e); }

		/**
		* @brief Get a reference to the component associated with an entity.
		*
		* @tparam Tcomponent The component type to retrieve.
		* @param e The ID of the entity to retrieve the component from.
		* @return An optional reference to the component, or an empty optional if it does not exist.
		*/
		template<typename Tcomponent>
		optional_reference<Tcomponent> get_component(entity e) {
			size_t id = get_global_component_id<Tcomponent>();
			if(e >= entity_component_indices.size()) return {};
			if(entity_component_indices[e].size() <= id) return {};
			if(entity_component_indices[e][id] == component_storage::invalid) return {};
			return get_storage<Tcomponent>()->template get<Tcomponent>(entity_component_indices[e][id]);
		}
		template<typename Tcomponent>
		optional_reference<const Tcomponent> get_component(entity e) const {
			size_t id = get_global_component_id<Tcomponent>();
			if(e >= entity_component_indices.size()) return {};
			if(entity_component_indices[e].size() <= id) return {};
			if(entity_component_indices[e][id] == component_storage::invalid) return {};
			if(auto s = get_storage<Tcomponent>(); s) return s->template get<Tcomponent>(entity_component_indices[e][id]);
			return {};
		}

		/**
		* @brief Checks if there is a component associated with the entity
		*
		* @tparam Tcomponent The component type to check for.
		* @param e The ID of the entity to check the component on.
		* @return true if the component is present, false otherwise
		*/
		template<typename Tcomponent>
		bool has_component(entity e) const {
			size_t id = get_global_component_id<Tcomponent>();
			return entity_component_indices.size() > e && entity_component_indices[e].size() > id && entity_component_indices[e][id] != component_storage::invalid;
		}
	};

	/**
	* @brief Function which removes the value associated with the provided entity
	* @note performs a swap with the last stored value thus needs to update offset information stored in the scene
	* 
	* @param scene The scene storing offset information
	* @param e The entity to remove
	* @param component_id The component id to remove if a type is not automatically provided!
	* @return true if the element was successfully removed, false if an error occured
	*/
	inline bool scene::component_storage::remove(scene& scene, entity e, size_t component_id) {\
		size_t size = this->size();
		if(size == 0 || e >= scene.entity_component_indices.size()) return false;
		
		auto& indices = scene.entity_component_indices[e];
		if(indices.size() <= component_id) return false;

		for(e = 0; e < scene.entity_component_indices.size(); ++e)
			if( scene.entity_component_indices[e][component_id] == size - 1)
				break;
		if(e >= scene.entity_component_indices.size()) return false;

		if(!swap(indices[component_id])) return false;
		std::swap(indices[component_id], scene.entity_component_indices[e][component_id]);
		data.erase(data.cbegin() + data.size() - element_size, data.cend());
		indices[component_id] = invalid;
		return true;
	}
}

#endif // __ECS__HPP__