#include "lox.parse.hpp"

enum class Type {
	Invalid = 0,
	Null,
	Variable,
	Number,
	String,
	Boolean,
	VariableDeclaire,
	FunctionDeclaire,
	Not,
	Negate,
	Divide,
	Multiply,
	Add,
	Subtract,
	LessThan,
	GreaterThan,
	LessThanEqualTo,
	GreaterThanEqualTo,
	EqualTo,
	NotEqualTo,
	And,
	Or,
	Call,
	Assign,
	Print,
	Return,
	While,
	If,
	Block
};

std::string_view to_string(Type t) {
	switch (t) {
	case Type::Invalid: return "<error>";
	case Type::Null: return "null";
	case Type::Variable: return "variable";
	case Type::Number: return "number";
	case Type::String: return "string";
	case Type::Boolean: return "boolean";
	case Type::VariableDeclaire: return "variable_declaire";
	case Type::FunctionDeclaire: return "function_declaire";
	case Type::Not: return "not";
	case Type::Negate: return "negate";
	case Type::Divide: return "divide";
	case Type::Multiply: return "multiply";
	case Type::Add: return "add";
	case Type::Subtract: return "subtract";
	case Type::LessThan: return "less_than";
	case Type::GreaterThan: return "greater_than";
	case Type::LessThanEqualTo: return "less_than_equal_to";
	case Type::GreaterThanEqualTo: return "greater_than_equal_to";
	case Type::EqualTo: return "equal_to";
	case Type::NotEqualTo: return "not_equal_to";
	case Type::And: return "and";
	case Type::Or: return "or";
	case Type::Call: return "call";
	case Type::Assign: return "assign";
	case Type::Print: return "print";
	case Type::Return: return "return";
	case Type::While: return "while";
	case Type::If: return "if";
	case Type::Block: return "block";
	}
	return "<error>"; // Shouldn't be nessicary?
}

Type token_type(doir::Module& module, doir::Token t) {
	if(module.has_attribute<lox::comp::Null>(t)) return Type::Null;
	else if(module.has_attribute<lox::comp::String>(t)) return Type::String;
	else if(module.has_attribute<bool>(t)) return Type::Boolean;
	else if(module.has_attribute<double>(t)) return Type::Number;
	else if(module.has_attribute<lox::comp::Variable>(t)) return Type::Variable;
	else if(module.has_attribute<lox::comp::Function>(t)) return Type::Call;
	else if(module.has_hashtable_attribute<lox::comp::VariableDeclaire>(t)) return Type::VariableDeclaire;
	else if(module.has_hashtable_attribute<lox::comp::FunctionDeclaire>(t)) return Type::FunctionDeclaire;
	else if(module.has_attribute<lox::comp::Not>(t)) return Type::Not;
	else if(module.has_attribute<lox::comp::Negate>(t)) return Type::Negate;
	else if(module.has_attribute<lox::comp::Divide>(t)) return Type::Divide;
	else if(module.has_attribute<lox::comp::Multiply>(t)) return Type::Multiply;
	else if(module.has_attribute<lox::comp::Add>(t)) return Type::Add;
	else if(module.has_attribute<lox::comp::Subtract>(t)) return Type::Subtract;
	else if(module.has_attribute<lox::comp::LessThan>(t)) return Type::LessThan;
	else if(module.has_attribute<lox::comp::GreaterThan>(t)) return Type::GreaterThan;
	else if(module.has_attribute<lox::comp::EqualTo>(t)) return Type::EqualTo;
	else if(module.has_attribute<lox::comp::NotEqualTo>(t)) return Type::NotEqualTo;
	else if(module.has_attribute<lox::comp::Add>(t)) return Type::And;
	else if(module.has_attribute<lox::comp::Or>(t)) return Type::Or;
	else if(module.has_attribute<lox::comp::Assign>(t)) return Type::Assign;
	else if(module.has_attribute<lox::comp::Print>(t)) return Type::Print;
	else if(module.has_attribute<lox::comp::Return>(t)) return Type::Return;
	else if(module.has_attribute<lox::comp::While>(t)) return Type::While;
	else if(module.has_attribute<lox::comp::If>(t)) return Type::If;
	else if(module.has_attribute<lox::comp::Block>(t)) return Type::Block; // This check needs to happen after other types which might have blocks
	else return Type::Invalid;
}

