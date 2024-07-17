#pragma once
#include "lox.parse.hpp"

namespace lox {
	enum class Type {
		Invalid = 0,
		Null,
		Variable,
		Number,
		String,
		Boolean,
		VariableDeclaire,
		FunctionDeclaire,
		ParameterDeclaire,
		BodyMarker,
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

	constexpr inline std::string_view to_string(Type t) {
		switch (t) {
		case Type::Invalid: return "<error>";
		case Type::Null: return "null";
		case Type::Variable: return "variable";
		case Type::Number: return "number";
		case Type::String: return "string";
		case Type::Boolean: return "boolean";
		case Type::VariableDeclaire: return "variable_declaire";
		case Type::FunctionDeclaire: return "function_declaire";
		case Type::ParameterDeclaire: return "parameter_declaire";
		case Type::BodyMarker: return "body_marker";
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

	inline Type token_type(doir::Module& module, doir::Token t) {
		if(module.has_attribute<lox::comp::Null>(t)) return Type::Null;
		else if(module.has_attribute<lox::comp::String>(t)) return Type::String;
		else if(module.has_attribute<bool>(t)) return Type::Boolean;
		else if(module.has_attribute<double>(t)) return Type::Number;
		else if(module.has_attribute<lox::comp::Variable>(t)) return Type::Variable;
		else if(module.has_attribute<lox::comp::Function>(t)) return Type::Call;
		else if(module.has_hashtable_attribute<lox::comp::VariableDeclaire>(t)) return Type::VariableDeclaire;
		else if(module.has_hashtable_attribute<lox::comp::FunctionDeclaire>(t)) return Type::FunctionDeclaire;
		else if(module.has_hashtable_attribute<lox::comp::ParameterDeclaire>(t)) return Type::ParameterDeclaire;
		else if(module.has_attribute<lox::comp::BodyMarker>(t)) return Type::BodyMarker;
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
}

void print(doir::Module& module, doir::Token root, bool show_token = false, size_t indent_size = 3, int64_t indent = 0);
void canonicalize(doir::Module& module, doir::Token root, bool clear_references = true);
bool verify_references(doir::Module& module);
bool verify_call_arrities(doir::Module& module);
bool identify_trailing_calls(doir::Module& module);