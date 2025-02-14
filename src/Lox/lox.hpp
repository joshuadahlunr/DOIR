#pragma once

#include "../module.hpp"
#include "../components.hpp"

#include "fp/dynarray.hpp"

namespace doir::Lox {
	extern fp_string comparison_buffer;

	inline namespace components {
		struct null {};
		struct variable { ecs::entity_t ref = doir::ecs::invalid_entity; };
		struct string {};
		struct literal {};

		struct block {
			ecs::entity_t parent; fp::dynarray<ecs::entity_t> children = nullptr;
			static void swap_entities(block& b, ecs::entity_t eA, ecs::entity_t eB) {
				if(b.parent == eA) b.parent = eB;
				else if(b.parent == eB) b.parent = eA;

				for(auto& child: b.children)
					if(child == eA) child = eB;
					else if(child == eB) child = eA;
			}
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
			static void swap_entities(declaire& decl, ecs::entity_t eA, ecs::entity_t eB) {
				if(decl.parent == eA) decl.parent = eB;
				else if(decl.parent == eB) decl.parent = eA;
			}
		};
		struct variable_declaire : public declaire {};
		struct function_declaire : public declaire {};
		struct parameter_declaire : public declaire {};
		struct parameters {
			fp::dynarray<ecs::entity_t> parameters;
			static void swap_entities(struct parameters& params, ecs::entity_t eA, ecs::entity_t eB) {
				for(auto& param: params.parameters)
					if(param == eA) param = eB;
					else if(param == eB) param = eA;
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
			std::array<ecs::entity_t, 4> array() { return std::array<ecs::entity_t, 4>{a, b, c, d}; }
			static void swap_entities(operation& op, ecs::entity_t eA, ecs::entity_t eB) {
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