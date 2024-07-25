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

#ifndef __ECS_QUERY_HPP__
#define __ECS_QUERY_HPP__

#include "ecs.hpp"
#include <ranges>
#include <variant>

/**
* @file ecs_query.hpp
* @brief Provides a query API for the Entity-Component-System (ECS) architecture.
*/

namespace ecs {
	/**
	* @brief Marker class which marks an entity as valid in the filter if any of the provided components are present.
	*
	* @tparam Tcomponents List of possible components to check for
	*/
	template<typename... Tcomponents>
	struct or_{};
	template<typename... Tcomponents>
	using Or = or_<Tcomponents...>;

	namespace detail {
		/**
		* @typedef post_increment_t
		* @brief A type alias for an integer representing a post-increment operation.
		*/
		using post_increment_t = int;

		/**
		* @struct is_optional
		* @tparam T The type to check
		* @brief A template struct that checks if a type is an optional type.
		*/
		template<typename>
		struct is_optional : public std::false_type {};

		/**
		* @struct is_optional
		* @tparam T The type to check
		* @brief A specialization of the is_optional struct for types that are optional.
		*/
		template<typename T>
		struct is_optional<optional<T>> : public std::true_type {};

		/**
		* @variable is_optional_v
		* @brief A static variable that contains the result of a call to the is_optional struct.
		*/
		template<typename T>
		static constexpr bool is_optional_v = is_optional<T>::value;

		/**
		* @struct is_or
		* @tparam T The type to check
		* @brief A template struct that checks if a type is an or type.
		*/
		template<typename>
		struct is_or : public std::false_type {};

		/**
		* @struct is_or
		* @tparam Ts... The types to check
		* @brief A specialization of the is_or struct for types that are ors.
		*/
		template<typename... Ts>
		struct is_or<or_<Ts...>> : public std::true_type {};

		/**
		* @variable is_or_v
		* @brief A static variable that contains the result of a call to the is_or struct.
		*/
		template<typename T>
		static constexpr bool is_or_v = is_or<T>::value;

		/**
		* @struct add_reference
		* @tparam T The type to get the reference for
		* @brief A template struct that adds a reference to a type.
		*/
		template<typename T>
		struct add_reference { using type = std::add_lvalue_reference_t<T>; };

		/**
		* @struct add_reference
		* @tparam T The type to get the reference for
		* @brief A specialization of the add_reference struct for optional types.
		*/
		template<typename T>
		struct add_reference<std::optional<T>> { using type = optional_reference<T>; };

		/**
		* @variable add_reference_t
		* @brief A using declaration that gets the type from the add_reference struct.
		*/
		template<typename T>
		using add_reference_t = typename add_reference<T>::type;

		/**
		* @struct reference_to_wrapper
		* @tparam T The type to get the wrapper for
		* @brief A template struct that adds a wrapper to a type.
		*/
		template<typename T>
		struct reference_to_wrapper { using type = T; };

		/**
		* @struct reference_to_wrapper
		* @tparam T The type to get the wrapper for
		* @brief A specialization of the reference_to_wrapper struct for lvalue references.
		*/
		template<typename T>
		struct reference_to_wrapper<T&> { using type = std::reference_wrapper<T>; };

		/**
		* @struct reference_to_wrapper
		* @tparam T The type to get the wrapper for
		* @brief A specialization of the reference_to_wrapper struct for rvalue references.
		*/
		template<typename T>
		struct reference_to_wrapper<T&&> { using type = std::reference_wrapper<T>; };

		/**
		* @variable reference_to_wrapper_t
		* @brief A using declaration that gets the type from the reference_to_wrapper struct.
		*/
		template<typename T>
		using reference_to_wrapper_t = typename reference_to_wrapper<T>::type;

		/**
		* @struct or_to_variant
		* @tparam T The type to get the variant for
		* @brief A template struct that adds a variant to a type.
		*/
		template<typename T>
		struct or_to_variant { using type = T; };

		/**
		* @struct or_to_variant
		* @tparam Ts... The types to get the variant for
		* @brief A specialization of the or_to_variant struct for ors.
		*/
		template<typename... Ts>
		struct or_to_variant<or_<Ts...>> { using type = std::variant<std::monostate, typename or_to_variant<Ts>::type...>; };

		/**
		* @variable or_to_variant_t
		* @brief A using declaration that gets the type from the or_to_variant struct.
		*/
		template<typename T>
		using or_to_variant_t = typename or_to_variant<T>::type;

