#define LEXER_CTRE_REGEX
// #define LEXER_IS_STATEFULL
#include "lexer.hpp"
#include "ECS.hpp"
size_t globalAttributeCounter = 0;

#include <iostream>
#include <map>
#include <deque>

using Token = ECS::Token;

struct SourceLocation {
	size_t line = 1, column = 1;

	void next_line() {
		line++;
		column = 1;
	}

	std::string to_string(std::optional<size_t> length = {}) const {
		if(length) return std::to_string(line) + ":" + std::to_string(column) + "-" + std::to_string(column + *length);
		return std::to_string(line) + ":" + std::to_string(column);
	};
	operator std::string() const { return to_string(); };
};
struct NamedSourceLocation: public SourceLocation {
	std::string_view filename = "<transient>";

	std::string to_string(std::optional<size_t> length = {}) const {
		return std::string(filename) + ":" + SourceLocation::to_string(length);
	};
	operator std::string() const { return to_string(); };
};

struct Lexeme {
	size_t start, length;

	std::string_view view(std::string_view buffer) { return buffer.substr(start, length); }
};

struct ParseData: public ECS::ParseData<ECS::SkiplistAttributeStorage> {
    std::string buffer;
	struct State {
		lex::lexer_generic_result lexer;
		NamedSourceLocation location;
	} state;


	ParseData(const std::string& buffer = "", NamedSourceLocation location = {}) : buffer(buffer), state({}, location) { state.lexer.remaining = this->buffer; }

	auto save_state() {
		return state;
	}
	void restore_state(State saved) {
		state = saved;
	}

	static State lookahead(/*lex::detail::instantiation_of_lexer<lex::basic_lexer>*/ auto& lexer, const State& state) {
		auto location = state.location;
		auto res = lexer.lex(state.lexer);
		if(res.lexeme.empty() || state.lexer.lexeme.empty()) return {res, location};
		for(size_t i = 0, traversed = res.lexeme.data() - state.lexer.lexeme.data(); i < traversed; i++) { // TODO: Is there a way to implement this without having to double iterate?
			auto c = state.lexer.lexeme.data()[i];
			if(c == '\n')
				location.next_line();
			else location.column++;
		}
		return {res, location};
	}
	State lookahead(/*lex::detail::instantiation_of_lexer<lex::basic_lexer>*/ auto& lexer) { return lookahead(lexer, this->state); }
	
	State& lex(/*lex::detail::instantiation_of_lexer<lex::basic_lexer>*/ auto& lexer, const State& state) {
		return this->state = lookahead(lexer, state);
	}
	State& lex(/*lex::detail::instantiation_of_lexer<lex::basic_lexer>*/ auto& lexer) { return lex(lexer, this->state); }

	Token make_token(const State& state) {
		if(!state.lexer.valid()) return -1;
		auto t = CreateToken();
		size_t start = state.lexer.lexeme.data() - buffer.data();
		AddAttribute<Lexeme>(t) = {start, state.lexer.lexeme.size()};
		AddAttribute<NamedSourceLocation>(t) = state.location;
		return t;
	}
	Token make_token() { return make_token(this->state); }

	Token lex_and_make_token(/*lex::detail::instantiation_of_lexer<lex::basic_lexer>*/ auto& lexer, const State& state) {
		lex(lexer, state);
		return make_token(state);
	}
	Token lex_and_make_token(/*lex::detail::instantiation_of_lexer<lex::basic_lexer>*/ auto& lexer) {
		return lex_and_make_token(lexer, this->state);
	}
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


// expressions : assignment_expression | assignment_expression \n expressions;
// assignment_expression: identifier = assignment_expression | add_expression;
// add_expression : mult_expression add_expression';
// add_expression' : + mult_expression add_expression' | - mult_expression add_expression' | eps;
// mult_expression : primary_expression mult_expression';
// mult_expression' : * primary_expression mult_expression' | / primary_expression mult_expression' | eps;
// primary_expression : identifier | literal | (assignment_expression);
struct parse {
	std::map<std::string, long double> variables;

