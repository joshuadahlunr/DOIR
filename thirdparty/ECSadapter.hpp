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

#ifndef __ECS_ADAPTER_HPP__
#define __ECS_ADAPTER_HPP__

#include "ECS.hpp"

#include <bit>
#include <cmath>
#include <cstdint>
#include <span>
#include <type_traits>

namespace ecs {
	template<typename T>
	optional_reference<T> get_adapted_component_storage(scene& scene) {
		auto res = scene.get_storage<typename T::component_type>();
		if(!res) return {};
		return {*(T*)&(*res)};
	}

	namespace typed {
		template<typename Tcomponent>
		struct component_storage : public ecs::scene::component_storage {
			using Base = ecs::scene::component_storage;
			using component_type = Tcomponent;
			using Base::Base;
			optional_reference<const Tcomponent> get(entity e) const { return Base::get<Tcomponent>(e); }
			optional_reference<Tcomponent> get(entity e) { return Base::get<Tcomponent>(e); }
			std::optional<std::pair<Tcomponent&, size_t>> allocate(size_t count = 1) { return Base::allocate<Tcomponent>(count); }
			optional_reference<Tcomponent> get_or_allocate(entity e) { return Base::get_or_allocate<Tcomponent>(e); }
			bool remove(struct scene& scene, entity e) { return Base::remove<Tcomponent>(scene, e); }
			template<typename F, bool with_entities = false>
			void sort(struct scene& scene, const F& comparator) { Base::sort<Tcomponent, F, with_entities>(scene, comparator); }
			void sort_by_value(struct scene& scene) { Base::sort_by_value<Tcomponent>(scene); }
			void sort_monotonic(struct scene& scene) { Base::sort_monotonic<Tcomponent>(scene); }

			Tcomponent* data() { return (Tcomponent*)Base::data.data(); }
			const Tcomponent* data() const { return (const Tcomponent*)Base::data.data(); }
			std::span<Tcomponent> span() { return {data(), Base::size()}; }
			std::span<const Tcomponent> span() const { return {data(), Base::size()}; }

		protected:
			bool swap(size_t a, std::optional<size_t> _b = {}) { return Base::swap<Tcomponent>(a, _b); }
			bool swap(struct scene& scene, size_t a, std::optional<size_t> _b = {}, bool swap_if_one_elementless = false) { return Base::swap<Tcomponent>(scene, a, _b, swap_if_one_elementless); }
		};
	}

	namespace hashtable {
		template<typename T>
		struct is_costly_to_compare : public std::false_type {};
		template<>
		struct is_costly_to_compare<std::string> : public std::true_type {};

		template<typename T>
		constexpr static bool is_costly_to_compare_v = is_costly_to_compare<T>::value;

		namespace detail {
			struct hash_entry_base {
				uint32_t hopInfo = 0;  // Bitmask to track neighbors (occupied stored in highest bit)

				bool is_occupied() const {
					return hopInfo & (1 << 31);
				}
				void set_occupied(bool value) {
					if(value) hopInfo |=(1 << 31);
					else hopInfo &= ~(1 << 31);
				}
			};

			template<typename Tkey, typename Tvalue>
			struct hash_entry : public hash_entry_base {
				Tkey key;
				Tvalue value;
			};
			template<typename Tkey>
			struct hash_entry<Tkey, void> : public hash_entry_base {
				Tkey key;
			};

			template<typename Tkey, typename Tvalue>
			struct hash_entry_with_hash: public hash_entry<Tkey, Tvalue> {
				size_t hash;
			};
		}

		template<typename Tkey, typename Tvalue = void>
		using component_wrapper = ecs::with_entity<std::conditional_t<
			is_costly_to_compare_v<Tkey>, detail::hash_entry_with_hash<Tkey, Tvalue>, detail::hash_entry<Tkey, Tvalue>>
		>;

		/*constexpr*/ size_t one_over_one_minus(float factor)
#ifdef ECS_IMPLEMENTATION
		{
			assert(0 < factor); assert(factor < 1);
			return std::round(1 / (1 - factor));
		}
#else
		;
#endif

