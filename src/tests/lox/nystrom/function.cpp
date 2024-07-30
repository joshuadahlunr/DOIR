#include "../lox.hpp"

TEST_CASE("Lox::Function::body_must_be_block.lox") {
	ZoneScopedN("Lox::Function::body_must_be_block.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/function/body_must_be_block.lox.hpp"
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
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:9-12
   
fun f() 123;
           ^^^
Expected token not found
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Function::empty_body.lox") {
	ZoneScopedN("Lox::Function::empty_body.lox");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/function/empty_body.lox.hpp"
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

TEST_CASE("Lox::Function::extra_arguments.lox") {
	ZoneScopedN("Lox::Function::extra_arguments.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/function/extra_arguments.lox.hpp"
		);
		auto root = lox::parse{}.start(module);
		REQUIRE(root != 0);
		canonicalize(module, root, false);
		REQUIRE(verify_references(module));
		REQUIRE(verify_redeclarations(module));
		REQUIRE(!verify_call_arrities(module));
		// REQUIRE(identify_trailing_calls(module));

		// REQUIRE(interpret(module));
	CAPTURE_ERROR_CONSOLE_END
#ifndef LOX_PERFORMANT_PRINTING
	CHECK(capture.str() == R"(An error has occurred at <transient>:6:1-2
   
f(1, 2, 3, 4); // expect runtime error: Expected 2 arguments but got 4.
   ^
Call arity (4) does not match declaration arity (2)
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Function::local_mutual_recursion.lox") {
	ZoneScopedN("Lox::Function::local_mutual_recursion.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/function/local_mutual_recursion.lox.hpp"
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
	CHECK(capture.str() == R"(An error has occurred at <transient>:4:12-17
   
    return isOdd(n - 1); // expect runtime error: Undefined variable 'isOdd'.
              ^^^^^
Failed to find variable: isOdd (29)
An error has occurred at <transient>:4:17-18
   
    return isOdd(n - 1); // expect runtime error: Undefined variable 'isOdd'.
                   ^
Failed to find function: isOdd (28)
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Function::missing_arguments.lox") {
	ZoneScopedN("Lox::Function::missing_arguments.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/function/missing_arguments.lox.hpp"
		);
		auto root = lox::parse{}.start(module);
		REQUIRE(root != 0);
		canonicalize(module, root, false);
		REQUIRE(verify_references(module));
		REQUIRE(verify_redeclarations(module));
		REQUIRE(!verify_call_arrities(module));
		// REQUIRE(identify_trailing_calls(module));

		// REQUIRE(interpret(module));
	CAPTURE_ERROR_CONSOLE_END
#ifndef LOX_PERFORMANT_PRINTING
	CHECK(capture.str() == R"(An error has occurred at <transient>:3:1-2
   
f(1); // expect runtime error: Expected 2 arguments but got 1.
   ^
Call arity (1) does not match declaration arity (2)
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Function::missing_comma_in_parameters.lox") {
	ZoneScopedN("Lox::Function::missing_comma_in_parameters.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/function/missing_comma_in_parameters.lox.hpp"
		);
		auto root = lox::parse{}.start(module);
		REQUIRE(root == 0);
		// canonicalize(module, root, false);
		// REQUIRE(verify_references(module));
		// REQUIRE(verify_redeclarations(module));
		// REQUIRE(!verify_call_arrities(module));
		// REQUIRE(identify_trailing_calls(module));

		// REQUIRE(interpret(module));
	CAPTURE_ERROR_CONSOLE_END
#ifndef LOX_PERFORMANT_PRINTING
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:14-15
   
fun foo(a, b c, d, e, f) {}
                ^
Expected token not found
An error has occurred at <transient>:1:39-40
   
fun foo(a, b c, d, e, f) {}
                                         ^
            Unexpected token `3` detected!
)");
#endif
	FrameMark;
}

// TEST_CASE("Lox::Function::nested_call_with_arguments.lox") {
// 	ZoneScopedN("Lox::Function::nested_call_with_arguments.lox");
// 	CAPTURE_ERROR_CONSOLE_BEGIN
// 		doir::ParseModule module(
// #include "../../../../generated/function/nested_call_with_arguments.lox.hpp"
// 		);
// 		auto root = lox::parse{}.start(module);
// 		REQUIRE(root != 0);
// 		// canonicalize(module, root, false);
// 		// REQUIRE(verify_references(module));
// 		// REQUIRE(verify_redeclarations(module));
// 		// REQUIRE(!verify_call_arrities(module));
// 		// REQUIRE(identify_trailing_calls(module));

// 		// REQUIRE(interpret(module));
// 	CAPTURE_ERROR_CONSOLE_END
// #ifndef LOX_PERFORMANT_PRINTING
// 	CHECK(capture.str() == R"()");
// #endif
// 	FrameMark;
// }

TEST_CASE("Lox::Function::parameters.lox") {
	ZoneScopedN("Lox::Function::parameters.lox");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/function/parameters.lox.hpp"
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
	CHECK(capture.str() == R"(0
1
3
6
10
15
21
28
36
)");
#endif
	FrameMark;
}