#define LEXER_CTRE_REGEX
// #define LEXER_IS_STATEFULL
#include "../lexer.hpp"
#include "../core.hpp"
#include "../parse_state.hpp"
#include "../unicode_identifier_head.hpp"

#include <doctest/doctest.h>
#include <tracy/Tracy.hpp>

// https://spec.json5.org/#grammar

enum LexerTokens {
	Whitespace,
	ObjectStart, // {
	ObjectEnd, // }
	Comma, // ,
	Colon, // :
	ArrayStart, // [
	ArrayEnd, // ]
	Null, // "null"
	True, // "true"
	False, // "false"
	String, // \"([^\\"]|\\")*\"
	Number, // (\+|-)?(\d+(\.\d*)?|\.\d+)([eE](\+|-)?\d+)?
	Identifier, // [a-zA-Z_$][0-9a-zA-Z_$]* (XIDIdentifier)
};

constexpr doir::lex::lexer<
	doir::lex::heads::token<LexerTokens::ObjectStart, doir::lex::heads::exact_character<'{'>>,
	doir::lex::heads::token<LexerTokens::ObjectEnd, doir::lex::heads::exact_character<'}'>>,
	doir::lex::heads::token<LexerTokens::Comma, doir::lex::heads::exact_character<','>>,
	doir::lex::heads::token<LexerTokens::Colon, doir::lex::heads::exact_character<':'>>,
	doir::lex::heads::token<LexerTokens::ArrayStart, doir::lex::heads::exact_character<'['>>,
	doir::lex::heads::token<LexerTokens::ArrayEnd, doir::lex::heads::exact_character<']'>>,
	doir::lex::heads::token<LexerTokens::Null, doir::lex::heads::exact_string<"null">>,
	doir::lex::heads::token<LexerTokens::True, doir::lex::heads::exact_string<"true">>,
	doir::lex::heads::token<LexerTokens::False, doir::lex::heads::exact_string<"false">>,
	doir::lex::heads::token<LexerTokens::String, doir::lex::heads::ctre_regex<R"_("(\\"|[^"])*"?)_">>, // Since we have to be able to constantly march forward... the trailing quote needs to be optional and checked as part of the parser!
	doir::lex::heads::token<LexerTokens::Number, doir::lex::heads::ctre_regex<R"_((\+|-)?(\d+(\.\d*)?|\.\d+)([eE](\+|-)?\d+)?)_">>,
	doir::lex::heads::skip<doir::lex::heads::whitespace>, // Skip whitespace!
	doir::lex::heads::token<LexerTokens::Identifier, XIDIdentifierHead<false>>
> lexer;

// Start ::= Value
// Value ::= Null | Boolean | String | Number | Object | Array
// Object ::= "{" (Member ("," Member)*)? "}"
// Member ::= (Identifier | String) ":" Value
// Array ::= "[" (Value ("," Value)*)? "]"
// Null ::= "null"
// Boolean ::= "true" | "false"
// String ::= \"([^\\"]|\\")*\"
// Number ::= (\+|-)?(\d+(\.\d*)?|\.\d+)([eE](\+|-)?\d+)?
// Identifier ::= XIDIdentifier
struct parse {
	struct Null {};
	struct ObjectMember : public doir::WithToken<std::string_view> {};
	struct ArrayMember : public doir::WithToken<size_t> {};

	// Start ::= Value
	doir::Token start(doir::ParseModule& module) {
		ZoneScoped;
		if(module.lexer_state.lexeme.empty()) module.lex(lexer);
		return value(module);
	}

