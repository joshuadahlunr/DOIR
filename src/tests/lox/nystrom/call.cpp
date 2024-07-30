#include "../lox.hpp"

TEST_CASE("Lox::Call::bool") {
	ZoneScopedN("Lox::Call::bool");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/call/bool.lox.hpp"
		);
		auto root = lox::parse{}.start(module);
		REQUIRE(root == 0);
		// canonicalize(module, root, false);
		// REQUIRE(!verify_references(module));
		// REQUIRE(verify_redeclarations(module));
		// REQUIRE(verify_call_arrities(module));
		// REQUIRE(identify_trailing_calls(module));

		// REQUIRE(interpret(module));
	CAPTURE_ERROR_CONSOLE_END
#ifndef LOX_PERFORMANT_PRINTING
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:5-6
   true(); // expect runtime error: Can only call functions and classes.
       ^
Can only call functions (Can't call literals)
An error has occurred at <transient>:1:8-9
   true(); // expect runtime error: Can only call functions and classes.
          ^
Unexpected token `7` detected!
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Call::nil") {
	ZoneScopedN("Lox::Call::nil");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/call/nil.lox.hpp"
		);
		auto root = lox::parse{}.start(module);
		REQUIRE(root == 0);
		// canonicalize(module, root, false);
		// REQUIRE(!verify_references(module));
		// REQUIRE(verify_redeclarations(module));
		// REQUIRE(verify_call_arrities(module));
		// REQUIRE(identify_trailing_calls(module));

		// REQUIRE(interpret(module));
	CAPTURE_ERROR_CONSOLE_END
#ifndef LOX_PERFORMANT_PRINTING
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:4-5
   nil(); // expect runtime error: Can only call functions and classes.
      ^
Can only call functions (Can't call literals)
An error has occurred at <transient>:1:7-8
   nil(); // expect runtime error: Can only call functions and classes.
         ^
Unexpected token `7` detected!
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Call::num") {
	ZoneScopedN("Lox::Call::num");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/call/num.lox.hpp"
		);
		auto root = lox::parse{}.start(module);
		REQUIRE(root == 0);
		// canonicalize(module, root, false);
		// REQUIRE(!verify_references(module));
		// REQUIRE(verify_redeclarations(module));
		// REQUIRE(verify_call_arrities(module));
		// REQUIRE(identify_trailing_calls(module));

		// REQUIRE(interpret(module));
	CAPTURE_ERROR_CONSOLE_END
#ifndef LOX_PERFORMANT_PRINTING
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:4-5
   123(); // expect runtime error: Can only call functions and classes.
      ^
Can only call functions (Can't call literals)
An error has occurred at <transient>:1:7-8
   123(); // expect runtime error: Can only call functions and classes.
         ^
Unexpected token `7` detected!
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Call::string") {
	ZoneScopedN("Lox::Call::string");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/call/string.lox.hpp"
		);
		auto root = lox::parse{}.start(module);
		REQUIRE(root == 0);
		// canonicalize(module, root, false);
		// REQUIRE(!verify_references(module));
		// REQUIRE(verify_redeclarations(module));
		// REQUIRE(verify_call_arrities(module));
		// REQUIRE(identify_trailing_calls(module));

		// REQUIRE(interpret(module));
	CAPTURE_ERROR_CONSOLE_END
#ifndef LOX_PERFORMANT_PRINTING
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:6-7
   "str"(); // expect runtime error: Can only call functions and classes.
        ^
Can only call functions (Can't call literals)
An error has occurred at <transient>:1:9-10
   "str"(); // expect runtime error: Can only call functions and classes.
           ^
Unexpected token `7` detected!
)");
#endif
	FrameMark;
}