#include "../lox.hpp"

TEST_CASE("Lox::If::dangling_else.lox") {
	ZoneScopedN("Lox::If::dangling_else.lox");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/if/dangling_else.lox.hpp"
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
	CHECK(capture.str() == "good\n");
#endif
	FrameMark;
}

TEST_CASE("Lox::If::else.lox") {
	ZoneScopedN("Lox::If::else.lox");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/if/else.lox.hpp"
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
	CHECK(capture.str() == R"(good
good
block
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::If::fun_in_else.lox") {
	ZoneScopedN("Lox::If::fun_in_else.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/if/fun_in_else.lox.hpp"
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
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:22-25
   
if (true) "ok"; else fun foo() {}
                        ^^^
Unexpected token `4` detected!
An error has occurred at <transient>:1:41-42
   
if (true) "ok"; else fun foo() {}
                                           ^
              Unexpected token `3` detected!
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::If::fun_in_then.lox") {
	ZoneScopedN("Lox::If::fun_in_then.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/if/fun_in_then.lox.hpp"
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
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:11-14
   
if (true) fun foo() {}
             ^^^
Unexpected token `4` detected!
An error has occurred at <transient>:1:30-31
   
if (true) fun foo() {}
                                ^
   Unexpected token `3` detected!
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::If::if.lox") {
	ZoneScopedN("Lox::If::if.lox");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/if/if.lox.hpp"
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
	CHECK(capture.str() == R"(good
block
true
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::If::truth.lox") {
	ZoneScopedN("Lox::If::truth.lox");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/if/truth.lox.hpp"
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
	CHECK(capture.str() == R"(false
nil
true
0
empty
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::If::var_in_else.lox") {
	ZoneScopedN("Lox::If::var_in_else.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/if/var_in_else.lox.hpp"
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
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:22-25
   
if (true) "ok"; else var foo;
                        ^^^
Unexpected token `5` detected!
An error has occurred at <transient>:1:33-34
   
if (true) "ok"; else var foo;
                                   ^
      Unexpected token `7` detected!
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::If::var_in_then.lox") {
	ZoneScopedN("Lox::If::var_in_then.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/if/var_in_then.lox.hpp"
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
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:11-14
   
if (true) var foo;
             ^^^
Unexpected token `5` detected!
An error has occurred at <transient>:1:22-23
   
if (true) var foo;
                        ^
Unexpected token `7` detected!
)");
#endif
	FrameMark;
}