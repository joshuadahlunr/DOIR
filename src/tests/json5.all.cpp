#define LEXER_CTRE_REGEX
// #define LEXER_IS_STATEFULL
#include "../lexer.hpp"
#include "../core.hpp"
#include "../parse_state.hpp"
#include "../unicode_identifier_head.hpp"
#include "../diagnostics.hpp"

#include "tests.utils.hpp"

// https://spec.json5.org/#grammar

namespace json5 {
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
		doir::lex::heads::token<LexerTokens::Identifier, XIDIdentifierHead<false>>,
		doir::lex::heads::token<LexerTokens::Whitespace, doir::lex::heads::exact_character<'-'>> // Makes sure that - is a valid character for the regex to parse!
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
		struct Object {};
		struct Array {};
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
			module.add_attribute<Object>(object);
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

				std::string_view name; 
				if(auto str = module.get_attribute<doir::ModuleWrapped<doir::Lexeme>>(identifier); str)
					name = str->view();
				else name = module.get_attribute<doir::Lexeme>(identifier)->view(module.buffer);
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
			module.add_attribute<Array>(array);
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
}

namespace fnv {
	template<>
	struct fnv1a_64<json5::parse::ObjectMember> {
		inline uint64_t operator()(const json5::parse::ObjectMember& mem) {
			return fnv1a_64<std::string_view>{}(mem.value) ^ fnv1a_64<doir::Token>{}(mem.entity);
		}
	};
	template<>
	struct fnv1a_64<json5::parse::ArrayMember> {
		inline uint64_t operator()(const json5::parse::ArrayMember& mem) {
			return fnv1a_64<size_t>{}(mem.value) ^ fnv1a_64<doir::Token>{}(mem.entity);
		}
	};
}

namespace json5 {
	static LexerTokens type(doir::Module& module, doir::Token node) {
		if(module.has_attribute<parse::Null>(node)) return LexerTokens::Null;
		else if(module.has_attribute<parse::Object>(node)) return LexerTokens::ObjectStart;
		else if(module.has_attribute<parse::Array>(node)) return LexerTokens::ArrayStart;
		else if(module.has_attribute<bool>(node)) return LexerTokens::True;
		else if(module.has_attribute<doir::ModuleWrapped<doir::Lexeme>>(node)) return LexerTokens::String;
		else if(module.has_attribute<double>(node)) return LexerTokens::Number;
		else return LexerTokens::Whitespace;
	}

	static std::string print(doir::Module& module, doir::Token root) {
		switch(type(module, root)) {
		break; case LexerTokens::Null: return "null";
		break; case LexerTokens::True: return *module.get_attribute<bool>(root) ? "true" : "false";
		break; case LexerTokens::String: return "\"" + std::string(module.get_attribute<doir::ModuleWrapped<doir::Lexeme>>(root)->view()) + "\"";
		break; case LexerTokens::Number: return std::to_string(*module.get_attribute<double>(root));
		break; case LexerTokens::ObjectStart: {
			std::string out = "{";
			bool empty = true;
			for(auto& mem: module.get_hashtable_attribute_as_span<parse::ObjectMember>())
				if(mem->key.entity == root) {
					empty = false;
					out += "\"" + std::string(mem->key.value) + "\": " 
						+ print(module, module.get_attribute<doir::TokenReference>(mem.entity)->token()) + ", ";
				}
			if(!empty) out.resize(out.size() - 2);
			return out + "}";
		}
		break; case LexerTokens::ArrayStart: {
			std::string out = "[";
			std::vector<parse::ArrayMember> members;
			for(auto& mem: module.get_hashtable_attribute_as_span<parse::ArrayMember>())
				if(mem->key.entity == root)
					members.emplace_back(mem->key);
			std::sort(members.begin(), members.end(), [](const parse::ArrayMember& a, const parse::ArrayMember& b){
				return a.value < b.value;
			});
			auto& hashtable = *module.get_hashtable<parse::ArrayMember>();
			for(auto& mem: members)
				out += print(module, *hashtable.find(mem)) + ", ";
			if(!members.empty()) out.resize(out.size() - 2);
			return out + "]";
		}
		break; default: return "<error>";
		}
	}
}

TEST_CASE("JSON5::null") {
	doir::ParseModule module("null");
	json5::parse p;
	auto root = p.start(module);
	CHECK(module.has_attribute<json5::parse::Null>(root) == true);
	// nowide::cout << json5::print(module, root) << std::endl;
	FrameMark;
}

TEST_CASE("JSON5::true") {
	doir::ParseModule module("true");
	json5::parse p;
	auto root = p.start(module);
	CHECK(*module.get_attribute<bool>(root) == true);
	// nowide::cout << json5::print(module, root) << std::endl;
	FrameMark;
}

TEST_CASE("JSON5::false") {
	doir::ParseModule module("false");
	json5::parse p;
	auto root = p.start(module);
	CHECK(*module.get_attribute<bool>(root) == false);
	// nowide::cout << json5::print(module, root) << std::endl;
	FrameMark;
}

TEST_CASE("JSON5::string") {
	doir::ParseModule module("\"Hello\"");
	json5::parse p;
	auto root = p.start(module);
	CHECK(module.get_attribute<doir::ModuleWrapped<doir::Lexeme>>(root)->view() == "Hello");
	// nowide::cout << json5::print(module, root) << std::endl;
	FrameMark;
}

TEST_CASE("JSON5::string (no terminating quote)") {
	doir::ParseModule module("\"Hello");
	json5::parse p;
	auto root = p.start(module);
	CHECK(module.has_attribute<doir::Error>(root) == true);
	// nowide::cout << json5::print(module, root) << std::endl;
	FrameMark;
}