	void start(ParseData& data) {
		// Ensure that the first token is ready
		if(data.state.lexer.lexeme.empty()) data.lex(lexer);
		expressions(data);
	}

	// expressions : assignment_expression | assignment_expression \n expressions;
	void expressions(ParseData& data) {
		static size_t i = 0;

		if(!data.state.lexer.valid()) { throw std::runtime_error(std::to_string(__LINE__) + ": Unexpected end of input"); }
		std::cout << i++ << ": " << parse::assignment_expression(data) << std::endl;

		data.lex(lexerNewline);
		if(!data.state.lexer.valid()) return;

		if(data.state.lexer.token<Tokens>() != Tokens::Newline) { throw std::runtime_error(std::to_string(__LINE__)); }
		data.lex(lexer);
		parse::expressions(data);
	}

	// assignment_expression: identifier = assignment_expression | add_expression;
	long double assignment_expression(ParseData& data) {
		if(!data.state.lexer.valid()) { throw std::runtime_error(std::to_string(__LINE__) + ": Unexpected end of input"); }

		switch(data.state.lexer.token<Tokens>()) {
			break; case Identifier: {
				auto lookahead = data.lookahead(lexer);
				if(!lookahead.lexer.valid_or_end()) { throw std::runtime_error(std::to_string(__LINE__)); }
				if(lookahead.lexer.token<Tokens>() == Tokens::Equals) {
					auto _1 = data.state.lexer;
					auto _2 = lookahead;
					data.make_token();
					data.make_token(lookahead);
					data.lex(lexer, _2);
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

	// add_expression : mult_expression add_expression';
	// add_expression' : + mult_expression add_expression' | - mult_expression add_expression' | eps;
	long double add_expression(ParseData& data) {
		const auto prime = [this](ParseData& data) -> std::deque<std::pair<bool, long double>> {
			const auto prime_impl = [this](ParseData& data, auto& prime) -> std::deque<std::pair<bool, long double>> {
				if(!data.state.lexer.valid_or_end()) { throw std::runtime_error(std::to_string(__LINE__) + ": Unexpected end of input"); }
				switch(data.state.lexer.token<Tokens>()) {
				break; case Plus: {
					data.make_token();
					data.lex(lexer);
					auto _2 = mult_expression(data);
					data.lex(lexer);
					auto _3 = prime(data, prime);
					_3.emplace_front(/*wasPlus*/true, _2);
					return _3;
				}
				break; case Minus: {
					data.make_token();
					data.lex(lexer);
					auto _2 = mult_expression(data);
					data.lex(lexer);
					auto _3 = prime(data, prime);
					_3.emplace_front(/*wasPlus*/false, _2);
					return _3;
				}
				break; default: return {};
				}
			};
			return prime_impl(data, prime_impl);
		};

		if(!data.state.lexer.valid()) { throw std::runtime_error(std::to_string(__LINE__) + ": Unexpected end of input"); }
		auto _1 = mult_expression(data);
		auto saved = data.save_state(); // Save the lexer state... this allows us to treat the prime as a lookahead!
		data.lex(lexer);
		auto _2 = prime(data);
		if(_2.empty()) {
			data.restore_state(saved); // Treat the previous prime as a lookahead
			return _1;
		} else for(auto [wasPlus, value]: _2)
			if(wasPlus) _1 += value;
			else _1 -= value;
		return _1;
	}

	// mult_expression : primary_expression mult_expression';
	// mult_expression' : * primary_expression mult_expression' | / primary_expression mult_expression' | eps;
	long double mult_expression(ParseData& data) {
		const auto prime = [this](ParseData& data) -> std::deque<std::pair<bool, long double>> {
			const auto prime_impl = [this](ParseData& data, auto& prime) -> std::deque<std::pair<bool, long double>> {
				if(!data.state.lexer.valid_or_end()) { throw std::runtime_error(std::to_string(__LINE__) + ": Unexpected end of input"); }
				switch(data.state.lexer.token<Tokens>()) {
				break; case Mult: {
					data.make_token();
					data.lex(lexer);
					auto _2 = primary_expression(data);
					data.lex(lexer);
					auto _3 = prime(data, prime);
					_3.emplace_front(/*wasMult*/true, _2);
					return _3;
				}
				break; case Divide: {
					data.make_token();
					data.lex(lexer);
					auto _2 = primary_expression(data);
					data.lex(lexer);
					auto _3 = prime(data, prime);
					_3.emplace_front(/*wasMult*/false, _2);
					return _3;
				}
				break; default: return {};
				}
			};
			return prime_impl(data, prime_impl);
		};

		if(!data.state.lexer.valid()) { throw std::runtime_error(std::to_string(__LINE__) + ": Unexpected end of input"); }
		auto _1 = primary_expression(data);
		auto saved = data.save_state(); // Save the lexer state... this allows us to treat the prime as a lookahead!
		data.lex(lexer);
		auto _2 = prime(data);
		if(_2.empty()) {
			data.restore_state(saved); // Treat the previous prime as a lookahead
			return _1;
		} else for(auto [wasMult, value]: _2)
			if(wasMult) _1 *= value;
			else _1 /= value;
		return _1;
	}

	// primary_expression : identifier | literal | (assignment_expression);
	long double primary_expression(ParseData& data) {
		if(!data.state.lexer.valid()) { throw std::runtime_error(std::to_string(__LINE__) + ": Unexpected end of input"); }

		switch (data.state.lexer.token<Tokens>()) {
		break; case Identifier: return identifier(data);
		break; case Literal: return literal(data);
		break; case Open: {
			data.lex(lexer);
			auto _2 = assignment_expression(data);
			auto _3 = data.lex(lexer);
			if(!data.state.lexer.valid()) { throw std::runtime_error(std::to_string(__LINE__)); }
			if(data.state.lexer.token<Tokens>() != Tokens::Close) { throw std::runtime_error(std::to_string(__LINE__)); }
			return _2;
		}
		break; default: { throw std::runtime_error(std::to_string(__LINE__)); }
		}
	}

	long double identifier(ParseData& data) {
		if(!data.state.lexer.valid()) { throw std::runtime_error(std::to_string(__LINE__) + ": Unexpected end of input"); }
		auto key = std::string(data.state.lexer.lexeme);
		if(!variables.contains(key)) { throw std::runtime_error(std::to_string(__LINE__)); }
		data.make_token();
		return variables.at(key);
	}

	long double literal(ParseData& data) {
		if(!data.state.lexer.valid()) { throw std::runtime_error(std::to_string(__LINE__) + ": Unexpected end of input"); }
		data.make_token();
		return std::strtold(data.state.lexer.lexeme.data(), nullptr);
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

	ParseData data("pi = 3.14159265358979323846");
	parse p;
	p.start(data);

	std::cout << "> ";
	size_t start = data.buffer.size();
	std::string temp;
	while(std::getline(std::cin, temp)) {
		if(temp == "\\q") break;

		data.buffer += "\n" + temp;
		data.state.lexer.remaining = std::string_view{data.buffer}.substr(start + 1);
		data.state.location.next_line();
		start = data.buffer.size();

		p.start(data);
		std::cout << "> ";
	}

	std::cout << data.entityMasks.size() << std::endl;
	size_t i = 0;
	for(auto [lexeme, location]: ECS::ParseDataView<Lexeme, NamedSourceLocation>{data})
		std::cout << i++ << ": `" << lexeme.view(data.buffer) << "` " << SourceLocation(location).to_string(lexeme.length) << std::endl;
}