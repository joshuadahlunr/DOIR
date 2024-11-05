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
%}

%option noyywrap

DIGIT1to9 [1-9]
DIGIT [0-9]
DIGITS {DIGIT}+
INT {DIGIT}|{DIGIT1to9}{DIGITS}|-{DIGIT}|-{DIGIT1to9}{DIGITS}
FRAC [.]{DIGITS}
E [eE][+-]?
EXP {E}{DIGITS}
HEX_DIGIT [0-9a-f]
NUMBER {INT}|{INT}{FRAC}|{INT}{EXP}|{INT}{FRAC}{EXP}
UNESCAPEDCHAR [ -!#-\[\]-~]
ESCAPEDCHAR \\["\\bfnrt/]
UNICODECHAR \\u{HEX_DIGIT}{HEX_DIGIT}{HEX_DIGIT}{HEX_DIGIT}
CHAR {UNESCAPEDCHAR}|{ESCAPEDCHAR}|{UNICODECHAR}
CHARS {CHAR}+
DBL_QUOTE ["]

%%

{DBL_QUOTE}{DBL_QUOTE} |
{DBL_QUOTE}{CHARS}{DBL_QUOTE} {
	size_t len = fp_string_length(text());
	yylval = module->create_entity();
	module->add_component<doir::comp::lexeme>(yylval) = {location, len};
	module->add_component<comp::string>(yylval);
	location += len;
	return STRING;
};
{NUMBER} {
	size_t len = fp_string_length(text());
	yylval = module->create_entity();
	module->add_component<doir::comp::lexeme>(yylval) = {location, len};
	module->add_component<double>(yylval) = atof(text());
	location += len;
	return NUMBER;
}
"true" { 
	size_t len = fp_string_length(text());
	yylval = module->create_entity();
	module->add_component<doir::comp::lexeme>(yylval) = {location, len};
	module->add_component<bool>(yylval) = true;
	location += len;
	return Jtrue; 
};
"false" { 
	size_t len = fp_string_length(text());
	yylval = module->create_entity();
	module->add_component<doir::comp::lexeme>(yylval) = {location, len};
	module->add_component<bool>(yylval) = false;
	location += len;
	return Jfalse; 
};
"null" { 
	size_t len = fp_string_length(text());
	yylval = module->create_entity();
	module->add_component<doir::comp::lexeme>(yylval) = {location, len};
	module->add_component<comp::null>(yylval);
	location += len;
	return Jnull; 
};

[ \t\n]+ { location += fp_string_length(text()); };

. { ++location; return text()[0]; }

%%

