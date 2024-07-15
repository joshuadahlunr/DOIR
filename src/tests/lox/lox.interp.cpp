#include "lox.hpp"
#include "lox.parse.hpp"
#include <sstream>
#include <stdexcept>
#include <string>

lox::Type value_type(doir::Module& module, doir::Token t) {
	if(module.has_attribute<lox::comp::Null>(t))
		return lox::Type::Null;
	else if(module.has_attribute<double>(t))
		return lox::Type::Number;
	else if(module.has_attribute<bool>(t))
		return lox::Type::Boolean;
	else if(module.has_attribute<lox::comp::String>(t))
		return lox::Type::String;
	else return lox::Type::Invalid;
}

inline std::string get_token_string(doir::Module& module, doir::Token str) {
	return module.has_attribute<std::string>(str) ? *module.get_attribute<std::string>(str) : std::string(module.get_attribute<doir::Lexeme>(str)->view(module.buffer));
}

void copy_runtime_value(doir::Module& module, doir::Token dest, doir::Token source) {
	switch (value_type(module, source)) {
	break; case lox::Type::Number: module.add_attribute<double>(dest) = *module.get_attribute<double>(source);
	break; case lox::Type::Boolean: module.add_attribute<bool>(dest) = *module.get_attribute<bool>(source);
	break; case lox::Type::String: 
		module.add_attribute<lox::comp::String>(dest);
		module.add_attribute<std::string>(dest) = get_token_string(module, source);
	break; default: module.add_attribute<lox::comp::Null>(dest);
	}
}

bool is_truthy(doir::Module& module, doir::Token t) {
	switch (value_type(module, t)) {
	break; case lox::Type::Null: return false;
	break; case lox::Type::Boolean: return *module.get_attribute<bool>(t);
	break; default: return true;
	}
}

bool is_equal(doir::Module& module, doir::Token a, doir::Token b) {
	auto aV = value_type(module, a);
	auto bV = value_type(module, b);
	if(aV == lox::Type::Null && bV == lox::Type::Null) return true;
	if(aV == lox::Type::Null) return false;
	if(bV == lox::Type::Null) return false;

	if(aV != bV) return false;
	switch (aV) {
		case lox::Type::Boolean: return *module.get_attribute<bool>(a) == *module.get_attribute<bool>(b);
		case lox::Type::Number: return *module.get_attribute<double>(a) == *module.get_attribute<double>(b);
		case lox::Type::String: return get_token_string(module, a) == get_token_string(module, b);
		default: return false;
	}
}



bool interpret_add(doir::Module& module, doir::Token add) {
	auto& op = *module.get_attribute<lox::comp::Operation>(add);
	if(module.has_attribute<double>(op.left) && module.has_attribute<double>(op.right)) {
		module.add_attribute<double>(add) = *module.get_attribute<double>(op.left) + *module.get_attribute<double>(op.right);
		return true;
	} else if(module.has_attribute<lox::comp::String>(op.left) && module.has_attribute<lox::comp::String>(op.right)) {
		module.add_attribute<lox::comp::String>(add);
		module.add_attribute<std::string>(add) = get_token_string(module, op.left) + get_token_string(module, op.right);
		return true;
	}
	if(auto left = value_type(module, op.left), right = value_type(module, op.right); left != right)
		doir::print_diagnostic(module, add, (std::stringstream{} << "Operands have different types: " << lox::to_string(left) << " and " << lox::to_string(right)).str()) << std::endl;
	else doir::print_diagnostic(module, add, "Only strings and numbers can be added!") << std::endl;
	return false;
}

bool interpret_subtract(doir::Module& module, doir::Token sub) {
	auto& op = *module.get_attribute<lox::comp::Operation>(sub);
	if(module.has_attribute<double>(op.left) && module.has_attribute<double>(op.right)) {
		module.add_attribute<double>(sub) = *module.get_attribute<double>(op.left) - *module.get_attribute<double>(op.right);
		return true;
	}
	if(auto left = value_type(module, op.left), right = value_type(module, op.right); left != right)
		doir::print_diagnostic(module, sub, (std::stringstream{} << "Operands have different types: " << lox::to_string(left) << " and " << lox::to_string(right)).str()) << std::endl;
	else doir::print_diagnostic(module, sub, "Only numbers can be subtracted!") << std::endl;
	return false;
}

