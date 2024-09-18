/* Definitions */

%{
/*#include "parser.c"*/
%}

%option noyywrap

ws [ \t\n\r]+
integer [0-9]+
identifier [a-zA-Z_][a-zA-Z0-9_]*


%% /* Actions */


{ws} { /* no action and no return */ }
{integer} { DOIR_ZONE_SCOPED_NAMED_AGRO("Lex Integer");
	yylval.n = atoi(yytext);
	return NUMBER;
}
{identifier} { DOIR_ZONE_SCOPED_NAMED_AGRO("Lex Identifier");
	yylval.i = fp_string_view_literal(yytext, strlen(yytext));
	return IDENTIFIER;
}
. { return yytext[0]; } /* Returns whatever character is found (most of which won't match the parser, creating an error) */


%% /* code */