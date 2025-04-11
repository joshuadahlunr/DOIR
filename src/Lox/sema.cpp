#include <limits>
#include <span>
#include <string_view>
#include <ranges>
#include <unordered_set>
#include <utility>
#include <vector>

#include "fp/string.h"
#include "lox.hpp"

// #include "fp/pointer.hpp"

#include <iostream>


namespace doir::Lox {

	size_t calculate_child_count(TrivialModule& module, ecs::entity_t root /* = 1 */, bool annotate /* = true */) {
		DOIR_ZONE_SCOPED_AGGRO;
		// using namespace lox::components;
		size_t immediate = 0, inChildren = 0;

		// TODO: Needs Tweaks
		if(module.has_component<operation>(root)) {
			auto& op = module.get_component<operation>(root);
			for(auto& child: op.array()) {
				if(!child) continue;
				++immediate;
				inChildren += calculate_child_count(module, child, annotate);
			}
		} else if(module.has_component<Module::HashtableComponent<function_declare>>(root)){
			auto& block = module.get_component<struct block>(root);
			for(auto child: block.children.iterate(module)) {
				++immediate;
				inChildren += calculate_child_count(module, child, annotate);
			}
			if(module.has_component<parameters>(root)) {
				auto& params = module.get_component<parameters>(root);
				for(auto param: params.iterate(module).range() | std::views::reverse) {
					++immediate;
					inChildren += calculate_child_count(module, param, annotate);
				}
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
			if(op.a) recurse(module, op.a, order, missing);
		} else if(module.has_component<Module::HashtableComponent<function_declare>>(root)) {
			auto& block = module.get_component<struct block>(root);
			for(auto child: block.children.iterate(module))
				recurse(module, child, order, missing);
			if(module.has_component<parameters>(root))
				for(auto param: module.get_component<parameters>(root).iterate(module).range() | std::views::reverse)
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
		DOIR_ZONE_SCOPED_AGGRO;
		size_t size = module.entity_count();
		std::vector<ecs::entity_t> order; order.reserve(size);
		std::unordered_set<ecs::entity_t> missing = std::move([size] {
			std::vector<ecs::entity_t> tmp(size > 0 ? size - 1 : 0, 0);
			std::iota(tmp.begin(), tmp.end(), 1);
			return std::unordered_set<ecs::entity_t>(tmp.begin(), tmp.end());
		}());

		// TODO: Do we want to sort functions based on some dependence graph?

		{
			DOIR_ZONE_SCOPED_NAMED_AGGRO("sort_parse_into_reverse_post_order_traversal::impl");
			sort_parse_into_post_order_traversal_impl(module, root, order, missing);
		}

		{
			DOIR_ZONE_SCOPED_NAMED_AGGRO("sort_parse_into_reverse_post_order_traversal::order_fixup");
			order.push_back(0); // The error token should always be token 0 (so put it last right before we reverse)
			std::reverse(order.begin(), order.end());

			// Add any superfluous tokens to the end of the list
			order.insert(order.cend(), missing.begin(), missing.end());
		}
		{
			DOIR_ZONE_SCOPED_NAMED_AGGRO("sort_parse_into_reverse_post_order_traversal::reorder");
			module.reorder_entities<
				Module::HashtableComponent<parameter_declare>,
				Module::HashtableComponent<variable_declare>,
				Module::HashtableComponent<function_declare>,
				operation,
				block,
				call,
				block_children_entry,
				parameters,
				parameters_entry,
				body_marker//,
				// variable
			>((fp_view(size_t))fp_void_view_literal(order.data(), order.size()));
		}
		{
			DOIR_ZONE_SCOPED_NAMED_AGGRO("sort_parse_into_reverse_post_order_traversal::make_monotonic");
			module.make_all_monotonic();
		}
	};


	ecs::Entity current_block(TrivialModule& module, ecs::entity_t root) {
		DOIR_ZONE_SCOPED_AGGRO;
		ecs::entity_t target = root;
		do {
			while((root - 1) > 0 && !module.has_component<block>(--root));
		} while(root > 0 && root + module.get_component<doir::children>(root).total < target); // If target's offset is larger than the number of children in the block... it can't be root's child
		return root;
	}
	ecs::Entity current_function(TrivialModule& module, ecs::entity_t root) {
		DOIR_ZONE_SCOPED_AGGRO;
		if(module.has_component<Module::HashtableComponent<function_declare>>(root)) return root;
		ecs::entity_t target = root;
		do {
			while((root - 1) > 0 && !module.has_component<Module::HashtableComponent<function_declare>>(--root));
		} while(root > 0 && root + module.get_component<doir::children>(root).total < target); // If target's offset is larger than the number of children in the block... it can't be root's child
		return root;
	}

	template<typename Tkey>
	std::optional<ecs::Entity> blockwise_find(TrivialModule& module, Tkey key, bool has) {
		DOIR_ZONE_SCOPED_AGGRO;
		auto& hashtable = module.get_hashtable_storage<Tkey>();
		while(key.parent.entity > 0) {
			auto dbg = key.name.view(module.buffer);
			if(has) if(auto res = hashtable.find(key); res) return *res;

			if(auto f = current_function(module, key.parent); f) {
				if(module.has_component<parameters>(f))
					for(ecs::Entity param: module.get_component<parameters>(f).iterate(module))
						if(param.template get_component<doir::lexeme>().view(module.buffer) == key.name.view(module.buffer))
							return param;
			}
			auto next = current_block(module, key.parent);
			if(next == key.parent) break;
			else key.parent = next;
		}
		return {};
	}

	void lookup_references(TrivialModule& module, bool clear_references /* = true */) {
		DOIR_ZONE_SCOPED_AGGRO;
		// We don't ever use these hashtable references... they are just here to make sure the tables are built for blockwise_find
		auto& functions = module.get_hashtable_storage_rehashed<function_declare>();
		bool hasFunctions = functions.size();
		auto& variables = module.get_hashtable_storage_rehashed<variable_declare>();
		bool hasVariables = variables.size();

		if(!hasFunctions && !hasVariables) return;

		if(clear_references) for(ecs::Entity e = module.get_component<doir::children>(1).reverse_iteration_start(1); e--;) {
			if(!e.has_component<doir::entity_reference>()) continue;
			e.get_component<doir::entity_reference>() = {ecs::invalid_entity, e.get_component<doir::lexeme>()};
		}

		for(ecs::Entity e = module.get_component<doir::children>(1).reverse_iteration_start(1); e--;) {
			if(!e.has_component<doir::entity_reference>(module)) continue;

			auto& ref = e.get_component<doir::entity_reference>(module);
			if(ref.looked_up()) continue;

			// Try to find a matching function
			auto block = current_block(module, e);
			auto res = blockwise_find<function_declare>(module, {ref.lexeme, block}, hasFunctions);
			size_t distance = 0;
			while(!res) {
				auto next = current_block(module, block);
				if(next == block) break;
				else block = next;
				++distance;
				res = blockwise_find<function_declare>(module, {ref.lexeme, block}, hasVariables);
			}
			if(res) ref.entity = *res;
			else distance = std::numeric_limits<size_t>::max();
			size_t function_distance = std::exchange(distance, 0);

			// Then try to find a matching variable in a closer block
			block = current_block(module, e);
			res = blockwise_find<variable_declare>(module, {ref.lexeme, block}, hasVariables);
			while(!res || *res < e) { // Variable declared after... so we need to search in a higher block!
				auto next = current_block(module, block);
				if(next == block) break;
				else block = next;
				++distance;
				res = blockwise_find<variable_declare>(module, {ref.lexeme, block}, hasVariables);
			}
			if(res && distance < function_distance)
				ref.entity = *res;
		}
	}

	bool verify_references(TrivialModule& module) {
		DOIR_ZONE_SCOPED_AGGRO;
		bool valid = true;
		for(ecs::Entity e = module.get_component<doir::children>(1).reverse_iteration_start(1); e--;) {
			if(e.has_component<call>()) {
				auto& call = e.get_component<struct call>();
				auto& ref = call.parent.get_component<entity_reference>();
				if(!ref.looked_up()) {
					std::cerr << "Failed to find function: " << fp_string_view_to_std(ref.lexeme.view(module.buffer)) << " (" << e << ")" << std::endl;
					valid = false;
				}
			} else if(e.has_component<assign>()) {
				auto& op = e.get_component<operation>();
				auto& ref = op.a.get_component<entity_reference>();
				if(!ref.looked_up()) {
					std::cerr << "Failed to find function: " << fp_string_view_to_std(ref.lexeme.view(module.buffer)) << " (" << e << ")" << std::endl;
					valid = false;
				}
			} else if(e.has_component<variable>()) {
				auto& ref = e.get_component<entity_reference>();
				if(!ref.looked_up()) {
					std::cerr << "Failed to find variable: " << fp_string_view_to_std(ref.lexeme.view(module.buffer)) << " (" << e << ")" << std::endl;
					valid = false;
				}
			}
		}
		return valid;
	}

	bool verify_redeclarations(TrivialModule& module) {
		DOIR_ZONE_SCOPED_AGGRO;
		auto& functions = module.get_hashtable_storage_rehashed<function_declare>();
		bool hasFunctions = functions.size();
		auto& variables = module.get_hashtable_storage_rehashed<variable_declare>();
		bool hasVariables = variables.size();

		if(!hasFunctions && !hasVariables) return true;

		bool valid = true;
		for(ecs::Entity e = module.get_component<doir::children>(1).reverse_iteration_start(1); e--;) {
			if(e.has_component<doir::Module::HashtableComponent<function_declare>>()) {
				auto& lexeme = e.get_component<doir::lexeme>();
				auto block = current_block(module, e - 1);
				auto res = blockwise_find<function_declare>(module, {lexeme, block}, hasFunctions);
				if(res && res != e) {
					std::cerr << "Function " << fp_string_view_to_std(lexeme.view(module.buffer)) << " redeclared!" << std::endl;
					valid = false;
				}
			} else if(e.has_component<doir::Module::HashtableComponent<variable_declare>>()) {
				auto& lexeme = e.get_component<doir::lexeme>();
				auto res = *blockwise_find<variable_declare>(module, {lexeme, current_block(module, e)}, hasVariables);
				if(res && res != e) {
					std::cerr << "Variable " << fp_string_view_to_std(lexeme.view(module.buffer)) << " redeclared!" << std::endl;
					valid = false;
				}
			} else if(e.has_component<doir::Module::HashtableComponent<parameter_declare>>()) {
				auto& lexeme = e.get_component<doir::lexeme>();
				auto res = *blockwise_find<variable_declare>(module, {lexeme, current_function(module, e) + 1}, false);
				if(res && res != e) {
					std::cerr << "Param " << fp_string_view_to_std(lexeme.view(module.buffer)) << " redeclared!" << std::endl;
					valid = false;
				}
			}
		}
		return valid;
	}

	// bool verify_call_arrities(TrivialModule& module) {
	// 	DOIR_ZONE_SCOPED_AGGRO;
	// 	bool valid = true;
	// 	for(ecs::Entity e = module.get_component<doir::children>(1).reverse_iteration_start(1); e--;) {
	// 		if(!e.has_component<call>()) continue;

	// 		auto& call = e.get_component<struct call>();
	// 		auto ref = call.parent.get_component<doir::entity_reference>().resolve(module);
	// 		if(ref == ecs::invalid_entity){
	// 			std::cerr << "Failed to find function: " << fp_string_view_to_std(ref.get_component<lexeme>().view(module.buffer)) << " (" << e << ")" << std::endl;
	// 			valid = false;
	// 		}
	// 		if()
	// 		auto& params = ref.get_component<parameters>();
	// 		size_t param_size = params.size(module);

	// 		size_t call_size = call.size(module);
	// 		if(call_size != param_size) {
	// 			std::cerr << "Call arity (" << call_size << ") does not match declaration arity (" << param_size << ")" << std::endl;
	// 			valid = false;
	// 		}
	// 	}
	// 	return valid;
	// }

	// bool identify_trailing_calls(TrivialModule& module) {
	// 	ZoneScoped;
	// 	for(ecs::entity_t t = module.get_attribute<doir::Children>(1)->total + 2; t--;) {
	// 		if(!module.has_attribute<lox::comp::Call>(t)) continue;

	// 		auto b = current_block(module, t);
	// 		if(b == 0) continue;
	// 		auto& block = *module.get_attribute<lox::components::Block>(b);

	// 		// Find the index of the call in its block
	// 		auto root = t;
	// 		auto i = block.children.begin();
	// 		while((i = std::ranges::find(block.children, root)) == block.children.end() && root > 0) --root;
	// 		if(root == 0) return false; // This represents some sort of invalid structure!

	// 		// If its not last it can't be trailing...
	// 		auto index = std::distance(block.children.begin(), i);
	// 		if(index != block.children.size() - 1) continue;

	// 		// If the call is top level in its block or is the immediate child of a return it is trailing
	// 		if(t == root || module.has_attribute<lox::components::Return>(t - 1))
	// 			module.add_attribute<lox::components::TrailingCall>(t);
	// 	}
	// 	return true;
	// }
	// // TODO: Detecting direct recursion at semantic analysis time should be possible!


	// // Ensures the parse tree is sorted and properly annotated
	// void canonicalize(TrivialModule& module, ecs::entity_t root, bool clear_references /*= true*/) {
	// 	ZoneScoped;
	// 	sort_parse_into_reverse_post_order_traversal(module, root);
	// 	calculate_child_count(module);
	// 	lookup_references(module, clear_references);
	// }

}