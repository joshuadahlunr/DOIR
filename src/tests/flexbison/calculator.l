/* Definitions */
/* C file built with: `flex --outfile=calculator.yy.c calculator.l` (flex 2.6.4) */

%{
#include "calculator.tab.c"
%}

%option noyywrap

ws [ \t\n\r]+
integer [0-9]+


%% /* Actions */


{ws} { /* no action and no return */ }
"+" { return PLUS; }
"-" { return MINUS; }
"*" { return MULT; }
"/" { return DIV; }
"(" { return OPEN; }
")" { return CLOSE; }
";" { return SEMI; }
{integer} { 
    yylval = atoi(yytext);
    return INTEGER;
}
 /*. { return ERROR; }*/
. { return yytext[0]; } /* Returns whatever character is found (which won't match the parser, creating an error) */


%% /* code */