	// Value ::= Null | Boolean | String | Number | Object | Array
	doir::Token value(doir::ParseModule& module) {
		ZoneScoped;
		if(!module.lexer_state.valid()) return module.make_error();

		switch (module.current_lexer_token<LexerTokens>()) {
		case LexerTokens::Null: {
			auto t = module.make_token();
			module.add_attribute<Null>(t);
			return t;
		}
		case LexerTokens::True: {
			auto t = module.make_token();
			module.add_attribute<bool>(t) = true;
			return t;
		}
		case LexerTokens::False: {
			auto t = module.make_token();
			module.add_attribute<bool>(t) = false;
			return t;
		}
		case LexerTokens::String: {
			auto t = module.make_token();
			auto tmp = module.get_attribute<doir::Lexeme>(t)->view(module.buffer);
			// Ensure the existence of the trailing quote
			if(std::ranges::count(tmp, '"') < 2) return module.make_error<doir::Error>({"Expected a terminating `\"`!"});
			module.add_attribute<doir::ModuleWrapped<doir::Lexeme>>(t)
				= {module, *doir::Lexeme::from_view(module.buffer, tmp.substr(1, tmp.size() - 2))};
			return t;
		}
		case LexerTokens::Number: {
			auto t = module.make_token();
			module.add_attribute<double>(t) = std::strtold(module.get_attribute<doir::Lexeme>(t)->view(module.buffer).data(), nullptr);
			return t;
		}
		case LexerTokens::ObjectStart: return object(module);
		case LexerTokens::ArrayStart: return array(module);
		default: return module.make_error<doir::Error>({"Unexpected token `" + std::to_string(module.current_lexer_token<LexerTokens>()) + "` detected!"});
		}
	}

	// Object ::= "{" (Member ("," Member)*)? "}"
	doir::Token object(doir::ParseModule& module) {
		ZoneScoped;
		if(auto error = module.expect(LexerTokens::ObjectStart)) return *error;

		doir::Token object = module.make_token_and_lex(lexer);
		if(module.current_lexer_token<LexerTokens>() == LexerTokens::ObjectEnd)
			return object;

		bool first = true;
		do {
			if(!first) if(auto error = module.expect_and_lex(lexer, LexerTokens::Comma)) return *error;
			first = false;

			doir::Token mem = member(module, object);
			if(module.has_attribute<doir::Error>(mem)) return mem;
			module.lex(lexer); // Consume the member
		} while(module.current_lexer_token<LexerTokens>() == Comma);

		if(auto error = module.expect(LexerTokens::ObjectEnd)) return *error;
		return object;
	}

	// Member ::= (Identifier | String) ":" Value
	doir::Token member(doir::ParseModule& module, doir::Token object) {
		ZoneScoped;
		if(!module.lexer_state.valid()) return module.make_error<doir::Error>({"Expected an Identifier or a String!"});

		doir::Token identifier = 0;
		switch (module.current_lexer_token<LexerTokens>()) {
		case LexerTokens::String:
			identifier = value(module); // Parse the string
			[[fallthrough]];
		case LexerTokens::Identifier:
		{
			if(identifier == 0) identifier = module.make_token();

			module.lex(lexer);
			if(auto error = module.expect_and_lex(lexer, LexerTokens::Colon, "Expected a `:`!")) return *error;

			doir::Token v = value(module);
			if(module.has_attribute<doir::Error>(v)) return v;
			module.add_attribute<doir::TokenReference>(identifier) = v; // Associate this identifier with its value

			std::string_view name = module.get_attribute<doir::Lexeme>(identifier)->view(module.buffer);
			if(auto str = module.get_attribute<doir::ModuleWrapped<doir::Lexeme>>(identifier); str)
				name = str->view();
			module.add_hashtable_attribute<ObjectMember>(identifier) = {name, object};

			return identifier;
		}
		break; default: return module.make_error<doir::Error>({"Expected an Identifier or a String!"});
		}
	}

	// Array ::= "[" (Value ("," Value)*)? "]"
	doir::Token array(doir::ParseModule& module) {
		ZoneScoped;
		if(auto error = module.expect(LexerTokens::ArrayStart)) return *error;

		doir::Token array = module.make_token_and_lex(lexer);
		if(module.current_lexer_token<LexerTokens>() == LexerTokens::ArrayEnd)
			return array;

		size_t i = 0;
		bool first = true;
		do {
			if(!first) if(auto error = module.expect_and_lex(lexer, LexerTokens::Comma)) return *error;
			first = false;

			doir::Token v = value(module);
			if(module.has_attribute<doir::Error>(v)) return v;
			module.add_hashtable_attribute<ArrayMember>(v) = {i++, array};
			module.lex(lexer); // Consume the value
		} while(module.current_lexer_token<LexerTokens>() == Comma);

		if(auto error = module.expect(LexerTokens::ArrayEnd)) return *error;
		return array;
	}
};

