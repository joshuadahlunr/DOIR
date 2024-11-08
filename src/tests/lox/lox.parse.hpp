#pragma once

#include <tracy/Tracy.hpp>
#define LEXER_CTRE_REGEX
#include "../../core.hpp"
#include "../../parse_state.hpp"
#include "../../unicode_identifier_head.hpp"
#include "../../diagnostics.hpp"

#include "../tests.utils.hpp"

// https://spec.json5.org/#grammar

namespace lox {

	enum LexerTokens {
		Whitespace = 0,
		Class, // "class"
		OpenCurly, // "{"
		CloseCurly, // "}"
		Fun, // "fun"
		Var, // "var"
		Assign, // "="
		Semicolon, // ";"
		OpenParenthesis, // "("
		CloseParenthesis, // ")"
		Comma, // ","
		For, // "for"
		If, // "if"
		Else, // "else"
		Print, // "print"
		Return, // "return"
		While, // "while"
		Dot, // "."
		Or, // "or"
		And, // "and"
		Equal, // "=="
		NotEqual, // "!="
		Less, // "<"
		Greater, // ">"
		LessEqual, // "<="
		GreaterEqual, // ">="
		Plus, // "+"
		Minus, // "-"
		Multiply, // "*"
		Divide, // "/"
		Not, // "!"
		True, // "true"
		False, // "false"
		Nil, // "nil"
		This, // "this"
		Super, // "super"
		Number, // \d+ ( "." \d+ )? ;
		String, // "\"" <any char except "\"">* "\"" ;
		Identifier, // XIDIdentifier
	};

	constexpr doir::lex::lexer<
		doir::lex::heads::token<LexerTokens::OpenCurly, doir::lex::heads::exact_character<'{'>>, // "{"
		doir::lex::heads::token<LexerTokens::CloseCurly, doir::lex::heads::exact_character<'}'>>, // "}"
		doir::lex::heads::token<LexerTokens::Assign, doir::lex::heads::exact_character<'='>>, // "="
		doir::lex::heads::token<LexerTokens::Semicolon, doir::lex::heads::exact_character<';'>>, // ";"
		doir::lex::heads::token<LexerTokens::OpenParenthesis, doir::lex::heads::exact_character<'('>>, // "("
		doir::lex::heads::token<LexerTokens::CloseParenthesis, doir::lex::heads::exact_character<')'>>, // ")"
		doir::lex::heads::token<LexerTokens::Comma, doir::lex::heads::exact_character<','>>, // ","
		doir::lex::heads::token<LexerTokens::Dot, doir::lex::heads::exact_character<'.'>>, // "."
		doir::lex::heads::token<LexerTokens::Plus, doir::lex::heads::exact_character<'+'>>, // "+"
		doir::lex::heads::token<LexerTokens::Minus, doir::lex::heads::exact_character<'-'>>, // "-"
		doir::lex::heads::token<LexerTokens::Multiply, doir::lex::heads::exact_character<'*'>>, // "*"
		doir::lex::heads::token<LexerTokens::Divide, doir::lex::heads::exact_character<'/'>>, // "/"
		doir::lex::heads::token<LexerTokens::Not, doir::lex::heads::exact_character<'!'>>, // "!"
		doir::lex::heads::token<LexerTokens::Less, doir::lex::heads::exact_character<'<'>>, // "<"
		doir::lex::heads::token<LexerTokens::Greater, doir::lex::heads::exact_character<'>'>>, // ">"
		doir::lex::heads::token<LexerTokens::String, doir::lex::heads::exact_character<'"'>>, // Needed to ensure that a string is still valid while parsing its opening quote
		doir::lex::heads::token<LexerTokens::If, doir::lex::heads::exact_string<"if">>, // "if"
		doir::lex::heads::token<LexerTokens::Or, doir::lex::heads::exact_string<"or">>, // "or"
		doir::lex::heads::token<LexerTokens::Equal, doir::lex::heads::exact_string<"==">>, // "=="
		doir::lex::heads::token<LexerTokens::NotEqual, doir::lex::heads::exact_string<"!=">>, // "!="
		doir::lex::heads::token<LexerTokens::LessEqual, doir::lex::heads::exact_string<"<=">>, // "<="
		doir::lex::heads::token<LexerTokens::GreaterEqual, doir::lex::heads::exact_string<">=">>, // ">="
		doir::lex::heads::token<LexerTokens::Fun, doir::lex::heads::exact_string<"fun">>, // "fun"
		doir::lex::heads::token<LexerTokens::Var, doir::lex::heads::exact_string<"var">>, // "var"
		doir::lex::heads::token<LexerTokens::For, doir::lex::heads::exact_string<"for">>, // "for"
		doir::lex::heads::token<LexerTokens::And, doir::lex::heads::exact_string<"and">>, // "and"
		doir::lex::heads::token<LexerTokens::Nil, doir::lex::heads::exact_string<"nil">>, // "nil"
		doir::lex::heads::token<LexerTokens::Else, doir::lex::heads::exact_string<"else">>, // "else"
		doir::lex::heads::token<LexerTokens::Print, doir::lex::heads::exact_string<"print">>, // "print"
		doir::lex::heads::token<LexerTokens::Return, doir::lex::heads::exact_string<"return">>, // "return"
		doir::lex::heads::token<LexerTokens::While, doir::lex::heads::exact_string<"while">>, // "while"
		doir::lex::heads::token<LexerTokens::Class, doir::lex::heads::exact_string<"class">>, // "class"
		doir::lex::heads::token<LexerTokens::True, doir::lex::heads::exact_string<"true">>, // "true"
		doir::lex::heads::token<LexerTokens::False, doir::lex::heads::exact_string<"false">>, // "false"
		doir::lex::heads::token<LexerTokens::This, doir::lex::heads::exact_string<"this">>, // "this"
		doir::lex::heads::token<LexerTokens::Super, doir::lex::heads::exact_string<"super">>, // "super"
		doir::lex::heads::token<LexerTokens::Number, doir::lex::heads::ctre_regex<"\\d+(\\.\\d*)?">>, // \d+ ( "." \d+ )? ;
		doir::lex::heads::token<LexerTokens::String, doir::lex::heads::ctre_regex<"\\\"[^\"]*(\\\")?">>, // "\"" <any char except "\"">* "\"" ;
		doir::lex::heads::skip<doir::lex::heads::whitespace>, // Skip whitespace!
		doir::lex::heads::skip<doir::lex::heads::c_style_single_line_comment>, // Skip comments!
		doir::lex::heads::token<LexerTokens::Identifier, XIDIdentifierHead<false>>
	> lexer;

