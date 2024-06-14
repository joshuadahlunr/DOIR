/* definitions */
/* C file built with: `bison calculator.y` (bison (GNU Bison) 3.8.2)*/


%token INTEGER
// %token ERROR
%token SEMI
%token PLUS
%token MINUS
%token MULT
%token DIV
%token OPEN
%token CLOSE


%% /* Rules */


expressionList: expressionList expression SEMI { std::cout << " = " << $2 << std::endl; }
    | expression SEMI { std::cout << " = " << $1 << std::endl; };

expression: expression PLUS mulExpression { $$ = $1 + $3; }
    | expression MINUS mulExpression { $$ = $1 - $3; }
    | mulExpression { $$ = $1; };
mulExpression: mulExpression MULT term { $$ = $1 * $3; }
    | mulExpression DIV term { $$ = $1 / $3; }
    | term { $$ = $1; };
term: OPEN expression CLOSE { $$ = $2; }
    | INTEGER { $$=yylval; };


%% /* Code */


void yyerror(char * s) {
    std::cerr << s << std::endl;
}