#include "ECS/ecs.hpp"
#include "ECS/entity.hpp"
#include "module.hpp"

#include <cassert>
#include <concepts>
#include <ranges>
#define FP_OSTREAM_SUPPORT
#include <fp/string.hpp>

#ifdef __cplusplus
	#include <algorithm>
#endif

namespace doir {
	inline namespace component {

		struct source_location {
			size_t line, column;
			fp_string_view filename;

#ifdef __cplusplus
			static source_location calculate(fp_string_view view, size_t position, fp_string_view filename = fp_string_view_null) {
				source_location out{.filename = filename};
				for(size_t i = 0; i < position; ++i)
					if(fp_view_data(char, view)[i] == '\n') {
						++out.line;
						out.column = 0;
					} else ++out.column;
				return out;
			}
#endif
		};
		struct source_range {
			size_t start_line, start_column;
			size_t end_line, end_column;
			fp_string_view filename;

#ifdef __cplusplus
			static source_range calculate(fp_string_view view, size_t start, size_t end, fp_string_view filename = fp_string_view_null) {
				assert(start < end);
				source_range out{.filename = filename};
				for(size_t i = 0; i < end; ++i) {
					if(fp_view_data(char, view)[i] == '\n') {
						++out.end_line;
						out.end_column = 0;
					} else ++out.end_column;
					if(i == start) {
						out.start_line = out.end_line;
						out.start_column = out.end_column;
					}
				}
				return out;
			}
#endif
		};

		struct lexeme {
			size_t start, length;

#ifdef __cplusplus
			inline fp::string_view view(fp_string buffer) const {
				return {buffer + start, length};
			}
			inline fp::string_view view(fp_string_view view) const {
				assert(start + length < fp_view_size(view));
				return {fp_view_data(char, view) + start, length};
			}

			inline source_location start_location(fp_string_view view, fp_string_view filename = fp_string_view_null) const {
				assert(start + length < fp_view_size(view));
				return source_location::calculate(view, start, filename);
			}
			inline source_location end_location(fp_string_view view, fp_string_view filename = fp_string_view_null) const {
				assert(start + length < fp_view_size(view));
				return source_location::calculate(view, start + length, filename);
			}
			inline struct source_range source_range(fp_string_view view, fp_string_view filename = fp_string_view_null) const {
				assert(start + length < fp_view_size(view));
				return source_range::calculate(view, start, start + length);
			}

			inline lexeme merge(const lexeme o) const {
				auto start = std::min(this->start, o.start);
				auto end = std::max(this->start + length, o.start + o.length);
				return {start, end - start};
			}
			inline lexeme operator+(const lexeme o) const  { return merge(o); }
#endif // __cplusplus
		};

		struct entity_reference {
			ecs::Entity entity = ecs::invalid_entity;
			struct lexeme lexeme;

			ecs::Entity resolve(TrivialModule& module) {
				assert(looked_up());
				auto chain = entity;
				while(chain.has_component<entity_reference>(module)) {
					auto ref = chain.get_component<entity_reference>(module);
					if(!ref.looked_up()) return ecs::invalid_entity;
					chain = ref.entity;
				}
				return chain;
			}
			bool looked_up() { return entity != ecs::invalid_entity; }
			bool resolved_looked_up(TrivialModule& module) { return resolve(module) != ecs::invalid_entity; }
		};

		struct children {
			size_t immediate, total;

			ecs::entity_t reverse_iteration_start(ecs::entity_t us) { return us + total + 1; }
		};

		struct list_entry {
			ecs::Entity next = ecs::invalid_entity, previous = ecs::invalid_entity;

			template <std::derived_from<list_entry> Tparent = list_entry>
			void set_next(ecs::TrivialModule& module, ecs::entity_t next, std::optional<ecs::Entity> self_ = {}) {
				list_entry& next_entry = module.get_or_add_component<Tparent>(next);
				auto self = self_.has_value() ? *self_ : module.get_or_add_component<Tparent>(this->previous).next; // NOTE: The else case in this expression will likely fail when the then case should be taken, thus value_or can't be used!

				next_entry.previous = self;
				this->next = next;
			}

			static void swap_entities(list_entry& e, ecs::TrivialModule& module, ecs::entity_t eA, ecs::entity_t eB) {
				if(e.next == eA) e.next = eB;
				else if(e.next == eB) e.next = eA;
				if(e.previous == eA) e.previous = eB;
				else if(e.previous == eB) e.previous = eA;
			}

			struct sentinel {};
			template<typename T, std::derived_from<list_entry> Tparent = list_entry>
			struct iterator {
				constexpr static bool lookup_on_dereference = !std::is_same_v<T, ecs::entity_t> && !std::is_same_v<T, ecs::Entity>;
				using iterator_category = std::bidirectional_iterator_tag;
				using difference_type = std::ptrdiff_t;
				using value_type = T;
				using pointer = value_type*;
				using reference = value_type&;

				ecs::entity_t current, previous = ecs::invalid_entity;
				ecs::TrivialModule* module;

				reference operator*() const requires(lookup_on_dereference) { assert(current && module); return module->get_component<T>(current); }
				pointer operator->() requires(lookup_on_dereference) { assert(current && module); return &module->get_component<T>(current); }

				value_type operator*() const requires(!lookup_on_dereference) { assert(current); return current; }
				value_type operator->() const requires(!lookup_on_dereference) { assert(current); return current; }

				// Prefix increment
				iterator& operator++() { assert(current && module); previous = current; current = module->get_component<Tparent>(current).next; return *this; }
				// Postfix increment
				iterator operator++(int) { iterator tmp = *this; ++(*this); return tmp; }

				// Prefix decrement
				iterator& operator--() {
					assert(module);
					if(previous) current = previous;
					else if(current) current = module->get_component<Tparent>(current).previous;
					else assert(false);

					if(current) previous = module->get_component<Tparent>(current).previous;
					else previous = ecs::invalid_entity;

					return *this;
				}
				// Postfix decrement
				iterator operator--(int) { iterator tmp = *this; --(*this); return tmp; }

				friend bool operator== (const iterator& a, const iterator& b) { return a.current == b.current && a.module == b.module; };
				friend bool operator!= (const iterator& a, const iterator& b) { return a.current != b.current || a.module != b.module; };

				friend bool operator== (const iterator& a, const sentinel& b) { return a.current == ecs::invalid_entity; };
			};

			template<typename T, std::derived_from<list_entry> Tparent = list_entry>
			struct iterate_impl {
				Tparent& parent;
				ecs::TrivialModule& module;
				iterator<T, Tparent> begin() { return iterator<T, Tparent>{parent.next, ecs::invalid_entity, &module}; }
				sentinel end() { return {}; }
				std::ranges::subrange<iterator<T, Tparent>, sentinel, std::ranges::subrange_kind::unsized> range() { return {begin(), end()}; }
			};
			template<typename T, std::derived_from<list_entry> Tparent = list_entry>
			iterate_impl<T, Tparent> iterate(ecs::TrivialModule& module) {
				return {*this, module};
			}
		};

		template<std::derived_from<list_entry> T>
		struct list {
			T children = {}; ecs::Entity children_end = ecs::invalid_entity;

			ecs::Entity front() { return children.next; }
			ecs::Entity back() { return children_end; }

			template<typename Tret = ecs::Entity>
			T::template iterate_impl<Tret, T> iterate(ecs::TrivialModule& module) {
				return {children, module};
			}

			list& push_back(TrivialModule& module, ecs::entity_t child) {
				if(children_end == ecs::invalid_entity)
					children.template set_next<T>(module, child, ecs::invalid_entity);
				else
					module.get_component<T>(children_end).template set_next<T>(module, child, children_end);
				children_end = child;
				return *this;
			}

			list& push_front(TrivialModule& module, ecs::entity_t child) {
				// If there are no children let push_back mark this child as the end
				if(children_end == ecs::invalid_entity)
					return push_back(module, child);

				auto old = children.next;
				children.template set_next<T>(module, child, ecs::invalid_entity);
				module.get_component<T>(child).set_next(module, old);
				return *this;
			}

			list& pop_back(TrivialModule& module) {
				auto& back = module.get_component<T>(children_end);
				auto& second_back = module.get_component<T>(back.previous);

				second_back.next = ecs::invalid_entity;
				children_end = back.previous;
				return *this;
			}

			size_t size(TrivialModule& module) {
				size_t count = 0;
				for(auto _: children.iterate(module))
					++count;
				return count;
			}

			ecs::Entity access(TrivialModule& module, size_t i) {
				size_t count = 0;
				for(auto e: children.iterate(module))
					if(count == i)
						return e;
					else ++count;
				return ecs::invalid_entity;
			}
		};
	}
	namespace comp = component;
}
