#include "json.hpp"

#ifdef _MSC_VER
#define YY_NO_UNISTD_H
#include <io.h>
#endif

#include <nowide/iostream.hpp>
#include <stack>
#include <fp/string.h>

#include "../components.hpp"

namespace doir::JSON {

	inline namespace component {
		struct object { fp_dynarray(ecs::entity_t) members = nullptr; };
		struct object_entry { ecs::entity_t object; doir::comp::lexeme name; };
		using object_entry_hash = ecs::hashtable::Storage<object_entry>::component_type;

		struct array { fp_dynarray(ecs::entity_t) members = nullptr; };
		struct array_entry { ecs::entity_t array; size_t index; };
		using array_entry_hash = ecs::hashtable::Storage<array_entry>::component_type;

		struct null {};
		struct string {};
	}
	namespace comp = component;

	size_t location = 0;
	TrivialModule* module;
	std::stack<ecs::entity_t> objects;

	#include "gen/parser.h"
	#include "gen/scanner.h"

	std::pair<TrivialModule, ecs::entity_t> parse_view(const fp_string_view view) {
		DOIR_ZONE_SCOPED_AGRO;
		yy_scan_bytes(fp_view_data(char, view), fp_view_size(view));
		TrivialModule out;
		module = &out;

		location = 0;
		fp_string_view_concatenate_inplace(out.buffer, view);
		yyparse();
		return {out, objects.size() ? objects.top() : 0};
	}

	std::pair<TrivialModule, ecs::entity_t> parse(const fp_string string) {
		DOIR_ZONE_SCOPED_AGRO;
		return parse_view(fp_string_to_view_const(string));
	}

	fp_string dump(TrivialModule& module, ecs::entity_t root) {
		if(module.has_component<comp::null>(root))
			return fp_string_make_dynamic("null");
		else if(module.has_component<bool>(root))
			return fp_string_make_dynamic(module.get_component<bool>(root) ? "true" : "false");
		else if(module.has_component<double>(root))
			return fp_string_format("%f", module.get_component<double>(root));
		else if(module.has_component<comp::string>(root)) {
			return fp_string_view_make_dynamic(module.get_component<doir::comp::lexeme>(root).view(module.buffer));
		} else if(module.has_component<comp::array>(root)) {
			auto out = fp_string_make_dynamic("["); size_t i = 0;
			fp_iterate_named(module.get_component<comp::array>(root).members, mem) {
				if(i++ > 0) fp_string_concatenate_inplace(out, ",");
				auto tmp = dump(module, *mem);
				fp_string_concatenate_inplace(out, tmp); fp_string_free(tmp);
			}
			fp_string_concatenate_inplace(out, "]");
			return out;
		} else if(module.has_component<comp::object>(root)) {
			auto out = fp_string_make_dynamic("{"); size_t i = 0;
			fp_iterate_named(module.get_component<comp::object>(root).members, mem) {
				if(i++ > 0) fp_string_concatenate_inplace(out, ",");
				auto& name = get_key(module.get_component<comp::object_entry_hash>(*mem)).name;
				fp_string_view_concatenate_inplace(out, name.view(module.buffer));
				fp_string_concatenate_inplace(out, ":");
				auto tmp = dump(module, *mem);
				fp_string_concatenate_inplace(out, tmp); fp_string_free(tmp);
			}
			fp_string_concatenate_inplace(out, "}");
			return out;
		} else return fp_string_make_dynamic("<invalid>");;
	}

}