#define LEXER_CTRE_REGEX
#include "lexer.hpp"

#include <iostream>

int main() {
	enum Tokens {
		Invalid,
		Whitespace,
		Hello,
		World,
	};

	lex::lexer<
		lex::token_head<Tokens::Hello, lex::heads::case_insensitive_string<"hello">>,
		lex::token_head<Tokens::World, lex::heads::case_insensitive_string<"world">>,
		lex::token_head<Tokens::Whitespace, lex::heads::exact_character<'!'>>,
		lex::token_head<Tokens::Whitespace, lex::heads::exact_character<' '>>,
		lex::heads::ctre_regex<"a*b?">
		// lex::heads::case_insensitive_string<"hello">,
		// lex::heads::case_insensitive_string<"world">,
		// lex::heads::exact_character<'!'>,
		// lex::heads::exact_character<' '>
	> lex;
	std::string_view buffer = "baaab!";
	auto res = lex.lex(buffer);
	// res = lex.lex(res);
	// res = lex.lex(res);
	// res = lex.lex(res);
	// res = lex.lex(res);
	std::cout << res.token<Tokens>() << std::endl;
	std::cout << "`" << res.lexeme << "`" << std::endl;
	std::cout << "`" << res.remaining << "`" << std::endl;
	std::cout << (res.valid() ? "t" : "f") << std::endl;
}