	namespace components {
		struct Null {};
		struct Variable {};
		struct Function {};
		struct String {};
		struct Literal {};

		struct Block {
			doir::Token parent; std::vector<doir::Token> children;
			static void swap_entities(Block& b, ecs::entity eA, ecs::entity eB) {
				if(b.parent == eA) b.parent = eB;
				else if(b.parent == eB) b.parent = eA;

				for(auto& child: b.children)
					if(child == eA) child = eB;
					else if(child == eB) child = eA;
			}
		};
		using Call = Block; // TODO: How bad of an idea is it for calls to reuse block's storage?
		struct TrailingCall {};

		struct VariableDeclaire {
			doir::Lexeme name;
			doir::Token parent; // Parent block
			bool operator==(const VariableDeclaire& o) const {
				return parent == o.parent && name.view(doir::hash_lookup_module->buffer)
					== o.name.view(doir::hash_lookup_module->buffer);
			}
			static void swap_entities(VariableDeclaire& decl, ecs::entity eA, ecs::entity eB) {
				if(decl.parent == eA) decl.parent = eB;
				else if(decl.parent == eB) decl.parent = eA;
			}
		};
		struct FunctionDeclaire {
			doir::Lexeme name;
			doir::Token parent; // Parent block
			bool operator==(const FunctionDeclaire& o) const {
				return parent == o.parent && name.view(doir::hash_lookup_module->buffer)
					== o.name.view(doir::hash_lookup_module->buffer);
			}
			static void swap_entities(FunctionDeclaire& decl, ecs::entity eA, ecs::entity eB) {
				if(decl.parent == eA) decl.parent = eB;
				else if(decl.parent == eB) decl.parent = eA;
			}
		};
		struct BodyMarker {
			doir::Token skipTo;
			static void swap_entities(BodyMarker& mark, ecs::entity eA, ecs::entity eB) {
				if(mark.skipTo == eA) mark.skipTo = eB;
				else if(mark.skipTo == eB) mark.skipTo = eA;
			}
		};
		struct ParameterDeclaire {
			doir::Lexeme name;
			doir::Token parent; // Parent function
			bool operator==(const ParameterDeclaire& o) const {
				return parent == o.parent && name.view(doir::hash_lookup_module->buffer)
					== o.name.view(doir::hash_lookup_module->buffer);
			}
			static void swap_entities(ParameterDeclaire& decl, ecs::entity eA, ecs::entity eB) {
				if(decl.parent == eA) decl.parent = eB;
				else if(decl.parent == eB) decl.parent = eA;
			}
		};
		struct Parameters : public std::vector<doir::Token> {
			using std::vector<doir::Token>::vector;
			static void swap_entities(Parameters& params, ecs::entity eA, ecs::entity eB) {
				for(auto& param: params)
					if(param == eA) param = eB;
					else if(param == eB) param = eA;
			}
		};

		struct Operation {
			doir::Token left = 0, right = 0;
			static void swap_entities(Operation& op, ecs::entity eA, ecs::entity eB) {
				if(op.left == eA) op.left = eB;
				else if(op.left == eB) op.left = eA;

				if(op.right == eA) op.right = eB;
				else if(op.right == eB) op.right = eA;
			}
		};
		struct OperationIf : public std::array<doir::Token, 4> { // Condition, Then, Else, Marker
			static void swap_entities(OperationIf& op, ecs::entity eA, ecs::entity eB) {
				for(auto& child: op)
					if(child == eA) child = eB;
					else if(child == eB) child = eA;
			}
		};

		struct Not {};
		struct Negate {};
		struct Divide {};
		struct Multiply {};
		struct Add {};
		struct Subtract {};
		struct LessThan {};
		struct GreaterThan {};
		struct LessThanEqualTo {};
		struct GreaterThanEqualTo {};
		struct EqualTo {};
		struct NotEqualTo {};
		struct And {};
		struct Or {};
		struct Assign {};
		struct Print {};
		struct Return {};
		struct While {};
		struct If {};
	}
	namespace comp = components;

