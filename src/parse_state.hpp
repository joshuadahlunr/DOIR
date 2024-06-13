#pragma once

#include "core.hpp"
#include "lexer.hpp"
#include <string_view>

namespace doir {

	struct ParseState {
		lex::lexer_generic_result lexer_state;
		NamedSourceLocation source_location;

		ParseState(std::string_view remaining = {}, NamedSourceLocation location = {}) : source_location(location) {
			lexer_state.remaining = remaining;
		}
		ParseState(const lex::lexer_generic_result& lexer_result, const NamedSourceLocation& location) : lexer_state(lexer_result), source_location(location) {}

		ParseState save_state() {
			return *this;
		}
		void restore_state(ParseState saved) {
			*this = saved;
		}

		static NamedSourceLocation update_location_from_lexem(std::string_view lexeme, const ParseState& state) {
			auto location = state.source_location;
			if(lexeme.empty()) return location;
			for(size_t i = 0, traversed = lexeme.data() - state.lexer_state.lexeme.data(); i < traversed; i++) { // TODO: Is there a way to implement this without having to double iterate?
				auto c = state.lexer_state.lexeme.data()[i];
				if(c == '\n')
					location.next_line();
				else location.column++;
			}
			return location;
		}
		NamedSourceLocation& update_location_from_lexem(std::string_view lexeme) { 
			return source_location = update_location_from_lexem(lexeme, *this); 
		}
		NamedSourceLocation update_location_from_lexem(std::string_view lexeme, bool dontMutate = true) const { 
			return update_location_from_lexem(lexeme, *this); 
		}

		static ParseState lookahead(/*doir::lex::detail::instantiation_of_lexer<doir::lex::basic_lexer>*/ auto& lexer, const ParseState& state) {
			auto res = lexer.lex(state.lexer_state);
			if(res.lexeme.empty() || state.lexer_state.lexeme.empty()) return {res, state.source_location};
			auto location = update_location_from_lexem(res.lexeme, state);
			return {res, location};
		}
		ParseState lookahead(/*doir::lex::detail::instantiation_of_lexer<doir::lex::basic_lexer>*/ auto& lexer) { return lookahead(lexer, *this); }

		ParseState& lex(/*doir::lex::detail::instantiation_of_lexer<doir::lex::basic_lexer>*/ auto& lexer, const ParseState& state) {
			return *this = lookahead(lexer, state);
		}
		ParseState& lex(/*doir::lex::detail::instantiation_of_lexer<doir::lex::basic_lexer>*/ auto& lexer) { return lex(lexer, *this); }

		static Token make_token(const ParseState& state, Module& module) {
			if(!state.lexer_state.valid()) return 0;
			auto t = module.make_token();
			module.add_attribute<Lexeme>(t) = *Lexeme::from_view(module.buffer, state.lexer_state.lexeme);
			module.add_attribute<NamedSourceLocation>(t) = state.source_location;
			return t;
		}
		Token make_token(Module& module) const { return make_token(*this, module); }

		template<typename Terror>
		static Token make_error(const ParseState& state, Module& module, Terror&& error) {
			Token t = 0;
			module.add_attribute<Terror>(t) = error;
			if(!state.lexer_state.valid()) return t;

			module.add_attribute<Lexeme>(t) = *Lexeme::from_view(module.buffer, state.lexer_state.lexeme);
			module.add_attribute<NamedSourceLocation>(t) = state.source_location;
			return t;
		}
		template<typename Terror>
		Token make_error(Module& module, Terror&& error) const { return make_error<Terror>(*this, module, std::move(error)); }
		Token make_error(Module& module) const { return make_error<doir::Error>(module, {"An error has occurred!"}); }

		Token lex_and_make_token(/*doir::lex::detail::instantiation_of_lexer<doir::lex::basic_lexer>*/ auto& lexer, const ParseState& state, Module& module) {
			lex(lexer, state);
			return make_token(state, module);
		}
		Token lex_and_make_token(/*doir::lex::detail::instantiation_of_lexer<doir::lex::basic_lexer>*/ auto& lexer, Module& module) {
			return lex_and_make_token(lexer, *this, module);
		}

		template<typename Token>
		static Token current_lexer_token(const ParseState& state) { return state.lexer_state.token<Token>(); }
		template<typename Token>
		Token current_lexer_token() const { return current_lexer_token<Token>(*this); }
	};

	struct ParseModule: public Module, public ParseState {
		ParseModule(const std::string& buffer = "", NamedSourceLocation location = {}) : Module(buffer), ParseState(this->buffer, location) {}

		Token make_token(const ParseState& state) { return ParseState::make_token(state, *this); }
		Token make_token() { return ParseState::make_token(*this); }

		template<typename Terror>
		Token make_error(const ParseState& state, Terror&& error) { return ParseState::make_error(state, *this, std::move(error)); }
		template<typename Terror>
		Token make_error(Terror&& error) { return ParseState::make_error(*this, std::move(error)); }
		Token make_error() { return ParseState::make_error(*this); }

		Token lex_and_make_token(/*doir::lex::detail::instantiation_of_lexer<doir::lex::basic_lexer>*/ auto& lexer, const ParseState& state) {
			return ParseState::lex_and_make_token(lexer, state, *this);
		}
		Token lex_and_make_token(/*doir::lex::detail::instantiation_of_lexer<doir::lex::basic_lexer>*/ auto& lexer) {
			return ParseState::lex_and_make_token(lexer, *this);
		}
	};

}