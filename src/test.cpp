#define LEXER_CTRE_REGEX
// #define LEXER_IS_STATEFULL
#include "lexer.hpp"
#define DOIR_IMPLEMENTATION
#include "core.hpp"

#include <codecvt>
#include <locale>
#include "../thirdparty/unicode_ident.h"
struct XIDIdentifierHead {
	static std::optional<std::uint32_t> utf8_to_utf32(std::string_view utf8) {
		uint32_t ch = 0;
		size_t bytes = 0;

		if ((utf8[0] & 0x80) == 0x00) {
			// Single byte (ASCII)
			ch = utf8[0];
			bytes = 1;
		} else if ((utf8[0] & 0xE0) == 0xC0) {
			// Two bytes
			if(utf8.size() < 2) return {};
			ch = (utf8[0] & 0x1F) << 6;
			ch |= (utf8[1] & 0x3F);
			bytes = 2;
		} else if ((utf8[0] & 0xF0) == 0xE0) {
			// Three bytes
			if(utf8.size() < 3) return {};
			ch = (utf8[0] & 0x0F) << 12;
			ch |= (utf8[1] & 0x3F) << 6;
			ch |= (utf8[2] & 0x3F);
			bytes = 3;
		} else if ((utf8[0] & 0xF8) == 0xF0) {
			// Four bytes
			if(utf8.size() < 4) return {};
			ch = (utf8[0] & 0x07) << 18;
			ch |= (utf8[1] & 0x3F) << 12;
			ch |= (utf8[2] & 0x3F) << 6;
			ch |= (utf8[3] & 0x3F);
			bytes = 4;
		} else return {};
		return ch;
	}

	constexpr static auto skip_if_invalid = true;
	thread_local static std::string tmp;
	thread_local static bool first /*= true*/;
	static bool next_valid(size_t index, char next) {
		if(index == 0) {
			tmp.clear();
			first = true;
		}
		tmp += next;
		std::string debug = tmp;

		auto res = utf8_to_utf32(tmp);
		if(!res) return true;
		tmp.clear(); // If nothing went wrong in the conversion then we need to move onto the next character
		if(std::isspace(*res)) return false;
		if(first) {
			first = false;
			return is_xid_start(*res);
		}
		return is_xid_continue(*res);
	}
	static bool token_valid(std::string_view token) {
		// Make sure that the last character is valid!
		bool valid = (token.size() >= 4 && utf8_to_utf32(token.substr(token.size() - 4)).has_value())
			|| (token.size() >= 3 && utf8_to_utf32(token.substr(token.size() - 3)).has_value())
			|| (token.size() >= 2 && utf8_to_utf32(token.substr(token.size() - 2)).has_value())
			|| (token.size() >= 1 && utf8_to_utf32(token.substr(token.size() - 1)).has_value());
		if(!token.empty() && std::isspace(token[0])) return false;
		return valid;
	}
};
thread_local std::string XIDIdentifierHead::tmp;
thread_local bool XIDIdentifierHead::first = true;

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

constexpr doir::lex::lexer<
	doir::lex::heads::token<Tokens::Plus, doir::lex::heads::exact_character<'+'>>,
	doir::lex::heads::token<Tokens::Minus, doir::lex::heads::exact_character<'-'>>,
	doir::lex::heads::token<Tokens::Mult, doir::lex::heads::exact_character<'*'>>,
	doir::lex::heads::token<Tokens::Divide, doir::lex::heads::exact_character<'/'>>,
	doir::lex::heads::token<Tokens::Equals, doir::lex::heads::exact_character<'='>>,
	doir::lex::heads::token<Tokens::Open, doir::lex::heads::exact_character<'('>>,
	doir::lex::heads::token<Tokens::Close, doir::lex::heads::exact_character<')'>>,
	// doir::lex::heads::token<Tokens::Identifier, doir::lex::heads::ctre_regex<"[_a-zA-z][_a-zA-z0-9]*">>,
	doir::lex::heads::token<Tokens::Literal, doir::lex::heads::ctre_regex<R"_((\+|-)?(\d+(\.\d*)?|\.\d+)([eE](\+|-)?\d+)?)_">>,
	doir::lex::heads::skip<doir::lex::heads::ctre_regex<"\\s+">>, // Skip whitespace!
	doir::lex::heads::token<Tokens::Identifier, XIDIdentifierHead>
> lexer;

