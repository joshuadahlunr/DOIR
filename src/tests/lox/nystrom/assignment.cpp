#include "../lox.hpp"

TEST_CASE("Lox::Assignment::associativity") {
	ZoneScopedN("Lox::Assignment::associativity");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/assignment/associativity.lox.hpp"
		);
		auto root = lox::parse{}.start(module);
		REQUIRE(root != 0);
		canonicalize(module, root, false);
		REQUIRE(verify_references(module));
		REQUIRE(verify_redeclarations(module));
		REQUIRE(verify_call_arrities(module));
		REQUIRE(identify_trailing_calls(module));

		REQUIRE(interpret(module));
	CAPTURE_CONSOLE_END
#ifndef LOX_PERFORMANT_PRINTING
	CHECK(capture.str() == R"(c
c
c
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Assignment::global") {
	ZoneScopedN("Lox::Assignment::global");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/assignment/global.lox.hpp"
		);
		auto root = lox::parse{}.start(module);
		REQUIRE(root != 0);
		canonicalize(module, root, false);
		REQUIRE(verify_references(module));
		REQUIRE(verify_redeclarations(module));
		REQUIRE(verify_call_arrities(module));
		REQUIRE(identify_trailing_calls(module));

		REQUIRE(interpret(module));
	CAPTURE_CONSOLE_END
#ifndef LOX_PERFORMANT_PRINTING
	CHECK(capture.str() == R"(before
after
arg
arg
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Assignment::grouping") {
	ZoneScopedN("Lox::Assignment::grouping");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/assignment/grouping.lox.hpp"
		);
		auto root = lox::parse{}.start(module);
		REQUIRE(root == 0);
		// canonicalize(module, root, false);
		// REQUIRE(verify_references(module));
		// REQUIRE(verify_redeclarations(module));
		// REQUIRE(verify_call_arrities(module));
		// REQUIRE(identify_trailing_calls(module));

		// REQUIRE(interpret(module));
	CAPTURE_ERROR_CONSOLE_END
#ifndef LOX_PERFORMANT_PRINTING
	CHECK(capture.str() == R"(An error has occurred at <transient>:2:5-6
   
(a) = "value"; // Error at '=': Invalid assignment target.
       ^
Expected token not found
An error has occurred at <transient>:2:22-23
   
(a) = "value"; // Error at '=': Invalid assignment target.
                        ^
Unexpected token `7` detected!
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Assignment::infix_operator") {
	ZoneScopedN("Lox::Assignment::infix_operator");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/assignment/infix_operator.lox.hpp"
		);
		auto root = lox::parse{}.start(module);
		REQUIRE(root == 0);
		// canonicalize(module, root, false);
		// REQUIRE(verify_references(module));
		// REQUIRE(verify_redeclarations(module));
		// REQUIRE(verify_call_arrities(module));
		// REQUIRE(identify_trailing_calls(module));

		// REQUIRE(interpret(module));
	CAPTURE_ERROR_CONSOLE_END
#ifndef LOX_PERFORMANT_PRINTING
	CHECK(capture.str() == R"(An error has occurred at <transient>:3:7-8
   
a + b = "value"; // Error at '=': Invalid assignment target.
         ^
Expected token not found
An error has occurred at <transient>:3:24-25
   
a + b = "value"; // Error at '=': Invalid assignment target.
                          ^
Unexpected token `7` detected!
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Assignment::local") {
	ZoneScopedN("Lox::Assignment::local");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/assignment/local.lox.hpp"
		);
		auto root = lox::parse{}.start(module);
		REQUIRE(root != 0);
		canonicalize(module, root, false);
		REQUIRE(verify_references(module));
		REQUIRE(verify_redeclarations(module));
		REQUIRE(verify_call_arrities(module));
		REQUIRE(identify_trailing_calls(module));

		REQUIRE(interpret(module));
	CAPTURE_CONSOLE_END
#ifndef LOX_PERFORMANT_PRINTING
	CHECK(capture.str() == R"(before
after
arg
arg
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Assignment::prefix_operator") {
	ZoneScopedN("Lox::Assignment::prefix_operator");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/assignment/prefix_operator.lox.hpp"
		);
		auto root = lox::parse{}.start(module);
		REQUIRE(root == 0);
		// canonicalize(module, root, false);
		// REQUIRE(verify_references(module));
		// REQUIRE(verify_redeclarations(module));
		// REQUIRE(verify_call_arrities(module));
		// REQUIRE(identify_trailing_calls(module));

		// REQUIRE(interpret(module));
	CAPTURE_ERROR_CONSOLE_END
#ifndef LOX_PERFORMANT_PRINTING
	CHECK(capture.str() == R"(An error has occurred at <transient>:2:4-5
   
!a = "value"; // Error at '=': Invalid assignment target.
      ^
Expected token not found
An error has occurred at <transient>:2:21-22
   
!a = "value"; // Error at '=': Invalid assignment target.
                       ^
Unexpected token `7` detected!
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Assignment::syntax") {
	ZoneScopedN("Lox::Assignment::syntax");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/assignment/syntax.lox.hpp"
		);
		auto root = lox::parse{}.start(module);
		REQUIRE(root != 0);
		canonicalize(module, root, false);
		REQUIRE(verify_references(module));
		REQUIRE(verify_redeclarations(module));
		REQUIRE(verify_call_arrities(module));
		REQUIRE(identify_trailing_calls(module));

		REQUIRE(interpret(module));
	CAPTURE_CONSOLE_END
#ifndef LOX_PERFORMANT_PRINTING
	CHECK(capture.str() == R"(var
var
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Assignment::undefined") {
	ZoneScopedN("Lox::Assignment::undefined");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/assignment/undefined.lox.hpp"
		);
		auto root = lox::parse{}.start(module);
		REQUIRE(root != 0);
		canonicalize(module, root, false);
		REQUIRE(!verify_references(module));
		// REQUIRE(verify_redeclarations(module));
		// REQUIRE(verify_call_arrities(module));
		// REQUIRE(identify_trailing_calls(module));

		// REQUIRE(interpret(module));
	CAPTURE_ERROR_CONSOLE_END
#ifndef LOX_PERFORMANT_PRINTING
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:1-8
   unknown = "what"; // expect runtime error: Undefined variable 'unknown'.
   ^^^^^^^
Failed to find variable: unknown (3)
)");
#endif
	FrameMark;
}