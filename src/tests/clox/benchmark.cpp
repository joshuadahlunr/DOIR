#include "clox.hpp"

TEST_CASE("Lox::Benchmark::equality" * doctest::skip()) {
	ZoneScopedN("Lox::Benchmark::equality");
	// CAPTURE_CONSOLE_BEGIN
		std::string source(
#include "../../../../generated/benchmark/equality.lox.hpp"
		);
		initVM();
		CHECK(interpret(source.c_str()) == INTERPRET_OK);
		freeVM();
// 	CAPTURE_CONSOLE_END
// #ifndef LOX_PERFORMANT_PRINTING
// 	CHECK(capture.str() == R"(c
// c
// c
// )");
// #endif
	FrameMark;
}