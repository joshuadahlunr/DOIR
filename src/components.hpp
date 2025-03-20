#include "ECS/ecs.hpp"
#include "ECS/entity.hpp"

#include <fp/string.h>
#include <ranges>

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
			inline fp_string_view view(fp_string buffer) const {
				return {buffer + start, length};
			}
			inline fp_string_view view(fp_string_view view) const {
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
			ecs::Entity entity = doir::ecs::invalid_entity;
			struct lexeme lexeme;
		};

		struct children {
			size_t immediate, total;
		};

		struct array_entry {
			ecs::Entity next, previous;

			template <std::derived_from<array_entry> Tparent = array_entry>
			void set_next(ecs::TrivialModule& module, ecs::Entity next, std::optional<ecs::Entity> self_ = {}) {
				array_entry& next_entry = module.get_or_add_component<Tparent>(next);
				auto self = self_.has_value() ? *self_ : module.get_or_add_component<Tparent>(this->previous).next; // NOTE: The else case in this expression will likely fail when the then case should be taken, thus value_or can't be used!

				next_entry.previous = self;
				this->next = next;
			}

			static void swap_entities(array_entry& e, ecs::TrivialModule& module, ecs::Entity eA, ecs::Entity eB) {
				if(e.next == eA) e.next = eB;
				else if(e.next == eB) e.next = eA;
				if(e.previous == eA) e.previous = eB;
				else if(e.previous == eB) e.previous = eA;
			}

			struct sentinel {};
			template<typename T, std::derived_from<array_entry> Tparent = array_entry>
			struct iterator {
				constexpr static bool lookup_on_dereference = !std::is_same_v<T, ecs::entity_t>;
				using iterator_category = std::bidirectional_iterator_tag;
				using difference_type = std::ptrdiff_t;
				using value_type = T;
				using pointer = value_type*;
				using reference = value_type&;

				ecs::entity_t current, previous;
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

			template<typename T, std::derived_from<array_entry> Tparent = array_entry>
			struct iterate_impl {
				Tparent& parent;
				ecs::TrivialModule& module;
				iterator<T, Tparent> begin() { return iterator<T, Tparent>{parent.next, ecs::invalid_entity, &module}; }
				sentinel end() { return {}; }
				std::ranges::subrange<iterator<T, Tparent>, sentinel, std::ranges::subrange_kind::unsized> range() { return {begin(), end()}; }
			};
			template<typename T, std::derived_from<array_entry> Tparent = array_entry>
			iterate_impl<T, Tparent> iterate(ecs::TrivialModule& module) {
				return {*this, module};
			}
		};

	}
	namespace comp = component;
}
