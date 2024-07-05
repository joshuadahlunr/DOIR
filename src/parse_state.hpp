#pragma once

#include "core.hpp"
#include "lexer.hpp"
#include <initializer_list>
#include <string_view>

namespace doir {

	struct ParseState {
		lex::lexer_generic_result lexer_state;
		NamedSourceLocation source_location;

		ParseState(std::string_view remaining = {}, NamedSourceLocation location = {}) : source_location(location) {
			lexer_state.remaining = remaining;
		}
		ParseState(const lex::lexer_generic_result& lexer_result, const NamedSourceLocation& location) : lexer_state(lexer_result), source_location(location) {}

		inline ParseState save_state() {
			return *this;
		}
		inline void restore_state(ParseState saved) {
			*this = saved;
		}

		inline static bool has_more_input(ParseState saved) {
			return !saved.lexer_state.remaining.empty();
		}
		inline bool has_more_input() {
			return has_more_input(*this);
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
		inline NamedSourceLocation& update_location_from_lexem(std::string_view lexeme) {
			return source_location = update_location_from_lexem(lexeme, *this);
		}
		inline NamedSourceLocation update_location_from_lexem(std::string_view lexeme, bool dontMutate = true) const {
			return update_location_from_lexem(lexeme, *this);
		}

		static ParseState lookahead(/*doir::lex::detail::instantiation_of_lexer<doir::lex::basic_lexer>*/ auto& lexer, const ParseState& state) {
			auto res = lexer.lex(state.lexer_state);
			if(res.lexeme.empty() || state.lexer_state.lexeme.empty()) return {res, state.source_location};
			auto location = update_location_from_lexem(res.lexeme, state);
			return {res, location};
		}
		inline ParseState lookahead(/*doir::lex::detail::instantiation_of_lexer<doir::lex::basic_lexer>*/ auto& lexer) { return lookahead(lexer, *this); }

		inline ParseState& lex(/*doir::lex::detail::instantiation_of_lexer<doir::lex::basic_lexer>*/ auto& lexer, const ParseState& state) {
			return *this = lookahead(lexer, state);
		}
		inline ParseState& lex(/*doir::lex::detail::instantiation_of_lexer<doir::lex::basic_lexer>*/ auto& lexer) { return lex(lexer, *this); }

		static Token make_token(const ParseState& state, Module& module) {
			if(!state.lexer_state.valid()) return 0;
			auto t = module.make_token();
			module.add_attribute<Lexeme>(t) = *Lexeme::from_view(module.buffer, state.lexer_state.lexeme);
			module.add_attribute<NamedSourceLocation>(t) = state.source_location;
			return t;
		}
		inline Token make_token(Module& module) const { return make_token(*this, module); }

		template<typename... Tattrs>
		static Token make_token_with(const ParseState& state, Module& module, Tattrs... attributes) {
			auto t = make_token(state, module);
			std::apply([module, t](Tattrs... elems){ ([module, t](auto&& elem) {
				using Tcomponent = decltype(elem);
				module.add_attribute<std::decay_t<Tcomponent>>(t) = elem;
				return true;
			}(elems) && ...); }, std::make_tuple(std::forward<Tattrs>(attributes)...));
			return t;
		}
		template<typename... Tattrs>
		inline Token make_token_with(Module& module, Tattrs... attributes) const { return make_token_with(*this, module, std::forward<Tattrs>(attributes)...); }

		template<typename Terror>
		static Token make_error(const ParseState& state, Module& module, Terror&& error) {
			Token t = 0;
			module.add_attribute<Terror>(t) = error;
			// if(!state.lexer_state.valid()) return t;

			module.add_attribute<Lexeme>(t) = *Lexeme::from_view(module.buffer, state.lexer_state.lexeme);
			module.add_attribute<NamedSourceLocation>(t) = state.source_location;
			return t;
		}
		template<typename Terror>
		inline Token make_error(Module& module, Terror&& error) const { return make_error<Terror>(*this, module, std::move(error)); }
		inline Token make_error(Module& module) const { return make_error<doir::Error>(module, {"An error has occurred!"}); }

		// Make a token with the current state and then lex the next lexer token
		inline Token make_token_and_lex(/*doir::lex::detail::instantiation_of_lexer<doir::lex::basic_lexer>*/ auto& lexer, const ParseState& state, Module& module) {
			lex(lexer, state);
			return make_token(state, module);
		}
		inline Token make_token_and_lex(/*doir::lex::detail::instantiation_of_lexer<doir::lex::basic_lexer>*/ auto& lexer, Module& module) {
			return make_token_and_lex(lexer, *this, module);
		}

		template<typename Token>
		inline static Token current_lexer_token(const ParseState& state) { return state.lexer_state.token<Token>(); }
		template<typename Token>
		inline Token current_lexer_token() const { return current_lexer_token<Token>(*this); }
	};

