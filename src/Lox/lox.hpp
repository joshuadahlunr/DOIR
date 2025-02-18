#pragma once

#include "../module.hpp"
#include "../components.hpp"

#include "fp/dynarray.hpp"
#include <array>

namespace doir::Lox {
	extern fp_string comparison_buffer;

	inline namespace components {
		struct null {};
		struct variable { ecs::entity_t ref = doir::ecs::invalid_entity; };
		struct string {};
		struct literal {};

		struct block_children_entry: public array_entry { auto iterate(ecs::TrivialModule& module) {
			return iterate_impl<ecs::entity_t, block_children_entry>{*this, module};
		}};
		struct block {
			ecs::entity_t parent; block_children_entry children = {ecs::invalid_entity}; ecs::entity_t children_end = ecs::invalid_entity;
			static void swap_entities(block& b, ecs::TrivialModule& module, ecs::entity_t eA, ecs::entity_t eB) {
				if(b.parent == eA) b.parent = eB;
				else if(b.parent == eB) b.parent = eA;

				if(b.children.next == eA) b.children.next = eB;
				else if(b.children.next == eB) b.children.next = eA;
				if(b.children_end == eA) b.children_end = eB;
				else if(b.children_end == eB) b.children_end = eA;
			}

			void add_child(TrivialModule& module, ecs::entity_t child) {
				if(children_end == ecs::invalid_entity)
					children.set_next<block_children_entry>(module, child, ecs::invalid_entity);
				else 
					module.get_component<block_children_entry>(children_end).set_next<block_children_entry>(module, child, children_end);
				children_end = child;
			}

			void pop_back_child(TrivialModule& module) {
				auto& back = module.get_component<block_children_entry>(children_end);
				auto& second_back = module.get_component<block_children_entry>(back.previous);
				
				second_back.next = ecs::invalid_entity;
				children_end = back.previous;
			}

			// void finalize_list(TrivialModule& module) {
			// 	module.get_or_add_component<block_children_entry>(children_end).set_next<block_children_entry>(module, 0, children_end);
			// }
		};
		struct call: public block {}; // parent -> object being called on, children -> arguments
		// using call = block; // TODO: How bad of an idea is it for calls to reuse block's storage?
		struct trailing_call {};

		struct declaire {
			doir::lexeme name;
			ecs::entity_t parent; // Parent block
			bool operator==(const declaire& o) const {
				return parent == o.parent && fp_string_view_equal(name.view(comparison_buffer), o.name.view(comparison_buffer));
			}
			static void swap_entities(declaire& decl, ecs::TrivialModule& module, ecs::entity_t eA, ecs::entity_t eB) {
				if(decl.parent == eA) decl.parent = eB;
				else if(decl.parent == eB) decl.parent = eA;
			}
		};
		struct variable_declaire : public declaire {};
		struct function_declaire : public declaire {};
		struct parameter_declaire : public declaire {};
		struct parameters_entry: public array_entry { auto iterate(ecs::TrivialModule& module) {
			return iterate_impl<ecs::entity_t, parameters_entry>{*this, module};
		}};
		struct parameters { 
			parameters_entry params = {ecs::invalid_entity}; ecs::entity_t parameters_end = ecs::invalid_entity;
			// fp::dynarray<ecs::entity_t> parameters;
			static void swap_entities(struct parameters& params, ecs::TrivialModule& module, ecs::entity_t eA, ecs::entity_t eB) {
				if(params.params.next == eA) params.params.next = eB;
				else if(params.params.next == eB) params.params.next = eA;
				if(params.parameters_end == eA) params.parameters_end = eB;
				else if(params.parameters_end == eB) params.parameters_end = eA;
			}

			void add_parameter(ecs::TrivialModule& module, ecs::entity_t param) {
				if(parameters_end == ecs::invalid_entity)
					params.set_next<parameters_entry>(module, param, ecs::invalid_entity);
				else
					module.get_component<parameters_entry>(parameters_end).set_next<parameters_entry>(module, param, parameters_end);
				parameters_end = param;
			}
		};
		// struct BodyMarker {
		// 	ecs::entity_t skipTo;
		// 	static void swap_entities(BodyMarker& mark, ecs::entity eA, ecs::entity eB) {
		// 		if(mark.skipTo == eA) mark.skipTo = eB;
		// 		else if(mark.skipTo == eB) mark.skipTo = eA;
		// 	}
		// };

		struct operation { // Condition, Then, Else, Marker
			ecs::entity_t a = 0, b = 0, c = 0, d = 0;
			std::pair<ecs::entity_t&, ecs::entity_t&> pair() { return {a, b}; }
			const std::array<ecs::entity_t, 4> array() const { return std::array<ecs::entity_t, 4>{a, b, c, d}; }
			static void swap_entities(operation& op, ecs::TrivialModule& module, ecs::entity_t eA, ecs::entity_t eB) {
				if(op.a == eA) op.a = eB;
				else if(op.a == eB) op.a = eA;
				if(op.b == eA) op.b = eB;
				else if(op.b == eB) op.b = eA;
				if(op.c == eA) op.c = eB;
				else if(op.c == eB) op.c = eA;
				if(op.d == eA) op.d = eB;
				else if(op.d == eB) op.d = eA;
			}
		};

		struct not_ {};
		struct negate {};
		struct divide {};
		struct multiply {};
		struct add {};
		struct subtract {};
		struct less_than {};
		struct greater_than {};
		struct less_than_equal_to {};
		struct greater_than_equal_to {};
		struct equal_to {};
		struct not_equal_to {};
		struct and_ {};
		struct or_ {};
		struct assign {};
		struct print {};
		struct return_ {};
		struct while_ {};
		struct if_ {};
	}
	namespace comp = component;

	std::pair<TrivialModule, ecs::entity_t> parse_view(const fp_string_view view);
	std::pair<TrivialModule, ecs::entity_t> parse(const fp_string string);

	void dump(TrivialModule& module, ecs::entity_t root, size_t depth = 0);

	void sort_parse_into_reverse_post_order_traversal(TrivialModule& module, ecs::entity_t root);
	size_t calculate_child_count(TrivialModule& module, ecs::entity_t root = 1, bool annotate = false);
}