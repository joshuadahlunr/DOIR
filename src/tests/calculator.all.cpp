#define LEXER_CTRE_REGEX
// #define LEXER_IS_STATEFULL
#include "../lexer.hpp"
#include "../core.hpp"
#include "../parse_state.hpp"
#include "../unicode_identifier_head.hpp"

#include <doctest/doctest.h>
#include <tracy/Tracy.hpp>

namespace calculator {

	enum LexerTokens {
		// Whitespace,
		Newline,
		Plus,
		Minus,
		Mult,
		Divide,
		Equals,
		Open,
		Close,
		Identifier,
		Literal,
	};

	constexpr doir::lex::lexer<
		doir::lex::heads::token<LexerTokens::Plus, doir::lex::heads::exact_character<'+'>>,
		doir::lex::heads::token<LexerTokens::Minus, doir::lex::heads::exact_character<'-'>>,
		doir::lex::heads::token<LexerTokens::Mult, doir::lex::heads::exact_character<'*'>>,
		doir::lex::heads::token<LexerTokens::Divide, doir::lex::heads::exact_character<'/'>>,
		doir::lex::heads::token<LexerTokens::Equals, doir::lex::heads::exact_character<'='>>,
		doir::lex::heads::token<LexerTokens::Open, doir::lex::heads::exact_character<'('>>,
		doir::lex::heads::token<LexerTokens::Close, doir::lex::heads::exact_character<')'>>,
		// doir::lex::heads::token<Tokens::Identifier, doir::lex::heads::ctre_regex<"[_a-zA-z][_a-zA-z0-9]*">>,
		doir::lex::heads::token<LexerTokens::Literal, doir::lex::heads::ctre_regex<R"_((\+|-)?(\d+(\.\d*)?|\.\d+)([eE](\+|-)?\d+)?)_">>,
		doir::lex::heads::skip<doir::lex::heads::whitespace>, // Skip whitespace!
		doir::lex::heads::token<LexerTokens::Identifier, XIDIdentifierHead<false>>
	> lexer;

	constexpr doir::lex::lexer<
		doir::lex::heads::token<LexerTokens::Newline, doir::lex::heads::exact_character<'\n'>>,
		doir::lex::heads::token<LexerTokens::Plus, doir::lex::heads::exact_character<'+'>>,
		doir::lex::heads::token<LexerTokens::Minus, doir::lex::heads::exact_character<'-'>>,
		doir::lex::heads::token<LexerTokens::Mult, doir::lex::heads::exact_character<'*'>>,
		doir::lex::heads::token<LexerTokens::Divide, doir::lex::heads::exact_character<'/'>>,
		doir::lex::heads::token<LexerTokens::Equals, doir::lex::heads::exact_character<'='>>,
		doir::lex::heads::token<LexerTokens::Open, doir::lex::heads::exact_character<'('>>,
		doir::lex::heads::token<LexerTokens::Close, doir::lex::heads::exact_character<')'>>,
		// doir::lex::heads::token<Tokens::Identifier, doir::lex::heads::ctre_regex<"[_a-zA-z][_a-zA-z0-9]*">>,
		doir::lex::heads::token<LexerTokens::Literal, doir::lex::heads::ctre_regex<R"_((\+|-)?(\d+(\.\d*)?|\.\d+)([eE](\+|-)?\d+)?)_">>,
		doir::lex::heads::skip<doir::lex::heads::single_whitespace>, // Skip whitespace (one at a time, excluding newlines)!
		doir::lex::heads::token<LexerTokens::Identifier, XIDIdentifierHead<false>>
	> lexerNewline;


	// start ::= expressions
	// expressions ::= assignment_expression | assignment_expression "\n" expressions;
	// assignment_expression ::= identifier "=" assignment_expression | add_expression;
	// add_expression ::= mult_expression add_expression';
	// add_expression' ::= "+" mult_expression add_expression' | "-" mult_expression add_expression' | eps;
	// mult_expression ::= primary_expression mult_expression';
	// mult_expression' ::= "*" primary_expression mult_expression' | "/" primary_expression mult_expression' | eps;
	// primary_expression ::= identifier | literal | (assignment_expression);
	struct parse {
		struct Variable {};

		void print_result(doir::ParseModule& module, doir::Token t) {
			ZoneScoped;
			static size_t i = 0;
			std::cout << i++ << ": ";
			if(module.has_attribute<doir::Error>(t))
				std::cerr << "!!ERROR!! " << module.get_attribute<doir::Error>(t)->message << std::endl;
			else std::cout << *module.get_attribute<float>(t) << std::endl;
		}