		// An adapter over a component storage which treats the underlying data as a hopscotch hash table
		template<typename Tkey, typename Tvalue = void, typename Hash = std::hash<Tkey>, size_t OneOverOneMinusMaxLoadFactor = /*one_over_one_minus(.95)*/20, size_t NeighborhoodSize = 8, size_t MaxRetries = 5>
		class component_storage
			: public ecs::typed::component_storage<
				component_wrapper<ecs::detail::remove_with_entity_t<Tkey>, ecs::detail::remove_with_entity_t<Tvalue>>
			>
		{
		protected:
			using key_type = ecs::detail::remove_with_entity_t<Tkey>;
			using value_type = ecs::detail::remove_with_entity_t<Tvalue>;
			using component_t = component_wrapper<key_type, value_type>;
			using Base = ecs::typed::component_storage<component_t>;

			// static constexpr bool has_value_type = std::is_same_v<value_type, void>;
			// using kv_pair = std::conditional_t<has_value_type, key_type, std::pair<key_type, value_type>>;

			static constexpr float maxLoadFactor = 1 - 1.0 / OneOverOneMinusMaxLoadFactor;
			static constexpr float store_hash = is_costly_to_compare_v<key_type>;

			size_t current_size() const {
				size_t size = 0;
				for(auto& e: Base::span())
					if(e.is_occupied())
						++size;
				return size;
			}

			// const key_type& key(const kv_pair& key_value) {
			// 	if constexpr(has_value_type)
			// 		return key_value.first;
			// 	else return key_value;
			// }

			inline float load_factor() const {
				return float(current_size()) / Base::size();
			}

			inline size_t hash(const key_type& key) const {
				return Hash{}(key) % Base::size();
			}

			std::optional<size_t> find_position(const key_type& key) const {
				size_t hash = this->hash(key);
				for(size_t i = 0; i < NeighborhoodSize; ++i) {
					size_t probe = (hash + i) % Base::size();
					if constexpr(store_hash) if(!Base::data()[probe]->is_occupied() || Base::data()[probe]->hash != hash) continue;
					if(Base::data()[probe]->is_occupied() && Base::data()[probe]->key == key)
						return probe;
				}
				return {};
			}

			std::optional<size_t> find_empty_spot(size_t start) const {
				for(size_t i = 0; i < NeighborhoodSize; ++i) {
					size_t probe = (start + i) % Base::size();
					if(!Base::data()[probe]->is_occupied())
						return probe;
				}
				return {};
			}

			std::optional<size_t> find_nearest_neighbor(size_t start) const {
				for(size_t j = 0; j < NeighborhoodSize; ++j) {
					size_t probe = (start + j) % Base::size();
					if((Base::data()[start]->hopInfo & (1 << j)) && !Base::data()[probe]->is_occupied())
						return probe;
				}
				return {};
			}

			inline bool is_in_neighborhood(size_t start, size_t needle) const {
				if(NeighborhoodSize > Base::size()) return true;
				size_t end = (start + NeighborhoodSize) % Base::size();
				if (start <= end)
					return needle >= start && needle <= end; // TODO: should be < instead?
				else // The neighborhood range wraps around the end of the table
					return needle >= start || needle <= end;
			}

			// bool insert_impl(scene& scene, const kv_pair& key_value, size_t retries = 0) {
			// 	size_t hash = this->hash(key(key_value));

			// 	auto emptyIndex = find_empty_spot(hash);
			// 	if(!emptyIndex) {
			// 		if(!resize_and_rehash(scene)) return false;
			// 		if(retries == 5) return false;
			// 		return insert_impl(scene, key_value, retries + 1);
			// 	}

			// 	if constexpr(has_value_type) {
			// 		Base::data()[*emptyIndex]->key = key_value.first;
			// 		Base::data()[*emptyIndex]->value = key_value.second;
			// 	} else
			// 		Base::data()[*emptyIndex].key = key_value;
			// 	Base::data()[*emptyIndex]->set_occupied(true);
			// 	if constexpr(store_hash) Base::data()[*emptyIndex].hash = hash;

			// 	size_t distance = *emptyIndex > hash ? *emptyIndex - hash : Base::size() - (hash - *emptyIndex);
			// 	Base::data()[hash]->hopInfo |= (1 << distance);
			// 	return true;
			// }

			inline bool resize_and_rehash(scene& scene, size_t retries = 0) {
				auto& raw = scene::component_storage::data;
				raw.resize(std::max(raw.size() * 2, scene::component_storage::element_size));
				return rehash(scene, retries, true);
			}

			bool rehash(scene& scene, size_t retries, bool resized = false) {
				// Clear the neighborhood information
				size_t size = Base::size(), half = size / 2;
				for(size_t i = 0; i < size; ++i) {
					bool occupied = Base::data()[i]->is_occupied();
					Base::data()[i]->hopInfo = 0;
					if(resized && occupied && i < half && (i % 2) == 1) { // Distribute every other element to the second half of the newly resized space
						bool success = Base::swap(scene, i, size - i, true);
						Base::data()[size - i]->set_occupied(occupied);
						Base::data()[i]->set_occupied(false);
					} else Base::data()[i]->set_occupied(occupied);
				}

				// Traverse through the old table and "reinsert" elements into the table
				for (size_t i = 0; i < Base::size(); ++i)
					if (Base::data()[i]->is_occupied()) {
						size_t hash = this->hash(Base::data()[i]->key);

						// If the value is already in the correct neighborhood... no need to move around just mark as present
						if(is_in_neighborhood(hash, i)) {
							if constexpr(store_hash) Base::data()[i]->hash = hash;
							size_t distance = i > hash ? i - hash : Base::size() - (hash - i);
							Base::data()[hash]->hopInfo |= (1 << distance);
							continue;
						}

						// Find an empty spot in the new table starting from the new hash value
						auto emptyIndex = find_empty_spot(hash);
						if (!emptyIndex) {
							if(retries >= MaxRetries) return false;
							return resize_and_rehash(scene, retries + 1); // TODO: We can probably use a better strategy than "resize and try again"
						}

						// Move the element to its new position in the table
						size_t hopInfo = Base::data()[i]->hopInfo;
						bool success = Base::swap(scene, *emptyIndex, i, true);
						Base::data()[i]->hopInfo = hopInfo;
						Base::data()[*emptyIndex]->set_occupied(true);
						Base::data()[i]->set_occupied(false);

						// Mark it as present in the element it hashes to
						size_t distance = *emptyIndex > hash ? *emptyIndex - hash : Base::size() - (hash - *emptyIndex);
						Base::data()[hash]->hopInfo |= (1 << distance);
					}

				return true;
			}

		public:
			using component_type = component_t;

			inline bool rehash(scene& scene) {
				return rehash(scene, 0);
			}

			// bool insert(scene& scene, const kv_pair& key_value, bool maybeRehash = true) {
			// 	if(maybeRehash && current_size() >= Base::size() * maxLoadFactor) // Takes a linear scan so that we don't need to store extra size information...
			// 		resize_and_rehash(scene);

			// 	if(find_position(key(key_value)))
			// 		return false;  // Key already exists

			// 	if(!insert_impl(scene, key_value)) return false;
			// 	return true;
			// }

			inline std::optional<entity> find(const key_type& key) const {
				if(auto index = find_position(key))
					return Base::data()[*index].entity;
				return {};  // Key not found
			}

			inline std::optional<entity> rehash_and_find(scene& scene, const key_type& key) {
				if(!rehash(scene)) return {};
				return find(key);
			}

			bool remove(scene& scene, const key_type& key) {
				auto index = find_position(key);
				if(!index)
					return false;  // Key not found

				// TODO: need to modify the scene to mark that the entity no long has a component

				Base::data()[*index].set_occupied(false);

				// Update hop information of neighbors
				auto hash = this->hash(key);
				for(size_t i = 0; i < NeighborhoodSize; ++i) {
					size_t probe = (hash + i) % Base::size();
					if(Base::data()[probe]->is_occupied())
						Base::data()[probe]->hopInfo &= ~(1 << (*index > i ? *index - i : Base::size() - (i - *index)));
				}

				return true;
			}
		};