bool interpret_multiply(doir::Module& module, doir::Token mult) {
	auto& op = *module.get_attribute<lox::comp::Operation>(mult);
	if(module.has_attribute<double>(op.left) && module.has_attribute<double>(op.right)) {
		module.add_attribute<double>(mult) = *module.get_attribute<double>(op.left) * *module.get_attribute<double>(op.right);
		return true;
	}
	if(auto left = value_type(module, op.left), right = value_type(module, op.right); left != right)
		doir::print_diagnostic(module, mult, (std::stringstream{} << "Operands have different types: " << lox::to_string(left) << " and " << lox::to_string(right)).str()) << std::endl;
	else doir::print_diagnostic(module, mult, "Only numbers can be multiplied!") << std::endl;
	return false;
}

bool interpret_divide(doir::Module& module, doir::Token div) {
	auto& op = *module.get_attribute<lox::comp::Operation>(div);
	if(module.has_attribute<double>(op.left) && module.has_attribute<double>(op.right)) {
		module.add_attribute<double>(div) = *module.get_attribute<double>(op.left) / *module.get_attribute<double>(op.right);
		return true;
	}
	if(auto left = value_type(module, op.left), right = value_type(module, op.right); left != right)
		doir::print_diagnostic(module, div, (std::stringstream{} << "Operands have different types: " << lox::to_string(left) << " and " << lox::to_string(right)).str()) << std::endl;
	else doir::print_diagnostic(module, div, "Only numbers can be divided!") << std::endl;
	return false;
}

bool interpret_less(doir::Module& module, doir::Token less) {
	auto& op = *module.get_attribute<lox::comp::Operation>(less);
	if(module.has_attribute<double>(op.left) && module.has_attribute<double>(op.right)) {
		module.add_attribute<double>(less) = *module.get_attribute<double>(op.left) < *module.get_attribute<double>(op.right);
		return true;
	}
	if(auto left = value_type(module, op.left), right = value_type(module, op.right); left != right)
		doir::print_diagnostic(module, less, (std::stringstream{} << "Operands have different types: " << lox::to_string(left) << " and " << lox::to_string(right)).str()) << std::endl;
	else doir::print_diagnostic(module, less, "Only numbers can be ordinally compared!") << std::endl;
	return false;
}

bool interpret_less_equal(doir::Module& module, doir::Token less) {
	auto& op = *module.get_attribute<lox::comp::Operation>(less);
	if(module.has_attribute<double>(op.left) && module.has_attribute<double>(op.right)) {
		module.add_attribute<bool>(less) = *module.get_attribute<double>(op.left) <= *module.get_attribute<double>(op.right);
		return true;
	}
	if(auto left = value_type(module, op.left), right = value_type(module, op.right); left != right)
		doir::print_diagnostic(module, less, (std::stringstream{} << "Operands have different types: " << lox::to_string(left) << " and " << lox::to_string(right)).str()) << std::endl;
	else doir::print_diagnostic(module, less, "Only numbers can be ordinally compared!") << std::endl;
	return false;
}

bool interpret_greater(doir::Module& module, doir::Token greater) {
	auto& op = *module.get_attribute<lox::comp::Operation>(greater);
	if(module.has_attribute<double>(op.left) && module.has_attribute<double>(op.right)) {
		module.add_attribute<bool>(greater) = *module.get_attribute<double>(op.left) > *module.get_attribute<double>(op.right);
		return true;
	}
	if(auto left = value_type(module, op.left), right = value_type(module, op.right); left != right)
		doir::print_diagnostic(module, greater, (std::stringstream{} << "Operands have different types: " << lox::to_string(left) << " and " << lox::to_string(right)).str()) << std::endl;
	else doir::print_diagnostic(module, greater, "Only numbers can be ordinally compared!") << std::endl;
	return false;
}