void print(doir::Module& module, doir::Token root, size_t indent_size = 3, int64_t indent = 0) {
	static constexpr auto reference2view = [](const doir::Module& module, const doir::TokenReference& ref) {
		if(ref.looked_up()) return module.get_attribute<doir::Lexeme>(ref.token())->view(module.buffer);
		else return ref.lexeme().view(module.buffer);
	};

	static constexpr std::string_view arrow =  "↳ ";
	using namespace lox::components;
	// ⇘
	std::cout << std::string(std::max<int64_t>(indent * indent_size - arrow.size(), 0), ' ');
	if(indent > 0) std::cout << arrow;

	switch (auto t = token_type(module, root); t) {
	break; case Type::Variable: std::cout << "variable:" << module.get_attribute<doir::Lexeme>(root)->view(module.buffer) << std::endl;
	break; case Type::Null: std::cout << "literal:null" << std::endl;
	break; case Type::Number: std::cout << "literal:" << *module.get_attribute<double>(root) << std::endl;
	break; case Type::String: std::cout << "literal:\"" << module.get_attribute<doir::Lexeme>(root)->view(module.buffer) << '"' << std::endl;
	break; case Type::Boolean: std::cout << "literal:" << (*module.get_attribute<bool>(root) ? "true" : "false") << std::endl;
	break; case Type::Block: {
		std::cout << "{" << "\n";
		for(auto child: module.get_attribute<Block>(root)->children)
			print(module, child, indent_size, indent + 1);
		std::cout << std::string(std::max<int64_t>(indent * indent_size - arrow.size(), 0), ' ') << "}" << std::endl;
	}
	break; case Type::Return: [[fallthrough]];
	case Type::Print: [[fallthrough]];
	case Type::Not: [[fallthrough]];
	case Type::Negate: {
		std::cout << to_string(t) << "\n";
		print(module, module.get_attribute<Operation>(root)->left, indent_size, indent + 1);
	}
	break; case Type::Divide: [[fallthrough]];
	case Type::Multiply: [[fallthrough]];
	case Type::Add: [[fallthrough]];
	case Type::Subtract: [[fallthrough]];
	case Type::LessThan: [[fallthrough]];
	case Type::GreaterThan: [[fallthrough]];
	case Type::LessThanEqualTo: [[fallthrough]];
	case Type::GreaterThanEqualTo: [[fallthrough]];
	case Type::EqualTo: [[fallthrough]];
	case Type::NotEqualTo: [[fallthrough]];
	case Type::And: [[fallthrough]];
	case Type::Or: [[fallthrough]];
	case Type::While: {
		std::cout << to_string(t) << "\n";
		print(module, module.get_attribute<Operation>(root)->left, indent_size, indent + 1);
		print(module, module.get_attribute<Operation>(root)->right, indent_size, indent + 1);
	}
	break; case Type::VariableDeclaire: {
		std::cout << "declaire:var:" << module.get_attribute<doir::Lexeme>(root)->view(module.buffer) << std::endl;
		if(auto op = module.get_attribute<Operation>(root); op)
			print(module, op->left, indent_size, indent + 1);
	}
	break; case Type::FunctionDeclaire: {
		std::cout << "declaire:fun:" << module.get_attribute<doir::Lexeme>(root)->view(module.buffer) << std::endl;
		for(auto param: *module.get_attribute<Parameters>(root))
			std::cout << std::string(std::max<int64_t>((indent + 1) * indent_size - arrow.size(), 0), ' ') << arrow
				<< "param:" << reference2view(module, param) << "\n";
		if(auto op = module.get_attribute<Operation>(root); op)
			print(module, op->left, indent_size, indent + 1);
	}
	break; case Type::Call: {
		auto& call = *module.get_attribute<Call>(root);
		std::cout << "call:" << module.get_attribute<doir::Lexeme>(call.parent)->view(module.buffer) << "\n";
		for(auto& param: call.children)
			print(module, param, indent_size, indent + 1);
	}
	break; case Type::Assign: {
		std::cout << "assign:" << reference2view(module, *module.get_attribute<doir::TokenReference>(root)) << "\n";
		print(module, module.get_attribute<Operation>(root)->left, indent_size, indent + 1);
	}
	break; case Type::If: {
		std::vector<doir::Token> sub; sub.reserve(3);
		std::cout << "if\n";
		bool hasElse = module.has_attribute<OperationIf>(root);
		if(hasElse) {
			auto& arr = *module.get_attribute<OperationIf>(root);
			sub = {arr.begin(), arr.end()};
		} else {
			auto& op = *module.get_attribute<Operation>(root);
			sub.push_back(op.left); sub.push_back(op.right);
		}
		for(auto& elem: sub)
			print(module, elem, indent_size, indent + 1);
	}
	break; default: std::cout << "<unknown node>" << std::endl;
	}
}


TEST_CASE("Lox::Print") {
	doir::ParseModule module("fun add(a, b) { var tmp = a; a = b; b = tmp; return a + b; } var x = 0; var y = 1; if(true) print add(x, y); for(;;) print x;");
	auto root = lox::parse{}.start(module);
	if(module.has_attribute<doir::Error>(root))
		std::cerr << "!!ERROR!! " << module.get_attribute<doir::Error>(root)->message << std::endl;
	print(module, root);
}