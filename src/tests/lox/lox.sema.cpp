#include "lox.hpp"
#include <algorithm>
#include <iterator>
#include <ranges>
#include <sstream>
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
		for(auto child: module.get_attribute<Block>(root)->children)
			recurse(module, child, order, missing);
	}
	break; case lox::Type::Return: [[fallthrough]];
	case lox::Type::Print: [[fallthrough]];
	case lox::Type::Not: [[fallthrough]];
	case lox::Type::Negate: {
		if(module.has_attribute<Operation>(root))
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
		for(auto param: *module.get_attribute<Parameters>(root) | std::views::reverse)
			recurse(module, param, order, missing);
	}
	break; case lox::Type::Call: {
		auto& call = *module.get_attribute<Call>(root);
		for(auto& param: call.children | std::views::reverse)
			recurse(module, param, order, missing);
		recurse(module, call.parent, order, missing);
	}
	break; case lox::Type::Assign: {
		recurse(module, module.get_attribute<Operation>(root)->left, order, missing);
	}
	break; case lox::Type::And: [[fallthrough]];
	case lox::Type::Or: [[fallthrough]];
	case lox::Type::If: {
		for(auto& elem: *module.get_attribute<OperationIf>(root) | std::views::reverse) {
			if(elem == 0) continue; // Skip else
			recurse(module, elem, order, missing);
		}
	}
	break; case lox::Type::ParameterDeclaire: [[fallthrough]];
	default: {}
	}

	order.push_back(root);
	missing.erase(root);
}

void sort_parse_into_reverse_post_order_traversal(doir::Module& module, doir::Token root) {
	ZoneScoped;
	size_t size = module.token_count();
	std::vector<doir::Token> order; order.reserve(size);
	std::unordered_set<doir::Token> missing = [size] {
		std::vector<doir::Token> tmp(size > 0 ? size - 1 : 0, 0);
		std::iota(tmp.begin(), tmp.end(), 1);
		return std::unordered_set<doir::Token>(tmp.begin(), tmp.end());
	}();

	// TODO: Do we want to sort functions based on some dependence graph?

	{
		ZoneScopedN("sort_parse_into_reverse_post_order_traversal::impl");
		sort_parse_into_post_order_traversal_impl(module, root, order, missing);
	}

	{
		ZoneScopedN("sort_parse_into_reverse_post_order_traversal::order_fixup");
		order.push_back(0); // The error token should always be token 0 (so put it last right before we reverse)
		std::reverse(order.begin(), order.end());

		// Add any superfluous tokens to the end of the list
		order.insert(order.cend(), missing.begin(), missing.end());
	}
	{
		ZoneScopedN("sort_parse_into_reverse_post_order_traversal::reorder");
		((ecs::scene*)&module)->reorder_entities<
			doir::hashtable_t<lox::comp::VariableDeclaire>,
			doir::hashtable_t<lox::comp::FunctionDeclaire>,
			lox::comp::BodyMarker,
			lox::comp::Operation,
			lox::comp::OperationIf,
			lox::comp::Block,
			lox::comp::Parameters
		>(order);
	}
	// TODO: There is a bug in make_monotonic!
	// module.make_monotonic<
	// 	lox::comp::BodyMarker,
	// 	lox::comp::Operation,
	// 	lox::comp::OperationIf,
	// 	lox::comp::Block,
	// 	lox::comp::Parameters
	// >();
};