	// program ::= declaration* EOF;
	//
	// declaration ::= classDecl | funDecl | varDecl | statement;
	// classDecl ::= "class" IDENTIFIER ( "<" IDENTIFIER )? "{" function* "}";
	// funDecl ::= "fun" function;
	// varDecl ::= "var" IDENTIFIER ( "=" expression )? ";";
	//
	// function ::= IDENTIFIER "(" parameters? ")" block;
	// parameters ::= IDENTIFIER ( "," IDENTIFIER )*;
	// arguments ::= expression ( "," expression )*;
	//
	// statement ::= exprStmt | forStmt | ifStmt | printStmt | returnStmt | whileStmt | block;
	// exprStmt ::= expression ";";
	// forStmt ::= "for" "(" ( varDecl | exprStmt | ";" ) expression? ";" expression? ")" statement;
	// ifStmt ::= "if" "(" expression ")" statement ( "else" statement )?;
	// printStmt ::= "print" expression ";";
	// returnStmt ::= "return" expression? ";";
	// whileStmt ::= "while" "(" expression ")" statement;
	// block ::= "{" declaration* "}";
	//
	// expression ::= assignment;
	// assignment ::= ( call "." )? IDENTIFIER "=" assignment | logic_or;
	// logic_or ::= logic_and ( "or" logic_and )*;
	// logic_and ::= equality ( "and" equality )*;
	// equality ::= comparison ( ( "!=" | "==" ) comparison )*;
	// comparison ::= term ( ( ">" | ">=" | "<" | "<=" ) term )*;
	// term ::= factor ( ( "-" | "+" ) factor )*;
	// factor ::= unary ( ( "/" | "*" ) unary )*;
	// unary ::= ( "!" | "-" ) unary | call;
	// call ::= primary ( "(" arguments? ")" | "." IDENTIFIER )*;
	// primary ::= "true" | "false" | "nil" | "this"
	//			| NUMBER | STRING | IDENTIFIER | "(" expression ")"
	//			| "super" "." IDENTIFIER;
	struct parse {
		#define PROPAGATE_ERROR(t) if(module.has_attribute<doir::Error>(t)) return t
		#define PROPAGATE_OPTIONAL_ERROR(expect) if(auto e = expect; e) return *e

		doir::Token currentBlock = 0;

		comp::Block& make_block(doir::ParseModule& module) {
			ZoneScoped;
			doir::Token parent = currentBlock;
			currentBlock = module.make_token();
			return module.add_attribute<comp::Block>(currentBlock) = {.parent = parent};
		}

		void declaire_builtin_functions(doir::ParseModule& module) {
			auto& block = *module.get_attribute<components::Block>(currentBlock);
			module.buffer += "\n"; // Make sure our scratch space doesn't show up in any diagnostics

			auto clock = module.make_token(true);
			{
				constexpr std::string_view str = "clock";
				*module.get_attribute<doir::Lexeme>(clock) = {module.buffer.size(), str.size()};
				module.buffer += str;
			}
			module.add_hashtable_attribute<components::FunctionDeclaire>(clock) = {*module.get_attribute<doir::Lexeme>(clock), currentBlock};
			module.add_attribute<comp::Parameters>(clock) = {};
			module.add_attribute<comp::Operation>(clock) = {doir::InvalidToken, false}; // .right stores weather or not the function is currently being called
			block.children.emplace_back(clock);
		}

		// program ::= declaration* EOF;
		doir::Token start(doir::ParseModule& module) {
			ZoneScoped;
			if(module.lexer_state.lexeme.empty()) module.lex(lexer);

			// comp::Block& topBlock = make_block(module);
			make_block(module);
			doir::Token topBlock = currentBlock;

			std::optional<doir::Token> error;
			do {
				doir::Token decl = declaration(module);
				if(module.has_attribute<doir::Error>(decl)) {
					error = decl;
					doir::print_diagnostic(module, decl) << std::endl;

					// Synchronize (Skip to the next statement or block)
					while(module.has_more_input()){
						if(module.lexer_state.remaining[0] == '\n')
							module.source_location.next_line();
						else ++module.source_location.column;
						module.lexer_state.remaining = module.lexer_state.remaining.substr(1);

						auto saved = module.save_state();
						module.lex(lexer);
						if(module.current_lexer_token<LexerTokens>() == LexerTokens::Semicolon || module.current_lexer_token<LexerTokens>() == LexerTokens::CloseCurly)
							break;
						module.restore_state(saved);
					}
				} else {
					auto& tb = *module.get_attribute<components::Block>(topBlock);
					tb.children.emplace_back(decl);
					module.lex(lexer);
				}
			} while(module.has_more_input());
			PROPAGATE_OPTIONAL_ERROR(error);
			declaire_builtin_functions(module);
			return currentBlock;
		}

		// declaration ::= classDecl | funDecl | varDecl | statement;
		doir::Token declaration(doir::ParseModule& module) {
			ZoneScoped;
			if(!module.lexer_state.valid()) return module.make_error();
			switch(module.current_lexer_token<LexerTokens>()) {
			case Class: return classDecl(module);
			case Fun: return funDecl(module);
			case Var: return varDecl(module);
			default: return statement(module);
			}
		}
		// classDecl ::= "class" IDENTIFIER ( "<" IDENTIFIER )? "{" function* "}";
		doir::Token classDecl(doir::ParseModule& module) {
			ZoneScoped;
			PROPAGATE_OPTIONAL_ERROR(module.expect_and_lex(lexer, LexerTokens::Class));
			return module.make_error<doir::Error>({"Classes not yet supported!"});
		}

		// funDecl ::= "fun" function;
		doir::Token funDecl(doir::ParseModule& module) {
			ZoneScoped;
			PROPAGATE_OPTIONAL_ERROR(module.expect_and_lex(lexer, LexerTokens::Fun));
			return function(module);
		}

