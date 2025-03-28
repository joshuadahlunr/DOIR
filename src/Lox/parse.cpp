#include "lox.hpp"

#include <reflex/input.h>
#include <nowide/iostream.hpp>

namespace doir::Lox {
	size_t location = 0;
	TrivialModule* module;
	fp::dynarray<ecs::Entity> blocks = nullptr;
	fp::dynarray<ecs::Entity> objects = nullptr;

	block& current_block() {
		return blocks.back().get_component<block>();
	}

	void add_body_marker(ecs::Entity block_, std::optional<ecs::entity_t> target_ = {}) {
		ecs::Entity target = target_.value_or(block_);
		auto& block = block_.get_component<struct block>();
		
		ecs::Entity marker = ecs::Entity::create(*module);
		marker.add_component<doir::lexeme>() = block_.get_component<doir::lexeme>();
		marker.add_component<body_marker>().skipTo = target;
		block.push_front_child(*module, marker);
	}

	doir::comp::lexeme& append_lexeme_to_buffer(TrivialModule& module, ecs::Entity e, const char* string) {
		auto& lexeme = e.get_or_add_component<doir::comp::lexeme>();
		lexeme.start = fp::string{module.buffer}.size();
		module.buffer = (fp::string{module.buffer} += "clock").data();
		lexeme.length = fp::string{module.buffer}.size() - lexeme.start;
		return lexeme;
	}

	void add_builtin_functions() {
		auto clock = ecs::Entity::create(*module);
		auto& lexeme = append_lexeme_to_buffer(*module, clock, "clock");
		auto& decl = get_key_and_mark_occupied(clock.add_component<Module::HashtableComponent<function_declare>>())
			= {declare{.name = lexeme, .parent = blocks.back()}};
		clock.add_component<interpreter::skippable>();
		clock.add_component<block>();
		current_block().push_back_child(*module, clock);
	}

	#include "gen/parser.h"
}

#include "gen/scanner.h"

namespace doir::Lox {

	inline int yylex(reflex::Input* input /* = nullptr */) {
		static Lexer lexer;
		if(input) { lexer = Lexer(*input); return true; }
		else return lexer.lex();
	}

	inline void set_input(reflex::Input& input) {
		yylex(&input);
	}
	inline void set_input(reflex::Input&& input) {
		yylex(&input);
	}

	std::pair<TrivialModule, ecs::entity_t> parse_view(const fp_string_view view) {
		DOIR_ZONE_SCOPED_AGGRO;
		set_input(reflex::Input(fp_view_data(char, view), fp_view_size(view)));
		TrivialModule out;
		doir::ecs::Entity::set_current_module(out);
		module = &out;

		// yydebug = 1;
		location = 0;
		fp_string_view_concatenate_inplace(out.buffer, view);
		if(objects) objects.free_and_null();
		if(blocks) blocks.free_and_null();
		blocks.push_back(ecs::Entity::create(*module));
		blocks.back().add_component<block>() = {0};

		yyparse();
		add_builtin_functions();
		return {out, blocks.empty() ? ecs::Entity{0} : blocks.back()};
	}

	std::pair<TrivialModule, ecs::entity_t> parse(const fp_string string) {
		DOIR_ZONE_SCOPED_AGGRO;
		return parse_view(fp_string_to_view_const(string));
	}
}