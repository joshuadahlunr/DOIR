#include "json.hpp"

#ifdef _MSC_VER
#define YY_NO_UNISTD_H
#include <io.h>
#endif

#include <nowide/iostream.hpp>

namespace doir::JSON {

	char* result;

	#include "gen/parser.h"
	#include "gen/scanner.h"

	char* parse_view(const fp_string_view view) {
		DOIR_ZONE_SCOPED_AGRO;

		yy_scan_bytes(fp_view_data(char, view), fp_view_size(view));
		// yydebug = 1;
		yyparse();
		return result;
	}

	char* parse(const fp_string string) {
		DOIR_ZONE_SCOPED_AGRO;
		return parse_view(fp_string_to_view_const(string)/* , variables */);
	}

}