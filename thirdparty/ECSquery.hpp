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
#include <ranges>
#include <variant>

/**
* @file ecs_query.hpp
* @brief Provides a query API for the Entity-Component-System (ECS) architecture.
*/

namespace ecs {
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

		template<typename>
		struct is_optional: public std::false_type {};
		template<typename T>
		struct is_optional<optional<T>> : public std::true_type {};
		template<typename T>
		static constexpr bool is_optional_v = is_optional<T>::value;

		template<typename>
		struct is_or: public std::false_type {};
		template<typename... Ts>
		struct is_or<or_<Ts...>> : public std::true_type {};
		template<typename T>
		static constexpr bool is_or_v = is_or<T>::value;


		template<typename T>
		struct add_reference { using type = std::add_lvalue_reference_t<T>; };
		template<typename T>
		struct add_reference<std::optional<T>> { using type = optional_reference<T>; };
		template<typename T>
		using add_reference_t = typename add_reference<T>::type;

		template<typename T>
		struct reference_to_wrapper { using type = T; };
		template<typename T>
		struct reference_to_wrapper<T&> { using type = std::reference_wrapper<T>; };
		template<typename T>
		struct reference_to_wrapper<T&&> { using type = std::reference_wrapper<T>; };
		// template<typename T>
		// struct reference_to_wrapper<std::reference_wrapper<T>> { using type = std::reference_wrapper<T>; };
		template<typename T>
		using reference_to_wrapper_t = typename reference_to_wrapper<T>::type;

		template<typename T>
		struct or_to_variant { using type = T; };
		template<typename... Ts>
		struct or_to_variant<or_<Ts...>> { using type = std::variant<std::monostate, typename or_to_variant<Ts>::type...>; };
		template<typename T>
		using or_to_variant_t = typename or_to_variant<T>::type;

		template<typename T>
		struct or_to_variant_reference { using type = add_reference_t<T>; };
		template<typename... Ts>
		struct or_to_variant_reference<or_<Ts...>> { using type = std::variant<std::monostate, reference_to_wrapper_t<typename or_to_variant_reference<Ts>::type>...>; };
		template<typename T>
		using or_to_variant_reference_t = typename or_to_variant_reference<T>::type;

		template<typename T>
		struct or_to_tuple { using type = T; };
		template<typename... Ts>
		struct or_to_tuple<or_<Ts...>> { using type = std::tuple<std::decay_t<or_to_variant_reference_t<Ts>>...>; };
		template<typename T>
		using or_to_tuple_t = typename or_to_tuple<T>::type;
	}



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
			using value_type = std::tuple<detail::or_to_variant_t<Tcomponents>...>; /**< The type of the values returned by the iterator. */
			using reference = std::tuple<detail::or_to_variant_reference_t<Tcomponents>...>; /**< The type of the references returned by the iterator. */
			using pointer = void; /**< The type of the pointers returned by the iterator. */
			using iterator_category = std::forward_iterator_tag; /**< The category of the iterator. */

			ecs::scene* scene = nullptr; /**< A pointer to the ECS scene being queried. */
			entity e; /**< The current entity being processed. */

			/**
			* @brief Returns whether the iterator is valid.
			*
			* @return true if the iterator is valid, false otherwise.
			*/
			bool valid() const { return (valid_impl<Tcomponents>() && ...); }
		protected:
			template<typename Tcomponent>
			bool valid_impl() const {
				if constexpr(detail::is_or_v<Tcomponent>) {
					return valid_impl_or_expand(Tcomponent{});
				} else if constexpr(detail::is_optional_v<Tcomponent>) {
					return true;
				} else return scene->has_component<Tcomponent>(e);
			}
			template<typename... Tcomps>
			bool valid_impl_or_expand(or_<Tcomps...>) const { return (valid_impl<Tcomps>() || ...); }
		public:

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
			Iterator operator++(detail::post_increment_t) {
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
			reference operator*() const { return { get_component<Tcomponents, true>()... }; }

		protected:
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
			template<typename... Tcomps>
			inline detail::or_to_variant_reference_t<or_<Tcomps...>> get_component_or(or_<Tcomps...>) const {
				using Variant = detail::or_to_variant_reference_t<or_<Tcomps...>>;
				Variant out = {};
				std::apply([this, &out](auto ...elem){ ([this, &out](auto elem) {
					using Tcomponent = decltype(elem);
					auto res = get_component_or_single<Tcomponent, Tcomps...>({});
					if(res.index() > 0){
						out = res;
						return false;
					}
					return true;
				}(elem) && ...); }, detail::or_to_tuple_t<or_<Tcomps...>>{});
				return out;
			}
			template<typename Tcomponent, typename... Tcomps>
			inline detail::or_to_variant_reference_t<or_<Tcomps...>> get_component_or_single(or_<Tcomps...>) const {
				// using Variant = detail::or_to_variant_reference_t<or_<Tcomps...>>;
				auto res = get_component<Tcomponent, false>();
				if(res) return std::reference_wrapper{*res};
				return {};
			}
			template<typename Tcomponent>
			inline optional_reference<Tcomponent> get_component_optional(std::optional<Tcomponent>) const {
				return scene->get_component<Tcomponent>(e);
			}
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