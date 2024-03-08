#pragma once

#include <bitset>
#include <algorithm>
#ifdef LEXER_CTRE_REGEX
	#include "ctre.hpp"
#endif

namespace lex {
	namespace detail {
		template<size_t N>
		struct string_literal {
			constexpr string_literal(const char (&str)[N]) {
				std::copy_n(str, N, value);
			}

			std::string_view view() { return {value, N}; }
			const std::string_view view() const { return {value, N}; }

			std::string runtime() { return std::string(view()); }
			const std::string runtime() const { return std::string(view()); }

			char value[N];
		};

		template<size_t N>
		size_t index_of_first_set(const std::bitset<N>& bits) {
			for(size_t i = 0; i < N; i++)
				if(bits[i]) return i;
			return std::string::npos;
		}

		// From: https://stackoverflow.com/a/29753388
		template<int N, typename... Ts>
		using nth_type = typename std::tuple_element<N, std::tuple<Ts...>>::type;

		// From: https://stackoverflow.com/a/11251408
		template < template <typename, size_t, typename> class Template, typename T >
		struct is_instantiation_of_token_head : std::false_type {};

		template < template <typename, size_t, typename> class Template, typename A1, size_t A2, typename A3 >
		struct is_instantiation_of_token_head< Template, Template<A1, A2, A3> > : std::true_type {};

		template<typename T, template <typename, size_t, typename> class Template>
		concept instantiation_of_token_head = is_instantiation_of_token_head<Template, T>::value;

		template < template <typename, typename> class Template, typename T >
		struct is_instantiation_of_skip_token_head : std::false_type {};

		template < template <typename, typename> class Template, typename A1, typename A2 >
		struct is_instantiation_of_skip_token_head< Template, Template<A1, A2> > : std::true_type {};

		template<typename T, template <typename, typename> class Template>
		concept instantiation_of_skip_token_head = is_instantiation_of_skip_token_head<Template, T>::value;
	}

	template<typename T, typename CharT>
	concept lexer_head = requires(T t, size_t index, CharT next, std::basic_string_view<CharT> token) {
		{ T::next_valid(index, next) } -> std::convertible_to<bool>;
		{ T::token_valid(token) } -> std::convertible_to<bool>;
		{ T::skip_if_invalid } -> std::convertible_to<bool>;
	};

