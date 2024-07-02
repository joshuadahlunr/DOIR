#pragma once

#ifdef DOIR_IMPLEMENTATION
	#define ECS_IMPLEMENTATION
#endif
#include "../thirdparty/ECS.hpp"
#include "../thirdparty/ECSquery.hpp"
#include "../thirdparty/ECSadapter.hpp"
#include "fnv1a.hpp"

#include <iostream>
#include <map>
#include <deque>

namespace doir {
	using ecs::optional_reference;
	using ecs::optional;

	using Token = ecs::entity;
	template<typename T>
	using WithToken = ecs::with_entity<T>;

	template<std::floating_point T>
	bool float_equal(T a, T b, T epsilon = .00001) {
		return std::abs(a - b) < epsilon;
	}

	struct Module: protected ecs::scene {
		std::string buffer;

		Module(const std::string& buffer = "") : buffer(buffer) {
			assert(make_token() == 0); // Reserve token 0 for errors!
		}

		inline size_t token_count() const { return size(); }

		inline Token make_token() { return create_entity(); }

		template<typename Tattr>
		inline Tattr& add_attribute(Token t) { return *add_component<Tattr>(t); }

		template<typename Tattr>
		inline Tattr& add_hashtable_attribute(Token t) {
			return ecs::hashtable::get_key_and_mark_occupied<Tattr>(
				add_attribute<typename ecs::hashtable::component_storage<Tattr>::component_type>(t)
			);
		}

		template<typename Tattr>
		inline ecs::optional_reference<Tattr> get_attribute(Token t) { return get_component<Tattr>(t); }
		template<typename Tattr>
		inline ecs::optional_reference<const Tattr> get_attribute(Token t) const { return get_component<Tattr>(t); }

		template<typename Tattr>
		optional_reference<ecs::hashtable::component_storage<Tattr, void, fnv::fnv1a_64<Tattr>>> get_attribute_hashtable(bool skip_rehash = false) {
			auto hashtable = ecs::get_adapted_component_storage<ecs::hashtable::component_storage<Tattr, void, fnv::fnv1a_64<Tattr>>>(*this);
			if(!hashtable) return {};
			if(!skip_rehash) hashtable->rehash(*this);
			return hashtable;
		}

		template<typename Tattr>
		inline bool has_attribute(Token t) const { return has_component<Tattr>(t); }

		template<typename... Tattrs>
		inline ecs::scene_view<Tattrs...> view() { return {*this}; }
	};

	// A module wrapped value assumes that the associated module won't move!
	#define DOIR_MODULE_WRAPPED_BODY_IMPLEMENTATION(baseType)\
		doir::Module* module;\
		ModuleWrapped() : module(nullptr), baseType() {}\
		template<typename... Args>\
		ModuleWrapped(doir::Module& module, Args... args) : module(&module), baseType(args...) {}\
		ModuleWrapped(doir::Module& module, const baseType& p) : module(&module), baseType(p) {}\
		ModuleWrapped(doir::Module& module, baseType&& p) : module(&module), baseType(std::move(p)) {}\
		ModuleWrapped(const ModuleWrapped&) = default;\
		ModuleWrapped(ModuleWrapped&&) = default;\
		ModuleWrapped& operator=(const ModuleWrapped&) = default;\
		ModuleWrapped& operator=(ModuleWrapped&&) = default
	template<typename Parent>
	struct ModuleWrapped : public Parent { DOIR_MODULE_WRAPPED_BODY_IMPLEMENTATION(Parent); };


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

		std::string_view view(std::string_view buffer) const { return buffer.substr(start, length); }
		static std::optional<Lexeme> from_view(std::string_view buffer, std::string_view source) {
			auto diff = source.data() - buffer.data();
			if(diff < 0) return {};
			if(diff + source.size() > buffer.size()) return {};
			return {{(size_t)diff, source.size()}};
		}

		std::strong_ordering operator<=>(const Lexeme&) const = default;
	};
	template<>
	struct ModuleWrapped<Lexeme> : public Lexeme {
		DOIR_MODULE_WRAPPED_BODY_IMPLEMENTATION(Lexeme);

		inline std::string_view view() const { return Lexeme::view(module->buffer); }
		inline operator std::string_view() const { return view(); }
		inline bool operator==(std::string_view other) { return view() == other; }
	};

	struct TokenReference : public std::variant<Token, Lexeme> {
		using std::variant<Token, Lexeme>::variant;

		inline bool looked_up() const { return index() == 0; }
		inline operator bool() const { return looked_up(); }

		inline Token& token() { return std::get<Token>(*this); }
		inline const Token& token() const { return std::get<Token>(*this); }
		inline Lexeme& lexeme() { return std::get<Lexeme>(*this); }
		inline const Lexeme& lexeme() const { return std::get<Lexeme>(*this); }
	};

	struct Error {
		std::string message;

#if __cpp_exceptions >= 199711
		void Throw() { throw std::runtime_error(message); }
#else
		void Throw() { std::terminate(); }
#endif
	};


	using ecs::or_;
	using ecs::Or;
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