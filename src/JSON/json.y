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
	int yylex(reflex::Input* input = nullptr);
	int yyparse();
	void yyerror(const char* s);
	#define YYSTYPE doir::ecs::entity_t
%}

%token NUMBER
%token STRING
%token Jtrue Jfalse Jnull
%left '{' '}' '[' ']'
%left ','
%left ':'

%%

START: ARRAY { objects.push($1); }
	| OBJECT { objects.push($1); }
	| VALUE { objects.push($1); };
OBJECT: '{' '}' {
	$$ = module->create_entity();
	module->add_component<doir::comp::lexeme>($$) = {location - 1, 2};
	module->add_component<comp::object>($$);
} | '{' {
	$$ = module->create_entity();
	module->add_component<doir::comp::lexeme>($$) = {location - 1, 2};
	module->add_component<comp::object>($$);
	objects.push($$);
} MEMBERS '}' {
	$$ = objects.top();
	auto& lexeme = module->get_component<doir::comp::lexeme>($$);
	lexeme.length = location - lexeme.start;
	objects.pop();
};
MEMBERS: PAIR | PAIR ',' MEMBERS;
PAIR: VALUE_STRING ':' VALUE {
	auto obj = objects.top();
	auto& members = module->get_component<comp::object>(obj).members;
	get_key_and_mark_occupied(module->add_component<comp::object_entry_hash>($3)) = {obj, module->get_component<doir::comp::lexeme>($1)};
	fpda_push_back(members, $3);
	// $$ = $1;
};
ARRAY: '[' {
	$$ = module->create_entity();
	module->add_component<doir::comp::lexeme>($$) = {location - 1, 2};
	module->add_component<comp::array>($$);
} ']' | '[' {
	$$ = module->create_entity();
	module->add_component<doir::comp::lexeme>($$) = {location - 1, 2};
	module->add_component<comp::array>($$);
	objects.push($$);
} ELEMENTS ']' {
	$$ = objects.top();
	auto& lexeme = module->get_component<doir::comp::lexeme>($$);
	lexeme.length = location - lexeme.start;
	auto& members = module->get_component<comp::array>($$).members;
	std::reverse(members, members + fpda_size(members));
	objects.pop();
};
ELEMENTS: VALUE {
	auto array = objects.top();
	auto& members = module->get_component<comp::array>(array).members;
	// get_key_and_mark_occupied(module->add_component<comp::array_entry_hash>($1)) = {array, fpda_size(members)};
	fpda_push_back(members, $1);
	// $$ = $1;
} | VALUE ',' ELEMENTS {
	auto array = objects.top();
	auto& members = module->get_component<comp::array>(array).members;
	// get_key_and_mark_occupied(module->add_component<comp::array_entry_hash>($1)) = {array, fpda_size(members)};
	fpda_push_back(members, $1);
	// $$ = $1;
};
VALUE: VALUE_STRING {$$=$1;}
	| NUMBER {$$=yylval;}
	| OBJECT {$$=$1;}
	| ARRAY {$$=$1;}
	| Jtrue {$$=yylval;}
	| Jfalse {$$=yylval;}
	| Jnull {$$=yylval;};
VALUE_STRING: STRING {$$=yylval;};

%%

inline void yyerror(const char* s) {
	nowide::cerr << s << std::endl;
}