	inline namespace heads {
		template<typename CharT>
		struct basic_null {
			constexpr static auto skip_if_invalid = true;
			static bool next_valid(size_t index, CharT next) { return false; }
			static bool token_valid(std::basic_string_view<CharT> token) { return false; }
		};
		using null = basic_null<char>;

		template<typename CharT, size_t Token, lexer_head<CharT> Head>
		struct basic_token {
			using head = Head;
			constexpr static size_t token = Token;
			constexpr static auto skip_if_invalid = head::skip_if_invalid;
			static bool next_valid(size_t index, CharT next) { return head::next_valid(index, next); }
			static bool token_valid(std::basic_string_view<CharT> token) { return head::token_valid(token); }
		};
		template<size_t Token, lexer_head<char> Head>
		using token = basic_token<char, Token, Head>;

		template<typename CharT, lexer_head<CharT> Head>
		struct basic_skip {
			using head = Head;
			constexpr static auto skip_if_invalid = head::skip_if_invalid;
			static bool next_valid(size_t index, CharT next) { return head::next_valid(index, next); }
			static bool token_valid(std::basic_string_view<CharT> token) { return head::token_valid(token); }
		};
		template<lexer_head<char> Head>
		using skip = basic_skip<char, Head>;

		template<typename CharT, detail::string_literal match>
		struct basic_exact_string {
			static constexpr bool skip_if_invalid = true;
			static bool next_valid(size_t index, CharT next) {
				return match.view()[index] == next;
			}
			static bool token_valid(std::basic_string_view<CharT> token) {
				return match.view() == token;
			}
		};
		template<detail::string_literal match>
		using exact_string = basic_exact_string<char, match>;

		template<typename CharT, detail::string_literal match>
		struct basic_case_insensitive_string {
			static constexpr bool skip_if_invalid = true;
			static bool next_valid(size_t index, CharT next) {
				return std::tolower(match.view()[index]) == std::tolower(next);
			}
			static bool token_valid(std::basic_string_view<CharT> token) {
				auto view = match.view();
				if(token.size() != view.size() && token.size() != view.size() - 1) return false;
				for(size_t i = 0; i < token.size(); i++)
					if(std::tolower(view[i]) != std::tolower(token[i])) return false;
				return true;
			}
		};
		template<detail::string_literal match>
		using case_insensitive_string = basic_case_insensitive_string<char, match>;

		template<typename CharT, size_t ID, bool View = false>
		struct basic_runtime_string {
			static std::conditional_t<View, std::string_view, std::string> match;
			static void set(std::string_view runtime) { match = std::conditional_t<View, std::string_view, std::string>{runtime}; }
			static void set(const std::string& runtime) { match = runtime; }
			static void reset() { match = ""; }

			static constexpr bool skip_if_invalid = true;
			static bool next_valid(size_t index, CharT next) {
				if(index >= match.size()) return false;
				return match[index] == next;
			}
			static bool token_valid(std::basic_string_view<CharT> token) {
				return match == token;
			}
		};
		template<size_t ID, bool View = false>
		using runtime_string = basic_runtime_string<char, ID, View>; // TODO: Do we need case insenstive versions? Do we need a char version?

		template<typename CharT, CharT match>
		struct basic_exact_character {
			static constexpr bool skip_if_invalid = true;
			static bool next_valid(size_t index, CharT next) {
				return index == 0 && match == next;
			}
			static bool token_valid(std::basic_string_view<CharT> token) {
				if(token.size() != 1) return false;
				return match == token[0];
			}
		};
		template<char match>
		using exact_character = basic_exact_character<char, match>;

		template<typename CharT, CharT match>
		struct basic_case_insensitive_character {
			static constexpr bool skip_if_invalid = true;
			static bool next_valid(size_t index, CharT next) {
				return index == 0 && std::tolower(match) == std::tolower(next);
			}
			static bool token_valid(std::basic_string_view<CharT> token) {
				if(token.size() != 1) return false;
				return std::tolower(match) == std::tolower(token[0]);
			}
		};
		template<char match>
		using case_insensitive_character = basic_case_insensitive_character<char, match>;

#ifdef LEXER_CTRE_REGEX
		template<typename CharT, ctll::fixed_string regex>
		struct basic_ctre_regex {
			static constexpr bool skip_if_invalid = false;
			static bool next_valid(size_t index, CharT next) {
				thread_local std::basic_string<CharT> buffer;
				if(index == 0) buffer.clear();
				buffer += next;
				return ctre::match<regex>(buffer);
			}
			static bool token_valid(std::basic_string_view<CharT> token) {
				return true;
			}
		};
		template<ctll::fixed_string regex>
		using ctre_regex = basic_ctre_regex<char, regex>;
#endif
	}

	template<typename CharT, lexer_head<CharT>... Heads>
	struct basic_lexer {
		struct result {
			using generic = basic_lexer<CharT, heads::basic_null<CharT>>::result;

			size_t head; // Which head parsed this result;
			std::basic_string_view<CharT> lexeme;
			std::basic_string_view<CharT> remaining;

			result(size_t head = 0, std::basic_string_view<CharT> lexeme = {}, std::basic_string_view<CharT> remaining = {})
				: head(head), lexeme(lexeme), remaining(remaining) {}
			result(const result&) = default;
			result(const generic& g) requires (!std::is_same_v<detail::nth_type<0, Heads...>, heads::basic_null<CharT>>)
				: head(g.head), lexeme(g.lexeme), remaining(g.remaining) {}
			result(result&&) = default;
			result(generic&& g) requires (!std::is_same_v<detail::nth_type<0, Heads...>, heads::basic_null<CharT>>)
				: head(g.head), lexeme(g.lexeme), remaining(g.remaining) {}
			result& operator=(const result&) = default;
			result& operator=(const generic& g) requires (!std::is_same_v<detail::nth_type<0, Heads...>, heads::basic_null<CharT>>) { return *this = result(g); }
			result& operator=(result&&) = default;
			result& operator=(generic&& g) requires (!std::is_same_v<detail::nth_type<0, Heads...>, heads::basic_null<CharT>>) { return *this = result(g); }

			template<std::convertible_to<size_t> Token>
			Token token() const { return (Token)head; }
			bool valid() const { return head != std::string::npos && !lexeme.empty(); }
			bool valid_or_end() const { return valid() || remaining.empty(); }

			operator generic() const { return generic{head, lexeme, remaining}; }
		};
	protected:
#ifdef LEXER_IS_STATEFULL
		std::bitset<sizeof...(Heads)> valid, lastValid;
#endif

