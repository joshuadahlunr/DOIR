#include "../lox.hpp"

TEST_CASE("Lox::Return::after_else.lox") {
	ZoneScopedN("Lox::Return::after_else.lox");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/return/after_else.lox.hpp"
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
	CHECK(capture.str() == "ok\n");
#endif
	FrameMark;
}

TEST_CASE("Lox::Return::after_if.lox") {
	ZoneScopedN("Lox::Return::after_if.lox");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/return/after_if.lox.hpp"
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
	CHECK(capture.str() == "ok\n");
#endif
	FrameMark;
}

// TEST_CASE("Lox::Return::after_while.lox") {
// 	ZoneScopedN("Lox::Return::after_while.lox");
// 	CAPTURE_CONSOLE_BEGIN
// 		doir::ParseModule module(
// #include "../../../../generated/return/after_while.lox.hpp"
// 		);
// 		auto root = lox::parse{}.start(module);
// 		REQUIRE(root != 0);
// 		canonicalize(module, root, false);
// 		REQUIRE(verify_references(module));
// 		REQUIRE(verify_redeclarations(module));
// 		REQUIRE(verify_call_arrities(module));
// 		REQUIRE(identify_trailing_calls(module));

// 		REQUIRE(interpret(module));
// 	CAPTURE_CONSOLE_END
// #ifndef LOX_PERFORMANT_PRINTING
// 	CHECK(capture.str() == "ok\n");
// #endif
// 	FrameMark;
// }

TEST_CASE("Lox::Return::at_top_level.lox") {
	ZoneScopedN("Lox::Return::at_top_level.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/return/at_top_level.lox.hpp"
		);
		auto root = lox::parse{}.start(module);
		REQUIRE(root != 0);
		canonicalize(module, root, false);
		REQUIRE(verify_references(module));
		REQUIRE(verify_redeclarations(module));
		REQUIRE(verify_call_arrities(module));
		REQUIRE(identify_trailing_calls(module));

		REQUIRE(!interpret(module));
	CAPTURE_ERROR_CONSOLE_END
#ifndef LOX_PERFORMANT_PRINTING
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:1-7
   return "wat"; // Error at 'return': Can't return from top-level code.
   ^^^^^^
Can't return from outside a function!
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Return::in_function.lox") {
	ZoneScopedN("Lox::Return::in_function.lox");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/return/in_function.lox.hpp"
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
	CHECK(capture.str() == "ok\n");
#endif
	FrameMark;
}

TEST_CASE("Lox::Return::return_nil_if_no_value.lox") {
	ZoneScopedN("Lox::Return::return_nil_if_no_value.lox");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/return/return_nil_if_no_value.lox.hpp"
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
	CHECK(capture.str() == "nil\n");
#endif
	FrameMark;
}