bool interpret_greater_equal(doir::Module& module, doir::Token greater) {
	auto& op = *module.get_attribute<lox::comp::Operation>(greater);
	if(module.has_attribute<double>(op.left) && module.has_attribute<double>(op.right)) {
		module.add_attribute<bool>(greater) = *module.get_attribute<double>(op.left) >= *module.get_attribute<double>(op.right);
		return true;
	}
	if(auto left = value_type(module, op.left), right = value_type(module, op.right); left != right)
		doir::print_diagnostic(module, greater, (std::stringstream{} << "Operands have different types: " << lox::to_string(left) << " and " << lox::to_string(right)).str()) << std::endl;
	else doir::print_diagnostic(module, greater, "Only numbers can be ordinally compared!") << std::endl;
	return false;
}

bool interpret_negate(doir::Module& module, doir::Token neg) {
	auto& op = *module.get_attribute<lox::comp::Operation>(neg);
	if(module.has_attribute<double>(op.left)) {
		module.add_attribute<double>(neg) = -*module.get_attribute<double>(op.left);
		return true;
	}
	else doir::print_diagnostic(module, neg, "Only numbers can be negated!") << std::endl;
	return false;
}

bool interpret_not(doir::Module& module, doir::Token Not) {
	auto& op = *module.get_attribute<lox::comp::Operation>(Not);
	module.add_attribute<bool>(Not) = !is_truthy(module, op.left);
	return true;
}

bool interpret_equal(doir::Module& module, doir::Token eq) {
	auto& op = *module.get_attribute<lox::comp::Operation>(eq);
	module.add_attribute<bool>(eq) = is_equal(module, op.left, op.right);
	return true;
}

bool interpret_not_equal(doir::Module& module, doir::Token eq) {
	auto& op = *module.get_attribute<lox::comp::Operation>(eq);
	module.add_attribute<bool>(eq) = !is_equal(module, op.left, op.right);
	return true;
}

bool interpret_print(doir::Module& module, doir::Token print) {
	auto& op = *module.get_attribute<lox::comp::Operation>(print);
	if(module.has_attribute<lox::comp::Null>(op.left)) {
		std::cout << "nil" << std::endl;
		return true;
	} else if(module.has_attribute<double>(op.left)) {
		std::cout << *module.get_attribute<double>(op.left) << std::endl;
		return true;
	} else if(module.has_attribute<bool>(op.left)) {
		std::cout << (*module.get_attribute<bool>(op.left) ? "true" : "false") << std::endl;
		return true;
	} else if(module.has_attribute<lox::comp::String>(op.left)) {
		std::cout << get_token_string(module, op.left) << std::endl;
		return true;
	}
	return false;
}

void clear_runtime_value(doir::Module& module, doir::Token t) {
	if(module.has_attribute<lox::comp::Null>(t))
		module.remove_attribute<lox::comp::Null>(t);
	if(module.has_attribute<lox::comp::String>(t))
		module.remove_attribute<lox::comp::String>(t);
	if(module.has_attribute<std::string>(t))
		module.remove_attribute<std::string>(t);
	if(module.has_attribute<double>(t))
		module.remove_attribute<double>(t);
	if(module.has_attribute<bool>(t))
		module.remove_attribute<bool>(t);
}

// Remove any (non literal) values associated with the given range of tokens from the ECS
void clear_runtime_values(doir::Module& module, doir::Token start = 1, std::optional<doir::Token> _end = {}, bool make_monotonic = true) {
	doir::Token end = _end.value_or(start + module.get_attribute<doir::Children>(start)->total);
	for(doir::Token t = start; t < end; ++t) {
		if(module.has_attribute<lox::comp::Literal>(t)) continue;
		if(module.has_hashtable_attribute<lox::comp::ParameterDeclaire>(t)) continue;

		clear_runtime_value(module, t);
	}

	if(make_monotonic) module.make_monotonic<
		lox::comp::Null,
		lox::comp::String,
		std::string,
		double,
		bool
	>();
}

