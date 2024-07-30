#include "../lox.hpp"

TEST_CASE("Lox::Block::empty") {
	ZoneScopedN("Lox::Block::empty");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/block/empty.lox.hpp"
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

TEST_CASE("Lox::Block::scope") {
	ZoneScopedN("Lox::Block::scope");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/block/scope.lox.hpp"
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
	CHECK(capture.str() == R"(inner
outer
)");
#endif
	FrameMark;
}