/* Definitions */

%{
/*#include "parser.c"*/
// extern doir::ecs::TrivialModule* module;
%}

%option noyywrap

ws [ \t\n\r]+
integer [0-9]+
identifier [a-zA-Z_][a-zA-Z0-9_]*


%% /* Actions */


{ws} { location += fp_string_length(yytext); }
{integer} { DOIR_ZONE_SCOPED_NAMED_AGRO("Lex Integer");
	size_t len = fp_string_length(yytext);
	yylval = module->create_entity();
	module->add_component<doir::comp::lexeme>(yylval) = {location, len};
	module->add_component<comp::constant>(yylval) = {static_cast<float>(atoi(yytext))};
	location += len;
	return NUMBER;
}
{identifier} { DOIR_ZONE_SCOPED_NAMED_AGRO("Lex Identifier");
	size_t len = fp_string_length(yytext);
	yylval = module->create_entity();
	module->add_component<doir::comp::lexeme>(yylval) = {location, len};
	location += len;
	return IDENTIFIER;
}
. { 
	++location;
	return yytext[0]; 
} /* Returns whatever character is found (most of which won't match the parser, creating an error) */


%% /* code */