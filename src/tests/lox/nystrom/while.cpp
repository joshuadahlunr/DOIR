#include "../lox.hpp"

TEST_CASE("Lox::While::fun_in_body.lox") {
	ZoneScopedN("Lox::While::fun_in_body.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/while/fun_in_body.lox.hpp"
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
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:14-17
   
while (true) fun foo() {}
                ^^^
Unexpected token `4` detected!
An error has occurred at <transient>:1:33-34
   
while (true) fun foo() {}
                                   ^
      Unexpected token `3` detected!
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::While::return_inside.lox") {
	ZoneScopedN("Lox::While::return_inside.lox");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/while/return_inside.lox.hpp"
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
	CHECK(capture.str() == "i\n");
#endif
	FrameMark;
}

TEST_CASE("Lox::While::syntax.lox") {
	ZoneScopedN("Lox::While::syntax.lox");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/while/syntax.lox.hpp"
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
	CHECK(capture.str() == R"(1
2
3
0
1
2
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::While::var_in_body.lox") {
	ZoneScopedN("Lox::While::var_in_body.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/while/var_in_body.lox.hpp"
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
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:14-17
   
while (true) var foo;
                ^^^
Unexpected token `5` detected!
An error has occurred at <transient>:1:25-26
   
while (true) var foo;
                           ^
Unexpected token `7` detected!
)");
#endif
	FrameMark;
}