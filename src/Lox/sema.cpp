#include <span>
#include "lox.hpp"
#include <ranges>
#include <unordered_set>
#include <vector>

#include "fp/pointer.hpp"

#include <iostream>


namespace doir::Lox {

	size_t calculate_child_count(TrivialModule& module, ecs::entity_t root /* = 1 */, bool annotate /* = true */) {
		DOIR_ZONE_SCOPED_AGRO;
		// using namespace lox::components;
		size_t immediate = 0, inChildren = 0;

		// TODO: Needs Tweaks
		if(module.has_component<operation>(root)) {
			auto& op = module.get_component<operation>(root);
			if(module.has_component<assign>(root)) {
				++immediate;
				inChildren = calculate_child_count(module, op.b, annotate);
			} else for(auto& child: op.array()) {
				if(!child) continue;
				++immediate;
				inChildren += calculate_child_count(module, child, annotate);
			}
		} else if(module.has_component<Module::HashtableComponent<function_declaire>>(root)){
			auto& block = module.get_component<struct block>(root);
			for(auto child: block.children.iterate(module)) {
				++immediate;
				inChildren += calculate_child_count(module, child, annotate);
			}
			auto& params = module.get_component<parameters>(root);
			for(auto param: params.parameters.iterate(module).range() | std::views::reverse) {
				++immediate;
				inChildren += calculate_child_count(module, param, annotate);
			}
		} else if(module.has_component<block>(root)) {
			auto& block = module.get_component<struct block>(root);
			for(auto child: block.children.iterate(module)) {
				++immediate;
				inChildren += calculate_child_count(module, child, annotate);
			}
		} else if(module.has_component<call>(root)) {
			auto& call = module.get_component<struct call>(root);
			for(auto param: call.children.iterate(module).range() | std::views::reverse) {
				++immediate;
				inChildren += calculate_child_count(module, param, annotate);
			}
			++immediate;
			inChildren += calculate_child_count(module, call.parent, annotate);
		} else { /* Do nothing */ }

		if(annotate) module.add_component<doir::comp::children>(root) = {immediate, inChildren + immediate};
		// auto dbg = module.get_component<doir::comp::children>(root);
		return inChildren + immediate;
	}

	void sort_parse_into_post_order_traversal_impl(TrivialModule& module, ecs::entity_t root, std::vector<ecs::entity_t>& order, std::unordered_set<ecs::entity_t>& missing) {
		constexpr static auto recurse = sort_parse_into_post_order_traversal_impl;

		if(module.has_component<operation>(root)) {
			auto& op = module.get_component<operation>(root);
			if(op.d) recurse(module, op.d, order, missing);
			if(op.c) recurse(module, op.c, order, missing);
			if(op.b) recurse(module, op.b, order, missing);
			if(op.a && !module.has_component<assign>(root))
				recurse(module, op.a, order, missing);
		} else if(module.has_component<Module::HashtableComponent<function_declaire>>(root)) {
			auto& block = module.get_component<struct block>(root);
			for(auto child: block.children.iterate(module))
				recurse(module, child, order, missing);
			for(auto param: module.get_component<parameters>(root).parameters.iterate(module).range() | std::views::reverse)
				recurse(module, param, order, missing);
		} else if(module.has_component<block>(root)) {
			auto& block = module.get_component<struct block>(root);
			for(auto child: block.children.iterate(module))
				recurse(module, child, order, missing);
		} else if(module.has_component<call>(root)) {
			auto& call = module.get_component<struct call>(root);
			for(auto param: call.children.iterate(module).range() | std::views::reverse)
				recurse(module, param, order, missing);
			recurse(module, call.parent, order, missing);
		} else { /* Do nothing */ }

		order.push_back(root);
		missing.erase(root);
	}

	void sort_parse_into_reverse_post_order_traversal(TrivialModule& module, ecs::entity_t root) {
		DOIR_ZONE_SCOPED_AGRO;
		size_t size = module.entity_count();
		std::vector<ecs::entity_t> order; order.reserve(size);
		std::unordered_set<ecs::entity_t> missing = std::move([size] {
			std::vector<ecs::entity_t> tmp(size > 0 ? size - 1 : 0, 0);
			std::iota(tmp.begin(), tmp.end(), 1);
			return std::unordered_set<ecs::entity_t>(tmp.begin(), tmp.end());
		}());

		// TODO: Do we want to sort functions based on some dependence graph?

		{
			DOIR_ZONE_SCOPED_NAMED_AGRO("sort_parse_into_reverse_post_order_traversal::impl");
			sort_parse_into_post_order_traversal_impl(module, root, order, missing);
		}

		{
			DOIR_ZONE_SCOPED_NAMED_AGRO("sort_parse_into_reverse_post_order_traversal::order_fixup");
			order.push_back(0); // The error token should always be token 0 (so put it last right before we reverse)
			std::reverse(order.begin(), order.end());

			// Add any superfluous tokens to the end of the list
			order.insert(order.cend(), missing.begin(), missing.end());
		}
		{
			DOIR_ZONE_SCOPED_NAMED_AGRO("sort_parse_into_reverse_post_order_traversal::reorder");
			module.reorder_entities<
				Module::HashtableComponent<parameter_declaire>,
				Module::HashtableComponent<variable_declaire>,
				Module::HashtableComponent<function_declaire>,
				operation,
				block,
				call,
				block_children_entry,
				parameters,
				parameters_entry//,
				// variable
			>((fp_view(size_t))fp_void_view_literal(order.data(), order.size()));
		}
		{
			DOIR_ZONE_SCOPED_NAMED_AGRO("sort_parse_into_reverse_post_order_traversal::make_monotonic");
			module.make_all_monotonic();
		}
	};

	

}