		// function ::= IDENTIFIER "(" parameters? ")" block;
		doir::Token function(doir::ParseModule& module) {
			ZoneScoped;
			auto t = module.make_token();
			PROPAGATE_OPTIONAL_ERROR(module.expect_and_lex(lexer, LexerTokens::Identifier));
			PROPAGATE_OPTIONAL_ERROR(module.expect_and_lex(lexer, LexerTokens::OpenParenthesis));

			comp::Parameters params;
			if(module.current_lexer_token<LexerTokens>() != LexerTokens::CloseParenthesis) {
				params = parameters(module, t);
				if(params.size() == 1 && module.has_attribute<doir::Error>(params[0]))
					return params[0];
				// module.lex(lexer);
			}

			PROPAGATE_OPTIONAL_ERROR(module.expect_and_lex(lexer, LexerTokens::CloseParenthesis));
			auto body = block(module, t); PROPAGATE_ERROR(body);

			module.add_hashtable_attribute<comp::FunctionDeclaire>(t) = {*module.get_attribute<doir::Lexeme>(t), currentBlock};
			module.add_attribute<comp::Parameters>(t) = params;
			module.add_attribute<comp::Operation>(t) = {body, false}; // .right stores weather or not the function is currently being called
			return t;
		}

		// parameters ::= IDENTIFIER ( "," IDENTIFIER )*;
		comp::Parameters parameters(doir::ParseModule& module, doir::Token function) {
			ZoneScoped;
			comp::Parameters params;
			do {
				doir::Token t = module.make_token();
				if(auto e = module.expect_and_lex(lexer, LexerTokens::Identifier); e) return {*e};

				params.emplace_back(t);
				module.add_hashtable_attribute<comp::ParameterDeclaire>(t) = {*module.get_attribute<doir::Lexeme>(t), function};

				if(module.current_lexer_token<LexerTokens>() != Comma) break;
				module.lex(lexer);
			} while(module.has_more_input());

			return params;
		}

		// arguments ::= expression ( "," expression )*;
		comp::Parameters arguments(doir::ParseModule& module) {
			ZoneScoped;
			comp::Parameters args;
			do {
				auto e = expression(module);
				if(module.has_attribute<doir::Error>(e)) {
					if(args.empty()) return args; // If the first expression fails, just assume there are no arguments!
					return {e};
				}
				args.emplace_back(e);

				if(module.has_attribute<doir::Error>(args.back())) return {args.back()};
				module.lex(lexer); // TODO: Do we need to lookahead here?
				if(module.current_lexer_token<LexerTokens>() != Comma) break;
				module.lex(lexer);
			} while(module.has_more_input());

			return args;
		}

		// varDecl ::= "var" IDENTIFIER ( "=" expression )? ";";
		doir::Token varDecl(doir::ParseModule& module) {
			ZoneScoped;
			PROPAGATE_OPTIONAL_ERROR(module.expect_and_lex(lexer, LexerTokens::Var));
			PROPAGATE_OPTIONAL_ERROR(module.expect(LexerTokens::Identifier));

			auto t = module.make_token();

			doir::Token defaultValue = 0;
			auto next = module.lookahead(lexer);
			if(module.current_lexer_token<LexerTokens>(next) == LexerTokens::Assign) {
				module.restore_state(next);
				PROPAGATE_OPTIONAL_ERROR(module.expect_and_lex(lexer, LexerTokens::Assign));

				defaultValue = expression(module); PROPAGATE_ERROR(defaultValue);
			}

			module.lex(lexer);
			PROPAGATE_OPTIONAL_ERROR(module.expect(LexerTokens::Semicolon));

			module.add_hashtable_attribute<comp::VariableDeclaire>(t) = {*module.get_attribute<doir::Lexeme>(t), currentBlock};
			if(defaultValue != 0)
				module.add_attribute<comp::Operation>(t) = {defaultValue};
			return t;
		}

		// statement ::= exprStmt | forStmt | ifStmt | printStmt | returnStmt | whileStmt | block;
		doir::Token statement(doir::ParseModule& module) {
			ZoneScoped;
			if(!module.lexer_state.valid()) return module.make_error();
			switch(module.current_lexer_token<LexerTokens>()) {
			case LexerTokens::For: return forStmt(module);
			case LexerTokens::If: return ifStmt(module);
			case LexerTokens::Print: return printStmt(module);
			case LexerTokens::Return: return returnStmt(module);
			case LexerTokens::While: return whileStmt(module);
			case LexerTokens::OpenCurly: return block(module);
			default: return exprStmt(module);
			}
		}

		// exprStmt ::= expression ";";
		doir::Token exprStmt(doir::ParseModule& module) {
			ZoneScoped;
			auto ret = expression(module); PROPAGATE_ERROR(ret);
			module.lex(lexer);
			PROPAGATE_OPTIONAL_ERROR(module.expect(LexerTokens::Semicolon));
			return ret;
		}

