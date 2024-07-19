#include "lox.hpp"
#include <chrono>
#include <sstream>
#include <string>
#include <print>

struct runtime_value_type { lox::Type type = lox::Type::Null; };

lox::Type value_type(doir::Module& module, doir::Token t) {
	ZoneScoped;
	if(auto ref = module.get_attribute<runtime_value_type>(t); ref)
		return ref->type;
	else if(module.has_attribute<lox::comp::Null>(t))
		return lox::Type::Null;
	else if(module.has_attribute<double>(t))
		return lox::Type::Number;
	else if(module.has_attribute<bool>(t))
		return lox::Type::Boolean;
	else if(module.has_attribute<lox::comp::String>(t))
		return lox::Type::String;
	else return lox::Type::Invalid;
}

template<typename Tcomponent>
Tcomponent& get_or_add(doir::Module& module, doir::Token t) {
	if(auto ref = module.get_attribute<Tcomponent>(t); ref)
		return *ref;
	return module.add_attribute<Tcomponent>(t);
}

inline std::string get_token_string(doir::Module& module, doir::Token str) {
	ZoneScoped;
	return module.has_attribute<std::string>(str) ? *module.get_attribute<std::string>(str) : std::string(module.get_attribute<doir::Lexeme>(str)->view(module.buffer));
}

void dbg_print(doir::Module& module, doir::Token t) {
	switch (value_type(module, t)) {
	break; case lox::Type::Null:
#ifdef LOX_PERFORMANT_PRINTING
		std::println("nil");
#else
		nowide::cout << "nil" << std::endl;
#endif
	break; case lox::Type::Number:
#ifdef LOX_PERFORMANT_PRINTING
		std::println("{}", *module.get_attribute<double>(t));
#else
		nowide::cout << *module.get_attribute<double>(t) << std::endl;
#endif
	break; case lox::Type::Boolean:
#ifdef LOX_PERFORMANT_PRINTING
		std::println("{}", *module.get_attribute<bool>(t));
#else
		nowide::cout << (*module.get_attribute<bool>(t) ? "true" : "false") << std::endl;
#endif
	break; case lox::Type::String:
#ifdef LOX_PERFORMANT_PRINTING
		std::println("{}", get_token_string(module, t));
#else
		nowide::cout << get_token_string(module, t) << std::endl;
#endif
	break; default:
#ifdef LOX_PERFORMANT_PRINTING
		std::println("<no value>");
#else
		nowide::cout << "<no value>" << std::endl;
#endif
	}
}

void copy_runtime_value(doir::Module& module, doir::Token dest, doir::Token source) {
	ZoneScoped;
	switch (value_type(module, source)) {
	break; case lox::Type::Number:
		get_or_add<runtime_value_type>(module, dest).type = lox::Type::Number;
		get_or_add<double>(module, dest) = *module.get_attribute<double>(source);
	break; case lox::Type::Boolean:
		get_or_add<runtime_value_type>(module, dest).type = lox::Type::Boolean;
		get_or_add<bool>(module, dest) = *module.get_attribute<bool>(source);
	break; case lox::Type::String:
		get_or_add<runtime_value_type>(module, dest).type = lox::Type::String;
		get_or_add<lox::comp::String>(module, dest);
		get_or_add<std::string>(module, dest) = get_token_string(module, source);
	break; default:
		get_or_add<runtime_value_type>(module, dest).type = lox::Type::Null;
		get_or_add<lox::comp::Null>(module, dest);
	}
	// dbg_print(module, dest);
}

bool is_truthy(doir::Module& module, doir::Token t) {
	ZoneScoped;
	switch (value_type(module, t)) {
	break; case lox::Type::Null: return false;
	break; case lox::Type::Boolean: return *module.get_attribute<bool>(t);
	break; default: return true;
	}
	return false; // TODO: Why is this nessicary?
}