		// If any of the heads are token_heads remap the returned result from the head index to the associated token
		size_t apply_tokens(size_t i) const {
			[&, this]<std::size_t... I>(std::index_sequence<I...>) {
				(ApplyTokenOp<I>{}(i) && ...);
			}(std::make_index_sequence<sizeof...(Heads)>{});
			return i;
		}
		template<size_t Idx>
		struct ApplyTokenOp {
			inline bool operator()(size_t& i) const {
				if(i == Idx) {
					if constexpr(detail::instantiation_of_token_head<detail::nth_type<Idx, Heads...>, heads::basic_token>)
						i = detail::nth_type<Idx, Heads...>::token;
					return false;
				}
				return true;
			}
		};

		// Checks that the finished token is in fact valid for all its supposedly valid heads (prevents matching strings which are too short)
		bool confirm_valid(std::bitset<sizeof...(Heads)>& lastValid, std::basic_string_view<CharT> token) const {
			[&, this]<std::size_t... I>(std::index_sequence<I...>) {
				(ConfirmValidOp<I>{}(lastValid, token) && ...);
			}(std::make_index_sequence<sizeof...(Heads)>{});
			return lastValid.any();
		}
		template<size_t Idx>
		struct ConfirmValidOp {
			inline bool operator()(std::bitset<sizeof...(Heads)>& lastValid, std::basic_string_view<CharT> token) const {
				if(lastValid[Idx])
					lastValid[Idx] = detail::nth_type<Idx, Heads...>::token_valid(token);
				return true;
			}
		};

		// Checks if the given head is a skip_head
		bool is_skip(size_t headIndex) const {
			return ![&, this]<std::size_t... I>(std::index_sequence<I...>) {
				return (IsSkipOp<I>{}(headIndex) && ...);
			}(std::make_index_sequence<sizeof...(Heads)>{});
		}
		template<size_t Idx>
		struct IsSkipOp {
			inline bool operator()(size_t headIndex) const {
				if(headIndex == Idx)
					if constexpr(detail::instantiation_of_skip_token_head<detail::nth_type<Idx, Heads...>, heads::basic_skip>)
						return false;
				return true;
			}
		};

	public:
		result lex(std::basic_string_view<CharT> buffer, size_t bufferOffset = 0)
#ifndef LEXER_IS_STATEFULL
			const
#endif
		{
			if(buffer.empty()) return {std::string::npos, {}, {}};

#ifndef LEXER_IS_STATEFULL
			std::bitset<sizeof...(Heads)> valid, lastValid;
#endif
			valid.set(); // At the start all heads are valid!

			// For each character we check if it is valid for each head, and disable any heads that are no longer valid
			// This repeats until we run out of characters or valid heads... we have to track which heads were valid on the last iteration
			//	so that in the case where we run out of heads we can look back a step and use the last known set of valid heads
			size_t i = 0;
			for( ; i < buffer.size() && valid.any(); ++i) {
				lastValid = valid;
				[&, this]<std::size_t... I>(std::index_sequence<I...>) {
					(LexerOp<I>{}(valid, i, buffer, bufferOffset) && ...);
				}(std::make_index_sequence<sizeof...(Heads)>{});
			}

			if(valid.any()) lastValid = valid;
			if(valid.any() && i == buffer.size()) ++i;
			auto token = buffer.substr(0, i - 1);
			if(!confirm_valid(lastValid, token)) return {std::string::npos, {}, buffer};

			auto headIndex = detail::index_of_first_set(lastValid);
			// If we should skip this token type, recursively lex on the remaining buffer
			if(is_skip(headIndex)) return lex(buffer.substr(i - 1, buffer.size()));
			// Otherwise return the token
			return { apply_tokens(headIndex), token, buffer.substr(i - 1, buffer.size()) };
		}
	protected:
		template<size_t Idx>
		struct LexerOp {
			inline bool operator()(std::bitset<sizeof...(Heads)>& valid, size_t i, std::basic_string_view<CharT> buffer, size_t bufferOffset) const {
				if(valid[Idx] || !detail::nth_type<Idx, Heads...>::skip_if_invalid)
					valid[Idx] = detail::nth_type<Idx, Heads...>::next_valid(i, buffer[i + bufferOffset]);
				return true;
			}
		};

	public:
		inline result lex(const result& res)
#ifndef LEXER_IS_STATEFULL
			const
#endif
		{ return lex(res.remaining); }
	};
	template<lexer_head<char>... Heads>
	using lexer = basic_lexer<char, Heads...>;

	template<typename CharT>
	using basic_lexer_generic_result = basic_lexer<CharT, heads::null>::result;
	using lexer_generic_result = basic_lexer_generic_result<char>;
}