		// forStmt ::= "for" "(" ( varDecl | exprStmt | ";" ) expression? ";" expression? ")" statement;
		doir::Token forStmt(doir::ParseModule& module) {
			ZoneScoped;
			auto t = module.make_token();
			auto marker = module.make_token();
			PROPAGATE_OPTIONAL_ERROR(module.expect_and_lex(lexer, LexerTokens::For));
			PROPAGATE_OPTIONAL_ERROR(module.expect_and_lex(lexer, LexerTokens::OpenParenthesis));

			doir::Token preLoop = 0;
			switch(module.current_lexer_token<LexerTokens>()) {
			break; case Var: preLoop = varDecl(module); PROPAGATE_ERROR(preLoop);
			break; case Semicolon: {} // Do Nothing
			break; default: preLoop = exprStmt(module); PROPAGATE_ERROR(preLoop);
			}

			PROPAGATE_OPTIONAL_ERROR(module.expect_and_lex(lexer, Semicolon));

			doir::Token condition = 0;
			if(module.current_lexer_token<LexerTokens>() != Semicolon) {
				condition = expression(module); PROPAGATE_ERROR(condition);
				module.lex(lexer);
			}

			PROPAGATE_OPTIONAL_ERROR(module.expect_and_lex(lexer, Semicolon));

			doir::Token postLoop = 0;
			if(module.current_lexer_token<LexerTokens>() != CloseParenthesis) {
				postLoop = expression(module); PROPAGATE_ERROR(postLoop);
				module.lex(lexer);
			}

			PROPAGATE_OPTIONAL_ERROR(module.expect_and_lex(lexer, CloseParenthesis));

			auto stmt = statement(module); PROPAGATE_ERROR(stmt);

			// Paste the pre loop before the loop (inside a new block so that declarations are properly scoped!)
			doir::Token wrappingBlock = 0;
			if(preLoop != 0) {
				wrappingBlock = module.make_token();
				module.add_attribute<comp::Block>(wrappingBlock).children = {preLoop, t};
			}

			// Make a while loop with the condition
			module.add_attribute<comp::While>(t);
			auto& loc = *module.get_attribute<doir::NamedSourceLocation>(t);
			auto& operation = module.add_attribute<comp::Operation>(t) = {.right = stmt};
			if(condition != 0)
				operation.left = condition;
			// If no condition provided then the condition is just "true"
			else {
				auto t = module.make_token();
				*module.get_attribute<doir::NamedSourceLocation>(t) = loc;
				module.add_attribute<bool>(t) = true;
				operation.left = t;
			}

			// Paste the post loop into the block (creating a block if one doesn't already exist)
			if(postLoop != 0) {
				if(module.has_attribute<comp::Block>(stmt))
					module.get_attribute<comp::Block>(stmt)->children.emplace_back(postLoop);
				else {
					auto t = module.make_token();
					*module.get_attribute<doir::NamedSourceLocation>(t) = *module.get_attribute<doir::NamedSourceLocation>(postLoop);
					module.add_attribute<comp::Block>(t).children = {stmt, postLoop};
					operation.right = t;
				}
			}

			components::Block* block;
			if(module.has_attribute<components::Block>(operation.right)) {
				block = &*module.get_attribute<components::Block>(operation.right);
			} else {
				auto b = module.make_token();
				block = &(module.add_attribute<components::Block>(b) = {currentBlock, {operation.right}});
				operation.right = b;
			}
			module.add_attribute<components::BodyMarker>(marker) = {t};
			block->children.insert(block->children.cbegin(), marker);

			if(wrappingBlock != 0) return wrappingBlock;
			return t;
		}

		// ifStmt ::= "if" "(" expression ")" statement ( "else" statement )?;
		doir::Token ifStmt(doir::ParseModule& module) {
			ZoneScoped;
			auto t = module.make_token();
			auto marker = module.make_token();
			PROPAGATE_OPTIONAL_ERROR(module.expect_and_lex(lexer, LexerTokens::If));
			PROPAGATE_OPTIONAL_ERROR(module.expect_and_lex(lexer, LexerTokens::OpenParenthesis));

			auto condition = expression(module); PROPAGATE_ERROR(condition);

			module.lex(lexer);
			PROPAGATE_OPTIONAL_ERROR(module.expect_and_lex(lexer, LexerTokens::CloseParenthesis));

			auto then = statement(module); PROPAGATE_ERROR(then);
			doir::Token Else = 0;

			auto next = module.lookahead(lexer);
			if(module.current_lexer_token<LexerTokens>(next) == LexerTokens::Else) {
				module.restore_state(next);
				module.lex(lexer);

				Else = statement(module); PROPAGATE_ERROR(Else);
			}

			module.add_attribute<components::BodyMarker>(marker) = {t};
			module.add_attribute<comp::If>(t);
			module.add_attribute<comp::OperationIf>(t) = {condition, then, Else, marker};
			return t;
		}

		// printStmt ::= "print" expression ";";
		doir::Token printStmt(doir::ParseModule& module) {
			ZoneScoped;
			auto t = module.make_token();
			PROPAGATE_OPTIONAL_ERROR(module.expect_and_lex(lexer, LexerTokens::Print));
			auto expr = expression(module); PROPAGATE_ERROR(expr);

			module.lex(lexer);
			PROPAGATE_OPTIONAL_ERROR(module.expect(LexerTokens::Semicolon));

			module.add_attribute<comp::Print>(t);
			module.add_attribute<comp::Operation>(t) = {expr};
			return t;
		}

		// returnStmt ::= "return" expression? ";";
		doir::Token returnStmt(doir::ParseModule& module) {
			ZoneScoped;
			auto t = module.make_token();
			module.add_attribute<comp::Return>(t);
			PROPAGATE_OPTIONAL_ERROR(module.expect_and_lex(lexer, LexerTokens::Return));
			if(module.current_lexer_token<LexerTokens>() == Semicolon) return t; // Since the expression is optional, bail out early if we see a semicolon!

			auto expr = expression(module); PROPAGATE_ERROR(expr);
			module.add_attribute<comp::Operation>(t) = {expr};

			module.lex(lexer);
			PROPAGATE_OPTIONAL_ERROR(module.expect(LexerTokens::Semicolon));
			return t;
		}