		/**
		* @struct or_to_variant_reference
		* @tparam T The type to get the reference for
		* @brief A template struct that adds a reference to a variant.
		*/
		template<typename T>
		struct or_to_variant_reference { using type = add_reference_t<T>; };

		/**
		* @struct or_to_variant_reference
		* @tparam Ts... The types to get the reference for
		* @brief A specialization of the or_to_variant_reference struct for ors.
		*/
		template<typename... Ts>
		struct or_to_variant_reference<or_<Ts...>> { using type = std::variant<std::monostate, reference_to_wrapper_t<typename or_to_variant_reference<Ts>::type>...>; };

		/**
		* @variable or_to_variant_reference_t
		* @brief A using declaration that gets the type from the or_to_variant_reference struct.
		*/
		template<typename T>
		using or_to_variant_reference_t = typename or_to_variant_reference<T>::type;

		/**
		* @struct or_to_tuple
		* @tparam T The type to get the tuple for
		* @brief A template struct that adds a tuple to a type.
		*/
		template<typename T>
		struct or_to_tuple { using type = T; };

		/**
		* @struct or_to_tuple
		* @tparam Ts... The types to get the tuple for
		* @brief A specialization of the or_to_tuple struct for ors.
		*/
		template<typename... Ts>
		struct or_to_tuple<or_<Ts...>> { using type = std::tuple<std::decay_t<or_to_variant_reference_t<Ts>>...>; };

		/**
		* @variable or_to_tuple_t
		* @brief A using declaration that gets the type from the or_to_tuple struct.
		*/
		template<typename T>
		using or_to_tuple_t = typename or_to_tuple<T>::type;
	}


	/**
	* @struct scene_view
	* @brief A class that provides a view into an ECS (Entity-Component-System) scene.
	*
	* This class is used to iterate over entities in a scene and access their components.
	*/
	template<typename... Tcomponents>
	struct scene_view {
		/**
		* @var scene& scene
		* The underlying ECS scene.
		*/
		ecs::scene& scene;

		/**
		* @class Sentinel
		* A sentinel value that marks the end of an iteration.
		*/
		struct Sentinel {};

		/**
		* @class Iterator
		* An iterator class used to iterate over entities in a scene.
		*
		* This iterator is a forward iterator, which means it supports both forward and backward iteration.
		*/
		struct Iterator {
			/**
			* The difference type of this iterator.
			*/
			using difference_type = std::ptrdiff_t;
			/**
			* The value type of this iterator. It's a tuple of variant references to the scene's components.
			*/
			using value_type = std::tuple<detail::or_to_variant_t<Tcomponents>...>;
			/**
			* A reference to the value type of this iterator.
			*/
			using reference = std::tuple<detail::or_to_variant_reference_t<Tcomponents>...>;
			/**
			* A pointer to nothing, indicating that the iterator doesn't support pointer dereferencing.
			*/
			using pointer = void;
			/**
			* The category of this iterator. It's a forward iterator.
			*/
			using iterator_category = std::forward_iterator_tag;

			/**
			* The ECS scene pointer and entity ID used by this iterator.
			*/
			ecs::scene* scene;
			entity e;

			/**
			* Checks if the iterator is valid.
			*
			* @return True if the iterator is valid, false otherwise.
			*/
			bool valid() const { return (valid_impl<Tcomponents>() && ...); }

		protected:
			/**
			* A template function that checks if the iterator is valid for a single component type.
			*
			* @param Tcomponent The component type to check.
			* @return True if the component is present, false otherwise.
			*/
			template<typename Tcomponent>
			bool valid_impl() const {
				if constexpr(detail::is_or_v<Tcomponent>) {
					return valid_impl_or_expand(Tcomponent{});
				} else if constexpr(detail::is_optional_v<Tcomponent>) {
					return true;
				} else
					return scene->has_component<Tcomponent>(e);
			}

			/**
			* A template function that checks if the iterator is valid for an "or expression"
			*
			* @param Tcomps The component types to check.
			* @return True if all components are present, false otherwise.
			*/
			template<typename... Tcomps>
			bool valid_impl_or_expand(or_<Tcomps...>) const { return (valid_impl<Tcomps>() || ...); }

		public:

