#include "../lox.hpp"

TEST_CASE("Lox::For::fun_in_body") {
	ZoneScopedN("Lox::For::fun_in_body");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/for/fun_in_body.lox.hpp"
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
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:10-13
   
for (;;) fun foo() {}
            ^^^
Unexpected token `4` detected!
An error has occurred at <transient>:1:29-30
   
for (;;) fun foo() {}
                               ^
  Unexpected token `3` detected!
)");
#endif
	FrameMark;
}

// TEST_CASE("Lox::For::scope") {
// 	ZoneScopedN("Lox::For::scope");
// 	// CAPTURE_CONSOLE_BEGIN
// 		doir::ParseModule module(
// #include "../../../../generated/for/scope.lox.hpp"
// 		);
// 		auto root = lox::parse{}.start(module);
// 		REQUIRE(root != 0);
// 		canonicalize(module, root, false);
//         print(module, root, true);
// 		REQUIRE(verify_references(module));
// 		REQUIRE(verify_redeclarations(module));
// 		REQUIRE(verify_call_arrities(module));
// 		REQUIRE(identify_trailing_calls(module));

// 		REQUIRE(interpret(module));
// // 	CAPTURE_CONSOLE_END
// // #ifndef LOX_PERFORMANT_PRINTING
// // 	CHECK(capture.str() == R"()");
// // #endif
// 	FrameMark;
// }

TEST_CASE("Lox::For::statement_condition") {
	ZoneScopedN("Lox::For::statement_condition");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/for/statement_condition.lox.hpp"
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
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:17-18
   
for (var a = 1; {}; a = a + 1) {}
                   ^
Unexpected token `2` detected!
An error has occurred at <transient>:1:20-21
   
for (var a = 1; {}; a = a + 1) {}
                      ^
Unexpected token `7` detected!
An error has occurred at <transient>:1:47-48
   
for (var a = 1; {}; a = a + 1) {}
                                                 ^
                    Unexpected token `3` detected!
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::For::statement_increment") {
	ZoneScopedN("Lox::For::statement_increment");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/for/statement_increment.lox.hpp"
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
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:24-25
   
for (var a = 1; a < 2; {}) {}
                          ^
Unexpected token `2` detected!
An error has occurred at <transient>:1:33-34
   
for (var a = 1; a < 2; {}) {}
                                   ^
      Unexpected token `3` detected!
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::For::statement_initializer") {
	ZoneScopedN("Lox::For::statement_initializer");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/for/statement_initializer.lox.hpp"
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
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:6-7
   
for ({}; a < 2; a = a + 1) {}
        ^
Unexpected token `2` detected!
An error has occurred at <transient>:1:9-10
   
for ({}; a < 2; a = a + 1) {}
           ^
Unexpected token `7` detected!
An error has occurred at <transient>:1:22-23
   
for ({}; a < 2; a = a + 1) {}
                        ^
Unexpected token `7` detected!
An error has occurred at <transient>:1:49-50
   
for ({}; a < 2; a = a + 1) {}
                                                   ^
                      Unexpected token `3` detected!
)");
#endif
	FrameMark;
}

// TEST_CASE("Lox::For::syntax") {
// 	ZoneScopedN("Lox::For::syntax");
// 	CAPTURE_CONSOLE_BEGIN
// 		doir::ParseModule module(
// #include "../../../../generated/for/syntax.lox.hpp"
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
// 	CHECK(capture.str() == R"()");
// #endif
// 	FrameMark;
// }

TEST_CASE("Lox::For::var_in_body") {
	ZoneScopedN("Lox::For::var_in_body");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/for/var_in_body.lox.hpp"
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
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:10-13
   
for (;;) var foo;
            ^^^
Unexpected token `5` detected!
An error has occurred at <transient>:1:21-22
   
for (;;) var foo;
                       ^
Unexpected token `7` detected!
)");
#endif
	FrameMark;
}