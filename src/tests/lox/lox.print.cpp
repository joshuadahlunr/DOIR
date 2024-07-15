#include "lox.hpp"
#include <string>

void print(doir::Module& module, doir::Token root, bool show_tokens /*=false*/, size_t indent_size /*= 3*/, int64_t indent /*= 0*/) {
	static constexpr auto reference2view = [](const doir::Module& module, const doir::TokenReference& ref) {
		if(ref.looked_up()) return module.get_attribute<doir::Lexeme>(ref.token())->view(module.buffer);
		else return ref.lexeme().view(module.buffer);
	};

	static constexpr std::string_view arrow =  "↳ ";
	using namespace lox::components;
	// ⇘
	std::cout << std::string(std::max<int64_t>(indent * indent_size - arrow.size(), 0), ' ');
	if(indent > 0) std::cout << arrow;

	auto end = [show_tokens](doir::Module& module, doir::Token t) -> std::string {
		if(show_tokens) {
			if(auto c = module.get_attribute<doir::Children>(t); c)
				return " (#↓" + std::to_string(c->total) + ", " + std::to_string(t) + ")\n";
			return " (" + std::to_string(t) + ")\n";
		}
		return "\n";
	};

	switch (auto t = lox::token_type(module, root); t) {
	break; case lox::Type::Variable: {
		auto& ref = *module.get_attribute<doir::TokenReference>(root);
		std::cout << "variable:" << reference2view(module, ref);
		if(ref.looked_up()) std::cout << " -> " << std::to_string(ref.token());
		std::cout << end(module, root);
	}
	break; case lox::Type::Null: std::cout << "literal:null" << end(module, root);
	break; case lox::Type::Number: std::cout << "literal:" << *module.get_attribute<double>(root) << end(module, root);
	break; case lox::Type::String: std::cout << "literal:\"" << module.get_attribute<doir::Lexeme>(root)->view(module.buffer) << '"' << end(module, root);
	break; case lox::Type::Boolean: std::cout << "literal:" << (*module.get_attribute<bool>(root) ? "true" : "false") << end(module, root);
	break; case lox::Type::Block: {
		std::cout << "{" << end(module, root);
		for(auto child: module.get_attribute<Block>(root)->children)
			print(module, child, show_tokens, indent_size, indent + 1);
		std::cout << std::string(std::max<int64_t>(indent * indent_size - arrow.size(), 0), ' ') << "}" << std::endl;
	}
	break; case lox::Type::Return: [[fallthrough]];
	case lox::Type::Print: [[fallthrough]];
	case lox::Type::Not: [[fallthrough]];
	case lox::Type::Negate: {
		std::cout << to_string(t) << end(module, root);
		if(module.has_attribute<Operation>(root))
			print(module, module.get_attribute<Operation>(root)->left, show_tokens, indent_size, indent + 1);
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
		std::cout << to_string(t) << end(module, root);
		print(module, module.get_attribute<Operation>(root)->left, show_tokens, indent_size, indent + 1);
		print(module, module.get_attribute<Operation>(root)->right, show_tokens, indent_size, indent + 1);
	}
	break; case lox::Type::VariableDeclaire: {
		std::cout << "declaire:var:" << module.get_attribute<doir::Lexeme>(root)->view(module.buffer) << end(module, root);
		if(auto op = module.get_attribute<Operation>(root); op)
			print(module, op->left, show_tokens, indent_size, indent + 1);
	}
	break; case lox::Type::FunctionDeclaire: {
		std::cout << "declaire:fun:" << module.get_attribute<doir::Lexeme>(root)->view(module.buffer) << end(module, root);
		for(auto param: *module.get_attribute<Parameters>(root))
			print(module, param, show_tokens, indent_size, indent + 1);
		if(auto op = module.get_attribute<Operation>(root); op)
			print(module, op->left, show_tokens, indent_size, indent + 1);
	}
	break; case lox::Type::ParameterDeclaire: {
		std::cout << "param:" << reference2view(module, root) << end(module, root);
	}
	break; case lox::Type::FunctionMarker: {
		auto& marker = *module.get_attribute<FunctionMarker>(root);
		std::cout << "marker:" << module.get_attribute<doir::Lexeme>(marker.function)->view(module.buffer) << " -> " << marker.function << end(module, root);
	}
	break; case lox::Type::Call: {
		auto& call = *module.get_attribute<Call>(root);
		// auto& ref = *module.get_attribute<doir::TokenReference>(call.parent);
		std::cout << "call" << end(module, root);
		print(module, call.parent, show_tokens, indent_size, indent + 1);
		for(auto& param: call.children)
			print(module, param, show_tokens, indent_size, indent + 1);
	}
	break; case lox::Type::Assign: {
		auto& ref = *module.get_attribute<doir::TokenReference>(root);
		std::cout << "assign:" << reference2view(module, ref);
		if(ref.looked_up()) std::cout << " -> " << std::to_string(ref.token());
		std::cout << end(module, root);
		print(module, module.get_attribute<Operation>(root)->left, show_tokens, indent_size, indent + 1);
	}
	break; case lox::Type::If: {
		std::vector<doir::Token> sub; sub.reserve(3);
		std::cout << "if" << end(module, root);
		bool hasElse = module.has_attribute<OperationIf>(root);
		if(hasElse) {
			auto& arr = *module.get_attribute<OperationIf>(root);
			sub = {arr.begin(), arr.end()};
		} else {
			auto& op = *module.get_attribute<Operation>(root);
			sub.push_back(op.left); sub.push_back(op.right);
		}
		for(auto& elem: sub)
			print(module, elem, show_tokens, indent_size, indent + 1);
	}
	break; default: std::cout << "<unknown node>" << end(module, root);
	}
}


TEST_CASE("Lox::Print" * doctest::skip()) {
	doir::ParseModule module("fun add(a, b) { var tmp = a; a = b; b = tmp; return a + b; } var x = 0; var y = 1; if(true) print add(x, y); for(;;) print x;");
	auto root = lox::parse{}.start(module);
	REQUIRE(root != 0);
	print(module, root);
}