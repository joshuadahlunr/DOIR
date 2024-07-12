#include "lox.hpp"
#include "lox.parse.hpp"
#include <stdexcept>
#include <string>

std::string get_token_string(doir::Module& module, doir::Token str) {
	return  module.has_attribute<std::string>(str) ? *module.get_attribute<std::string>(str) : std::string(module.get_attribute<doir::Lexeme>(str)->view(module.buffer));	
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
	return false;
}

bool interpret_print(doir::Module& module, doir::Token print) {
	auto& op = *module.get_attribute<lox::comp::Operation>(print);
	if(module.has_attribute<lox::comp::Null>(op.left)) {
		std::cout << "Nil" << std::endl;
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

// Remove any (non literal) values associated with the given range of tokens from the ECS
void clear_values(doir::Module& module, doir::Token start = 1, std::optional<doir::Token> _end = {}, bool make_monotonic = true) {
	doir::Token end = _end.value_or(start + module.get_attribute<doir::Children>(start)->total);
	for(doir::Token t = start; t < end; ++t) {
		if(module.has_attribute<lox::comp::Literal>(t)) continue;

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

	clear_values(module, root);

	for(doir::Token t = root + module.get_attribute<doir::Children>(root)->total; t-- > root; )
		switch(auto type = lox::token_type(module, t); type) {
		break; case lox::Type::Number: [[fallthrough]];
		case lox::Type::Null: [[fallthrough]];
		case lox::Type::String: [[fallthrough]];
		case lox::Type::Boolean: [[fallthrough]];
		case lox::Type::Block: // Do nothing!
		break; case lox::Type::Add: valid &= interpret_add(module, t);
		break; case lox::Type::Print: valid &= interpret_print(module, t);
		break; default: throw std::runtime_error((std::stringstream{} << "Operation " << lox::to_string(type) << " not supported yet!").str().c_str());
		}

	return valid;
}

TEST_CASE("Lox::Interp") {
	// doir::ParseModule module("fun add(a, b) { var tmp = a; a = b; b = tmp; return a + b; } var x = 0; var y = 1; if(true) print add(x, y); for(;;) print x;");
	doir::ParseModule module("print 5 + 6; print \"Hello \" + \"world\" + \"!\";");
	auto root = lox::parse{}.start(module);
	canonicalize(module, root, false);
	REQUIRE(verify_references(module));
	REQUIRE(verify_call_arrities(module));

	// print(module, root, true);
	interpret(module);
}