namespace fnv {
	template<>
	struct fnv1a_64<parse::ObjectMember> {
		inline uint64_t operator()(const parse::ObjectMember& mem) {
			return fnv1a_64<std::string_view>{}(mem.value) ^ fnv1a_64<doir::Token>{}(mem.entity);
		}
	};
	template<>
	struct fnv1a_64<parse::ArrayMember> {
		inline uint64_t operator()(const parse::ArrayMember& mem) {
			return fnv1a_64<size_t>{}(mem.value) ^ fnv1a_64<doir::Token>{}(mem.entity);
		}
	};
}

TEST_CASE("JSON::null") {
	doir::ParseModule module("null");
	parse p;
	auto res = p.start(module);
	CHECK(module.has_attribute<parse::Null>(res) == true);
	FrameMark;
}

TEST_CASE("JSON::true") {
	doir::ParseModule module("true");
	parse p;
	auto res = p.start(module);
	CHECK(*module.get_attribute<bool>(res) == true);
	FrameMark;
}

TEST_CASE("JSON::false") {
	doir::ParseModule module("false");
	parse p;
	auto res = p.start(module);
	CHECK(*module.get_attribute<bool>(res) == false);
	FrameMark;
}

TEST_CASE("JSON::string") {
	doir::ParseModule module("\"Hello\"");
	parse p;
	auto res = p.start(module);
	CHECK(module.get_attribute<doir::ModuleWrapped<doir::Lexeme>>(res)->view() == "Hello");
	FrameMark;
}

TEST_CASE("JSON::string (no terminating quote)") {
	doir::ParseModule module("\"Hello");
	parse p;
	auto res = p.start(module);
	CHECK(module.has_attribute<doir::Error>(res) == true);
	FrameMark;
}

TEST_CASE("JSON::number") {
	doir::ParseModule module("27");
	parse p;
	auto res = p.start(module);
	CHECK(*module.get_attribute<double>(res) == 27);
	FrameMark;
}

TEST_CASE("JSON::object") {
	doir::ParseModule module("{x: 5, \"y\": 6}");
	parse p;
	doir::Token res = p.start(module);
	auto& hashtable = *module.get_attribute_hashtable<parse::ObjectMember>();
	auto a = hashtable.find({"x", res});
	auto b = module.get_attribute<doir::TokenReference>(*a);
	doir::Token x = b->token();
	CHECK(*module.get_attribute<double>(x) == 5);

	doir::Token y = module.get_attribute<doir::TokenReference>(*hashtable.find({"y", res}))->token();
	CHECK(module.get_attribute<double>(y) == 6);
	FrameMark;
}

TEST_CASE("JSON::array") {
	doir::ParseModule module("[5, 6, 7, \"Hello World\"]");
	parse p;
	auto root = p.start(module);
	auto& hashtable = *module.get_attribute_hashtable<parse::ArrayMember>();
	CHECK(*module.get_attribute<double>(*hashtable.find({0, root})) == 5);
	CHECK(*module.get_attribute<double>(*hashtable.find({1, root})) == 6);
	CHECK(*module.get_attribute<double>(*hashtable.find({2, root})) == 7);
	CHECK(module.get_attribute<doir::ModuleWrapped<doir::Lexeme>>(*hashtable.find({3, root}))->view() == "Hello World");
	FrameMark;
}

TEST_CASE("JSON::nested_array_in_object") {
	doir::ParseModule module("{x : [5, 6, 7, \"Hello World\"]}");
	parse p;
	doir::Token root = p.start(module);
	auto& objectTable = *module.get_attribute_hashtable<parse::ObjectMember>();
	auto& arrayTable = *module.get_attribute_hashtable<parse::ArrayMember>();
	doir::Token x = module.get_attribute<doir::TokenReference>(*objectTable.find({"x", root}))->token();
	CHECK(*module.get_attribute<double>(*arrayTable.find({0, x})) == 5);
	CHECK(*module.get_attribute<double>(*arrayTable.find({1, x})) == 6);
	CHECK(*module.get_attribute<double>(*arrayTable.find({2, x})) == 7);
	CHECK(module.get_attribute<doir::ModuleWrapped<doir::Lexeme>>(*arrayTable.find({3, x}))->view() == "Hello World");
	FrameMark;
}