		doir::Token lookup_variable(doir::ParseModule& module, std::string_view target) {
			ZoneScoped;
			auto query = doir::query_with_token<Variable, float, doir::Lexeme>(module);
			auto res = std::ranges::find_if(query, [&module, target](const auto& tuple){
				// auto [_0, _1, _2, name] = tuple;
				return std::get<3>(tuple).view(module.buffer) == target;
			});
			return res == std::ranges::end(query) ? 0 : std::get<doir::Token>(*res);
		}

		// start ::= expressions
		bool start(doir::ParseModule& module) {
			ZoneScoped;
			if(module.lexer_state.lexeme.empty()) module.lex(lexer);
			return !module.has_attribute<doir::Error>(expressions(module));
		}

		// expressions ::= assignment_expression | assignment_expression "\n" expressions;
		doir::Token expressions(doir::ParseModule& module) {
			ZoneScoped;
			if(!module.lexer_state.valid()) return module.make_error();
			auto t = assignment_expression(module);
			print_result(module, t);

			if(module.lex(lexerNewline).lexer_state.token<LexerTokens>() == Newline){
				module.lex(lexer);
				return expressions(module);
			}

			return t;
		}

		// assignment_expression ::= identifier "=" assignment_expression | add_expression;
		doir::Token assignment_expression(doir::ParseModule& module) {
			ZoneScoped;
			if(!module.lexer_state.valid()) return module.make_error();

			if(module.current_lexer_token<LexerTokens>() == Identifier){
				if(module.current_lexer_token<LexerTokens>(module.lookahead(lexer)) == Equals) {
					// Find the attribute storing the identifier value (or make it if it doesn't exist!)
					doir::Token ident = lookup_variable(module, module.lexer_state.lexeme);
					if(ident == 0) {
						ident = module.make_token();
						module.add_attribute<Variable>(ident);
						module.add_attribute<float>(ident);
					}

					module.lex(lexer);
					if(auto error = module.expect_and_lex(lexer, Equals, "Expected `=`!")) return *error;
					auto expr = assignment_expression(module);
					if(expr == 0) return expr;
					auto value = *module.get_attribute<float>(expr);
					*module.get_attribute<float>(ident) = value;
					return ident;
				}
			}
			return add_expression(module);
		}

		// add_expression ::= mult_expression add_expression';
		// add_expression' ::= "+" mult_expression add_expression' | "-" mult_expression add_expression' | eps;
		doir::Token add_expression_prime(doir::ParseModule& module) {
			ZoneScoped;
			if (auto t = module.current_lexer_token<LexerTokens>(); t == Plus || t == Minus) {
				module.lex(lexer);
				doir::Token value = mult_expression(module);
				if(module.has_attribute<doir::Error>(value)) return value;
				if(t == Minus) *module.get_attribute<float>(value) = -(*module.get_attribute<float>(value));

				// data.lex(lexer);
				doir::Token prime = add_expression_prime(module);
				if(prime == 0) return value;
				if(module.has_attribute<doir::Error>(prime)) return prime;

				*module.get_attribute<float>(prime) += *module.get_attribute<float>(value);
				return prime;
			}
			return 0;
		}
		doir::Token add_expression(doir::ParseModule& module) {
			ZoneScoped;
			doir::Token value = mult_expression(module);
			if(module.has_attribute<doir::Error>(value)) return value;

			// data.lex(lexer); Don't need to get the next token here, mult_expression does it in this same spot!
			doir::Token prime = add_expression_prime(module);
			if(prime == 0) return value;
			if(module.has_attribute<doir::Error>(prime)) return prime;

			*module.get_attribute<float>(prime) += *module.get_attribute<float>(value);
			return prime;
		}

