#pragma once

#ifdef DOIR_IMPLEMENTATION
	#define ECS_IMPLEMENTATION
#endif
#include "../thirdparty/ECS.hpp"
#include "../thirdparty/ECSquery.hpp"

#include <iostream>
#include <map>
#include <deque>

namespace doir {

	using ecs::optional_reference;
	using ecs::optional;

	using Token = ecs::entity;

	struct Module: protected ecs::scene {
		std::string buffer;

		Module(const std::string& buffer = "") : buffer(buffer) {
			assert(create_entity() == 0); // Reserve token 0 for errors!
		}

		size_t token_count() const { return size(); }

		Token make_token() { return create_entity(); }

		template<typename Tattr>
		Tattr& add_attribute(Token t) { return *add_component<Tattr>(t); }

		template<typename Tattr>
		ecs::optional_reference<Tattr> get_attribute(Token t) { return get_component<Tattr>(t); }
		template<typename Tattr>
		ecs::optional_reference<const Tattr> get_attribute(Token t) const { return get_component<Tattr>(t); }

		template<typename Tattr>
		bool has_attribute(Token t) const { return has_component<Tattr>(t); }

		template<typename... Tattrs>
		ecs::scene_view<Tattrs...> view() { return {*this}; }
	};


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

	struct Error {
		std::string message;

		// Probably want to add some checks for disabled exceptions around this!
		void Throw() { throw std::runtime_error(message); }
	};

	struct ParseModule: public Module {
		struct State {
			doir::lex::lexer_generic_result lexer;
			NamedSourceLocation location;
		} state;

		ParseModule(const std::string& buffer = "", NamedSourceLocation location = {}) : Module(buffer), state({}, location) {
			state.lexer.remaining = this->buffer;
		}

		auto save_state() {
			return state;
		}
		void restore_state(State saved) {
			state = saved;
		}

		static State lookahead(/*doir::lex::detail::instantiation_of_lexer<doir::lex::basic_lexer>*/ auto& lexer, const State& state) {
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
		State lookahead(/*doir::lex::detail::instantiation_of_lexer<doir::lex::basic_lexer>*/ auto& lexer) { return lookahead(lexer, this->state); }

		State& lex(/*doir::lex::detail::instantiation_of_lexer<doir::lex::basic_lexer>*/ auto& lexer, const State& state) {
			return this->state = lookahead(lexer, state);
		}
		State& lex(/*doir::lex::detail::instantiation_of_lexer<doir::lex::basic_lexer>*/ auto& lexer) { return lex(lexer, this->state); }

		Token make_token(const State& state) {
			if(!state.lexer.valid()) return 0;
			auto t = Module::make_token();
			size_t start = state.lexer.lexeme.data() - buffer.data();
			add_attribute<Lexeme>(t) = {start, state.lexer.lexeme.size()};
			add_attribute<NamedSourceLocation>(t) = state.location;
			return t;
		}
		Token make_token() { return make_token(this->state); }

		template<typename Terror>
		Token make_error(const State& state, Terror&& error) {
			Token t = 0;
			if(!state.lexer.valid()) return t;

			size_t start = state.lexer.lexeme.data() - buffer.data();
			add_attribute<Lexeme>(t) = {start, state.lexer.lexeme.size()};
			add_attribute<NamedSourceLocation>(t) = state.location;
			add_attribute<Terror>(t) = error;
			return t;
		}
		template<typename Terror>
		Token make_error(Terror&& error) { return make_error<Terror>(this->state, std::move(error)); }
		Token make_error() { return make_error<doir::Error>({"An error has occurred!"}); }

		Token lex_and_make_token(/*doir::lex::detail::instantiation_of_lexer<doir::lex::basic_lexer>*/ auto& lexer, const State& state) {
			lex(lexer, state);
			return make_token(state);
		}
		Token lex_and_make_token(/*doir::lex::detail::instantiation_of_lexer<doir::lex::basic_lexer>*/ auto& lexer) {
			return lex_and_make_token(lexer, this->state);
		}

		template<typename Token>
		Token current_lexer_token(const State& state) { return state.lexer.token<Token>(); }
		template<typename Token>
		Token current_lexer_token() { return current_lexer_token<Token>(this->state); }
	};



	using include_token = ecs::include_entity;
	using include_module = ecs::include_scene;

	template<typename... Tattrs>
	auto query(Module& module) {
		auto v = module.view<Tattrs...>();
		using View = decltype(v);
		return std::ranges::subrange<typename View::Iterator, typename View::Sentinel, std::ranges::subrange_kind::unsized>(v.begin(), v.end());
	}

	template<typename... Tattrs>
	auto query_with_token(Module& module) {
		auto v = module.view<include_token, Tattrs...>();
		using View = decltype(v);
		return std::ranges::subrange<typename View::Iterator, typename View::Sentinel, std::ranges::subrange_kind::unsized>(v.begin(), v.end());
	}
}