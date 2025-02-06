#include "lox.hpp"

#include <reflex/input.h>
#include <nowide/iostream.hpp>

namespace doir::Lox {
	fp_string comparison_buffer = nullptr;

	size_t location = 0;
	TrivialModule* module;
	fp_dynarray(ecs::entity_t) blocks = nullptr;
	fp_dynarray(ecs::entity_t) objects = nullptr;

	block& current_block() {
		return module->get_component<block>(*fpda_back(blocks));
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
		DOIR_ZONE_SCOPED_AGRO;
		set_input(reflex::Input(fp_view_data(char, view), fp_view_size(view)));
		TrivialModule out;
		module = &out;

		// yydebug = 1;
		location = 0;
		fp_string_view_concatenate_inplace(out.buffer, view);
		if(objects) fpda_free_and_null(objects);
		if(blocks) fpda_free_and_null(blocks);
		fpda_push_back(blocks, module->create_entity());
		module->add_component<block>(*fpda_back(blocks)) = {0, nullptr};

		yyparse();
		return {out, fpda_empty(blocks) ? 0 : *fpda_back(blocks)};
	}

	std::pair<TrivialModule, ecs::entity_t> parse(const fp_string string) {
		DOIR_ZONE_SCOPED_AGRO;
		return parse_view(fp_string_to_view_const(string));
	}
}