bool interpret(doir::Module& module, doir::Token root = 1, doir::Token returnTo = 0) {
	bool valid = true;

	clear_runtime_values(module, root);

	for(doir::Token t = root + module.get_attribute<doir::Children>(root)->total + 1; t-- > root && valid; )
		switch(auto type = lox::token_type(module, t); type) {
		break; case lox::Type::Number: [[fallthrough]];
		case lox::Type::Null: [[fallthrough]];
		case lox::Type::String: [[fallthrough]];
		case lox::Type::Boolean: [[fallthrough]];
		case lox::Type::ParameterDeclaire: [[fallthrough]];
		case lox::Type::FunctionDeclaire: [[fallthrough]];
		case lox::Type::VariableDeclaire: [[fallthrough]];
		case lox::Type::Block: // Do nothing!
		break; case lox::Type::Variable: {
			auto& ref = *module.get_attribute<doir::TokenReference>(t);
			copy_runtime_value(module, t, ref.token());
		}
		break; case lox::Type::FunctionMarker: {
			// Skip over any functions we aren't in!
			auto& marker = *module.get_attribute<lox::components::FunctionMarker>(t);
			if(marker.function != root)
				t = marker.function;
		}
		break; case lox::Type::Return: {
			if(returnTo == 0) {
				doir::print_diagnostic(module, t, "Can't return from outside a function!", doir::diagnostic_type::Warning) << std::endl;
				continue;
			}

			if(module.has_attribute<lox::comp::Operation>(t))
				copy_runtime_value(module, returnTo, module.get_attribute<lox::comp::Operation>(t)->left);
			else module.add_attribute<lox::comp::Null>(returnTo);
			return valid;
		}
		break; case lox::Type::Call: {
			auto& call = *module.get_attribute<lox::comp::Call>(t);
			auto ref = module.get_attribute<doir::TokenReference>(call.parent)->token();
			auto& params = *module.get_attribute<lox::comp::Parameters>(ref);

			// Copy the argument values to the parameters
			for(size_t i = 0; i < params.size(); ++i) {
				clear_runtime_value(module, params[i]);
				copy_runtime_value(module, params[i], call.children[i]);
			}
			valid &= interpret(module, ref, t);
		}
		break; case lox::Type::Add: valid &= interpret_add(module, t);
		break; case lox::Type::Subtract: valid &= interpret_subtract(module, t);
		break; case lox::Type::Multiply: valid &= interpret_multiply(module, t);
		break; case lox::Type::Divide: valid &= interpret_divide(module, t);
		break; case lox::Type::LessThan: valid &= interpret_less(module, t);
		break; case lox::Type::LessThanEqualTo: valid &= interpret_less_equal(module, t);
		break; case lox::Type::GreaterThan: valid &= interpret_greater(module, t);
		break; case lox::Type::GreaterThanEqualTo: valid &= interpret_greater_equal(module, t);
		break; case lox::Type::Negate: valid &= interpret_negate(module, t);
		break; case lox::Type::Not: valid &= interpret_not(module, t);
		break; case lox::Type::EqualTo: valid &= interpret_equal(module, t);
		break; case lox::Type::NotEqualTo: valid &= interpret_not_equal(module, t);
		break; case lox::Type::Print: valid &= interpret_print(module, t);
		break; default: throw std::runtime_error((std::stringstream{} << "Operation " << lox::to_string(type) << " not supported yet!").str().c_str());
		}

	// If this is a function call... mark that we returned null
	if(returnTo > 0) module.add_attribute<lox::comp::Null>(returnTo);
	return valid;
}

TEST_CASE("Lox::Interp") {
	// doir::ParseModule module("fun add(a, b) { var tmp = a; a = b; b = tmp; return a + b; } var x = 0; var y = 1; if(true) print add(x, y); for(;;) print x;");
	doir::ParseModule module("fun check(x) { print nil == x; } print 5 * -6; print \"Hello \" + \"world\" + \"!\"; check(5); check(nil);");
	auto root = lox::parse{}.start(module);
	REQUIRE(root != 0);
	canonicalize(module, root, false);
	REQUIRE(verify_references(module));
	REQUIRE(verify_call_arrities(module));

	print(module, root, true);
	REQUIRE(interpret(module));
}