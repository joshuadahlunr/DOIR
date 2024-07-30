#include "../lox.hpp"

// TEST_CASE("Lox::Variable::collide_with_parameter.lox") {
// 	ZoneScopedN("Lox::Variable::collide_with_parameter.lox");
// 	CAPTURE_CONSOLE_BEGIN
// 		doir::ParseModule module(
// #include "../../../../generated/variable/collide_with_parameter.lox.hpp"
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

TEST_CASE("Lox::Variable::duplicate_local.lox") {
	ZoneScopedN("Lox::Variable::duplicate_local.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/variable/duplicate_local.lox.hpp"
		);
		auto root = lox::parse{}.start(module);
		REQUIRE(root != 0);
		canonicalize(module, root, false);
		REQUIRE(verify_references(module));
		REQUIRE(!verify_redeclarations(module));
		// REQUIRE(verify_call_arrities(module));
		// REQUIRE(identify_trailing_calls(module));

		// REQUIRE(interpret(module));
	CAPTURE_CONSOLE_END CAPTURE_ERROR_CONSOLE_END
#ifndef LOX_PERFORMANT_PRINTING
	CHECK(capture.str() == R"(An error has occurred at <transient>:2:7-8
   
  var a = "value";
         ^
Variable a redeclaired!
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Variable::duplicate_parameter.lox") {
	ZoneScopedN("Lox::Variable::duplicate_parameter.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/variable/duplicate_parameter.lox.hpp"
		);
		auto root = lox::parse{}.start(module);
		REQUIRE(root != 0);
		canonicalize(module, root, false);
		REQUIRE(verify_references(module));
		REQUIRE(!verify_redeclarations(module));
		// REQUIRE(verify_call_arrities(module));
		// REQUIRE(identify_trailing_calls(module));

		// REQUIRE(interpret(module));
	CAPTURE_CONSOLE_END CAPTURE_ERROR_CONSOLE_END
#ifndef LOX_PERFORMANT_PRINTING
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:9-12
   fun foo(arg,
           ^^^
Variable arg redeclaired!
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Variable::early_bound.lox") {
	ZoneScopedN("Lox::Variable::early_bound.lox");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/variable/early_bound.lox.hpp"
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
	CHECK(capture.str() == R"(outer
outer
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Variable::in_middle_of_block.lox") {
	ZoneScopedN("Lox::Variable::in_middle_of_block.lox");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/variable/in_middle_of_block.lox.hpp"
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
	CHECK(capture.str() == R"(a
a b
a c
a b d
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Variable::in_nested_block.lox") {
	ZoneScopedN("Lox::Variable::in_nested_block.lox");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/variable/in_nested_block.lox.hpp"
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
	CHECK(capture.str() == "outer\n");
#endif
	FrameMark;
}


// TEST_CASE("Lox::Variable::redeclare_global.lox") {
// 	ZoneScopedN("Lox::Variable::redeclare_global.lox");
// 	CAPTURE_CONSOLE_BEGIN
// 		doir::ParseModule module(
// #include "../../../../generated/variable/redeclare_global.lox.hpp"
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

// TEST_CASE("Lox::Variable::redefine_global.lox") {
// 	ZoneScopedN("Lox::Variable::redefine_global.lox");
// 	CAPTURE_CONSOLE_BEGIN
// 		doir::ParseModule module(
// #include "../../../../generated/variable/redefine_global.lox.hpp"
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

TEST_CASE("Lox::Variable::scope_reuse_in_different_blocks.lox") {
	ZoneScopedN("Lox::Variable::scope_reuse_in_different_blocks.lox");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/variable/scope_reuse_in_different_blocks.lox.hpp"
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
	CHECK(capture.str() == R"(first
second
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Variable::shadow_and_local.lox") {
	ZoneScopedN("Lox::Variable::shadow_and_local.lox");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/variable/shadow_and_local.lox.hpp"
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
	CHECK(capture.str() == R"(outer
inner
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Variable::shadow_global.lox") {
	ZoneScopedN("Lox::Variable::shadow_global.lox");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/variable/shadow_global.lox.hpp"
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
	CHECK(capture.str() == R"(shadow
global
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Variable::shadow_local.lox") {
	ZoneScopedN("Lox::Variable::shadow_local.lox");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/variable/shadow_local.lox.hpp"
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
	CHECK(capture.str() == R"(shadow
local
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Variable::undefined_global.lox") {
	ZoneScopedN("Lox::Variable::undefined_global.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/variable/undefined_global.lox.hpp"
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
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:7-17
   print notDefined;  // expect runtime error: Undefined variable 'notDefined'.
         ^^^^^^^^^^
Failed to find variable: notDefined (4)
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Variable::undefined_local.lox") {
	ZoneScopedN("Lox::Variable::undefined_local.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/variable/undefined_local.lox.hpp"
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
	CHECK(capture.str() == R"(An error has occurred at <transient>:2:9-19
   
  print notDefined;  // expect runtime error: Undefined variable 'notDefined'.
           ^^^^^^^^^^
Failed to find variable: notDefined (5)
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Variable::uninitialized.lox") {
	ZoneScopedN("Lox::Variable::uninitialized.lox");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/variable/uninitialized.lox.hpp"
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

// TEST_CASE("Lox::Variable::unreached_undefined.lox") {
// 	ZoneScopedN("Lox::Variable::unreached_undefined.lox");
// 	CAPTURE_CONSOLE_BEGIN
// 		doir::ParseModule module(
// #include "../../../../generated/variable/unreached_undefined.lox.hpp"
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

TEST_CASE("Lox::Variable::use_false_as_var.lox") {
	ZoneScopedN("Lox::Variable::use_false_as_var.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/variable/use_false_as_var.lox.hpp"
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
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:5-10
   
var false = "value";
       ^^^^^
Expected token not found
An error has occurred at <transient>:1:30-31
   
var false = "value";
                                ^
   Unexpected token `7` detected!
)");
#endif
	FrameMark;
}

// TEST_CASE("Lox::Variable::use_global_in_initializer.lox") {
// 	ZoneScopedN("Lox::Variable::use_global_in_initializer.lox");
// 	CAPTURE_CONSOLE_BEGIN
// 		doir::ParseModule module(
// #include "../../../../generated/variable/use_global_in_initializer.lox.hpp"
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

// TEST_CASE("Lox::Variable::use_local_in_initializer.lox") {
// 	ZoneScopedN("Lox::Variable::use_local_in_initializer.lox");
// 	CAPTURE_CONSOLE_BEGIN
// 		doir::ParseModule module(
// #include "../../../../generated/variable/use_local_in_initializer.lox.hpp"
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

TEST_CASE("Lox::Variable::use_nil_as_var.lox") {
	ZoneScopedN("Lox::Variable::use_nil_as_var.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/variable/use_nil_as_var.lox.hpp"
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
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:5-8
   
var nil = "value";
       ^^^
Expected token not found
An error has occurred at <transient>:1:28-29
   
var nil = "value";
                              ^
 Unexpected token `7` detected!
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Variable::use_this_as_var.lox") {
	ZoneScopedN("Lox::Variable::use_this_as_var.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/variable/use_this_as_var.lox.hpp"
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
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:5-9
   
var this = "value";
       ^^^^
Expected token not found
An error has occurred at <transient>:1:29-30
   
var this = "value";
                               ^
  Unexpected token `7` detected!
)");
#endif
	FrameMark;
}
