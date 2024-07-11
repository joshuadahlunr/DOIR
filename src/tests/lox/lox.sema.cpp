#include "lox.AST.hpp"
#include "lox.parse.hpp"
#include <algorithm>
#include <ranges>
#include <unordered_set>
#include <vector>

void sort_parse_into_post_order_traversal_impl(doir::Module& module, doir::Token root, std::vector<doir::Token>& order, std::unordered_set<doir::Token>& missing) {
	using namespace lox::components;
	auto recurse = sort_parse_into_post_order_traversal_impl;

	switch (auto t = lox::token_type(module, root); t) {
	break; case lox::Type::Variable: [[fallthrough]];
	case lox::Type::Null: [[fallthrough]];
	case lox::Type::Number: [[fallthrough]];
	case lox::Type::String: [[fallthrough]];
	case lox::Type::Boolean: // Do nothing!
	break; case lox::Type::Block: {
		for(auto child: module.get_attribute<Block>(root)->children | std::views::reverse)
			recurse(module, child, order, missing);
	}
	break; case lox::Type::Return: [[fallthrough]];
	case lox::Type::Print: [[fallthrough]];
	case lox::Type::Not: [[fallthrough]];
	case lox::Type::Negate: {
		recurse(module, module.get_attribute<Operation>(root)->left, order, missing);
	}
	break; case lox::Type::Divide: [[fallthrough]];
	case lox::Type::Multiply: [[fallthrough]];
	case lox::Type::Add: [[fallthrough]];
	case lox::Type::Subtract: [[fallthrough]];
	case lox::Type::LessThan: [[fallthrough]];
	case lox::Type::GreaterThan: [[fallthrough]];
	case lox::Type::LessThanEqualTo: [[fallthrough]];
	case lox::Type::GreaterThanEqualTo: [[fallthrough]];
	case lox::Type::EqualTo: [[fallthrough]];
	case lox::Type::NotEqualTo: [[fallthrough]];
	case lox::Type::And: [[fallthrough]];
	case lox::Type::Or: [[fallthrough]];
	case lox::Type::While: {
		recurse(module, module.get_attribute<Operation>(root)->right, order, missing);
		recurse(module, module.get_attribute<Operation>(root)->left, order, missing);
	}
	break; case lox::Type::VariableDeclaire: {
		if(auto op = module.get_attribute<Operation>(root); op)
			recurse(module, op->left, order, missing);
	}
	break; case lox::Type::FunctionDeclaire: {
		if(auto op = module.get_attribute<Operation>(root); op)
			recurse(module, op->left, order, missing);
	}
	break; case lox::Type::Call: {
		auto& call = *module.get_attribute<Call>(root);
		for(auto& param: call.children | std::views::reverse)
			recurse(module, param, order, missing);
	}
	break; case lox::Type::Assign: {
		recurse(module, module.get_attribute<Operation>(root)->left, order, missing);
	}
	break; case lox::Type::If: {
		std::vector<doir::Token> sub; sub.reserve(3);
		bool hasElse = module.has_attribute<OperationIf>(root);
		if(hasElse) {
			auto& arr = *module.get_attribute<OperationIf>(root);
			sub = {arr.begin(), arr.end()};
		} else {
			auto& op = *module.get_attribute<Operation>(root);
			sub.push_back(op.left); sub.push_back(op.right);
		}
		for(auto& elem: sub | std::views::reverse)
			recurse(module, elem, order, missing);
	}
	break; default: {}// std::cout << "<unknown node>" << std::endl;
	}

	order.push_back(root);
	missing.erase(root);
}

void sort_parse_into_reverse_post_order_traversal(doir::Module& module, doir::Token root) {
	size_t size = module.token_count();
	std::vector<doir::Token> order; order.reserve(size);
	std::unordered_set<doir::Token> missing = [size] {
		std::vector<doir::Token> tmp(size > 0 ? size - 1 : 0, 0);
		std::iota(tmp.begin(), tmp.end(), 1);
		return std::unordered_set<doir::Token>(tmp.begin(), tmp.end());
	}();

	// TODO: Do we want to sort functions based on some dependence graph?
	
	sort_parse_into_post_order_traversal_impl(module, root, order, missing);
	
	order.push_back(0); // The error token should always be token 0 (so put it last right before we reverse)
	std::reverse(order.begin(), order.end());

	// Add any superfluous tokens to the end of the list
	order.insert(order.cend(), missing.begin(), missing.end());

	((ecs::scene*)&module)->reorder_entities<
		doir::hashtable_t<lox::comp::VariableDeclaire>, 
		doir::hashtable_t<lox::comp::FunctionDeclaire>,
		lox::comp::Operation,
		lox::comp::OperationIf,
		lox::comp::Block
	>(order);
	((ecs::scene*)&module)->make_monotonic<
		lox::comp::Operation,
		lox::comp::OperationIf,
		lox::comp::Block
	>();
};



TEST_CASE("Lox::Sema") {
	doir::ParseModule module("fun add(a, b) { var tmp = a; a = b; b = tmp; return a + b; } var x = 0; var y = 1; if(true) print add(x, y); for(;;) print x;");
	auto root = lox::parse{}.start(module);
	if(module.has_attribute<doir::Error>(root))
		std::cerr << "!!ERROR!! " << module.get_attribute<doir::Error>(root)->message << std::endl;
	sort_parse_into_reverse_post_order_traversal(module, root);
	print(module, root, true);
}