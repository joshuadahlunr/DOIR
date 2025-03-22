%{
%}

%option noyywrap
%option unicode
%x COMMENT

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
CHAR {UNESCAPEDCHAR}|{ESCAPEDCHAR}|{UNICODECHAR}|\p{Non_ASCII_Unicode}
CHARS {CHAR}+
DBL_QUOTE ["]
// ALPHA [a-zA-Z_]
// ALNUM [a-zA-Z0-9_]
IDENTIFIER \p{UnicodeIdentifierStart}\p{UnicodeIdentifierPart}*

%%

"true" {
	size_t len = fp_string_length(text());
	yylval = ecs::Entity::create(*module);
	yylval.add_component<doir::comp::lexeme>() = {location, len};
	yylval.add_component<literal>();
	yylval.add_component<bool>() = true;
	yylval.add_component<interpreter::skippable>();
	location += len;
	return True;
}
"false" {
	size_t len = fp_string_length(text());
	yylval = ecs::Entity::create(*module);
	yylval.add_component<doir::comp::lexeme>() = {location, len};
	yylval.add_component<literal>();
	yylval.add_component<bool>() = false;
	yylval.add_component<interpreter::skippable>();
	location += len;
	return False;
}
"null"|"nil" {
	size_t len = fp_string_length(text());
	yylval = ecs::Entity::create(*module);
	yylval.add_component<doir::comp::lexeme>() = {location, len};
	yylval.add_component<literal>();
	yylval.add_component<null>();
	yylval.add_component<interpreter::skippable>();
	location += len;
	return Null;
}
"class" {
	size_t len = fp_string_length(text());
	location += len;
	return CLASS;
}
"fun"|"fn" {
	size_t len = fp_string_length(text());
	location += len;
	return FUN;
}
"var" {
	size_t len = fp_string_length(text());
	location += len;
	return VAR;
}
"for" {
	size_t len = fp_string_length(text());
	location += len;
	return FOR;
}
"if" {
	size_t len = fp_string_length(text());
	location += len;
	return IF;
}
"else" {
	size_t len = fp_string_length(text());
	location += len;
	return ELSE;
}
"print" {
	size_t len = fp_string_length(text());
	location += len;
	return PRINT;
}
"return" {
	size_t len = fp_string_length(text());
	location += len;
	return RETURN;
}
"while" {
	size_t len = fp_string_length(text());
	location += len;
	return WHILE;
}
"or" {
	size_t len = fp_string_length(text());
	location += len;
	return OR;
}
"and" {
	size_t len = fp_string_length(text());
	location += len;
	return AND;
}
"this" {
	size_t len = fp_string_length(text());
	location += len;
	return THIS;
}
"super" {
	size_t len = fp_string_length(text());
	location += len;
	return SUPER;
}

"!=" {
	size_t len = fp_string_length(text());
	location += len;
	return NOT_EQUAL;
}
"==" {
	size_t len = fp_string_length(text());
	location += len;
	return EQUAL;
}
">=" {
	size_t len = fp_string_length(text());
	location += len;
	return GREATER_EQUAL;
}
"<=" {
	size_t len = fp_string_length(text());
	location += len;
	return LESS_EQUAL;
}

{DBL_QUOTE}{DBL_QUOTE} |
{DBL_QUOTE}{CHARS}{DBL_QUOTE} {
	size_t len = fp_string_length(text());
	yylval = ecs::Entity::create(*module);
	yylval.add_component<doir::comp::lexeme>() = {location, len};
	yylval.add_component<literal>();
	yylval.add_component<string>();
	yylval.add_component<interpreter::skippable>();
	location += len;
	return STRING;
}
{NUMBER} {
	size_t len = fp_string_length(text());
	yylval = ecs::Entity::create(*module);
	yylval.add_component<doir::comp::lexeme>() = {location, len};
	yylval.add_component<literal>();
	yylval.add_component<double>() = strtod(text(), nullptr);
	yylval.add_component<interpreter::skippable>();
	location += len;
	return NUMBER;
}
{IDENTIFIER} {
	size_t len = fp_string_length(text());
	yylval = ecs::Entity::create(*module);
	yylval.add_component<doir::comp::lexeme>() = {location, len};
	location += len;
	return IDENTIFIER;
}

[ \t\n] { ++location; }
"//".* { location += fp_string_length(text()); }

"/*" { location += 2; start(COMMENT); }
<COMMENT>"*/" { location += 2; start(INITIAL); }
<COMMENT>\n { ++location; }
<COMMENT>. { ++location; }

. { ++location; return text()[0]; }

%%

