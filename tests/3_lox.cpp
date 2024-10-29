#include "tests.utils.hpp"

#include "../src/Lox/lox.hpp"

TEST_SUITE("calculator") {
	TEST_CASE("doir::Lox::HelloWorld") {
#ifdef DOIR_ENABLE_BENCHMARKING
		ankerl::nanobench::Bench().run("doir::Lox::HelloWorld", []{
#endif
			DOIR_ZONE_SCOPED_NAMED("doir::Lox::HelloWorld");
			auto [module, root] = doir::Lox::parse("print \"Hello World\";");
			CHECK(root == 1);
#ifdef DOIR_ENABLE_BENCHMARKING
		});
#endif
		DOIR_FRAME_MARK;
	}

	TEST_CASE("doir::Lox::Equality") {
#ifdef DOIR_ENABLE_BENCHMARKING
		ankerl::nanobench::Bench().run("doir::Lox::Equality", []{
#endif
			DOIR_ZONE_SCOPED_NAMED("doir::Lox::Equality");
			// From: https://github.com/munificent/craftinginterpreters/blob/master/test/benchmark/equality.lox
			auto [module, root] = doir::Lox::parse(R"(
var i = 0;

var loopStart = clock();

while (i < 10000000) {
  i = i + 1;

  1; 1; 1; 2; 1; nil; 1; "str"; 1; true;
  nil; nil; nil; 1; nil; "str"; nil; true;
  true; true; true; 1; true; false; true; "str"; true; nil;
  "str"; "str"; "str"; "stru"; "str"; 1; "str"; nil; "str"; true;
}

var loopTime = clock() - loopStart;

var start = clock();

i = 0;
while (i < 10000000) {
  i = i + 1;

  1 == 1; 1 == 2; 1 == nil; 1 == "str"; 1 == true;
  nil == nil; nil == 1; nil == "str"; nil == true;
  true == true; true == 1; true == false; true == "str"; true == nil;
  "str" == "str"; "str" == "stru"; "str" == 1; "str" == nil; "str" == true;
}
			)");
			CHECK(root == 1);
#ifdef DOIR_ENABLE_BENCHMARKING
		});
#endif
		DOIR_FRAME_MARK;
	}
}