constexpr doir::lex::lexer<
	doir::lex::heads::token<Tokens::Newline, doir::lex::heads::exact_character<'\n'>>,
	doir::lex::heads::token<Tokens::Plus, doir::lex::heads::exact_character<'+'>>,
	doir::lex::heads::token<Tokens::Minus, doir::lex::heads::exact_character<'-'>>,
	doir::lex::heads::token<Tokens::Mult, doir::lex::heads::exact_character<'*'>>,
	doir::lex::heads::token<Tokens::Divide, doir::lex::heads::exact_character<'/'>>,
	doir::lex::heads::token<Tokens::Equals, doir::lex::heads::exact_character<'='>>,
	doir::lex::heads::token<Tokens::Open, doir::lex::heads::exact_character<'('>>,
	doir::lex::heads::token<Tokens::Close, doir::lex::heads::exact_character<')'>>,
	// doir::lex::heads::token<Tokens::Identifier, doir::lex::heads::ctre_regex<"[_a-zA-z][_a-zA-z0-9]*">>,
	doir::lex::heads::token<Tokens::Literal, doir::lex::heads::ctre_regex<R"_((\+|-)?(\d+(\.\d*)?|\.\d+)([eE](\+|-)?\d+)?)_">>,
	doir::lex::heads::skip<doir::lex::heads::ctre_regex<"\\s">>, // Skip whitespace (one at a time, excluding newlines)!
	doir::lex::heads::token<Tokens::Identifier, XIDIdentifierHead>
> lexerNewline;


// start: expressions
// expressions : assignment_expression | assignment_expression \n expressions;
// assignment_expression: identifier = assignment_expression | add_expression;
// add_expression : mult_expression add_expression';
// add_expression' : + mult_expression add_expression' | - mult_expression add_expression' | eps;
// mult_expression : primary_expression mult_expression';
// mult_expression' : * primary_expression mult_expression' | / primary_expression mult_expression' | eps;
// primary_expression : identifier | literal | (assignment_expression);
struct parse {
	struct Variable {};

	void print_result(doir::ParseModule& data, doir::Token t) {
		static size_t i = 0;
		std::cout << i++;
		if(data.has_attribute<doir::Error>(t))
			std::cerr << " !!ERROR: " << data.get_attribute<doir::Error>(t)->message << std::endl;
		else std::cout << ": " << *data.get_attribute<float>(t) << std::endl;
	}

	doir::Token lookup_variable(doir::ParseModule& data, std::string_view target) {
		for(auto [t, _1, _2, name] : doir::query_with_token<Variable, float, doir::Lexeme>(data))
			if(name.view(data.buffer) == target)
				return t;
		return 0;
	}

	// start: expressions
	bool start(doir::ParseModule& data) {
		if(data.state.lexer.lexeme.empty()) data.lex(lexer);
		return !data.has_attribute<doir::Error>(expressions(data));
	}

	// expressions : assignment_expression | assignment_expression \n expressions;
	doir::Token expressions(doir::ParseModule& data) {
		if(!data.state.lexer.valid()) return data.make_error();
		auto t = assignment_expression(data);
		print_result(data, t);

		if(data.lex(lexerNewline).lexer.token<Tokens>() == Newline){
			data.lex(lexer);
			return expressions(data);
		}

		return t;
	}

	// assignment_expression: identifier = assignment_expression | add_expression;
	doir::Token assignment_expression(doir::ParseModule& data) {
		if(!data.state.lexer.valid()) return data.make_error();

		if(data.current_lexer_token<Tokens>() == Identifier){
			if(data.current_lexer_token<Tokens>(data.lookahead(lexer)) == Equals) {
				// Find the attribute storing the identifier value (or make it if it doesn't exist!)
				doir::Token ident = lookup_variable(data, data.state.lexer.lexeme);
				if(ident == 0) {
					ident = data.make_token();
					data.add_attribute<Variable>(ident);
					data.add_attribute<float>(ident);
				}

				if(data.lex(lexer).lexer.token<Tokens>() != Equals)
					return data.make_error<doir::Error>({"Expected `=`!"});
				data.lex(lexer);
				auto expr = assignment_expression(data);
				if(expr == 0) return expr;
				auto value = *data.get_attribute<float>(expr);
				*data.get_attribute<float>(ident) = value;
				return ident;
			}
		}
		return add_expression(data);
	}

	// add_expression : mult_expression add_expression';
	// add_expression' : + mult_expression add_expression' | - mult_expression add_expression' | eps;
	doir::Token add_expression_prime(doir::ParseModule& data) {
		if (auto t = data.current_lexer_token<Tokens>(); t == Plus || t == Minus) {
			data.lex(lexer);
			doir::Token value = mult_expression(data);
			if(data.has_attribute<doir::Error>(value)) return value;
			if(t == Minus) *data.get_attribute<float>(value) = -(*data.get_attribute<float>(value));

			// data.lex(lexer);
			doir::Token prime = add_expression_prime(data);
			if(data.has_attribute<doir::Error>(prime)) return prime;
			if(prime == 0) return value;

			*data.get_attribute<float>(prime) += *data.get_attribute<float>(value);
			return prime;
		}
		return 0;
	}
	doir::Token add_expression(doir::ParseModule& data) {
		doir::Token value = mult_expression(data);
		if(data.has_attribute<doir::Error>(value)) return value;

		// data.lex(lexer); Don't need to get the next token here, mult_expression does it in this same spot!
		doir::Token prime = add_expression_prime(data);
		if(data.has_attribute<doir::Error>(prime)) return prime;
		if(prime == 0) return value;

		*data.get_attribute<float>(prime) += *data.get_attribute<float>(value);
		return prime;
	}

