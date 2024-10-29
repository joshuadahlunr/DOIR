%{
	int yylex(reflex::Input* input = nullptr);
	int yyparse();
	void yyerror(const char* s);
	#define YYSTYPE ecs::entity_t
%}

%token IDENTIFIER
%token NUMBER
%token STRING
%token True False Null
%token CLASS FUN VAR FOR IF ELSE PRINT RETURN WHILE OR AND THIS SUPER
%token NOT_EQUAL EQUAL GREATER_EQUAL LESS_EQUAL
%left '{' '}' '[' ']'
%left ','
%left ':'


%%


START: program;
program: declaration | declaration program;
declaration: classDecl
| funDecl
| varDecl
| statement;

classDecl: CLASS IDENTIFIER classDeclTail;
classDeclTail: '<' IDENTIFIER '{' functionList '}'
| '{' functionList '}';
functionList: function | function functionList;
funDecl: FUN function;
varDecl: VAR IDENTIFIER varDeclTail;
varDeclTail: '=' expression ';' | ';';

statement: exprStmt
| forStmt
| ifStmt
| printStmt
| returnStmt
| whileStmt
| block;

exprStmt: expression ';';

forStmt: FOR '(' forStmtContentFirst forStmtContent forStmtContent ')' statement;
forStmtContentFirst: varDecl | exprStmt | ';';
forStmtContent: exprStmt | ';';

ifStmt: IF '(' expression ')' statement ifStmtTail;
ifStmtTail: ELSE statement | ;

printStmt: PRINT expression ';';
returnStmt: RETURN expression ';' | RETURN ';';
whileStmt: WHILE '(' expression ')' statement;
block: '{' declarationList '}';
declarationList: declaration | declaration declarationList;

expression: assignment;

assignment: call '.' assignmentTail | assignmentTail | logic_or;
assignmentTail: IDENTIFIER '=' assignment;

logic_or: logic_and logic_orTail;
logic_orTail: OR logic_and logic_orTail | ;

logic_and: equality logic_andTail;
logic_andTail: AND equality logic_andTail | ;

equality: comparison equalityTail;
equalityTail: NOT_EQUAL equalityTailTail | EQUAL equalityTailTail | ;
equalityTailTail: comparison equalityTail;

comparison: term comparisonTail;
comparisonTail: '>' comparisonTailTail | GREATER_EQUAL comparisonTailTail | '<' comparisonTailTail | LESS_EQUAL comparisonTailTail | ;
comparisonTailTail: term comparisonTail;

term: factor termTail;
termTail: '-' factor termTail | '+' factor termTail | ;

factor: unary factorTail;
factorTail: '/' unary factorTail | '*' unary factorTail | ;

unary: '!' unary | '-' unary | call;

call: primary callTail;
callTail: '(' ')' | '(' arguments ')' | '.' IDENTIFIER callTail | ;

primary: True | False | Null | THIS | NUMBER | STRING | IDENTIFIER | '(' expression ')' | SUPER '.' IDENTIFIER;

function: IDENTIFIER '(' ')' block | IDENTIFIER '(' parameters ')' block;
parameters: IDENTIFIER parametersTail;
parametersTail: ',' IDENTIFIER parametersTail | ;

arguments: expression argumentsTail;
argumentsTail: ',' expression argumentsTail | ;

%%

void yyerror(const char* s) {
	nowide::cerr << s << std::endl;
}