		// whileStmt ::= "while" "(" expression ")" statement;
		doir::Token whileStmt(doir::ParseModule& module) {
			ZoneScoped;
			auto t = module.make_token();
			auto marker = module.make_token();
			PROPAGATE_OPTIONAL_ERROR(module.expect_and_lex(lexer, LexerTokens::While));
			PROPAGATE_OPTIONAL_ERROR(module.expect_and_lex(lexer, LexerTokens::OpenParenthesis));

			auto condition = expression(module); PROPAGATE_ERROR(condition);

			module.lex(lexer);
			PROPAGATE_OPTIONAL_ERROR(module.expect_and_lex(lexer, LexerTokens::CloseParenthesis));

			auto stmt = statement(module); PROPAGATE_ERROR(stmt);

			components::Block* block;
			if(module.has_attribute<components::Block>(stmt)) {
				block = &*module.get_attribute<components::Block>(stmt);
			} else {
				auto b = module.make_token();
				block = &(module.add_attribute<components::Block>(b) = {currentBlock, {stmt}});
				stmt = b;
			}
			module.add_attribute<components::BodyMarker>(marker) = {t};
			block->children.insert(block->children.cbegin(), marker);

			module.add_attribute<comp::While>(t);
			module.add_attribute<comp::Operation>(t) = {condition, stmt};
			return t;
		}

		// block ::= "{" declaration* "}";
		doir::Token block(doir::ParseModule& module, doir::Token withFunctionMarker = false) {
			ZoneScoped;
			doir::Token oldBlock = currentBlock;
			// defer currentBlock = oldBlock;
			comp::Block& block = make_block(module);
			PROPAGATE_OPTIONAL_ERROR(module.expect_and_lex(lexer, LexerTokens::OpenCurly));

			if(withFunctionMarker) {
				doir::Token marker = module.make_token();
				module.add_attribute<components::BodyMarker>(marker) = {withFunctionMarker};
				block.children.emplace_back(marker);
			}

			while(module.current_lexer_token<LexerTokens>() != CloseCurly && module.has_more_input()) {
				doir::Token decl = declaration(module);
				if(module.has_attribute<doir::Error>(decl)) {
					currentBlock = oldBlock;
					return decl;
				}
				module.get_attribute<comp::Block>(currentBlock)->children.emplace_back(decl);
				module.lex(lexer);
			}

			doir::Token out = currentBlock;
			currentBlock = oldBlock;
			return out;
		}

		// expression ::= assignment;
		inline doir::Token expression(doir::ParseModule& module) {
			ZoneScoped;
			return assignment(module);
		}

		// assignment ::= ( call "." )? IDENTIFIER "=" assignment | logic_or;
		doir::Token assignment(doir::ParseModule& module) {
			ZoneScoped;
			auto impl = [this](doir::ParseModule& module) {
				ZoneScopedN("assignment::impl");
				auto saved = module.save_state();

				doir::Token parent = call(module);
				if(!module.has_attribute<doir::Error>(parent)) {
					module.lex(lexer);
					if(auto e = module.expect(LexerTokens::Dot, "Expected a `.`"); e) parent = *e;
				}
				if(module.has_attribute<doir::Error>(parent))
					module.restore_state(saved);

				PROPAGATE_OPTIONAL_ERROR(module.expect(LexerTokens::Identifier));
				auto t = module.make_token();
				// TODO: If var is set need to do something to handle the class!
				if(parent) return module.make_error<doir::Error>({"Classes are not yet supported!"});
				auto name = *module.get_attribute<doir::Lexeme>(t);

				module.lex(lexer);
				PROPAGATE_OPTIONAL_ERROR(module.expect_and_lex(lexer, LexerTokens::Assign));
				auto value = assignment(module); PROPAGATE_ERROR(value);

				module.add_attribute<comp::Assign>(t);
				module.add_attribute<doir::TokenReference>(t) = {name};
				module.add_attribute<comp::Operation>(t) = {value};
				return t;
			};

			if(!module.lexer_state.valid()) return module.make_error();
			auto saved = module.save_state();

			doir::Token assign = impl(module);
			if(module.has_attribute<doir::Error>(assign)) {
				module.restore_state(saved);
				auto chained = logic_or(module); PROPAGATE_ERROR(chained);
				return chained;
			}
			return assign;
		}

		// logic_or ::= logic_and ( "or" logic_and )*;
		doir::Token logic_or(doir::ParseModule& module) {
			ZoneScoped;
			doir::Token a = logic_and(module); PROPAGATE_ERROR(a);

			for(doir::ParseState peak = module.lookahead(lexer);
				module.current_lexer_token<LexerTokens>(peak) == LexerTokens::Or;
				peak = module.lookahead(lexer)
			) {
				module.restore_state(peak);

				auto t = module.make_token();
				auto marker = module.make_token();

				module.lex(lexer);
				doir::Token b = logic_and(module); PROPAGATE_ERROR(b);

				module.add_attribute<comp::BodyMarker>(marker) = {t};
				module.add_attribute<comp::OperationIf>(t) = {a, b, marker};
				module.add_attribute<comp::Or>(t);
				a = t;
			}
			return a;
		}

		// logic_and ::= equality ( "and" equality )*;
		doir::Token logic_and(doir::ParseModule& module) {
			ZoneScoped;
			doir::Token a = equality(module); PROPAGATE_ERROR(a);

			for(doir::ParseState peak = module.lookahead(lexer);
				module.current_lexer_token<LexerTokens>(peak) == LexerTokens::And;
				peak = module.lookahead(lexer)
			) {
				module.restore_state(peak);

				auto t = module.make_token();
				auto marker = module.make_token();

				module.lex(lexer);
				doir::Token b = equality(module); PROPAGATE_ERROR(b);

				module.add_attribute<comp::BodyMarker>(marker) = {t};
				module.add_attribute<comp::OperationIf>(t) = {a, b, marker};
				module.add_attribute<comp::And>(t);
				a = t;
			}
			return a;
		}