		// mult_expression ::= primary_expression mult_expression';
		// mult_expression' ::= "*" primary_expression mult_expression' | "/" primary_expression mult_expression' | eps;
		doir::Token mult_expression_prime(doir::ParseModule& module) {
			ZoneScoped;
			if (auto t = module.current_lexer_token<LexerTokens>(); t == Mult || t == Divide) {
				module.lex(lexer);
				doir::Token value = primary_expression(module);
				if(module.has_attribute<doir::Error>(value)) return value;
				if (t == Divide) *module.get_attribute<float>(value) = 1 / (*module.get_attribute<float>(value));

				module.lex(lexer);
				doir::Token prime = mult_expression_prime(module);
				if(prime == 0) return value;
				if(module.has_attribute<doir::Error>(prime)) return prime;

				*module.get_attribute<float>(prime) *= *module.get_attribute<float>(value);
				return prime;
			}
			return 0;
		}
		doir::Token mult_expression(doir::ParseModule& module) {
			ZoneScoped;
			doir::Token value = primary_expression(module);
			if(module.has_attribute<doir::Error>(value)) return value;

			module.lex(lexer);
			doir::Token prime = mult_expression_prime(module);
			if(prime == 0) return value;
			if(module.has_attribute<doir::Error>(prime)) return prime;

			*module.get_attribute<float>(prime) *= *module.get_attribute<float>(value);
			return prime;
		}

		// primary_expression ::= identifier | literal | "(" assignment_expression ")";
		doir::Token primary_expression(doir::ParseModule& module) {
			ZoneScoped;
			if(!module.lexer_state.valid()) return module.make_error();

			switch(module.lexer_state.token<LexerTokens>()){
			break; case Identifier: {
				doir::Token ident = lookup_variable(module, module.lexer_state.lexeme);
				if(ident == 0) return module.make_error<doir::Error>({"Identifier not found!"});
				doir::Token t = module.make_token();
				module.add_attribute<float>(t) = *module.get_attribute<float>(ident);
				return t;
			}
			break; case Literal: {
				doir::Token t = module.make_token();
				module.add_attribute<float>(t) = std::strtold(module.get_attribute<doir::Lexeme>(t)->view(module.buffer).data(), nullptr);
				return t;
			}
			break; case Open: {
				module.lex(lexer);
				doir::Token expr = assignment_expression(module);
				if(module.has_attribute<doir::Error>(expr)) return expr;
				if(module.lexer_state.token<LexerTokens>() != Close)
					return module.make_error<doir::Error>({"Expected `)`!"});
				return expr;
			}
			break; default: return module.make_error<doir::Error>({"Unexpected token!"});
			}
			return 0; // TODO: Why does the the default return in the switch count as all paths returning?
		}
	};

}

// NOTE: Need to provide backing memory for any runtime strings that are used!
template<> std::string_view doir::lex::heads::runtime_string<0, true>::match = {};

TEST_CASE("runtime_strings") {
	doir::lex::lexer<doir::lex::heads::ctre_regex<"a+b*">> lexFirst;
	doir::lex::lexer<doir::lex::heads::runtime_string<0, true>> lexRest;
	std::string threeInARow = "aaaabbaaaabbaaaabb"; // Works!
	// std::string threeInARow = "aaaabbaaaabbaaabb"; // Fails!
	doir::lex::lexer_generic_result res = lexFirst.lex(threeInARow);
	CHECK(res.valid());
	doir::lex::heads::runtime_string<0, true>::set(res.lexeme);
	res = lexRest.lex(res);
	CHECK(res.valid());
	res = lexRest.lex(res);
	CHECK(res.valid());
	FrameMark;
}

TEST_CASE("Calculator::Parse") {
	doir::ParseModule module("pi = 3.14159265358979323846\n");
	calculator::parse p;
	p.start(module);
	CHECK(doir::float_equal<float>(*module.get_attribute<float>(1), 3.14159265358979323846) == true);
	FrameMark;
}

TEST_CASE("Calculator::REPL" * doctest::skip()) {
	doir::ParseModule module("");
	calculator::parse p;

	std::cout << "> ";
	size_t start = module.buffer.size();
	std::string temp;
	while(std::getline(std::cin, temp)) {
		if(temp == "\\q") break;

		module.buffer = module.buffer + temp + "\n";
		module.lexer_state.lexeme = {};
		module.lexer_state.remaining = std::string_view{module.buffer}.substr(start);
		start = module.buffer.size();

		p.start(module);
		std::cout << "> ";
		module.source_location.next_line();
		FrameMark;
	}

	std::cout << module.token_count() << std::endl;
	size_t i = 0;
	for(auto [t, lexeme, location, value]: doir::query_with_token<doir::Lexeme, doir::NamedSourceLocation, float>(module))
	// for(auto [t, lexeme, location, value]: doir::query_with_token<doir::Lexeme, doir::NamedSourceLocation, doir::or_<float, double>>(data))
		std::cout << i++ << " (" << t << "): `" << lexeme.view(module.buffer) << "` = " << value << "; " << doir::SourceLocation(location).to_string(lexeme.length) << std::endl;
}