	// mult_expression : primary_expression mult_expression';
	// mult_expression' : * primary_expression mult_expression' | / primary_expression mult_expression' | eps;
	doir::Token mult_expression_prime(doir::ParseModule& data) {
		if (auto t = data.current_lexer_token<Tokens>(); t == Mult || t == Divide) {
			data.lex(lexer);
			doir::Token value = primary_expression(data);
			if(data.has_attribute<doir::Error>(value)) return value;
			if (t == Divide) *data.get_attribute<float>(value) = 1 / (*data.get_attribute<float>(value));

			data.lex(lexer);
			doir::Token prime = mult_expression_prime(data);
			if(data.has_attribute<doir::Error>(prime)) return prime;
			if(prime == 0) return value;

			*data.get_attribute<float>(prime) *= *data.get_attribute<float>(value);
			return prime;
		}
		return 0;
	}
	doir::Token mult_expression(doir::ParseModule& data) {
		doir::Token value = primary_expression(data);
		if(data.has_attribute<doir::Error>(value)) return value;

		data.lex(lexer);
		doir::Token prime = mult_expression_prime(data);
		if(data.has_attribute<doir::Error>(prime)) return prime;
		if(prime == 0) return value;

		*data.get_attribute<float>(prime) *= *data.get_attribute<float>(value);
		return prime;
	}

	// primary_expression : identifier | literal | (assignment_expression);
	doir::Token primary_expression(doir::ParseModule& data) {
		if(!data.state.lexer.valid()) return data.make_error();

		switch(data.state.lexer.token<Tokens>()){
		break; case Identifier: {
			doir::Token ident = lookup_variable(data, data.state.lexer.lexeme);
			if(ident == 0) return data.make_error<doir::Error>({"Identifier not found!"});
			return ident;
		}
		break; case Literal: {
			auto t = data.make_token();
			data.add_attribute<float>(t) = std::strtold(data.get_attribute<doir::Lexeme>(t)->view(data.buffer).data(), nullptr);
			return t;
		}
		break; case Open: {
			data.lex(lexer);
			auto expr = assignment_expression(data);
			if(data.has_attribute<doir::Error>(expr)) return expr;
			if(data.state.lexer.token<Tokens>() != Close)
				return data.make_error<doir::Error>({"Expected `)`!"});
			return expr;
		}
		break; default: return data.make_error<doir::Error>({"Unexpected token!"});
		}
	}
};

// NOTE: Need to provide backing memory for any runtime strings that are used!
template<> std::string_view doir::lex::heads::runtime_string<0, true>::match = {};

int main() {
	{
		doir::lex::lexer<doir::lex::heads::ctre_regex<"a+b*">> lexFirst;
		doir::lex::lexer<doir::lex::heads::runtime_string<0, true>> lexRest;
		std::string threeInARow = "aaaabbaaaabbaaaabb"; // Works!
		// std::string threeInARow = "aaaabbaaaabbaaabb"; // Fails!
		doir::lex::lexer_generic_result res = lexFirst.lex(threeInARow);
		doir::lex::heads::runtime_string<0, true>::set(res.lexeme);
		res = lexRest.lex(res);
		res = lexRest.lex(res);
		std::cout << "3 of the same in a row? " << res.valid() << std::endl;
	}

	doir::ParseModule data("pi = 3.14159265358979323846\n");
	parse p;
	p.start(data);

	std::cout << "> ";
	size_t start = data.buffer.size();
	std::string temp;
	while(std::getline(std::cin, temp)) {
		if(temp == "\\q") break;

		data.buffer = data.buffer + temp + "\n";
		data.state.lexer.lexeme = {};
		data.state.lexer.remaining = std::string_view{data.buffer}.substr(start);
		data.state.location.next_line();
		start = data.buffer.size();

		p.start(data);
		std::cout << "> ";
	}

	std::cout << data.token_count() << std::endl;
	size_t i = 0;
	for(auto [t, lexeme, location, value]: doir::query_with_token<doir::Lexeme, doir::NamedSourceLocation, float>(data))
		std::cout << i++ << " (" << t << "): `" << lexeme.view(data.buffer) << "` = " << value << "; " << doir::SourceLocation(location).to_string(lexeme.length) << std::endl;
}