#include "../lox.hpp"

TEST_CASE("Lox::Benchmark::equality" * doctest::skip()) {
	ZoneScopedN("Lox::Benchmark::equality");
	// CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/benchmark/equality.lox.hpp"
		);
		auto root = lox::parse{}.start(module);
		REQUIRE(root != 0);
		canonicalize(module, root, false);
		REQUIRE(verify_references(module));
		REQUIRE(verify_redeclarations(module));
		REQUIRE(verify_call_arrities(module));
		REQUIRE(identify_trailing_calls(module));

		REQUIRE(interpret(module));
// 	CAPTURE_CONSOLE_END
// #ifndef LOX_PERFORMANT_PRINTING
// 	CHECK(capture.str() == R"(c
// c
// c
// )");
// #endif
	FrameMark;
}