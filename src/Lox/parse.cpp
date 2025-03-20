#include "lox.hpp"

#include <reflex/input.h>
#include <nowide/iostream.hpp>

namespace doir::Lox {
	fp_string comparison_buffer = nullptr;

	size_t location = 0;
	TrivialModule* module;
	fp::dynarray<ecs::Entity> blocks = nullptr;
	fp::dynarray<ecs::Entity> objects = nullptr;

	block& current_block() {
		return blocks.back().get_component<block>();
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
		return {out, blocks.empty() ? ecs::Entity{0} : blocks.back()};
	}

	std::pair<TrivialModule, ecs::entity_t> parse(const fp_string string) {
		DOIR_ZONE_SCOPED_AGGRO;
		return parse_view(fp_string_to_view_const(string));
	}
}