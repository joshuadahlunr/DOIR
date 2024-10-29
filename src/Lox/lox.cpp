#include "lox.hpp"

#include <reflex/input.h>
#include <nowide/iostream.hpp>
#include <stack>
#include <fp/string.h>

#include "../components.hpp"

namespace doir::Lox {

	// inline namespace component {
	// 	struct object { fp_dynarray(ecs::entity_t) members = nullptr; };
	// 	struct object_entry { ecs::entity_t object; doir::comp::lexeme name; };
	// 	using object_entry_hash = ecs::hashtable::Storage<object_entry>::component_type;

	// 	struct array { fp_dynarray(ecs::entity_t) members = nullptr; };
	// 	struct array_entry { ecs::entity_t array; size_t index; };
	// 	using array_entry_hash = ecs::hashtable::Storage<array_entry>::component_type;

	// 	struct null {};
	// 	struct string {};
	// }
	// namespace comp = component;

	size_t location = 0;
	// TrivialModule* module;
	// std::stack<ecs::entity_t> objects;

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
		// TrivialModule out;
		// module = &out;

		// yydebug = 1;
		location = 0;
		// fp_string_view_concatenate_inplace(out.buffer, view);
		yyparse();
		// return {out, objects.size() ? objects.top() : 0};
		return {};
	}

	std::pair<TrivialModule, ecs::entity_t> parse(const fp_string string) {
		DOIR_ZONE_SCOPED_AGRO;
		return parse_view(fp_string_to_view_const(string));
	}

}