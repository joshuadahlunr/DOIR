#include "clox.hpp"

TEST_CASE("Lox::Bool::equality") {
	ZoneScopedN("Lox::Bool::equality");
	CAPTURE_CONSOLE_BEGIN
		std::string source =
#include "../../../generated/bool/equality.lox.hpp"
		;
		initVM();
		CHECK(interpret(source.c_str()) == INTERPRET_OK);
		freeVM();
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
		std::string source =
#include "../../../../generated/bool/not.lox.hpp"
		;
		initVM();
		CHECK(interpret(source.c_str()) == INTERPRET_OK);
		freeVM();
	CAPTURE_CONSOLE_END
#ifndef LOX_PERFORMANT_PRINTING
	CHECK(capture.str() == R"(false
true
true
)");
#endif
	FrameMark;
}

