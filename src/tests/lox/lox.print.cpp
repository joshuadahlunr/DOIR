#include "lox.AST.hpp"
#include <string>

void print(doir::Module& module, doir::Token root, bool show_token /*=false*/, size_t indent_size /*= 3*/, int64_t indent /*= 0*/) {
	static constexpr auto reference2view = [](const doir::Module& module, const doir::TokenReference& ref) {
		if(ref.looked_up()) return module.get_attribute<doir::Lexeme>(ref.token())->view(module.buffer);
		else return ref.lexeme().view(module.buffer);
	};

	static constexpr std::string_view arrow =  "↳ ";
	using namespace lox::components;
	// ⇘
	std::cout << std::string(std::max<int64_t>(indent * indent_size - arrow.size(), 0), ' ');
	if(indent > 0) std::cout << arrow;

	auto end = [show_token](doir::Token t) -> std::string {
		if(show_token) return " (" + std::to_string(t) + ")\n";
		return "\n";
	};

	switch (auto t = lox::token_type(module, root); t) {
	break; case lox::Type::Variable: std::cout << "variable:" << module.get_attribute<doir::Lexeme>(root)->view(module.buffer) << end(root);
	break; case lox::Type::Null: std::cout << "literal:null" << std::endl;
	break; case lox::Type::Number: std::cout << "literal:" << *module.get_attribute<double>(root) << end(root);
	break; case lox::Type::String: std::cout << "literal:\"" << module.get_attribute<doir::Lexeme>(root)->view(module.buffer) << '"' << end(root);
	break; case lox::Type::Boolean: std::cout << "literal:" << (*module.get_attribute<bool>(root) ? "true" : "false") << end(root);
	break; case lox::Type::Block: {
		std::cout << "{" << end(root);
		for(auto child: module.get_attribute<Block>(root)->children)
			print(module, child, show_token, indent_size, indent + 1);
		std::cout << std::string(std::max<int64_t>(indent * indent_size - arrow.size(), 0), ' ') << "}" << std::endl;
	}
	break; case lox::Type::Return: [[fallthrough]];
	case lox::Type::Print: [[fallthrough]];
	case lox::Type::Not: [[fallthrough]];
	case lox::Type::Negate: {
		std::cout << to_string(t) << end(root);
		print(module, module.get_attribute<Operation>(root)->left, show_token, indent_size, indent + 1);
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
		std::cout << to_string(t) << end(root);
		print(module, module.get_attribute<Operation>(root)->left, show_token, indent_size, indent + 1);
		print(module, module.get_attribute<Operation>(root)->right, show_token, indent_size, indent + 1);
	}
	break; case lox::Type::VariableDeclaire: {
		std::cout << "declaire:var:" << module.get_attribute<doir::Lexeme>(root)->view(module.buffer) << end(root);
		if(auto op = module.get_attribute<Operation>(root); op)
			print(module, op->left, show_token, indent_size, indent + 1);
	}
	break; case lox::Type::FunctionDeclaire: {
		std::cout << "declaire:fun:" << module.get_attribute<doir::Lexeme>(root)->view(module.buffer) << end(root);
		for(auto param: *module.get_attribute<Parameters>(root))
			std::cout << std::string(std::max<int64_t>((indent + 1) * indent_size - arrow.size(), 0), ' ') << arrow
				<< "param:" << reference2view(module, param) << "\n";
		if(auto op = module.get_attribute<Operation>(root); op)
			print(module, op->left, show_token, indent_size, indent + 1);
	}
	break; case lox::Type::Call: {
		auto& call = *module.get_attribute<Call>(root);
		std::cout << "call:" << module.get_attribute<doir::Lexeme>(call.parent)->view(module.buffer) << end(root);
		for(auto& param: call.children)
			print(module, param, show_token, indent_size, indent + 1);
	}
	break; case lox::Type::Assign: {
		std::cout << "assign:" << reference2view(module, *module.get_attribute<doir::TokenReference>(root)) << end(root);
		print(module, module.get_attribute<Operation>(root)->left, show_token, indent_size, indent + 1);
	}
	break; case lox::Type::If: {
		std::vector<doir::Token> sub; sub.reserve(3);
		std::cout << "if" << end(root);
		bool hasElse = module.has_attribute<OperationIf>(root);
		if(hasElse) {
			auto& arr = *module.get_attribute<OperationIf>(root);
			sub = {arr.begin(), arr.end()};
		} else {
			auto& op = *module.get_attribute<Operation>(root);
			sub.push_back(op.left); sub.push_back(op.right);
		}
		for(auto& elem: sub)
			print(module, elem, show_token, indent_size, indent + 1);
	}
	break; default: std::cout << "<unknown node>" << end(root);
	}
}


TEST_CASE("Lox::Print") {
	doir::ParseModule module("fun add(a, b) { var tmp = a; a = b; b = tmp; return a + b; } var x = 0; var y = 1; if(true) print add(x, y); for(;;) print x;");
	auto root = lox::parse{}.start(module);
	if(module.has_attribute<doir::Error>(root))
		std::cerr << "!!ERROR!! " << module.get_attribute<doir::Error>(root)->message << std::endl;
	print(module, root);
}