	struct ParseModule: public Module, public ParseState {
		ParseModule(const std::string& buffer = "", NamedSourceLocation location = {}) : Module(buffer), ParseState(this->buffer, location) {}

		inline Token make_token(const ParseState& state) { return ParseState::make_token(state, *this); }
		inline Token make_token() { return ParseState::make_token(*this); }

		template<typename... Tattrs>
		inline Token make_token_with(const ParseState& state, Tattrs... attributes) {
			return ParseState::make_token_with(state, *this, std::forward<Tattrs>(attributes)...);
		}
		template<typename... Tattrs>
		inline Token make_token_with(Tattrs... attributes) { return ParseState::make_token_with(*this, std::forward<Tattrs>(attributes)...); }

		template<typename Terror>
		inline Token make_error(const ParseState& state, Terror&& error) { return ParseState::make_error(state, *this, std::move(error)); }
		template<typename Terror>
		inline Token make_error(Terror&& error) { return ParseState::make_error(*this, std::move(error)); }
		inline Token make_error() { return ParseState::make_error(*this); }

		inline Token make_token_and_lex(/*doir::lex::detail::instantiation_of_lexer<doir::lex::basic_lexer>*/ auto& lexer, const ParseState& state) {
			return ParseState::make_token_and_lex(lexer, state, *this);
		}
		inline Token make_token_and_lex(/*doir::lex::detail::instantiation_of_lexer<doir::lex::basic_lexer>*/ auto& lexer) {
			return ParseState::make_token_and_lex(lexer, *this);
		}

		// Returns a token representing an error if the current lexer token doesn't match!
		template<typename Token, typename Error = doir::Error>
		inline std::optional<doir::Token> expect(Token what, std::string_view error = "Expected token not found") {
			if( !(lexer_state.valid() && current_lexer_token<Token>() == what) )
				return make_error<Error>({std::string(error)});

			return {};
		}

		template<typename Token, typename Error = doir::Error>
		inline std::optional<doir::Token> expect(std::initializer_list<Token> what, std::string_view error = "None of expected tokens found") {
			bool found = false;
			for(Token t: what) 
				if(current_lexer_token<Token>() == what) {
					found = true;
					break;
				}
				
			if(!lexer_state.valid() || !found)
				return make_error<Error>({std::string(error)});
			return {};
		}

		// Returns a token representing an error if the current lexer token doesn't match, lexes the next token if it does match
		template<typename Token, typename Error = doir::Error>
		inline std::optional<doir::Token> expect_and_lex(auto lexer, Token what, std::string_view error = "Expected token not found") {
			if(auto fail = expect<Token, Error>(what, error)) return fail;
			lex(lexer);
			return {};
		}
		template<typename Token, typename Error = doir::Error>
		inline std::optional<doir::Token> expect_and_lex(auto lexer, std::initializer_list<Token> what, std::string_view error = "Expected token not found") {
			if(auto fail = expect<Token, Error>(what, error)) return fail;
			lex(lexer);
			return {};
		}
	};
}