			/**
			* Checks if the iterator is equal to a sentinel value.
			*
			* @param Sentinel The sentinel value to compare with.
			* @return True if the iterators are equal, false otherwise.
			*/
			bool operator==(Sentinel) const { return scene == nullptr || e >= scene->size<true>(); }

			/**
			* Compares two iterators for ordering.
			*
			* @param o The other iterator to compare with.
			* @return A partial ordering of the iterators.
			*/
			std::partial_ordering operator<=>(const Iterator& o) const {
				// if(scene == nullptr) return std::partial_ordering::unordered;
				if(scene != o.scene) return std::partial_ordering::unordered;
				return e <=> o.e;
			}

			/**
			* Increments the iterator to the next valid enity.
			*
			* @param detail::post_increment_t A flag indicating whether this is a post-increment or not.
			* @return The old state of the iterator before incrementation.
			*/
			Iterator operator++(detail::post_increment_t) {
				Iterator old{scene, e};
				operator++();
				return old;
			}

			/**
			* Increments the iterator to the next valid enity.
			*
			* @return This iterator after incrementation.
			*/
			Iterator& operator++() {
				do {
					e++;
				} while(!valid() && e < scene->size<true>());
				return *this;
			}

			/**
			* Dereferences the iterator and returns a reference to the components at this position.
			*
			* @return A tuple of references to the components at this position.
			*/
			reference operator*() const { return { get_component<Tcomponents, true>()... }; }

		protected:
			/**
			* @brief Get a component from the scene.
			*
			* @tparam Tcomponent The type of the component to retrieve.
			* @param[in] deref Whether to dereference the result if it's a pointer. Defaults to true.
			* @return The retrieved component, or an empty optional if no component is found.
			*/
			template<typename Tcomponent, bool deref = true>
			decltype(auto) get_component() const {
				if constexpr(detail::is_or_v<Tcomponent>)
					return get_component_or(Tcomponent{});
				else if constexpr(detail::is_optional_v<Tcomponent>)
					return get_component_optional(Tcomponent{});
				else if constexpr(deref)
					return *scene->get_component<Tcomponent>(e);
				else return scene->get_component<Tcomponent>(e);
			}

			/**
			* @brief Get all components from an OR of component types.
			*
			* @tparam Tcomps A tuple of component types to retrieve.
			* @return The first non-empty optional component, or an empty optional if no components are found.
			*/
			template<typename... Tcomps>
			inline auto get_component_or(or_<Tcomps...>) const {
				detail::or_to_variant_reference_t<or_<Tcomps...>> out = {};
				std::apply([this, &out](auto... elems){ ([this, &out](auto elem) {
					using Tcomponent = decltype(elem);
					auto res = get_component<Tcomponent, false>();
					if(res) {
						out = *res;
						return false;
					}
					return true;
				}(elems) && ...); }, detail::or_to_tuple_t<or_<Tcomps...>>{});
				return out;
			}

			/**
			* @brief Get an optional component from the scene.
			*
			* @tparam Tcomponent The type of the optional component to retrieve.
			* @param[in] opt An optional component.
			* @return An optional reference to the retrieved component, or an empty optional if no component is
			found.
			*/
			template<typename Tcomponent>
			inline optional_reference<Tcomponent> get_component_optional(std::optional<Tcomponent>) const {
				return scene->get_component<Tcomponent>(e);
			}
		};

		/**
		* @brief Begins an iteration over the matching entities in the scene.
		*
		* @return The starting iterator for the iteration.
		*/
		Iterator begin() {
			Iterator out{&scene, 0};
			if(!out.valid()) ++out;
			return out;
		}
		/**
		* @brief Marks the end of an iteration over the matching entities in the scene.
		*/
		Sentinel end() { return {}; }
	};


	/**
	* @brief Struct which when added to the list of components to filter for, includes the entity in the result
	* @note Must be present at the beginning of the filter list
	*/
	struct include_entity{};
	using IncludeEntity = include_entity;

	template<typename... Tcomponents>
	struct scene_view<include_entity, Tcomponents...> : public scene_view<Tcomponents...>  {
		struct Iterator: public scene_view<Tcomponents...>::Iterator {
			using Base = scene_view<Tcomponents...>::Iterator;
			using value_type = std::tuple<entity, detail::or_to_variant_t<Tcomponents>...>;
			using reference = std::tuple<entity, detail::or_to_variant_reference_t<Tcomponents>...>;
			Iterator operator++(detail::post_increment_t) { Iterator old{this->scene, this->e}; operator++(); return old; }
			Iterator& operator++() { Base::operator++(); return *this; }
			reference operator*() const { return { this->e, this->template get_component<Tcomponents, true>()... }; }
		};

