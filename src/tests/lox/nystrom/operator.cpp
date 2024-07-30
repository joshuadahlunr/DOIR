#include "../lox.hpp"

TEST_CASE("Lox::Operator::add_bool_nil.lox") {
	ZoneScopedN("Lox::Operator::add_bool_nil.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/operator/add_bool_nil.lox.hpp"
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
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:6-7
   true + nil; // expect runtime error: Operands must be two numbers or two strings.
        ^
Operands have different types: boolean and null
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Operator::add_bool_num.lox") {
	ZoneScopedN("Lox::Operator::add_bool_num.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/operator/add_bool_num.lox.hpp"
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
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:6-7
   true + 123; // expect runtime error: Operands must be two numbers or two strings.
        ^
Operands have different types: boolean and number
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Operator::add_bool_string.lox") {
	ZoneScopedN("Lox::Operator::add_bool_string.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/operator/add_bool_string.lox.hpp"
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
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:6-7
   true + "s"; // expect runtime error: Operands must be two numbers or two strings.
        ^
Operands have different types: boolean and string
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Operator::add_nil_nil.lox") {
	ZoneScopedN("Lox::Operator::add_nil_nil.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/operator/add_nil_nil.lox.hpp"
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
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:5-6
   nil + nil; // expect runtime error: Operands must be two numbers or two strings.
       ^
Only strings and numbers can be added!
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Operator::add_string_nil.lox") {
	ZoneScopedN("Lox::Operator::add_string_nil.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/operator/add_string_nil.lox.hpp"
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
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:5-6
   "s" + nil; // expect runtime error: Operands must be two numbers or two strings.
       ^
Operands have different types: string and null
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Operator::add.lox") {
	ZoneScopedN("Lox::Operator::add.lox");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/operator/add.lox.hpp"
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
	CHECK(capture.str() == R"(579
string
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Operator::comparison.lox") {
	ZoneScopedN("Lox::Operator::comparison.lox");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/operator/comparison.lox.hpp"
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
true
false
false
false
true
false
true
true
false
false
false
false
true
true
true
true
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Operator::divide_nonnum_num.lox") {
	ZoneScopedN("Lox::Operator::divide_nonnum_num.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/operator/divide_nonnum_num.lox.hpp"
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
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:5-6
   "1" / 1; // expect runtime error: Operands must be numbers.
       ^
Operands have different types: string and number
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Operator::divide_num_nonnum.lox") {
	ZoneScopedN("Lox::Operator::divide_num_nonnum.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/operator/divide_num_nonnum.lox.hpp"
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
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:3-4
   1 / "1"; // expect runtime error: Operands must be numbers.
     ^
Operands have different types: number and string
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Operator::divide.lox") {
	ZoneScopedN("Lox::Operator::divide.lox");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/operator/divide.lox.hpp"
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
	CHECK(capture.str() == R"(4
1
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Operator::equals.lox") {
	ZoneScopedN("Lox::Operator::equals.lox");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/operator/equals.lox.hpp"
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
true
false
true
false
true
false
false
false
false
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Operator::greater_nonnum_num.lox") {
	ZoneScopedN("Lox::Operator::greater_nonnum_num.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/operator/greater_nonnum_num.lox.hpp"
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
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:5-6
   "1" > 1; // expect runtime error: Operands must be numbers.
       ^
Operands have different types: string and number
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Operator::greater_num_nonnum.lox") {
	ZoneScopedN("Lox::Operator::greater_num_nonnum.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/operator/greater_num_nonnum.lox.hpp"
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
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:3-4
   1 > "1"; // expect runtime error: Operands must be numbers.
     ^
Operands have different types: number and string
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Operator::greater_or_equal_nonnum_num.lox") {
	ZoneScopedN("Lox::Operator::greater_or_equal_nonnum_num.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/operator/greater_or_equal_nonnum_num.lox.hpp"
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
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:5-7
   "1" >= 1; // expect runtime error: Operands must be numbers.
       ^^
Operands have different types: string and number
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Operator::greater_or_equal_num_nonnum.lox") {
	ZoneScopedN("Lox::Operator::greater_or_equal_num_nonnum.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/operator/greater_or_equal_num_nonnum.lox.hpp"
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
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:3-5
   1 >= "1"; // expect runtime error: Operands must be numbers.
     ^^
Operands have different types: number and string
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Operator::less_nonnum_num.lox") {
	ZoneScopedN("Lox::Operator::less_nonnum_num.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/operator/less_nonnum_num.lox.hpp"
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
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:5-6
   "1" < 1; // expect runtime error: Operands must be numbers.
       ^
Operands have different types: string and number
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Operator::less_num_nonnum.lox") {
	ZoneScopedN("Lox::Operator::less_num_nonnum.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/operator/less_num_nonnum.lox.hpp"
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
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:3-4
   1 < "1"; // expect runtime error: Operands must be numbers.
     ^
Operands have different types: number and string
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Operator::less_or_equal_nonnum_num.lox") {
	ZoneScopedN("Lox::Operator::less_or_equal_nonnum_num.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/operator/less_or_equal_nonnum_num.lox.hpp"
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
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:5-7
   "1" <= 1; // expect runtime error: Operands must be numbers.
       ^^
Operands have different types: string and number
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Operator::less_or_equal_num_nonnum.lox") {
	ZoneScopedN("Lox::Operator::less_or_equal_num_nonnum.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/operator/less_or_equal_num_nonnum.lox.hpp"
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
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:3-5
   1 <= "1"; // expect runtime error: Operands must be numbers.
     ^^
Operands have different types: number and string
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Operator::multiply_nonnum_num.lox") {
	ZoneScopedN("Lox::Operator::multiply_nonnum_num.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/operator/multiply_nonnum_num.lox.hpp"
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
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:5-6
   "1" * 1; // expect runtime error: Operands must be numbers.
       ^
Operands have different types: string and number
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Operator::multiply_num_nonnum.lox") {
	ZoneScopedN("Lox::Operator::multiply_num_nonnum.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/operator/multiply_num_nonnum.lox.hpp"
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
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:3-4
   1 * "1"; // expect runtime error: Operands must be numbers.
     ^
Operands have different types: number and string
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Operator::multiply.lox") {
	ZoneScopedN("Lox::Operator::multiply.lox");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/operator/multiply.lox.hpp"
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
	CHECK(capture.str() == R"(15
3.702
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Operator::negate_nonnum.lox") {
	ZoneScopedN("Lox::Operator::negate_nonnum.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/operator/negate_nonnum.lox.hpp"
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
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:1-2
   -"s"; // expect runtime error: Operand must be a number.
   ^
Only numbers can be negated!
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Operator::negate.lox") {
	ZoneScopedN("Lox::Operator::negate.lox");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/operator/negate.lox.hpp"
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
	CHECK(capture.str() == R"(-3
3
-3
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Operator::not_equals.lox") {
	ZoneScopedN("Lox::Operator::not_equals.lox");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/operator/not_equals.lox.hpp"
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
false
true
false
true
false
true
true
true
true
)");
#endif
	FrameMark;
}

// TEST_CASE("Lox::Operator::not.lox") {
// 	ZoneScopedN("Lox::Operator::not.lox");
// 	CAPTURE_CONSOLE_BEGIN
// 		doir::ParseModule module(
// #include "../../../../generated/operator/not.lox.hpp"
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

TEST_CASE("Lox::Operator::subtract_nonnum_num.lox") {
	ZoneScopedN("Lox::Operator::subtract_nonnum_num.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/operator/subtract_nonnum_num.lox.hpp"
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
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:5-6
   "1" - 1; // expect runtime error: Operands must be numbers.
       ^
Operands have different types: string and number
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Operator::subtract_num_nonnum.lox") {
	ZoneScopedN("Lox::Operator::subtract_num_nonnum.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/operator/subtract_num_nonnum.lox.hpp"
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
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:3-4
   1 - "1"; // expect runtime error: Operands must be numbers.
     ^
Operands have different types: number and string
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Operator::subtract.lox") {
	ZoneScopedN("Lox::Operator::subtract.lox");
	CAPTURE_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/operator/subtract.lox.hpp"
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
	CHECK(capture.str() == R"(1
0
)");
#endif
	FrameMark;
}

TEST_CASE("Lox::Print::missing_argument.lox") {
	ZoneScopedN("Lox::Print::missing_argument.lox");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module(
#include "../../../../generated/print/missing_argument.lox.hpp"
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
   
print;
        ^
Unexpected token `7` detected!
)");
#endif
	FrameMark;
}