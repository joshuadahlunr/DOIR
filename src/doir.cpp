#define LEXER_CTRE_REGEX
#include "lexer.hpp"
#define DOIR_IMPLEMENTATION
#define ECS_IMPLEMENTATION
#define LEXER_CTRE_REGEX
// #define LEXER_IS_STATEFULL
#include "parse_state.hpp"
#include "unicode_identifier_head.hpp"

enum LexerTokens {
	Whitespace, // `[ \t\n\r]+` or `\s` (if looking for a terminator)
	Colen, // :
	Equals, // =
	External, // "external"
	Or, // |
	OpenParen, // (
	CloseParen, // )
	Auto, // "auto"
	Type, // "type"
	Block, // "block"
	OpenAngle, // <
	CloseAngle, // >
	Comma, // ,
	Pointer, // *
	FatPointer, // [*]
	Constant, // "const" or "constant"
	Implicit, // "implicit"
	Ellipses, // ...
	Terminator, // ; or "\n"
	Dash, // -
	OpenBrace, // {
	CloseBrace, // }
	If, // "if"
	Else, // "else"
	Inline, // "inline"
	NoInline, // "noinline"
	Comptime, // "comptime"
	NoComptime, // "nocomptime"
	Terminating, // "terminating"
	Assembler, // "assembler"
	Dot, // .
	True, // "true"
	False, // "false"
	NodotIdentifier, // `%UNICODE_XID_CONTINUE+|(UNICODE_XID_START|_)UNICODE_XID_CONTINUE*`
	BinaryNumber, // `0[bB]([01]+|[01]+\.|[01]*\.[01]+)([eE][+-]?[01]+)?`
	DecimalNumber, // `([0-9]+|[0-9]+\.|[0-9]*\.[0-9]+)([eE][+-]?[0-9]+)?` NOTE: Any valid octal_number string is also a valid decimal_number string!
	HexadecimalNumber, // `0[xX]([0-9A-F]+|[0-9A-F]+\.|[0-9A-F]*\.[0-9A-F]+)(e[+-]?[0-9A-F]+)?`
	String, // `"(\\"|[^"])*"`
	Character, // `'(\\'|[^'])'` NOTE: Any single valid UTF-32 character
	Documentation, // `(/\*\*(.*?)\*/)`
	Comment, // `(//[^\n]*\n)|(/\*(.*?)\*/)`
	Filename, // `[^:]+?`
};