		Iterator begin() {
			Iterator out{&this->scene, 0};
			if(!out.valid()) ++out;
			return out;
		}
	};

	/**
	* @brief Struct which when added to the list of components to filter for, includes a reference to the scene in the result
	* @note Must be present at the beginning of the filter list
	*/
	struct include_scene{};
	using IncludeScene = include_scene;

	template<typename... Tcomponents>
	struct scene_view<include_scene, Tcomponents...> : public scene_view<Tcomponents...>  {
		struct Iterator: public scene_view<Tcomponents...>::Iterator {
			using Base = scene_view<Tcomponents...>::Iterator;
			using value_type = std::tuple<scene&, detail::or_to_variant_t<Tcomponents>...>;
			using reference = std::tuple<scene&, detail::or_to_variant_reference_t<Tcomponents>...>;
			Iterator operator++(detail::post_increment_t) { Iterator old{this->scene, this->e}; operator++(); return old; }
			Iterator& operator++() { Base::operator++(); return *this; }
			reference operator*() const { return { this->scene, this->template get_component<Tcomponents, true>()... }; }
		};

		Iterator begin() {
			Iterator out{&this->scene, 0};
			if(!out.valid()) ++out;
			return out;
		}
	};

	template<typename... Tcomponents>
	struct scene_view<include_scene, include_entity, Tcomponents...> : public scene_view<Tcomponents...>  {
		struct Iterator: public scene_view<Tcomponents...>::Iterator {
			using Base = scene_view<Tcomponents...>::Iterator;
			using value_type = std::tuple<scene&, entity, detail::or_to_variant_t<Tcomponents>...>;
			using reference = std::tuple<scene&, entity, detail::or_to_variant_reference_t<Tcomponents>...>;
			Iterator operator++(detail::post_increment_t) { Iterator old{this->scene, this->e}; operator++(); return old; }
			Iterator& operator++() { Base::operator++(); return *this; }
			reference operator*() const { return { this->scene, this->e, this->template get_component<Tcomponents, true>()... }; }
		};

		Iterator begin() {
			Iterator out{&this->scene, 0};
			if(!out.valid()) ++out;
			return out;
		}
	};

	template<typename... Tcomponents>
	struct scene_view<include_entity, include_scene, Tcomponents...> : public scene_view<Tcomponents...>  {
		struct Iterator: public scene_view<Tcomponents...>::Iterator {
			using Base = scene_view<Tcomponents...>::Iterator;
			using value_type = std::tuple<entity, scene&, detail::or_to_variant_t<Tcomponents>...>;
			using reference = std::tuple<entity, scene&, detail::or_to_variant_reference_t<Tcomponents>...>;
			Iterator operator++(detail::post_increment_t) { Iterator old{this->scene, this->e}; operator++(); return old; }
			Iterator& operator++() { Base::operator++(); return *this; }
			reference operator*() const { return { this->e, this->scene, this->template get_component<Tcomponents, true>()... }; }
		};

		Iterator begin() {
			Iterator out{&this->scene, 0};
			if(!out.valid()) ++out;
			return out;
		}
	};

	/**
	* @brief Queries the ECS scene for entities and their components that match the given filter.
	*
	* @param scene The ECS scene to query.
	* @return A subrange representing the filtered entities and their components.
	*/
	template<typename... Tcomponents>
	auto query(scene& scene) {
		using View = scene_view<Tcomponents...>;
		View v{scene};
		return std::ranges::subrange<typename View::Iterator, typename View::Sentinel, std::ranges::subrange_kind::unsized>(v.begin(), v.end());
	}

	/**
	* @brief Queries the ECS scene for entities and their components that match the given filter.
	*
	* @param scene The ECS scene to query.
	* @return A subrange representing the filtered entities and their components.
	*/
	template<typename... Tcomponents>
	auto query_with_entity(scene& scene) {
		using View = scene_view<include_entity, Tcomponents...>;
		View v{scene};
		return std::ranges::subrange<typename View::Iterator, typename View::Sentinel, std::ranges::subrange_kind::unsized>(v.begin(), v.end());
	}
}

#endif // __ECS_QUERY_HPP__