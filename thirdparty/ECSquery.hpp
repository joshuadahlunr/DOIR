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

#include "ECS.hpp"
#include <compare>
#include <ranges>

/**
* @file ecs_query.hpp
* @brief Provides a query API for the Entity-Component-System (ECS) architecture.
*/

namespace ecs {
	/**
	* @typedef post_increment_t
	* @brief A type alias for an integer representing a post-increment operation.
	*/
	using post_increment_t = int;

	/**
	* @struct scene_view
	* @brief A view into the ECS scene, allowing iteration over entities and their components.
	*
	* @tparam Tcomponents A variadic template parameter pack containing the types of the components.
	*/
	template<typename... Tcomponents>
	struct scene_view {
		ecs::scene& scene; /**< The ECS scene being queried. */

		/**
		* @struct Sentinel
		* @brief A sentinel value indicating the end of the query iteration.
		*/
		struct Sentinel {};

		/**
		* @struct Iterator
		* @brief An iterator over the entities and their components in the ECS scene.
		*
		* @see scene_view
		*/
		struct Iterator {
			using difference_type = std::ptrdiff_t; /**< The type of the difference between two iterators. */
			using value_type = std::tuple<Tcomponents...>; /**< The type of the values returned by the iterator. */
			using reference = std::tuple<std::add_lvalue_reference_t<Tcomponents>...>; /**< The type of the references returned by the iterator. */
			using pointer = void; /**< The type of the pointers returned by the iterator. */
			using iterator_category = std::forward_iterator_tag; /**< The category of the iterator. */

			ecs::scene* scene = nullptr; /**< A pointer to the ECS scene being queried. */
			entity e; /**< The current entity being processed. */

			/**
			* @brief Returns whether the iterator is valid.
			*
			* @return true if the iterator is valid, false otherwise.
			*/
			bool valid() const { return (scene->has_component<Tcomponents>(e) && ...); }

			/**
			* @brief Equality operator for comparing two iterators.
			*
			* @param o The other iterator to compare with.
			* @return true if the iterators are equal, false otherwise.
			*/
			bool operator==(Sentinel) const { return scene == nullptr || e >= scene->size<true>(); }

			/**
			* @brief Partial ordering operator for comparing two iterators.
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
			* @brief Advances the iterator to the next entity.
			*/
			Iterator operator++(post_increment_t) {
				Iterator old{scene, e};
				operator++();
				return old;
			}
			Iterator& operator++() {
				do {
					e++;
				} while(!valid() && e < scene->size<true>());
				return *this;
			}

			/**
			* @brief Deference opperator
			* 
			* @return References to all of the components currently being viewed
			*/
			std::tuple<std::add_lvalue_reference_t<Tcomponents>...> operator*() const { return { *scene->get_component<Tcomponents>(e)... }; }
		};

		Iterator begin() {
			Iterator out{&scene, 0};
			if(!out.valid()) ++out;
			return out;
		}
		Sentinel end() { return {}; }
	};

	struct include_entity{};
	using IncludeEntity = include_entity;

	template<typename... Tcomponents>
	struct scene_view<include_entity, Tcomponents...> : public scene_view<Tcomponents...>  {
		struct Iterator: public scene_view<Tcomponents...>::Iterator {
			using Base = scene_view<Tcomponents...>::Iterator;
			using value_type = std::tuple<entity, Tcomponents...>;
			using reference = std::tuple<entity, std::add_lvalue_reference_t<Tcomponents>...>;
			Iterator operator++(post_increment_t) { Iterator old{this->scene, this->e}; operator++(); return old; }
			Iterator& operator++() { Base::operator++(); return *this; }
			std::tuple<entity, std::add_lvalue_reference_t<Tcomponents>...> operator*() const { return { this->e, *this->scene->template get_component<Tcomponents>(this->e)... }; }
		};

		Iterator begin() {
			Iterator out{&this->scene, 0};
			if(!out.valid()) ++out;
			return out;
		}
	};

	struct include_scene{};
	using IncludeScene = include_scene;

	template<typename... Tcomponents>
	struct scene_view<include_scene, Tcomponents...> : public scene_view<Tcomponents...>  {
		struct Iterator: public scene_view<Tcomponents...>::Iterator {
			using Base = scene_view<Tcomponents...>::Iterator;
			using value_type = std::tuple<scene&, Tcomponents...>;
			using reference = std::tuple<scene&, std::add_lvalue_reference_t<Tcomponents>...>;
			Iterator operator++(post_increment_t) { Iterator old{this->scene, this->e}; operator++(); return old; }
			Iterator& operator++() { Base::operator++(); return *this; }
			std::tuple<scene&, std::add_lvalue_reference_t<Tcomponents>...> operator*() const { return { this->scene, *this->scene->template get_component<Tcomponents>(this->e)... }; }
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
			using value_type = std::tuple<scene&, entity, Tcomponents...>;
			using reference = std::tuple<scene&, entity, std::add_lvalue_reference_t<Tcomponents>...>;
			Iterator operator++(post_increment_t) { Iterator old{this->scene, this->e}; operator++(); return old; }
			Iterator& operator++() { Base::operator++(); return *this; }
			std::tuple<scene&, entity, std::add_lvalue_reference_t<Tcomponents>...> operator*() const { return { this->scene, this->e, *this->scene->template get_component<Tcomponents>(this->e)... }; }
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
			using value_type = std::tuple<entity, scene&, Tcomponents...>;
			using reference = std::tuple<entity, scene&, std::add_lvalue_reference_t<Tcomponents>...>;
			Iterator operator++(post_increment_t) { Iterator old{this->scene, this->e}; operator++(); return old; }
			Iterator& operator++() { Base::operator++(); return *this; }
			std::tuple<entity, scene&, std::add_lvalue_reference<Tcomponents>...> operator*() const { return { this->e, this->scene, *this->scene->template get_component<Tcomponents>(this->e)... }; }
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