namespace heads {
	using SkipWhitespace = doir::lex::heads::skip<doir::lex::heads::ctre_regex<"\\s+">>; // Skip whitespace!
	using SkipWhitespaceSingle = doir::lex::heads::skip<doir::lex::heads::ctre_regex<"\\s">>; // Skip whitespace!
	using Colen = doir::lex::heads::token<LexerTokens::Colen, doir::lex::heads::exact_character<':'>>;
	using Equals = doir::lex::heads::token<LexerTokens::Equals, doir::lex::heads::exact_character<'='>>;
	using External = doir::lex::heads::token<LexerTokens::External, doir::lex::heads::exact_string<"external">>;
	using Or = doir::lex::heads::token<LexerTokens::Or, doir::lex::heads::exact_character<'|'>>;
	using OpenParen = doir::lex::heads::token<LexerTokens::OpenParen, doir::lex::heads::exact_character<'('>>;
	using CloseParen = doir::lex::heads::token<LexerTokens::CloseParen, doir::lex::heads::exact_character<')'>>;
	using Auto = doir::lex::heads::token<LexerTokens::Auto, doir::lex::heads::exact_string<"auto">>;
	using Type = doir::lex::heads::token<LexerTokens::Type, doir::lex::heads::exact_string<"type">>;
	using Block = doir::lex::heads::token<LexerTokens::Block, doir::lex::heads::exact_string<"block">>;
	using OpenAngle = doir::lex::heads::token<LexerTokens::OpenAngle, doir::lex::heads::exact_character<'<'>>;
	using CloseAngle = doir::lex::heads::token<LexerTokens::CloseAngle, doir::lex::heads::exact_character<'>'>>;
	using Comma = doir::lex::heads::token<LexerTokens::Comma, doir::lex::heads::exact_character<','>>;
	using Pointer = doir::lex::heads::token<LexerTokens::Pointer, doir::lex::heads::exact_character<'*'>>;
	using FatPointer = doir::lex::heads::token<LexerTokens::FatPointer, doir::lex::heads::exact_string<"[*]">>;
	using Const = doir::lex::heads::token<LexerTokens::Constant, doir::lex::heads::exact_string<"const">>;
	using Constant = doir::lex::heads::token<LexerTokens::Constant, doir::lex::heads::exact_string<"constant">>;
	using Implicit = doir::lex::heads::token<LexerTokens::Implicit, doir::lex::heads::exact_string<"implicit">>;
	using Ellipses = doir::lex::heads::token<LexerTokens::Ellipses, doir::lex::heads::exact_string<"...">>;
	using Semicolon = doir::lex::heads::token<LexerTokens::Terminator, doir::lex::heads::exact_character<';'>>;
	using Newline = doir::lex::heads::token<LexerTokens::Terminator, doir::lex::heads::exact_character<'\n'>>;
	using Dash = doir::lex::heads::token<LexerTokens::Dash, doir::lex::heads::exact_character<'-'>>;
	using OpenBrace = doir::lex::heads::token<LexerTokens::OpenBrace, doir::lex::heads::exact_character<'{'>>;
	using CloseBrace = doir::lex::heads::token<LexerTokens::CloseBrace, doir::lex::heads::exact_character<'}'>>;
	using If = doir::lex::heads::token<LexerTokens::If, doir::lex::heads::exact_string<"if">>;
	using Else = doir::lex::heads::token<LexerTokens::Else, doir::lex::heads::exact_string<"else">>;
	using Inline = doir::lex::heads::token<LexerTokens::Inline, doir::lex::heads::exact_string<"inline">>;
	using NoInline = doir::lex::heads::token<LexerTokens::NoInline, doir::lex::heads::exact_string<"noinline">>;
	using Comptime = doir::lex::heads::token<LexerTokens::Comptime, doir::lex::heads::exact_string<"comptime">>;
	using NoComptime = doir::lex::heads::token<LexerTokens::NoComptime, doir::lex::heads::exact_string<"nocomptime">>;
	using Terminating = doir::lex::heads::token<LexerTokens::Terminating, doir::lex::heads::exact_string<"terminating">>;
	using Assembler = doir::lex::heads::token<LexerTokens::Assembler, doir::lex::heads::exact_string<"assembler">>;
	using Dot = doir::lex::heads::token<LexerTokens::Dot, doir::lex::heads::exact_character<'.'>>;
	using True = doir::lex::heads::token<LexerTokens::True, doir::lex::heads::exact_string<"true">>;
	using False = doir::lex::heads::token<LexerTokens::False, doir::lex::heads::exact_string<"false">>;
	using NodotIdentifier = doir::lex::heads::token<LexerTokens::NodotIdentifier, XIDIdentifierHead</*leading percent*/true>>;
	using BinaryNumber = doir::lex::heads::token<LexerTokens::BinaryNumber, doir::lex::heads::ctre_regex<R"_(0[bB]([01]+|[01]+\.|[01]*\.[01]+)([eE][+-]?[01]+)?)_">>;
	using DecimalNumber = doir::lex::heads::token<LexerTokens::DecimalNumber, doir::lex::heads::ctre_regex<R"_(([0-9]+|[0-9]+\.|[0-9]*\.[0-9]+)([eE][+-]?[0-9]+)?)_">>;
	using HexadecimalNumber = doir::lex::heads::token<LexerTokens::HexadecimalNumber, doir::lex::heads::ctre_regex<R"_(0[xX]([0-9A-F]+|[0-9A-F]+\.|[0-9A-F]*\.[0-9A-F]+)(e[+-]?[0-9A-F]+)?)_">>;
	using String = doir::lex::heads::token<LexerTokens::String, doir::lex::heads::ctre_regex<R"_("(\\"|[^"])*"?)_">>;
	using Character = doir::lex::heads::token<LexerTokens::Character, doir::lex::heads::ctre_regex<R"_((\\'|[^']))_">>;
	using Documentation = doir::lex::heads::token<LexerTokens::Documentation, doir::lex::heads::ctre_regex<R"_((/\*\*(.*?)\*/))_">>;
	using SkipComment = doir::lex::heads::skip<doir::lex::heads::ctre_regex<R"_((//[^\n]*\n)|(/\*(.*?)\*/))_">>;
	using Filename = doir::lex::heads::token<LexerTokens::Filename, doir::lex::heads::ctre_regex<R"_([^:]+?)_">>;

	#define EVERGREEN_HEADS heads::Colen, heads::Equals, heads::External, heads::Or, heads::OpenParen, heads::CloseParen, heads::Auto,\
		heads::Type, heads::Block, heads::OpenAngle, heads::CloseAngle, heads::Comma, heads::Pointer, heads::FatPointer, heads::Const,\
		heads::Constant, heads::Implicit, heads::Dot, heads::Ellipses, heads::Dash, heads::OpenBrace, heads::CloseBrace, heads::If, heads::Else,\
		heads::Inline, heads::NoInline, heads::Comptime, heads::NoComptime, heads::Terminating, heads::Assembler, heads::True, heads::False,\
		heads::BinaryNumber, heads::DecimalNumber, heads::HexadecimalNumber, heads::String, heads::Character, heads::Documentation
}

