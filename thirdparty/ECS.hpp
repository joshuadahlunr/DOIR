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
#endif

/**
* @defgroup ECS Entity-Component-System (ECS) Framework
*
* The ECS framework provides a way to manage entities, components, and systems.
*/

#ifdef ECS_IMPLEMENTATION
/**
* @var ecs::globalComponentCounter
* Global component counter.
*/
static size_t globalComponentCounter = 0;

/**
* @var ecs::globalComponentForwardLookup
* Forward lookup map for components by name to their IDs.
*/
static std::unordered_map<std::string, size_t> globalComponentForwardLookup = {};

/**
* @var ecs::globalComponentReverseLookup
* Reverse lookup map for components by ID to their names.
*/
static std::unordered_map<size_t, std::string> globalComponentReverseLookup = {};
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
		/**
		* @brief Get a const reference to the wrapped value.
		*
		* Returns a const reference to the wrapped value if it is valid, otherwise returns nullptr.
		*/
		constexpr const T* operator->() const noexcept { return &Base::operator*().get(); }

		/**
		* @brief Get a non-const reference to the wrapped value.
		*
		* Returns a non-const reference to the wrapped value if it is valid, otherwise returns nullptr.
		*/
		constexpr T* operator->() noexcept { return &Base::operator*().get(); }

		/**
		* @brief Get a const reference to the wrapped value.
		*
		* Returns a const reference to the wrapped value if it is valid, otherwise returns nullptr.
		*/
		constexpr T& operator*() /*&*/ noexcept { return Base::operator*().get(); }

		/**
		* @brief Get a non-const reference to the wrapped value.
		*
		* Returns a non-const reference to the wrapped value if it is valid, otherwise returns nullptr.
		*/
		constexpr const T& operator*() const/*&*/ noexcept { return Base::operator*().get(); }

		constexpr T& value() /*&*/ { return Base::operator*().get(); }
		constexpr const T& value() const /*&*/ { return Base::operator*().get(); }

		template< class U >
		constexpr T value_or( U&& default_value ) const& { return bool(*this) ? Base::operator*().get() : static_cast<T>(std::forward<U>(default_value)); }

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
	* @brief A structure for storing components of various types.
	*/
	struct component_storage {
		/**
		* @brief An invalid index value.
		*/
		static constexpr size_t invalid = std::numeric_limits<size_t>::max();
		size_t element_size = invalid;
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
		* @brief Template function that retrieves a component by its entity index, if it exists and matchesthe expected type.
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

		/**
		* @brief Template function that retrieves a component by its entity index, if it exists and matches the expected type.
		*
		* @tparam Tcomponent The type of component.
		* @param e The entity index.
		* @return An optional reference to the retrieved component, or an empty optional if it doesn't exist or doesn't match the expected type.
		*/
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
			return {
				*new(data.data() + data.size() - element_size) Tcomponent(),
				data.size() / element_size
			};
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
				if (!allocate<Tcomponent>(std::max<int64_t>(int64_t(e) - size + 1, 1))) return {};
			return get<Tcomponent>(e);
		}
	};

	/**
	* @brief A struct for storing skiplist components.
	*
	* This struct is used to store and manage skiplist components.
	*/
	struct skiplist_component_storage {
		/**
		* @brief The maximum value for a size_t.
		*/
		static constexpr size_t invalid = std::numeric_limits<size_t>::max();

		/**
		* @brief The element size of the stored components.
		*
		* This is set to the maximum value by default, and can be changed when creating an instance.
		*/
		size_t element_size = invalid;

		/**
		* @brief A vector of indices for storing component data.
		*/
		std::vector<size_t> indices;

		/**
		* @brief A vector of bytes for storing component data.
		*/
		std::vector<std::byte> data;

		/**
		* @brief Default constructor.
		*
		* Sets the element size to the maximum value and initializes the indices and data vectors.
		*/
		skiplist_component_storage() : element_size(invalid), indices(1, invalid), data(1, std::byte{0}) {}

		/**
		* @brief Constructor with specified element size.
		*
		* Sets the element size to the specified value and initializes the data vector.
		*
		* @param element_size The element size of the stored components.
		*/
		skiplist_component_storage(size_t element_size, size_t element_count = 5) : element_size(element_size) { data.reserve(element_count * element_size); }

		/**
		* @brief Template constructor for storing components with specified type.
		*
		* Creates an instance with the specified component type and initializes the data vector.
		*
		* @param Tcomponent The type of component to store.
		*/
		template<typename Tcomponent>
		skiplist_component_storage(Tcomponent reference = {}, size_t element_count = 5) : skiplist_component_storage(sizeof(Tcomponent), element_count) {}

		/**
		* @brief Template function for getting a stored component.
		*
		* Returns an optional reference to the stored component at the specified entity index, or an empty optional if the entity is out of bounds.
		*
		* @param e The entity index.
		* @return An optional reference to the stored component.
		*/
		template<typename Tcomponent>
		optional_reference<const Tcomponent> get(entity e) const {
			if (!(sizeof(Tcomponent) == element_size)) return {};
			if (!(e < indices.size())) return {};
			if (!(indices[e] != invalid)) return {};
			return {*(Tcomponent*)(data.data() + indices[e])};
		}

		/**
		* @brief Template function for getting a stored component.
		*
		* Returns an optional reference to the stored component at the specified entity index, or an empty optional if the entity is out of bounds.
		*
		* @param e The entity index.
		* @return An optional reference to the stored component.
		*/
		template<typename Tcomponent>
		optional_reference<Tcomponent> get(entity e) {
			if (auto got = ((const skiplist_component_storage*)this)->get<Tcomponent>(e); got) return {const_cast<Tcomponent&>(*got)}; else return {};
		}

		/**
		* @brief Template function for allocating a new component.
		*
		* Allocates a new component of the specified type and returns an optional reference to it, or an empty optional if allocation fails.
		*
		* @param Tcomponent The type of component to allocate.
		* @return An optional reference to the allocated component.
		*/
		template<typename Tcomponent>
		std::optional<std::pair<Tcomponent&, size_t>> allocate() {
			if (!(sizeof(Tcomponent) == element_size)) return {};
			data.insert(data.end(), element_size, std::byte{0});
			return {{
				*new(data.data() + data.size() - element_size) Tcomponent(),
				(data.size() - 1) / element_size
			}};
		}

		/**
		* @brief Template function for allocating a new component.
		*
		* Allocates a new component of the specified type at the specified entity index, or returns an empty optional if allocation fails.
		*
		* @param e The entity index.
		* @param skipMonitinicityPass Whether to skip monotonicity pass after allocation.
		* @return An optional reference to the allocated component.
		*/
		template<typename Tcomponent>
		optional_reference<Tcomponent> allocate(entity e, bool skipMonitinicityPass = false) {
			auto res = allocate<Tcomponent>();
			if(!res) return {}; auto [ret, i] = *res;
			if (indices.size() <= e)
				indices.insert(indices.end(), std::max<int64_t>(int64_t(e) - indices.size() + 1, 1), invalid);
			indices[e] = i * element_size;
			if(!skipMonitinicityPass) make_monotonic();
			return {ret};
		}
		/**
		* @brief Template function for updating the component storage.
		*
		* Updates the component storage with the specified entity index and value.
		*
		* @param e The entity index.
		* @param value The new value to store at the specified entity index.
		*/
		template<typename Tcomponent>
		optional_reference<Tcomponent> get_or_allocate(entity e, bool skipMonitinicityPass = true) {
			if(!(sizeof(Tcomponent) == element_size)) return {};
			if (indices.size() <= e)
				indices.insert(indices.end(), std::max<int64_t>(int64_t(e) - indices.size() + 1, 1), invalid);
			if (indices[e] == std::numeric_limits<size_t>::max())
				return allocate<Tcomponent>(e, skipMonitinicityPass);
			return get<Tcomponent>(e);
		}

		// TODO: Broken!
		void make_monotonic() {
			std::vector<std::byte> swapTemporaryStorage; swapTemporaryStorage.resize(element_size);
			// We manipulate a proxy array that stores index references (so that they are updated when swapped)
			//	and indices allowing us treat the sparsely packed skiplist layer as a densely packed array
			std::vector<std::pair<size_t&, size_t>> filledIndices; filledIndices.reserve(indices.size());
			for(size_t i = 0; i < indices.size(); i++)
				if(indices[i] != std::numeric_limits<size_t>::max())
					filledIndices.emplace_back(indices[i], i);

			// Use insertion sort... assumes that the data is already close to being monotonic
			for(size_t i = 1; i < filledIndices.size(); i++) {
				// Move elements (that are greater than key) to one position ahead of their current position
				size_t j;
				for (j = i - 1; j >= 0 && filledIndices[j].first > filledIndices[i - 1].first; j--)
					// TODO: If we could swap large ranges it would be better! (Would that work given the sparseness?)
					data_swap(filledIndices[j + 1].second, filledIndices[j].second, swapTemporaryStorage);

				// arr[j + 1] = key;
				data_swap(filledIndices[j + 1].second, filledIndices[i].second, swapTemporaryStorage);
			}
		}
	protected:
		void data_swap(size_t _first, size_t _second, std::vector<std::byte>& _tmp) {
			assert(_tmp.size() >= element_size);
			// Swap the data referenced by indices[first] and indices[second]
			{
				std::byte* tmp = _tmp.data();
				std::byte* first = data.data() + indices[_first];
				std::byte* second = data.data() + indices[_second];

				memcpy(first, tmp, element_size);
				memcpy(second, first, element_size);
				memcpy(tmp, second, element_size);
			}

			// Swap the references
			{
				auto tmp = indices[_first];
				indices[_first] = indices[_second];
				indices[_second] = tmp;
			}
		}
	};


	/**
	* @defgroup BasicScene Basic Scene Structure
	* @brief Template-based scene structure for storing and managing entities and components.
	*/
	template<typename Storage = component_storage>
	struct basic_scene {
		/**
		* @brief Vector of entity masks, where each mask represents an entity's presence in various components.
		*/
		std::vector<std::vector<bool>> entityMasks;

		/**
		* @brief Vector of storage objects for storing and retrieving components.
		*/
		std::vector<Storage> storages = {Storage()};

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
			size_t size = entityMasks.size();
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
		optional_reference<Storage> get_storage() {
			size_t id = get_global_component_id<Tcomponent>();
			if(storages.size() <= id)
				storages.insert(storages.cend(), std::max<int64_t>(id - storages.size(), 1), Storage());
			if (storages[id].element_size == Storage::invalid)
				storages[id] = Storage(Tcomponent{});
			return {storages[id]};
		}

		/**
		* @brief Get a const reference to a storage object for the given component type.
		*
		* @tparam Tcomponent The component type to retrieve.
		* @return An optional reference to the storage object, or an empty optional if the storage does not exist.
		*/
		template<typename Tcomponent>
		optional_reference<const Storage> get_storage() const {
			size_t id = get_global_component_id<Tcomponent>();
			if(!(storages.size() > id)) return {};
			if(!(storages[id].element_size != Storage::invalid)) return {};
			return {storages[id]};
		}

		/**
		* @brief Release a storage object for the given component type.
		*
		* @tparam Tcomponent The component type to release.
		* @return Whether the release was successful.
		*/
		template<typename Tcomponent>
		bool release_storage() {
			size_t id = get_global_component_id<Tcomponent>();
			if(storages.size() <= id) return false;
			if(storages[id].element_size == Storage::invalid) return false;
			storages[id] = Storage();
			return true;
		}

		/**
		* @brief Create a new entity and add it to the scene.
		*
		* @return The ID of the newly created entity.
		*/
		entity create_entity() {
			if(freelist.empty()) {
				entity e = entityMasks.size();
				entityMasks.emplace_back(std::vector<bool>{false});
				return e;
			}

			entity e = freelist.back();
			entityMasks[e] = std::vector<bool>{false};
			freelist.pop();
			return e;
		}

		/**
		* @brief Release an entity back to the free list.
		*
		* @param e The ID of the entity to release.
		* @return Whether the release was successful.
		*/
		bool release_entity(entity e) {
			if(e >= entityMasks.size()) return false;

			entityMasks[e] = std::vector<bool>{false};
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
			auto& eMask = entityMasks[e];
			if(eMask.empty() || eMask.size() <= id)
				eMask.resize(id + 1, false);
			eMask[id] = true;
			return get_storage<Tcomponent>()->template get_or_allocate<Tcomponent>(e);
		}

		/**
		* @brief Remove a component from an entity and release the associated storage.
		*
		* @tparam Tcomponent The component type to remove.
		* @param e The ID of the entity to remove the component from.
		* @param clearMemory Whether to clear the memory associated with the removed component.
		* @return Whether the removal was successful.
		*/
		template<typename Tcomponent>
		bool remove_component(entity e, bool clearMemory = true) {
			size_t id = get_global_component_id<Tcomponent>();
			if(e >= entityMasks.size()) return false;
			auto& eMask = entityMasks[e];
			if(!(eMask.size() > id)) return false;
			if(eMask[id] && clearMemory) if(auto res = get_component<Tcomponent>(e); res) res = {};
			eMask[id] = false;
			return true;
		}

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
			if(e >= entityMasks.size()) return {};
			if(!entityMasks[e][id]) return {};
			return get_storage<Tcomponent>()->template get<Tcomponent>(e);
		}
		template<typename Tcomponent>
		optional_reference<const Tcomponent> get_component(entity e) const {
			size_t id = get_global_component_id<Tcomponent>();
			if(!entityMasks[e][id]) return {};
			if(auto s = get_storage<Tcomponent>(); s) return s->template get<Tcomponent>(e);
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
			return entityMasks.size() > e && entityMasks[e].size() > id && entityMasks[e][id];
		}
	};

	using scene = basic_scene<skiplist_component_storage>;
}

#endif // __ECS__HPP__