TEST_CASE("JSON5::number") {
	doir::ParseModule module("27");
	json5::parse p;
	auto root = p.start(module);
	CHECK(*module.get_attribute<double>(root) == 27);
	// nowide::cout << json5::print(module, root) << std::endl;
	FrameMark;
}

TEST_CASE("JSON5::negative_number") {
	doir::ParseModule module("-27");
	json5::parse p;
	auto root = p.start(module);
	CHECK(*module.get_attribute<double>(root) == -27);
	// nowide::cout << json5::print(module, root) << std::endl;
	FrameMark;
}

TEST_CASE("JSON5::negative_sign") {
	doir::ParseModule module("-");
	json5::parse p;
	CHECK(p.start(module) == 0);
	FrameMark;
}

TEST_CASE("JSON5::object") {
	doir::ParseModule module("{x: 5, \"y\": 6}");
	json5::parse p;
	doir::Token root = p.start(module);
	auto& hashtable = *module.get_hashtable<json5::parse::ObjectMember>();
	auto a = hashtable.find({"x", root});
	auto b = module.get_attribute<doir::TokenReference>(*a);
	doir::Token x = b->token();
	CHECK(*module.get_attribute<double>(x) == 5);

	doir::Token y = module.get_attribute<doir::TokenReference>(*hashtable.find({"y", root}))->token();
	CHECK(module.get_attribute<double>(y) == 6);
	// nowide::cout << json5::print(module, root) << std::endl;
	FrameMark;
}

TEST_CASE("JSON5::array") {
	doir::ParseModule module("[5, 6, 7, \"Hello World\"]");
	json5::parse p;
	auto root = p.start(module);
	auto& hashtable = *module.get_hashtable<json5::parse::ArrayMember>();
	CHECK(*module.get_attribute<double>(*hashtable.find({0, root})) == 5);
	CHECK(*module.get_attribute<double>(*hashtable.find({1, root})) == 6);
	CHECK(*module.get_attribute<double>(*hashtable.find({2, root})) == 7);
	CHECK(module.get_attribute<doir::ModuleWrapped<doir::Lexeme>>(*hashtable.find({3, root}))->view() == "Hello World");
	// nowide::cout << json5::print(module, root) << std::endl;
	FrameMark;
}

TEST_CASE("JSON5::nested_array_in_object") {
	doir::ParseModule module("{x : [5, 6, 7, \"Hello World\"]}");
	json5::parse p;
	doir::Token root = p.start(module);
	auto& objectTable = *module.get_hashtable<json5::parse::ObjectMember>();
	auto& arrayTable = *module.get_hashtable<json5::parse::ArrayMember>();
	doir::Token x = module.get_attribute<doir::TokenReference>(*objectTable.find({"x", root}))->token();
	CHECK(*module.get_attribute<double>(*arrayTable.find({0, x})) == 5);
	CHECK(*module.get_attribute<double>(*arrayTable.find({1, x})) == 6);
	CHECK(*module.get_attribute<double>(*arrayTable.find({2, x})) == 7);
	CHECK(module.get_attribute<doir::ModuleWrapped<doir::Lexeme>>(*arrayTable.find({3, x}))->view() == "Hello World");
	// nowide::cout << json5::print(module, root) << std::endl;
	FrameMark;
}

TEST_CASE("JSON5::nested_array") {
	doir::ParseModule module("[[1, 2], [3, 4]]");
	json5::parse p;
	doir::Token root = p.start(module);
	auto& hashtable = *module.get_hashtable<json5::parse::ArrayMember>();
	doir::Token childrenA = *hashtable.find({0, root});
	doir::Token childrenB = *hashtable.find({1, root});
	CHECK(*module.get_attribute<double>(*hashtable.find({0, childrenA})) == 1);
	CHECK(*module.get_attribute<double>(*hashtable.find({1, childrenA})) == 2);
	CHECK(*module.get_attribute<double>(*hashtable.find({0, childrenB})) == 3);
	CHECK(*module.get_attribute<double>(*hashtable.find({1, childrenB})) == 4);
	// nowide::cout << json5::print(module, root) << std::endl;
	FrameMark;
}

TEST_CASE("JSON5::nested_object") {
	doir::ParseModule module("{x: {y: 5, z: 6}}");
	json5::parse p;
	doir::Token root = p.start(module);
	auto& hashtable = *module.get_hashtable<json5::parse::ObjectMember>();
	doir::Token x = module.get_attribute<doir::TokenReference>(*hashtable.find({"x", root}))->token(); // TODO: Why is this not attached to root?
	doir::Token y = module.get_attribute<doir::TokenReference>(*hashtable.find({"y", x}))->token();
	doir::Token z = module.get_attribute<doir::TokenReference>(*hashtable.find({"z", x}))->token();

	CHECK(*module.get_attribute<double>(y) == 5);
	CHECK(*module.get_attribute<double>(z) == 6);
	// nowide::cout << json5::print(module, root) << std::endl;
	FrameMark;
}

// TEST_CASE("JSON5::1k" /* * doctest::skip()*/) {
// 	doir::ParseModule module(
// #include "random_data.json"
// 	);
// 	json5::parse p;
// 	doir::Token root = p.start(module);
// 	if(module.has_attribute<doir::Error>(root)) 
// 		doir::print_diagnostic(module, root);
// 	CHECK(root != 0);
// 	CHECK(module.get_attribute_hashtable<json5::parse::ObjectMember>().has_value());
// 	CHECK(module.get_attribute_hashtable<json5::parse::ArrayMember>().has_value());
// 	FrameMark;
// }