constexpr doir::lex::lexer<EVERGREEN_HEADS, heads::SkipWhitespace, heads::SkipComment, heads::NodotIdentifier> lexer;
constexpr doir::lex::lexer<EVERGREEN_HEADS, heads::NodotIdentifier> lexerIdentifier;
constexpr doir::lex::lexer<heads::Semicolon, heads::Newline, EVERGREEN_HEADS, heads::SkipWhitespaceSingle, heads::SkipComment, heads::NodotIdentifier> lexerTerminal;



struct parse {
	// start = top_level
	// top_level = expression*
	// expression = documentation? identifier (":" type?)? "=" (constant | identifier | block | function_call | if | compound | type_block | "external") terminator
	// type = type_impl | (type "|" type_impl) | ("(" type ")")
	// type_impl = ("auto" | "type" | "block" | identifier) ("<" (type | constant) ("," (type | constant))* ">" | "(" (function_parameter ("," function_parameter)*)? ")" function_modifiers | "*" ("const" | "constant")? | "[*]" ("const" | "constant")? )*
	// function_parameter = "implicit"? type "..."? (nodot_identifier | ":" "implicit"? type "..."?) // NOTE: This grammar allows illegal parameter definitions, since if a `:` is present the leading `implicit` and `...` are invalid and the only valid path through type is one which results in a nodot_identifier

	// terminator = source_location? (";" | "\n") source_location?
	// source_location = ("<" (filename ":")? decimal_number ":" decimal_number ("-" decimal_number)? ">")?

	// block = "{" (expression)+ "}"
	// function_call = identifier "(" ((type | compound) ("," (type | compound))* )?  ")" function_modifiers block*
	// if = "if" (nodot_identifier | "(" nodot_identifier ")") block "else" (block | if)
	// compound = "block" block
	// type_block = "type" "{" (documentation? nodot_identifier ":" type ("=" constant)? terminator)* "}"

	// function_modifiers = ("inline" | "noinline" | "comptime" | "nocomptime" | "terminating" | "assembler")*
	// identifier = nodot_identifier ("." nodot_identifier)* // NOTE: Whitespace and comments are not cannonically allowed between identifiers and their dots, implementations may allow it however
	// constant = number | string | "true" | "false" | ("{" (constant ("," constant)* )? "}")
	// number = binary_number | decimal_number | hexadecimal_number | character
};

int main() {
	std::cout << "Hello World" << std::endl;
}