bool is_equal(doir::Module& module, doir::Token a, doir::Token b) {
	ZoneScoped;
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
	ZoneScoped;
	auto& op = *module.get_attribute<lox::comp::Operation>(add);
	if(module.has_attribute<double>(op.left) && module.has_attribute<double>(op.right)) {
		get_or_add<runtime_value_type>(module, add).type = lox::Type::Number;
		get_or_add<double>(module, add) = *module.get_attribute<double>(op.left) + *module.get_attribute<double>(op.right);
		return true;
	} else if(module.has_attribute<lox::comp::String>(op.left) && module.has_attribute<lox::comp::String>(op.right)) {
		get_or_add<runtime_value_type>(module, add).type = lox::Type::String;
		get_or_add<lox::comp::String>(module, add);
		get_or_add<std::string>(module, add) = get_token_string(module, op.left) + get_token_string(module, op.right);
		return true;
	}
	if(auto left = value_type(module, op.left), right = value_type(module, op.right); left != right)
		doir::print_diagnostic(module, add, (std::stringstream{} << "Operands have different types: " << lox::to_string(left) << " and " << lox::to_string(right)).str()) << std::endl;
	else doir::print_diagnostic(module, add, "Only strings and numbers can be added!") << std::endl;
	return false;
}

bool interpret_subtract(doir::Module& module, doir::Token sub) {
	ZoneScoped;
	auto& op = *module.get_attribute<lox::comp::Operation>(sub);
	if(module.has_attribute<double>(op.left) && module.has_attribute<double>(op.right)) {
		get_or_add<runtime_value_type>(module, sub).type = lox::Type::Number;
		get_or_add<double>(module, sub) = *module.get_attribute<double>(op.left) - *module.get_attribute<double>(op.right);
		return true;
	}
	if(auto left = value_type(module, op.left), right = value_type(module, op.right); left != right)
		doir::print_diagnostic(module, sub, (std::stringstream{} << "Operands have different types: " << lox::to_string(left) << " and " << lox::to_string(right)).str()) << std::endl;
	else doir::print_diagnostic(module, sub, "Only numbers can be subtracted!") << std::endl;
	return false;
}

bool interpret_multiply(doir::Module& module, doir::Token mult) {
	ZoneScoped;
	auto& op = *module.get_attribute<lox::comp::Operation>(mult);
	if(module.has_attribute<double>(op.left) && module.has_attribute<double>(op.right)) {
		get_or_add<runtime_value_type>(module, mult).type = lox::Type::Number;
		get_or_add<double>(module, mult) = *module.get_attribute<double>(op.left) * *module.get_attribute<double>(op.right);
		return true;
	}
	if(auto left = value_type(module, op.left), right = value_type(module, op.right); left != right)
		doir::print_diagnostic(module, mult, (std::stringstream{} << "Operands have different types: " << lox::to_string(left) << " and " << lox::to_string(right)).str()) << std::endl;
	else doir::print_diagnostic(module, mult, "Only numbers can be multiplied!") << std::endl;
	return false;
}

bool interpret_divide(doir::Module& module, doir::Token div) {
	ZoneScoped;
	auto& op = *module.get_attribute<lox::comp::Operation>(div);
	if(module.has_attribute<double>(op.left) && module.has_attribute<double>(op.right)) {
		get_or_add<runtime_value_type>(module, div).type = lox::Type::Number;
		get_or_add<double>(module, div) = *module.get_attribute<double>(op.left) / *module.get_attribute<double>(op.right);
		return true;
	}
	if(auto left = value_type(module, op.left), right = value_type(module, op.right); left != right)
		doir::print_diagnostic(module, div, (std::stringstream{} << "Operands have different types: " << lox::to_string(left) << " and " << lox::to_string(right)).str()) << std::endl;
	else doir::print_diagnostic(module, div, "Only numbers can be divided!") << std::endl;
	return false;
}