		// equality ::= comparison ( ( "!=" | "==" ) comparison )*;
		doir::Token equality(doir::ParseModule& module) {
			ZoneScoped;
			doir::Token a = comparison(module); PROPAGATE_ERROR(a);

			for(doir::ParseState peak = module.lookahead(lexer);
				module.current_lexer_token<LexerTokens>(peak) == LexerTokens::NotEqual
					|| module.current_lexer_token<LexerTokens>(peak) == LexerTokens::Equal;
				peak = module.lookahead(lexer)
			) {
				module.restore_state(peak);

				auto lexerToken = module.current_lexer_token<LexerTokens>();
				auto t = module.make_token();

				module.lex(lexer);
				doir::Token b = comparison(module); PROPAGATE_ERROR(b);

				module.add_attribute<comp::Operation>(t) = {a, b};
				if(lexerToken == LexerTokens::Equal)
					module.add_attribute<comp::EqualTo>(t);
				else module.add_attribute<comp::NotEqualTo>(t);
				a = t;
			}
			return a;
		}

		// comparison ::= term ( ( ">" | ">=" | "<" | "<=" ) term )*;
		doir::Token comparison(doir::ParseModule& module) {
			ZoneScoped;
			doir::Token a = term(module); PROPAGATE_ERROR(a);

			for(doir::ParseState peak = module.lookahead(lexer);
				module.current_lexer_token<LexerTokens>(peak) == LexerTokens::Greater
					|| module.current_lexer_token<LexerTokens>(peak) == LexerTokens::GreaterEqual
					|| module.current_lexer_token<LexerTokens>(peak) == LexerTokens::Less
					|| module.current_lexer_token<LexerTokens>(peak) == LexerTokens::LessEqual;
				peak = module.lookahead(lexer)
			) {
				module.restore_state(peak);

				auto lexerToken = module.current_lexer_token<LexerTokens>();
				auto t = module.make_token();

				module.lex(lexer);
				doir::Token b = term(module); PROPAGATE_ERROR(b);

				module.add_attribute<comp::Operation>(t) = {a, b};
				switch (lexerToken) {
				break; case Less: module.add_attribute<comp::LessThan>(t);
				break; case LessEqual: module.add_attribute<comp::LessThanEqualTo>(t);
				break; case Greater: module.add_attribute<comp::GreaterThan>(t);
				break; case GreaterEqual: module.add_attribute<comp::GreaterThanEqualTo>(t);
				break; default: {} // Do nothing!
				}
				a = t;
			}
			return a;
		}

		// term ::= factor ( ( "-" | "+" ) factor )*;
		doir::Token term(doir::ParseModule& module) {
			ZoneScoped;
			doir::Token a = factor(module); PROPAGATE_ERROR(a);

			for(doir::ParseState peak = module.lookahead(lexer);
				module.current_lexer_token<LexerTokens>(peak) == LexerTokens::Plus
					|| module.current_lexer_token<LexerTokens>(peak) == LexerTokens::Minus;
				peak = module.lookahead(lexer)
			) {
				module.restore_state(peak);

				auto lexerToken = module.current_lexer_token<LexerTokens>();
				auto t = module.make_token();

				module.lex(lexer);
				doir::Token b = factor(module); PROPAGATE_ERROR(b);

				module.add_attribute<comp::Operation>(t) = {a, b};
				if(lexerToken == LexerTokens::Plus)
					module.add_attribute<comp::Add>(t);
				else module.add_attribute<comp::Subtract>(t);
				a = t;
			}
			return a;
		}

		// factor ::= unary ( ( "/" | "*" ) unary )*;
		doir::Token factor(doir::ParseModule& module) {
			ZoneScoped;
			doir::Token a = unary(module); PROPAGATE_ERROR(a);

			for(doir::ParseState peak = module.lookahead(lexer);
				module.current_lexer_token<LexerTokens>(peak) == LexerTokens::Divide
					|| module.current_lexer_token<LexerTokens>(peak) == LexerTokens::Multiply;
				peak = module.lookahead(lexer)
			) {
				module.restore_state(peak);

				auto lexerToken = module.current_lexer_token<LexerTokens>();
				auto t = module.make_token();

				module.lex(lexer);
				doir::Token b = unary(module); PROPAGATE_ERROR(b);

				module.add_attribute<comp::Operation>(t) = {a, b};
				if(lexerToken == LexerTokens::Multiply)
					module.add_attribute<comp::Multiply>(t);
				else module.add_attribute<comp::Divide>(t);
				a = t;
			}
			return a;
		}

		// unary ::= ( "!" | "-" ) unary | call;
		doir::Token unary(doir::ParseModule& module) {
			ZoneScoped;
			if(!module.lexer_state.valid()) return module.make_error();

			switch(module.current_lexer_token<LexerTokens>()) {
			break; case LexerTokens::Not: {
				doir::Token t = module.make_token();
				module.lex(lexer);
				doir::Token value = unary(module); PROPAGATE_ERROR(value);
				module.add_attribute<comp::Operation>(t) = {value};
				module.add_attribute<comp::Not>(t);
				return t;
			}
			break; case LexerTokens::Minus: {
				doir::Token t = module.make_token();
				module.lex(lexer);
				doir::Token value = unary(module); PROPAGATE_ERROR(value);
				module.add_attribute<comp::Operation>(t) = {value};
				module.add_attribute<comp::Negate>(t);
				return t;
			}
			break; default: return call(module);
			}
			return 0; // TODO: Why is this nessicary?
		}

