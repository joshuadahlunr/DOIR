#include "../lox.hpp"

TEST_CASE("Lox::Bool::equality") {
	ZoneScopedN("Lox::Bool::equality");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/bool/equality.lox.hpp"
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
	CHECK(capture.str() == R"(true
false
false
true
false
false
false
false
false
false
true
true
false
true
true
true
true
true
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Bool::not") {
	ZoneScopedN("Lox::Bool::not");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/bool/not.lox.hpp"
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
true
true
)");
#endif
	FrameMark;
}