		template<typename Tkey, typename Tvalue = void>
		inline void mark_occupied(component_wrapper<Tkey, Tvalue>& comp) {
			comp->set_occupied(true);
		}
		template<typename Tkey, typename Tvalue = void>
		inline void mark_occupied(optional_reference<component_wrapper<Tkey, Tvalue>> opt) {
			opt.value()->set_occupied(true);
		}

		template<typename Tkey, typename Tvalue = void>
		inline Tkey& get_key(component_wrapper<Tkey, Tvalue>& comp) {
			return comp->key;
		}
		template<typename Tkey, typename Tvalue = void>
		inline Tkey& get_key(optional_reference<component_wrapper<Tkey, Tvalue>> opt) {
			return opt.value()->key;
		}

		template<typename Tkey, typename Tvalue = void>
		inline Tkey& get_key_and_mark_occupied(component_wrapper<Tkey, Tvalue>& comp) {
			mark_occupied<Tkey, Tvalue>(comp);
			return get_key<Tkey, Tvalue>(comp);
		}
		template<typename Tkey, typename Tvalue = void>
		inline Tkey& get_key_and_mark_occupied(optional_reference<component_wrapper<Tkey, Tvalue>> opt) {
			mark_occupied<Tkey, Tvalue>(opt);
			return get_key<Tkey, Tvalue>(*opt);
		}

		template<typename Tkey, typename Tvalue = void>
			requires((!std::is_same_v<Tvalue, void>))
		inline Tvalue& get_value(component_wrapper<Tkey, Tvalue>& comp) {
			return comp.value.value;
		}
		template<typename Tkey, typename Tvalue = void>
			requires((!std::is_same_v<Tvalue, void>))
		inline Tvalue& get_value(optional_reference<component_wrapper<Tkey, Tvalue>> comp) {
			return comp.value().value.value;
		}
	}

	using hashtable::get_key;
	using hashtable::get_key_and_mark_occupied;
	using hashtable::get_value;
}

#endif // __ECS_ADAPTER_HPP__