bool interpret_less(doir::Module& module, doir::Token less) {
	ZoneScoped;
	auto& op = *module.get_attribute<lox::comp::Operation>(less);
	if(module.has_attribute<double>(op.left) && module.has_attribute<double>(op.right)) {
		get_or_add<runtime_value_type>(module, less).type = lox::Type::Boolean;
		get_or_add<bool>(module, less) = *module.get_attribute<double>(op.left) < *module.get_attribute<double>(op.right);
		return true;
	}
	if(auto left = value_type(module, op.left), right = value_type(module, op.right); left != right)
		doir::print_diagnostic(module, less, (std::stringstream{} << "Operands have different types: " << lox::to_string(left) << " and " << lox::to_string(right)).str()) << std::endl;
	else doir::print_diagnostic(module, less, "Only numbers can be ordinally compared!") << std::endl;
	return false;
}

bool interpret_less_equal(doir::Module& module, doir::Token less) {
	ZoneScoped;
	auto& op = *module.get_attribute<lox::comp::Operation>(less);
	if(module.has_attribute<double>(op.left) && module.has_attribute<double>(op.right)) {
		get_or_add<runtime_value_type>(module, less).type = lox::Type::Boolean;
		get_or_add<bool>(module, less) = *module.get_attribute<double>(op.left) <= *module.get_attribute<double>(op.right);
		return true;
	}
	if(auto left = value_type(module, op.left), right = value_type(module, op.right); left != right)
		doir::print_diagnostic(module, less, (std::stringstream{} << "Operands have different types: " << lox::to_string(left) << " and " << lox::to_string(right)).str()) << std::endl;
	else doir::print_diagnostic(module, less, "Only numbers can be ordinally compared!") << std::endl;
	return false;
}

bool interpret_greater(doir::Module& module, doir::Token greater) {
	ZoneScoped;
	auto& op = *module.get_attribute<lox::comp::Operation>(greater);
	if(module.has_attribute<double>(op.left) && module.has_attribute<double>(op.right)) {
		get_or_add<runtime_value_type>(module, greater).type = lox::Type::Boolean;
		get_or_add<bool>(module, greater) = *module.get_attribute<double>(op.left) > *module.get_attribute<double>(op.right);
		return true;
	}
	if(auto left = value_type(module, op.left), right = value_type(module, op.right); left != right)
		doir::print_diagnostic(module, greater, (std::stringstream{} << "Operands have different types: " << lox::to_string(left) << " and " << lox::to_string(right)).str()) << std::endl;
	else doir::print_diagnostic(module, greater, "Only numbers can be ordinally compared!") << std::endl;
	return false;
}

bool interpret_greater_equal(doir::Module& module, doir::Token greater) {
	ZoneScoped;
	auto& op = *module.get_attribute<lox::comp::Operation>(greater);
	if(module.has_attribute<double>(op.left) && module.has_attribute<double>(op.right)) {
		get_or_add<runtime_value_type>(module, greater).type = lox::Type::Boolean;
		get_or_add<bool>(module, greater) = *module.get_attribute<double>(op.left) >= *module.get_attribute<double>(op.right);
		return true;
	}
	if(auto left = value_type(module, op.left), right = value_type(module, op.right); left != right)
		doir::print_diagnostic(module, greater, (std::stringstream{} << "Operands have different types: " << lox::to_string(left) << " and " << lox::to_string(right)).str()) << std::endl;
	else doir::print_diagnostic(module, greater, "Only numbers can be ordinally compared!") << std::endl;
	return false;
}

bool interpret_negate(doir::Module& module, doir::Token neg) {
	ZoneScoped;
	auto& op = *module.get_attribute<lox::comp::Operation>(neg);
	if(module.has_attribute<double>(op.left)) {
		get_or_add<runtime_value_type>(module, neg).type = lox::Type::Number;
		get_or_add<double>(module, neg) = -*module.get_attribute<double>(op.left);
		return true;
	}
	else doir::print_diagnostic(module, neg, "Only numbers can be negated!") << std::endl;
	return false;
}

bool interpret_not(doir::Module& module, doir::Token Not) {
	ZoneScoped;
	auto& op = *module.get_attribute<lox::comp::Operation>(Not);
	get_or_add<runtime_value_type>(module, Not).type = lox::Type::Boolean;
	get_or_add<bool>(module, Not) = !is_truthy(module, op.left);
	return true;
}

