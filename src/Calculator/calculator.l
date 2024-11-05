/* Definitions */

%{
%}

%option noyywrap

ws [ \t\n\r]+
integer [0-9]+
identifier [a-zA-Z_][a-zA-Z0-9_]*


%% /* Actions */


{ws} { using namespace doir::Calculator; location += fp_string_length(text()); }
{integer} { DOIR_ZONE_SCOPED_NAMED_AGRO("Lex Integer");
	size_t len = fp_string_length(text());
	yylval = module->create_entity();
	module->add_component<doir::comp::lexeme>(yylval) = {location, len};
	module->add_component<comp::constant>(yylval) = {static_cast<float>(atoi(text()))};
	location += len;
	return NUMBER;
}
{identifier} { DOIR_ZONE_SCOPED_NAMED_AGRO("Lex Identifier");
	size_t len = fp_string_length(text());
	yylval = module->create_entity();
	module->add_component<doir::comp::lexeme>(yylval) = {location, len};
	location += len;
	return IDENTIFIER;
}
. { 
	++location;
	return text()[0]; 
} /* Returns whatever character is found (most of which won't match the parser, creating an error) */


%% /* code */