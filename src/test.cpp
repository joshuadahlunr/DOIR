#include <cmath>
#include <cstddef>
#include <stdexcept>
#include <string>
#define LEXER_CTRE_REGEX
// #define LEXER_IS_STATEFULL
#include "lexer.hpp"
#include "ECS.hpp"
size_t globalAttributeCounter = 0;

#include <iostream>

using Token = ECS::Token;

struct ParseData: public ECS::ParseData<ECS::SkiplistAttributeStorage> {
    std::string buffer;
	lex::lexer_generic_result lex_result;
};

enum Tokens {
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

constexpr lex::lexer<
	lex::heads::token<Tokens::Plus, lex::heads::exact_character<'+'>>,
	lex::heads::token<Tokens::Minus, lex::heads::exact_character<'-'>>,
	lex::heads::token<Tokens::Mult, lex::heads::exact_character<'*'>>,
	lex::heads::token<Tokens::Divide, lex::heads::exact_character<'/'>>,
	lex::heads::token<Tokens::Equals, lex::heads::exact_character<'='>>,
	lex::heads::token<Tokens::Open, lex::heads::exact_character<'('>>,
	lex::heads::token<Tokens::Close, lex::heads::exact_character<')'>>,
	lex::heads::token<Tokens::Identifier, lex::heads::ctre_regex<"[_a-zA-z][_a-zA-z0-9]*">>,
	lex::heads::token<Tokens::Literal, lex::heads::ctre_regex<R"_((\+|-)?(\d+(\.\d*)?|\.\d+)([eE](\+|-)?\d+)?)_">>,
	lex::heads::skip<lex::heads::ctre_regex<"\\s+">> // Skip whitespace!
> lexer;

constexpr lex::lexer<
	lex::heads::token<Tokens::Newline, lex::heads::exact_character<'\n'>>,
	lex::heads::token<Tokens::Plus, lex::heads::exact_character<'+'>>,
	lex::heads::token<Tokens::Minus, lex::heads::exact_character<'-'>>,
	lex::heads::token<Tokens::Mult, lex::heads::exact_character<'*'>>,
	lex::heads::token<Tokens::Divide, lex::heads::exact_character<'/'>>,
	lex::heads::token<Tokens::Equals, lex::heads::exact_character<'='>>,
	lex::heads::token<Tokens::Open, lex::heads::exact_character<'('>>,
	lex::heads::token<Tokens::Close, lex::heads::exact_character<')'>>,
	lex::heads::token<Tokens::Identifier, lex::heads::ctre_regex<"[_a-zA-z][_a-zA-z0-9]*">>,
	lex::heads::token<Tokens::Literal, lex::heads::ctre_regex<R"_((\+|-)?(\d+(\.\d*)?|\.\d+)([eE](\+|-)?\d+)?)_">>,
	lex::heads::skip<lex::heads::ctre_regex<"\\s">> // Skip whitespace (one at a time, excluding newlines)!
> lexerNewline;



#include <map>
struct parse {
	std::map<std::string, long double> variables;

	void start(ParseData& data) {
		// Ensure that the first token is ready
		if(!data.lex_result.valid()) data.lex_result = lexer.lex(data.buffer);
		expressions(data);
	}

	// expressions : assignment_expression | assignment_expression , expressions;
	void expressions(ParseData& data) {
		static size_t i = 0;

		if(!data.lex_result.valid()) { throw std::runtime_error(std::to_string(__LINE__) + ": Unexpected end of input"); }
		std::cout << i++ << ": " << parse::assignment_expression(data) << std::endl;

		data.lex_result = lexerNewline.lex(data.lex_result);
		if(!data.lex_result.valid()) return;

		if(data.lex_result.token<Tokens>() != Tokens::Newline) { throw std::runtime_error(std::to_string(__LINE__)); }
		data.lex_result = lexer.lex(data.lex_result);
		parse::expressions(data);
	}

	// assignment_expression: identifier = assignment_expression | add_expression;
	long double assignment_expression(ParseData& data) {
		if(!data.lex_result.valid()) { throw std::runtime_error(std::to_string(__LINE__) + ": Unexpected end of input"); }

		switch(data.lex_result.token<Tokens>()) {
			break; case Identifier: {
				auto lookahead = lexer.lex(data.lex_result);
				if(!lookahead.valid_or_end()) { throw std::runtime_error(std::to_string(__LINE__)); }
				if(lookahead.token<Tokens>() == Tokens::Equals) {
					auto _1 = data.lex_result;
					auto _2 = lookahead;
					data.lex_result = lexer.lex(_2);
					auto _3 = parse::assignment_expression(data);
					// Assign _3 to _1
					return variables[std::string(_1.lexeme)] = _3;
				} else return parse::add_expression(data); // NOTE: Invalid second tokens will be handled by add_expression
			}
			break;case Open: // fallthrough
			case Literal:
				return parse::add_expression(data);
			break; default: { throw std::runtime_error(std::to_string(__LINE__)); }
		}
	}

