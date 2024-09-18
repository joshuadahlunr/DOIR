#include "calculator.hpp"

#ifdef _MSC_VER
#define YY_NO_UNISTD_H
#include <io.h>
#endif

#include <iostream>
#include <cmath>

namespace doir::Calculator {

	fp_hashtable(calculator_variable) create_variable_table() {
		DOIR_ZONE_SCOPED_AGRO;
		fp_hashtable(calculator_variable) map = nullptr;
		fp_hash_create_empty_table(calculator_variable, map, true);
		// Only hash and compare the first element in the pair (makes it a map!)
		fp_hash_set_hash_function(map, [](const fp_void_view key) noexcept -> uint64_t {
			assert(fp_view_size(key) == sizeof(calculator_variable));
			calculator_variable& pair = *fp_view_data(calculator_variable, key);
			{
				auto view = fp_string_to_view(pair.first);
				return FP_HASH_FUNCTION({fp_view_data_void(view), fp_view_size(view)});
			}
		});
		fp_hash_set_equal_function(map, [](const fp_void_view _a, const fp_void_view _b) noexcept -> bool {
			assert(fp_view_size(_a) == sizeof(calculator_variable)); assert(fp_view_size(_b) == sizeof(calculator_variable));
			calculator_variable& a = *fp_view_data(calculator_variable, _a);
			calculator_variable& b = *fp_view_data(calculator_variable, _b);
			return fp_string_compare(a.first, b.first) == 0;
		});
		fp_hash_set_finalize_function(map, [](fp_void_view _key) noexcept {
			assert(fp_view_size(_key) == sizeof(calculator_variable));
			calculator_variable& key = *fp_view_data(calculator_variable, _key);
			fp_string_free(key.first);
		});
		return map;
	}

	static thread_local fp_hashtable(calculator_variable) variables_map = nullptr;

	#include "gen/parser.h"
	#include "gen/scanner.h"

	void calculate_view(const fp_string_view view, fp_hashtable(calculator_variable) variables /*= nullptr*/) {
		DOIR_ZONE_SCOPED_AGRO;
		bool free = false;
		if(!variables) {
			variables = create_variable_table();
			free = true;
		}

		yy_scan_bytes(fp_view_data(char, view), fp_view_size(view));
		variables_map = variables;
		yyparse();
		if(free) fpda_free(variables);
	}

	void calculate(const fp_string string, fp_hashtable(calculator_variable) variables /*= nullptr*/) {
		DOIR_ZONE_SCOPED_AGRO;
		calculate_view(fp_string_to_view_const(string), variables);
	}

}