bool interpret_equal(doir::Module& module, doir::Token eq) {
	ZoneScoped;
	auto& op = *module.get_attribute<lox::comp::Operation>(eq);
	get_or_add<runtime_value_type>(module, eq).type = lox::Type::Boolean;
	get_or_add<bool>(module, eq) = is_equal(module, op.left, op.right);
	return true;
}

bool interpret_not_equal(doir::Module& module, doir::Token eq) {
	ZoneScoped;
	auto& op = *module.get_attribute<lox::comp::Operation>(eq);
	get_or_add<runtime_value_type>(module, eq).type = lox::Type::Boolean;
	get_or_add<bool>(module, eq) = !is_equal(module, op.left, op.right);
	return true;
}

bool interpret_print(doir::Module& module, doir::Token print) {
	ZoneScoped;
	auto& op = *module.get_attribute<lox::comp::Operation>(print);
	switch (value_type(module, op.left)) {
	break; case lox::Type::Null:
#ifdef LOX_PERFORMANT_PRINTING
		std::println("nil");
#else
		nowide::cout << "nil" << std::endl;
#endif
		return true;
	break; case lox::Type::Number:
#ifdef LOX_PERFORMANT_PRINTING
		std::println("{}", *module.get_attribute<double>(op.left));
#else
		nowide::cout << *module.get_attribute<double>(op.left) << std::endl;
#endif
		return true;
	break; case lox::Type::Boolean:
#ifdef LOX_PERFORMANT_PRINTING
		std::println("{}", *module.get_attribute<bool>(op.left));
#else
		nowide::cout << (*module.get_attribute<bool>(op.left) ? "true" : "false") << std::endl;
#endif
		return true;
	break; case lox::Type::String:
#ifdef LOX_PERFORMANT_PRINTING
		std::println("{}", get_token_string(module, op.left));
#else
		nowide::cout << get_token_string(module, op.left) << std::endl;
#endif
		return true;
	break; default:
		doir::print_diagnostic(module, print, "Attempted to print something with no value!");
		return false;
	}
}

bool interpret_builtin_clock(doir::Module& module, doir::Token call) {
	ZoneScoped;
	static auto first_called = std::chrono::steady_clock::now();
	std::chrono::duration<double> elapsed_seconds = std::chrono::steady_clock::now() - first_called;
	get_or_add<runtime_value_type>(module, call).type = lox::Type::Number;
	get_or_add<double>(module, call) = elapsed_seconds.count();
	return true;
}

// Inserts the result of a call to interpret with the current state (&= valid, |= should_return) 
std::pair<bool, bool> operator<<(std::pair<bool&, bool&> ref, std::pair<bool, bool> val) {
	ref.first &= val.first;
	ref.second |= val.second;
	return val;
}