	// add_expression : mult_expression + add_expression | mult_expression - add_expression | mult_expression
	long double add_expression(ParseData& data) {
		if(!data.lex_result.valid()) { throw std::runtime_error(std::to_string(__LINE__) + ": Unexpected end of input"); }

		auto _1 = mult_expression(data);
		auto _2 = lexer.lex(data.lex_result);
		if(!_2.valid_or_end()) { throw std::runtime_error(std::to_string(__LINE__)); }
		switch (_2.token<Tokens>()) {
		break; case Plus: {
			data.lex_result = lexer.lex(_2);
			auto _3 = add_expression(data);
			return _1 + _3;
		}
		break; case Minus: {
			data.lex_result = lexer.lex(_2);
			auto _3 = add_expression(data);
			return _1 - _3;
		}
		break; default: return _1;
        }
	}
	// mult_expression : primary_expression * mult_expression | primary_expression / mult_expression | primary_expression
	long double mult_expression(ParseData& data) {
		if(!data.lex_result.valid()) { throw std::runtime_error(std::to_string(__LINE__) + ": Unexpected end of input"); }

		auto _1 = primary_expression(data);
		auto _2 = lexer.lex(data.lex_result);
		if(!_2.valid_or_end()) { throw std::runtime_error(std::to_string(__LINE__)); }
		switch (_2.token<Tokens>()) {
		break; case Mult: {
			data.lex_result = lexer.lex(_2);
			auto _3 = mult_expression(data);
			return _1 * _3;
		}
		break; case Divide: {
			data.lex_result = lexer.lex(_2);
			auto _3 = mult_expression(data);
			return _1 / _3;
		}
		break; default: return _1;
        }
	}

	// primary_expression : identifier | literal | (assignment_expression);
	long double primary_expression(ParseData& data) {
		if(!data.lex_result.valid()) { throw std::runtime_error(std::to_string(__LINE__) + ": Unexpected end of input"); }

		switch (data.lex_result.token<Tokens>()) {
		break; case Identifier: return identifier(data);
		break; case Literal: return literal(data);
		break; case Open: {
			data.lex_result = lexer.lex(data.lex_result);
			auto _2 = assignment_expression(data);
			auto _3 = data.lex_result = lexer.lex(data.lex_result);
			if(!_3.valid()) { throw std::runtime_error(std::to_string(__LINE__)); }
			if(_3.token<Tokens>() != Tokens::Close) { throw std::runtime_error(std::to_string(__LINE__)); }
			return _2;
		}
		break; default: { throw std::runtime_error(std::to_string(__LINE__)); }
		}
	}

	long double identifier(ParseData& data) {
		if(!data.lex_result.valid()) { throw std::runtime_error(std::to_string(__LINE__) + ": Unexpected end of input"); }
		auto key = std::string(data.lex_result.lexeme);
		if(!variables.contains(key)) { throw std::runtime_error(std::to_string(__LINE__)); }
		return variables.at(key);
	}

	long double literal(ParseData& data) {
		if(!data.lex_result.valid()) { throw std::runtime_error(std::to_string(__LINE__) + ": Unexpected end of input"); }
		return std::strtold(data.lex_result.lexeme.data(), nullptr);
	}
};

// NOTE: Need to provide backing memory for any runtime strings that are used!
template<> std::string_view lex::heads::runtime_string<0, true>::match = {};

int main() {
	{
		lex::lexer<lex::heads::ctre_regex<"a+b*">> lexFirst;
		lex::lexer<lex::heads::runtime_string<0, true>> lexRest;
		std::string threeInARow = "aaaabbaaaabbaaaabb"; // Works!
		// std::string threeInARow = "aaaabbaaaabbaaabb"; // Fails!
		lex::lexer_generic_result res = lexFirst.lex(threeInARow);
		lex::heads::runtime_string<0, true>::set(res.lexeme);
		res = lexRest.lex(res);
		res = lexRest.lex(res);
		std::cout << "3 of the same in a row? " << res.valid() << std::endl;
	}

	ParseData data;
	parse p;
	data.buffer = "pi = 3.14159265358979323846";
	p.start(data);

	std::cout << "> ";
	while(std::getline(std::cin, data.buffer)) {
		if(data.buffer == "\\q") break;

		p.start(data);
		std::cout << "> ";
	}
}