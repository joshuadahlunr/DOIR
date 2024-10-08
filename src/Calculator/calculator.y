/* definitions */

%{
extern int yylex();
extern int yyparse();
void yyerror(const char* s);
%}

%union {
	float n;
	fp_string_view i;
}

%token NUMBER
%token IDENTIFIER


%% /* Rules */


expressionList: expressionList expression ';' { DOIR_ZONE_SCOPED_NAMED_AGRO("Print"); nowide::cout << " = " << $<n>2 << std::endl; }
	| expression ';' { DOIR_ZONE_SCOPED_NAMED_AGRO("Print"); nowide::cout << " = " << $<n>1 << std::endl; };

expression: identifier '=' expression { DOIR_ZONE_SCOPED_NAMED_AGRO("Parse Assignment");
		auto owned = fp_string_view_make_dynamic($<i>1);
		calculator_variable key = {owned, $<n>3};
		bool free = fp_hash_contains(calculator_variable, variables_map, key);
		auto variable = fp_hash_insert_or_replace(calculator_variable, variables_map, key);
		if(free) fp_string_free(owned);
		$<n>$ = $<n>3;
	} | addExpression { $<n>$ = $<n>1; }
addExpression: addExpression '+' mulExpression { $<n>$ = $<n>1 + $<n>3; }
	| addExpression '-' mulExpression { $<n>$ = $<n>1 - $<n>3; }
	| mulExpression { $<n>$ = $<n>1; };
mulExpression: mulExpression '*' powExpression { $<n>$ = $<n>1 * $<n>3; }
	| mulExpression '/' powExpression { $<n>$ = $<n>1 / $<n>3; }
	| powExpression { $<n>$ = $<n>1; };
powExpression: powExpression '^' term { $<n>$ = std::pow($<n>1, $<n>3); }
	| term { $<n>$ = $<n>1; };

term: '(' expression ')' { $<n>$ = $<n>2; }
	| NUMBER { $<n>$=yylval.n; }
	| identifier { DOIR_ZONE_SCOPED_NAMED_AGRO("Parse Variable Term");
		auto owned = fp_string_view_make_dynamic($<i>1);
		calculator_variable key = {owned, 0};
		auto variable = fp_hash_find(calculator_variable, variables_map, key);
		fp_string_free(owned);
		if(!variable) {
			yyerror("Variable not found!");
			YYERROR;
		}
		$<n>$ = variable->second;
	};
identifier: IDENTIFIER { $<i>$ = yylval.i; };


%% /* Code */


void yyerror(const char* s) {
	nowide::cerr << s << std::endl;
}