TEST_CASE("JSON::nested_array") {
	doir::ParseModule module("[[1, 2], [3, 4]]");
	parse p;
	doir::Token root = p.start(module);
	auto& hashtable = *module.get_attribute_hashtable<parse::ArrayMember>();
	doir::Token childrenA = *hashtable.find({0, root});
	doir::Token childrenB = *hashtable.find({1, root});
	CHECK(*module.get_attribute<double>(*hashtable.find({0, childrenA})) == 1);
	CHECK(*module.get_attribute<double>(*hashtable.find({1, childrenA})) == 2);
	CHECK(*module.get_attribute<double>(*hashtable.find({0, childrenB})) == 3);
	CHECK(*module.get_attribute<double>(*hashtable.find({1, childrenB})) == 4);
	FrameMark;
}

TEST_CASE("JSON::nested_object") {
	doir::ParseModule module("{x: {y: 5, z: 6}}");
	parse p;
	doir::Token root = p.start(module);
	auto& hashtable = *module.get_attribute_hashtable<parse::ObjectMember>();
	doir::Token x = module.get_attribute<doir::TokenReference>(*hashtable.find({"x", root}))->token(); // TODO: Why is this not attached to root?
	doir::Token y = module.get_attribute<doir::TokenReference>(*hashtable.find({"y", x}))->token();
	doir::Token z = module.get_attribute<doir::TokenReference>(*hashtable.find({"z", x}))->token();

	CHECK(*module.get_attribute<double>(y) == 5);
	CHECK(*module.get_attribute<double>(z) == 6);
	FrameMark;
}

// TEST_CASE("JSON Parse") {
// 	doir::ParseModule module("{x : [5, 6, 7, \"Hello World\"]}");
// 	parse p;
// 	auto res = p.start(module);
// 	if(module.has_attribute<doir::Error>(res))
// 		std::cerr << "!!ERROR!! " << module.get_attribute<doir::Error>(res)->message << std::endl;

// 	doir::Token x = module.get_attribute<parse::Object>(res)->children.at("x");
// 	auto& dbg  = *module.get_attribute<parse::Array>(x);
// 	auto& children = module.get_attribute<parse::Array>(x)->children;
// 	CHECK(*module.get_attribute<double>(children[0]) == 5);
// 	CHECK(*module.get_attribute<double>(children[1]) == 6);
// 	CHECK(*module.get_attribute<double>(children[2]) == 7);
// 	CHECK(module.get_attribute<doir::ModuleWrapped<doir::Lexeme>>(children[3])->view() == "Hello World");
// 	// CHECK(*module.get_attribute<std::string>(res) == "Hello \\n Bob");
// }

// TEST_CASE("JSON REPL" * doctest::skip()) {
// 	doir::ParseModule module("");
// 	parse p;

// 	std::cout << "> ";
// 	size_t start = module.buffer.size();
// 	std::string temp;
// 	while(std::getline(std::cin, temp)) {
// 		if(temp == "\\q") break;

// 		module.buffer = module.buffer + temp + "\n";
// 		module.lexer_state.lexeme = {};
// 		module.lexer_state.remaining = std::string_view{module.buffer}.substr(start);
// 		module.source_location.next_line();
// 		start = module.buffer.size();

// 		p.start(module);
// 		std::cout << "> ";
// 	}

// 	std::cout << module.token_count() << std::endl;
// 	size_t i = 0;
// 	for(auto [t, lexeme, location, value]: doir::query_with_token<doir::Lexeme, doir::NamedSourceLocation, float>(module))
// 	// for(auto [t, lexeme, location, value]: doir::query_with_token<doir::Lexeme, doir::NamedSourceLocation, doir::or_<float, double>>(data))
// 		std::cout << i++ << " (" << t << "): `" << lexeme.view(module.buffer) << "` = " << value << "; " << doir::SourceLocation(location).to_string(lexeme.length) << std::endl;
// }


