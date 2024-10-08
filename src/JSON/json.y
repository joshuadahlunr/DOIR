/* The MIT License (MIT)

Copyright (c) 2015 J Kishore Kumar

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE. */

/* Modified from: https://gist.github.com/justjkk/436828 */

%{
	extern int yylex();
	extern int yyparse();
	void yyerror(const char* s);
	#define YYSTYPE char*
%}

%token NUMBER
%token STRING
%token Jtrue Jfalse Jnull
%left '{' '}' '[' ']'
%left ','
%left ':'

%%

START: ARRAY {
	result = $1;
} | OBJECT {
	result = $1;
} | VALUE {
	result = $1;
};
OBJECT: '{' '}' {
	$$ = (char*)"{}";
} | '{' MEMBERS '}' {
	$$ = (char *)malloc(sizeof(char)*(1+strlen($2)+1+1));
	sprintf($$,"{%s}",$2);
};
MEMBERS: PAIR {
	$$ = $1;
} | PAIR ',' MEMBERS {
	$$ = (char *)malloc(sizeof(char)*(strlen($1)+1+strlen($3)+1));
	sprintf($$,"%s,%s",$1,$3);
};
PAIR: STRING ':' VALUE {
	$$ = (char *)malloc(sizeof(char)*(strlen($1)+1+strlen($3)+1));
	sprintf($$,"%s:%s",$1,$3);
};
ARRAY: '[' ']' {
	$$ = (char *)malloc(sizeof(char)*(2+1));
	sprintf($$,"[]");
} | '[' ELEMENTS ']' {
	$$ = (char *)malloc(sizeof(char)*(1+strlen($2)+1+1));
	sprintf($$,"[%s]",$2);
};
ELEMENTS: VALUE {
	$$ = $1;
} | VALUE ',' ELEMENTS {
	$$ = (char *)malloc(sizeof(char)*(strlen($1)+1+strlen($3)+1));
	sprintf($$,"%s,%s",$1,$3);
};
VALUE: STRING {$$=yylval;}
| NUMBER {$$=yylval;}
| OBJECT {$$=$1;}
| ARRAY {$$=$1;}
| Jtrue {$$=(char*)"true";}
| Jfalse {$$=(char*)"false";}
| Jnull {$$=(char*)"null";}
;

%%

void yyerror(const char* s) {
	nowide::cerr << s << std::endl;
}