		// call ::= primary ( "(" arguments? ")" | "." IDENTIFIER )*;
		doir::Token call(doir::ParseModule& module) {
			ZoneScoped;
			if(!module.lexer_state.valid()) return module.make_error();

			auto prim = primary(module);

			for(auto next = module.lookahead(lexer);
				module.current_lexer_token<LexerTokens>(next) == OpenParenthesis
					|| module.current_lexer_token<LexerTokens>(next) == Dot;
				next = module.lookahead(lexer)
			) {
				module.restore_state(next);
				if(module.current_lexer_token<LexerTokens>() == Dot) {
					return module.make_error<doir::Error>({"Classes are not yet supported!"});
				} else {
					if(module.has_attribute<components::Literal>(prim))
						return module.make_error<doir::Error>({"Can only call functions (Can't call literals)"});

					auto t = module.make_token();
					PROPAGATE_OPTIONAL_ERROR(module.expect_and_lex(lexer, LexerTokens::OpenParenthesis));

					auto args = arguments(module);
					if(args.size() == 1 && module.has_attribute<doir::Error>(args[0]))
						return args[0];

					PROPAGATE_OPTIONAL_ERROR(module.expect(LexerTokens::CloseParenthesis));

					module.add_attribute<comp::Function>(t);
					module.add_attribute<comp::Call>(t) = {prim, args};
					prim = t;
				}
			}

			return prim;
		}

		// primary ::= "true" | "false" | "nil" | "this"
		//			| NUMBER | STRING | IDENTIFIER | "(" expression ")"
		//			| "super" "." IDENTIFIER;
		doir::Token primary(doir::ParseModule& module) {
			ZoneScoped;
			if(!module.lexer_state.valid()) return module.make_error();

			switch (module.current_lexer_token<LexerTokens>()) {
			case LexerTokens::OpenParenthesis: {
				PROPAGATE_OPTIONAL_ERROR(module.expect_and_lex(lexer, LexerTokens::OpenParenthesis));
				auto ret = expression(module);

				module.lex(lexer);
				PROPAGATE_OPTIONAL_ERROR(module.expect(LexerTokens::CloseParenthesis));
				return ret;
			}
			case LexerTokens::Nil: {
				auto t = module.make_token();
				module.add_attribute<comp::Literal>(t);
				module.add_attribute<comp::Null>(t);
				return t;
			}
			case LexerTokens::True: {
				auto t = module.make_token();
				module.add_attribute<comp::Literal>(t);
				module.add_attribute<bool>(t) = true;
				return t;
			}
			case LexerTokens::False: {
				auto t = module.make_token();
				module.add_attribute<comp::Literal>(t);
				module.add_attribute<bool>(t) = false;
				return t;
			}
			case LexerTokens::String: {
				auto t = module.make_token();
				auto& lexem = *module.get_attribute<doir::Lexeme>(t);
				// Ensure the existence of the trailing quote
				if(std::ranges::count(lexem.view(module.buffer), '"') < 2)
					return module.make_error<doir::Error>({"Expected a terminating `\"`!"});
				module.add_attribute<comp::Literal>(t);
				module.add_attribute<comp::String>(t);

				// Remove the quotes from the token
				++lexem.start;
				lexem.length -= 2; // -1 just compensates for the start being pushed back one
				return t;
			}
			case LexerTokens::Number: {
				auto t = module.make_token();
				module.add_attribute<comp::Literal>(t);
				module.add_attribute<double>(t) = std::strtold(module.get_attribute<doir::Lexeme>(t)->view(module.buffer).data(), nullptr);
				return t;
			}
			case LexerTokens::This: [[fallthrough]];
			case LexerTokens::Identifier: {
				auto t = module.make_token();
				module.add_attribute<comp::Variable>(t);
				module.add_attribute<doir::TokenReference>(t) = *module.get_attribute<doir::Lexeme>(t);
				return t;
			}
			// case LexerTokens::Super: {
			// 	module.lex(lexer);
			// 	PROPAGATE_EXPECT_ERROR(module.expect_and_lex(lexer, LexerTokens::Dot));
			// 	PROPAGATE_EXPECT_ERROR(module.expect(LexerTokens::Identifier));

			// 	auto t = module.make_token();
			// 	module.add_attribute<Variable>(t);
			// 	module.add_attribute<doir::TokenReference>(t) = *module.get_attribute<doir::Lexeme>(t);
			// 	return t;
			// }
			default: return module.make_error<doir::Error>({"Unexpected token `" + std::to_string(module.current_lexer_token<LexerTokens>()) + "` detected!"});
			}
		}
	};
}

namespace fnv {
	template<>
	struct fnv1a_64<lox::comp::VariableDeclaire> {
		inline uint64_t operator()(const lox::comp::VariableDeclaire& v) {
			return fnv1a_64<std::string_view>{}(v.name.view(doir::hash_lookup_module->buffer))
				^ fnv1a_64<doir::Token>{}(v.parent);
		}
	};
	template<>
	struct fnv1a_64<lox::comp::FunctionDeclaire> {
		inline uint64_t operator()(const lox::comp::FunctionDeclaire& f) {
			return fnv1a_64<std::string_view>{}(f.name.view(doir::hash_lookup_module->buffer))
				^ fnv1a_64<doir::Token>{}(f.parent);
		}
	};
	template<>
	struct fnv1a_64<lox::comp::ParameterDeclaire> {
		inline uint64_t operator()(const lox::comp::ParameterDeclaire& p) {
			return fnv1a_64<std::string_view>{}(p.name.view(doir::hash_lookup_module->buffer))
				^ fnv1a_64<doir::Token>{}(p.parent);
		}
	};
}
