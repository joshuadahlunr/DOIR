#include <doctest/doctest.h>
#include <tracy/Tracy.hpp>
#include <nowide/iostream.hpp>
#include <sstream>

#define CAPTURE_CONSOLE_BEGIN std::stringstream capture; \
/* capture(nowide::cout) */{\
	std::streambuf* std__cout_buf = nowide::cout.rdbuf();\
	nowide::cout.rdbuf(capture.rdbuf());

#define CAPTURE_CONSOLE_END nowide::cout.rdbuf(std__cout_buf); }

#define CAPTURE_ERROR_CONSOLE_BEGIN std::stringstream capture; \
/* capture(nowide::cerr) */{\
	std::streambuf* std__cerr_buf = nowide::cerr.rdbuf();\
	nowide::cerr.rdbuf(capture.rdbuf());

#define CAPTURE_ERROR_CONSOLE_END nowide::cerr.rdbuf(std__cerr_buf); }




// Include the parser and the lexer
extern "C" {
	int yylex(void);
	void yyerror(char * s);

	#include "flexbison/calculator.yy.c"
}


int flex() {
	ZoneScoped;
	return yylex();
}

void lexTest(std::string string) {
	yy_scan_string(string.c_str());
	int	token;

	while((token=flex()) != 0){
		switch(token){
			break; case PLUS: nowide::cout << "+" << std::endl;
			break; case MINUS: nowide::cout << "-" << std::endl;
			break; case MULT: nowide::cout << "*" << std::endl;
			break; case DIV: nowide::cout << "/" << std::endl;
			break; case SEMI: nowide::cout << ";" << std::endl;
			break; case OPEN: nowide::cout << "(" << std::endl;
			break; case CLOSE: nowide::cout << ")" << std::endl;
			break; case INTEGER: nowide::cout << yylval << std::endl;
			break; default: nowide::cout << "!ERROR!" << std::endl;
		}
	}
}

TEST_CASE("Lex Test 1") {
	CAPTURE_CONSOLE_BEGIN
	lexTest("2 + 2;");
	CAPTURE_CONSOLE_END

	CHECK(capture.str() == R"p(2
+
2
;
)p");
	FrameMark;
}

TEST_CASE("Lex Test 2") {
	CAPTURE_CONSOLE_BEGIN
	lexTest("2 + (3 * 4);");
	CAPTURE_CONSOLE_END

	CHECK(capture.str() == R"p(2
+
(
3
*
4
)
;
)p");
	FrameMark;
}

TEST_CASE("Lex Test 3") {
	CAPTURE_CONSOLE_BEGIN
	lexTest("20 + 30;");
	CAPTURE_CONSOLE_END

	CHECK(capture.str() == R"p(20
+
30
;
)p");
	FrameMark;
}

TEST_CASE("Lex Test Negative") {
	CAPTURE_CONSOLE_BEGIN
	lexTest("2 + (-3 * 4);");
	CAPTURE_CONSOLE_END

	CHECK(capture.str() == R"p(2
+
(
-
3
*
4
)
;
)p");
}

TEST_CASE("Lex Error") {
	CAPTURE_CONSOLE_BEGIN
	lexTest("2 % 2;");
	CAPTURE_CONSOLE_END

	CHECK(capture.str() == R"p(2
!ERROR!
2
;
)p");
	FrameMark;
}

TEST_CASE("Lex Multi") {
	CAPTURE_CONSOLE_BEGIN
	lexTest("2 + 2; 4 / 2; 5 - 6;");
	CAPTURE_CONSOLE_END

	CHECK(capture.str() == R"p(2
+
2
;
4
/
2
;
5
-
6
;
)p");
	FrameMark;
}





void yaccTest(std::string string) {
	yy_scan_string(string.c_str());
	ZoneScoped;
	yyparse();
}

TEST_CASE("Yacc Test 1") {
	CAPTURE_CONSOLE_BEGIN
	yaccTest("2 + 2;");
	CAPTURE_CONSOLE_END

	CHECK(capture.str() == " = 4\n");
	FrameMark;
}

TEST_CASE("Yacc Test 2") {
	CAPTURE_CONSOLE_BEGIN
	yaccTest("2 + (3 * 4);");
	CAPTURE_CONSOLE_END

	CHECK(capture.str() == " = 14\n");
	FrameMark;
}

TEST_CASE("Yacc Test 2 (precedence)") {
	CAPTURE_CONSOLE_BEGIN
	yaccTest("2 + 3 * 4;");
	CAPTURE_CONSOLE_END

	CHECK(capture.str() == " = 14\n");
	FrameMark;
}

TEST_CASE("Yacc Test 3") {
	CAPTURE_CONSOLE_BEGIN
	yaccTest("20 + 30;");
	CAPTURE_CONSOLE_END

	CHECK(capture.str() == " = 50\n");
	FrameMark;
}

TEST_CASE("Yacc Test Negative") {
	CAPTURE_ERROR_CONSOLE_BEGIN
	yaccTest("2 + (-3 * 4);");
	CAPTURE_ERROR_CONSOLE_END

	CHECK(capture.str() == "syntax error\n");
	FrameMark;
}

TEST_CASE("Yacc Error") {
	CAPTURE_ERROR_CONSOLE_BEGIN
	yaccTest("2 % 2;");
	CAPTURE_ERROR_CONSOLE_END

	CHECK(capture.str() == "syntax error\n");
	FrameMark;
}

TEST_CASE("Yacc Multi") {
	CAPTURE_CONSOLE_BEGIN
	yaccTest("2 + 2; 4 / 2; 5 - 6;");
	CAPTURE_CONSOLE_END

	CHECK(capture.str() == " = 4\n = 2\n = -1\n");
	FrameMark;
}