std::pair<bool, bool> interpret(doir::Module& module, doir::Token root, doir::Token returnTo = 0, std::optional<doir::Token> _skipCheck = {}) {
	ZoneScoped;
	doir::Token skipCheck = _skipCheck.value_or(root); // Token we should check any blocks against to determine weather or not to skip them
	bool valid = true;
	bool should_return = false;

	for(doir::Token t = root + module.get_attribute<doir::Children>(root)->total + 1; t-- > root && valid && !should_return; )
		switch(auto type = lox::token_type(module, t); type) {
		break; case lox::Type::Number: [[fallthrough]];
		case lox::Type::Null: [[fallthrough]];
		case lox::Type::String: [[fallthrough]];
		case lox::Type::Boolean: [[fallthrough]];
		case lox::Type::ParameterDeclaire: [[fallthrough]];
		case lox::Type::FunctionDeclaire: [[fallthrough]];
		case lox::Type::Block: // Do nothing!
		break; case lox::Type::VariableDeclaire:
		if(module.has_attribute<lox::components::Operation>(t)) {
			auto& op = *module.get_attribute<lox::components::Operation>(t);
			copy_runtime_value(module, t, op.left);
		}
		break; case lox::Type::Variable: {
			auto& ref = *module.get_attribute<doir::TokenReference>(t);
			copy_runtime_value(module, t, ref.token());
		}
		break; case lox::Type::Assign: {
			auto& ref = *module.get_attribute<doir::TokenReference>(t);
			auto& op = *module.get_attribute<lox::components::Operation>(t);
			copy_runtime_value(module, ref.token(), op.left);
			copy_runtime_value(module, t, op.left);
		}
		break; case lox::Type::BodyMarker: {
			// Skip over any functions we aren't in!
			auto& marker = *module.get_attribute<lox::components::BodyMarker>(t);
			if(marker.skipTo != skipCheck)
				t = marker.skipTo + 1; // +1 so that when decrement during the next loop iteration we process the skipTo node
		}
		break; case lox::Type::Return: {
			if(returnTo == 0) {
				doir::print_diagnostic(module, t, "Can't return from outside a function!", doir::diagnostic_type::Warning) << std::endl;
				continue;
			}

			if(module.has_attribute<lox::comp::Operation>(t))
				copy_runtime_value(module, returnTo, module.get_attribute<lox::comp::Operation>(t)->left);
			else module.add_attribute<lox::comp::Null>(returnTo);
			return {valid, true};
		}
		break; case lox::Type::Call: {
			auto& call = *module.get_attribute<lox::comp::Call>(t);
			auto ref = module.get_attribute<doir::TokenReference>(call.parent)->token();
			if(ref == 2) { // The builtin function is processed specially
				valid &= interpret_builtin_clock(module, t);
				continue;
			}
			auto& params = *module.get_attribute<lox::comp::Parameters>(ref);
			auto& op = *module.get_attribute<lox::components::Operation>(ref);

			// Check for recursion
			if(op.right) {
				if(module.has_attribute<lox::comp::TrailingCall>(t))
					doir::print_diagnostic(module, t, "Tail recursion detected.", doir::diagnostic_type::Warning) << std::endl;
				else {
					auto& msg = doir::print_diagnostic(module, t, "(Non tail) recursion is not supported.");
					if(ref != root) msg << " This indirectly recursive call is invalid.";
					msg << std::endl;
					return {false, false};
				}
			}

			// Mark the call as started
			++op.right;

			// Copy the argument values to the parameters
			for(size_t i = 0; i < params.size(); ++i)
				copy_runtime_value(module, params[i], call.children[i]);
			valid &= interpret(module, ref, t).first; // NOTE: Doesn't touch should return!

			// Mark the call as finished
			--op.right;
		}
		break; case lox::Type::If: {
			auto& [a] = *module.get_attribute<lox::components::OperationIf>(t);
			auto& [condition, then, Else, marker] = a;

			std::tie(valid, should_return) << interpret(module, condition, returnTo);
			if(is_truthy(module, condition))
				std::tie(valid, should_return) << interpret(module, then, returnTo, t);
			else if(Else != 0)
				std::tie(valid, should_return) << interpret(module, Else, returnTo, t);
		}
		break; case lox::Type::While: {
			auto& op = *module.get_attribute<lox::components::Operation>(t);

			std::tie(valid, should_return) << interpret(module, op.left, returnTo);
			while(is_truthy(module, op.left)) {
				// Evaluate the body of the loop
				std::tie(valid, should_return) << interpret(module, op.right, returnTo, t);
				// Evaluate the condition for the next truthyness check
				std::tie(valid, should_return) << interpret(module, op.left, returnTo);
			}
		}
		break; case lox::Type::And: {
			auto [a] = *module.get_attribute<lox::components::OperationIf>(t);
			auto [left, right, marker, _] = a;

			std::tie(valid, should_return) << interpret(module, left, returnTo);
			if(is_truthy(module, left)) {
				std::tie(valid, should_return) << interpret(module, right, returnTo);
				auto dbg = module.add_attribute<bool>(t) = is_truthy(module, right);
			} else module.add_attribute<bool>(t) = false;
		}
		break; case lox::Type::Or: {
			auto [a] = *module.get_attribute<lox::components::OperationIf>(t);
			auto [left, right, marker, _] = a;

			std::tie(valid, should_return) << interpret(module, left, returnTo);
			if(!is_truthy(module, left)) {
				std::tie(valid, should_return) << interpret(module, right, returnTo);
				module.add_attribute<bool>(t) = is_truthy(module, right);
			} else module.add_attribute<bool>(t) = true;
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
		break; default: {}//throw std::runtime_error((std::stringstream{} << "Operation " << lox::to_string(type) << " not supported yet!").str().c_str());
		}

	// If this is a function call... mark that we returned null
	if(returnTo > 0) module.add_attribute<lox::comp::Null>(returnTo);
	return {valid, should_return};
}
bool interpret(doir::Module& module) {
	return interpret(module, 1).first;
}

TEST_CASE("Lox::Interp::And") {
	ZoneScopedN("Lox::Interp::And");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module("fun skipped() { print \"Nope!\"; return false; } print true and skipped(); print true or skipped();");
		auto root = lox::parse{}.start(module);
		REQUIRE(root != 0);
		canonicalize(module, root, false);
		REQUIRE(verify_references(module));
		REQUIRE(verify_redeclarations(module));
		REQUIRE(verify_call_arrities(module));
		REQUIRE(identify_trailing_calls(module));

		REQUIRE(interpret(module));
	CAPTURE_CONSOLE_END
#ifndef LOX_PERFORMANT_PRINTING
	CHECK(capture.str() == R"(Nope!
false
true
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Interp::TailRecursion") {
	ZoneScopedN("Lox::Interp::TailRecursion");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module("fun fib(x) { if(x < 2) return 1; return fib(x - 2); } fib(5);");
		auto root = lox::parse{}.start(module);
		REQUIRE(root != 0);
		canonicalize(module, root, false);
		REQUIRE(verify_references(module));
		REQUIRE(verify_redeclarations(module));
		REQUIRE(verify_call_arrities(module));
		REQUIRE(identify_trailing_calls(module));

		REQUIRE(interpret(module));
	CAPTURE_CONSOLE_END
	CHECK(capture.str() == R"(Warning at <transient>:1:44-45
   fun fib(x) { if(x < 2) return 1; return fib(x - 2); } fib(5);
                                              ^
                       Tail recursion detected.
Warning at <transient>:1:44-45
   fun fib(x) { if(x < 2) return 1; return fib(x - 2); } fib(5);
                                              ^
                       Tail recursion detected.
)");
	FrameMark;
}

TEST_CASE("Lox::Interp::Expressions") {
	ZoneScopedN("Lox::Interp::Expressions");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module("fun check(x) { print nil == x; } for(var i = 0; i < 5; i = i + 1) print (i + 1) * -6; print \"Hello \" + \"world\" + \"!\"; check(5); check(nil);");
		auto root = lox::parse{}.start(module);
		REQUIRE(root != 0);
		canonicalize(module, root, false);
		REQUIRE(verify_references(module));
		REQUIRE(verify_redeclarations(module));
		REQUIRE(verify_call_arrities(module));
		REQUIRE(identify_trailing_calls(module));

		REQUIRE(interpret(module));
	CAPTURE_CONSOLE_END
#ifndef LOX_PERFORMANT_PRINTING
	CHECK(capture.str() == R"(-6
-12
-18
-24
-30
Hello world!
false
true
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Interp" * doctest::skip()) {
// TEST_CASE("Lox::Interp") {
	ZoneScopedN("Lox::Interp");
	doir::ParseModule module("fun add(a, b) { var tmp = a; a = b; b = tmp; return a + b; } var x = 0; var y = 1; if(true) print add(x, y);" /*for(;;) print x;"*/);
	auto root = lox::parse{}.start(module);
	REQUIRE(root != 0);
	canonicalize(module, root, false);
	REQUIRE(verify_references(module));
	REQUIRE(verify_redeclarations(module));
	REQUIRE(verify_call_arrities(module));
	REQUIRE(identify_trailing_calls(module));

	print(module, root, true);
	REQUIRE(interpret(module));
	FrameMark;
}