size_t calculate_child_count(doir::Module& module, doir::Token root = 1, bool anotate = true) {
	ZoneScoped;
	using namespace lox::components;
	size_t immediate = 0, inChildren = 0;

	switch (auto t = lox::token_type(module, root); t) {
	break; case lox::Type::Block: {
		for(auto child: module.get_attribute<Block>(root)->children) {
			++immediate;
			inChildren += calculate_child_count(module, child, anotate);
		}
	}
	break; case lox::Type::Return: [[fallthrough]];
	case lox::Type::Print: [[fallthrough]];
	case lox::Type::Not: [[fallthrough]];
	case lox::Type::Negate: {
		if(module.has_attribute<Operation>(root)) {
			immediate = 1;
			inChildren = calculate_child_count(module, module.get_attribute<Operation>(root)->left, anotate);
		}
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
	case lox::Type::While: {
		immediate = 2;
		inChildren = calculate_child_count(module, module.get_attribute<Operation>(root)->left, anotate);
		inChildren += calculate_child_count(module, module.get_attribute<Operation>(root)->right, anotate);
	}
	break; case lox::Type::VariableDeclaire: {
		if(auto op = module.get_attribute<Operation>(root); op) {
			immediate = 1;
			inChildren = calculate_child_count(module, op->left, anotate);
		}
	}
	break; case lox::Type::FunctionDeclaire: {
		if(auto op = module.get_attribute<Operation>(root); op) {
			immediate = 1;
			inChildren = calculate_child_count(module, op->left, anotate);
		}
		for(auto param: *module.get_attribute<Parameters>(root)) {
			++immediate;
			inChildren += calculate_child_count(module, param, anotate);
		}
	}
	break; case lox::Type::Call: {
		auto& call = *module.get_attribute<Call>(root);
		immediate = 1;
		inChildren += calculate_child_count(module, call.parent, anotate);
		for(auto& param: call.children) {
			++immediate;
			inChildren += calculate_child_count(module, param, anotate);
		}
	}
	break; case lox::Type::Assign: {
		immediate = 1;
		inChildren = calculate_child_count(module, module.get_attribute<Operation>(root)->left, anotate);
	}
	break; case lox::Type::And: [[fallthrough]];
	case lox::Type::Or: [[fallthrough]];
	case lox::Type::If: {
		for(auto& elem: *module.get_attribute<OperationIf>(root)) {
			if(elem == 0) continue; // Skip else
			++immediate;
			inChildren += calculate_child_count(module, elem, anotate);
		}
	}
	break; case lox::Type::Variable: [[fallthrough]];
	case lox::Type::Null: [[fallthrough]];
	case lox::Type::Number: [[fallthrough]];
	case lox::Type::String: [[fallthrough]];
	case lox::Type::Boolean: [[fallthrough]];
	case lox::Type::ParameterDeclaire: [[fallthrough]];
	default: immediate = 0; inChildren = 0;
	}

	if(anotate) module.add_attribute<doir::Children>(root) = {immediate, inChildren + immediate};
	return inChildren + immediate;
}

doir::Token current_block(doir::Module& module, doir::Token root) {
	ZoneScoped;
	doir::Token target = root;
	do {
		--root;
		for(; !module.has_attribute<lox::comp::Block>(root) && root > 0; --root);
	} while(root > 0 && root + module.get_attribute<doir::Children>(root)->total < target); // If our offset is larger than the number of children in the block... we can't be its child
	return root;
}
doir::Token current_function(doir::Module& module, doir::Token root) {
	ZoneScoped;
	doir::Token target = root;
	do {
		--root;
		for(; !module.has_hashtable_attribute<lox::comp::FunctionDeclaire>(root) && root > 0; --root);
	} while(root > 0 && root + module.get_attribute<doir::Children>(root)->total < target); // If our offset is larger than the number of children in the block... we can't be its child
	return root;
}

template<typename Tkey>
std::optional<doir::Token> blockwise_find(doir::Module& module, Tkey key, bool has) {
	ZoneScoped;
	auto& hashtable = module.get_hashtable<Tkey>(true).value();
	while(key.parent > 0) {
		auto dbg = key.name.view(module.buffer);
		if(has) if(auto res = hashtable.find(key); res) return *res;

		if(auto f = current_function(module, key.parent); f) {
			for(auto& param: *module.get_attribute<lox::comp::Parameters>(f))
				if(module.get_attribute<doir::Lexeme>(param)->view(module.buffer) == key.name.view(module.buffer))
					return param;
		}
		key.parent = current_block(module, key.parent);
	}
	return {};
}

void lookup_references(doir::Module& module, bool clear_references = true) {
	ZoneScoped;
	// We don't ever use these hashtable references... they are just here to make sure the tables are built for blockwise_find
	auto& functions = *module.get_hashtable<lox::comp::FunctionDeclaire>();
	bool hasFunctions = functions.size();
	auto& variables = *module.get_hashtable<lox::comp::VariableDeclaire>();
	bool hasVariables = variables.size();

	if(!hasFunctions && !hasVariables) return;

	if(clear_references) for(doir::Token t = module.get_attribute<doir::Children>(1)->total + 2; t--;) {
		if(!module.has_attribute<doir::TokenReference>(t)) continue;
		*module.get_attribute<doir::TokenReference>(t) = *module.get_attribute<doir::Lexeme>(t);
	}

	for(doir::Token t = module.get_attribute<doir::Children>(1)->total + 2; t--;) {
		if(!module.has_attribute<doir::TokenReference>(t) && !module.has_attribute<lox::comp::Function>(t)) continue;

		if(module.has_attribute<lox::comp::Function>(t)) {
			auto& call = *module.get_attribute<lox::comp::Call>(t);
			auto& ref = *module.get_attribute<doir::TokenReference>(call.parent);
			if(ref.looked_up()) continue;

			auto res = blockwise_find<lox::comp::FunctionDeclaire>(module, {ref.lexeme(), current_block(module, t)}, hasFunctions);
			if(res) ref = *res;
		}
		if((module.has_attribute<lox::comp::Variable>(t) || module.has_attribute<lox::comp::Assign>(t))) {
			auto& ref = *module.get_attribute<doir::TokenReference>(t);
			if(ref.looked_up()) continue;

			auto res = blockwise_find<lox::comp::VariableDeclaire>(module, {ref.lexeme(), current_block(module, t)}, hasVariables);
			if(res) ref = *res;
		}
	}
}

bool verify_references(doir::Module& module) {
	ZoneScoped;
	bool valid = true;
	for(doir::Token t = module.get_attribute<doir::Children>(1)->total + 2; t--;) {
		if(!module.has_attribute<doir::TokenReference>(t) && !module.has_attribute<lox::comp::Function>(t)) continue;

		if(module.has_attribute<lox::comp::Function>(t)) {
			auto& call = *module.get_attribute<lox::comp::Call>(t);
			auto& ref = *module.get_attribute<doir::TokenReference>(call.parent);
			if(!ref.looked_up()) {
				doir::print_diagnostic(module, t, (std::stringstream{} << "Failed to find function: " << ref.lexeme().view(module.buffer) << " (" << t << ")").str()) << std::endl;
				valid = false;
			}
		}
		if(module.has_attribute<lox::comp::Variable>(t) || module.has_attribute<lox::comp::Assign>(t)) {
			auto& ref = *module.get_attribute<doir::TokenReference>(t);
			if(!ref.looked_up()) {
				doir::print_diagnostic(module, t, (std::stringstream{} << "Failed to find variable: " << ref.lexeme().view(module.buffer) << " (" << t << ")").str()) << std::endl;
				valid = false;
			}
		}
	}
	return valid;
}

bool verify_redeclarations(doir::Module& module) {
	ZoneScoped;
	auto& functions = *module.get_hashtable<lox::comp::FunctionDeclaire>();
	bool hasFunctions = functions.size();
	auto& variables = *module.get_hashtable<lox::comp::VariableDeclaire>();
	bool hasVariables = variables.size();

	if(!hasFunctions && !hasVariables) return true;

	bool valid = true;
	for(doir::Token t = module.get_attribute<doir::Children>(1)->total + 2; t--;) {
		if(!module.has_hashtable_attribute<lox::components::VariableDeclaire>(t) && !module.has_hashtable_attribute<lox::components::FunctionDeclaire>(t)) continue;

		if(module.has_hashtable_attribute<lox::components::FunctionDeclaire>(t)) {
			auto& lexeme = *module.get_attribute<doir::Lexeme>(t);
			auto res = *blockwise_find<lox::comp::FunctionDeclaire>(module, {lexeme, current_block(module, t)}, hasFunctions);
			if(res != t) {
				doir::print_diagnostic(module, res, (std::stringstream{} << "Function " << lexeme.view(module.buffer) << " redeclaired!").str()) << "\n";
				doir::print_diagnostic(module, t, "Identified here...", doir::diagnostic_type::Info) << std::endl;
				valid = false;
			}
		}
		if(module.has_hashtable_attribute<lox::components::VariableDeclaire>(t)) {
			auto& lexeme = *module.get_attribute<doir::Lexeme>(t);
			auto res = *blockwise_find<lox::comp::VariableDeclaire>(module, {lexeme, current_block(module, t)}, hasVariables);
			if(res != t) {
				doir::print_diagnostic(module, res, (std::stringstream{} << "Variable " << lexeme.view(module.buffer) << " redeclaired!").str()) << "\n";
				doir::print_diagnostic(module, t, "Identified here...", doir::diagnostic_type::Info) << std::endl;
				valid = false;
			}
		}
	}
	return valid;
}

bool verify_call_arrities(doir::Module& module) {
	ZoneScoped;
	bool valid = true;
	for(doir::Token t = module.get_attribute<doir::Children>(1)->total + 2; t--;) {
		if(!module.has_attribute<lox::comp::Function>(t)) continue;

		auto& call = *module.get_attribute<lox::comp::Call>(t);
		auto& ref = *module.get_attribute<doir::TokenReference>(call.parent);
		if(!ref.looked_up()){
			doir::print_diagnostic(module, t, (std::stringstream{} << "Failed to find function: " << ref.lexeme().view(module.buffer) << " (" << t << ")").str()) << std::endl;
			valid = false;
		}
		auto& params = *module.get_attribute<lox::comp::Parameters>(ref.token());

		if(call.children.size() != params.size()) {
			doir::print_diagnostic(module, call.parent, (std::stringstream{} << "Call arity (" << call.children.size() << ") does not match declaration arity (" << params.size() << ")").str()) << std::endl;
			valid = false;
		}
	}
	return valid;
}

bool identify_trailing_calls(doir::Module& module) {
	ZoneScoped;
	for(doir::Token t = module.get_attribute<doir::Children>(1)->total + 2; t--;) {
		if(!module.has_attribute<lox::comp::Call>(t)) continue;

		auto b = current_block(module, t);
		if(b == 0) continue;
		auto& block = *module.get_attribute<lox::components::Block>(b);
		
		// Find the index of the call in its block
		auto root = t;
		auto i = block.children.begin();
		while((i = std::ranges::find(block.children, root)) == block.children.end() && root > 0) --root;
		if(root == 0) return false; // This represents some sort of invalid structure!

		// If its not last it can't be trailing...
		auto index = std::distance(block.children.begin(), i);
		if(index != block.children.size() - 1) continue;

		// If the call is top level in its block or is the immediate child of a return it is trailing
		if(t == root || module.has_attribute<lox::components::Return>(t - 1))
			module.add_attribute<lox::components::TrailingCall>(t);
	}
	return true;
}
// TODO: Detecting direct recursion at semantic analysis time should be possible!


// Ensures the parse tree is sorted and properly anotated
void canonicalize(doir::Module& module, doir::Token root, bool clear_references /*= true*/) {
	ZoneScoped;
	sort_parse_into_reverse_post_order_traversal(module, root);
	calculate_child_count(module);
	lookup_references(module, clear_references);
}

TEST_CASE("Lox::Sema::Redeclaration") {
	ZoneScopedN("Lox::Sema::Redeclaration");
	std::string error;
	CAPTURE_CONSOLE_BEGIN
		CAPTURE_ERROR_CONSOLE_BEGIN
			doir::ParseModule module("var x = 0; var x = nil;");
			auto root = lox::parse{}.start(module);
			REQUIRE(root != 0);
			canonicalize(module, root, false);
			REQUIRE(verify_references(module));
			REQUIRE(!verify_redeclarations(module));
			REQUIRE(verify_call_arrities(module));
			REQUIRE(identify_trailing_calls(module));
		CAPTURE_ERROR_CONSOLE_END
		error = capture.str();
	CAPTURE_CONSOLE_END
	CHECK(error == R"(An error has occured at <transient>:1:16-17
   var x = 0; var x = nil;
                  ^
Variable x redeclaired!
)");
	CHECK(capture.str() == R"(Info at <transient>:1:5-6
   var x = 0; var x = nil;
       ^
Identified here...
)");
	FrameMark;
}

TEST_CASE("Lox::Sema" * doctest::skip()) {
	doir::ParseModule module("fun add(a, b) { var tmp = a; a = b; b = tmp; return a + b; } var x = 0; var y = 1; if(true) print add(x, y); for(;;) print x;");
	auto root = lox::parse{}.start(module);
	REQUIRE(root != 0);
	canonicalize(module, root);
	CHECK(verify_references(module));
	CHECK(verify_redeclarations(module));
	CHECK(verify_call_arrities(module));
	CHECK(identify_trailing_calls(module));
	print(module, root, true);
}