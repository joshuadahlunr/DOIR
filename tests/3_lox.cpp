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
			doir::TrivialModule::set_current_module(module);
			doir::Lox::calculate_child_count(module, root, true);
			doir::Lox::sort_parse_into_reverse_post_order_traversal(module, root);
			doir::Lox::lookup_references(module);

			auto valid = doir::Lox::verify_references(module);
			valid = valid & doir::Lox::verify_redeclarations(module);
			// valid = valid & doir::Lox::verify_call_arrities(module);
			CHECK(valid);
#ifdef DOIR_ENABLE_BENCHMARKING
		});
#endif
		DOIR_FRAME_MARK;
	}

	TEST_CASE("doir::Lox::3AC") {
		#ifdef DOIR_ENABLE_BENCHMARKING
				ankerl::nanobench::Bench().run("doir::Lox::3AC", []{
		#endif
					DOIR_ZONE_SCOPED_NAMED("doir::Lox::3AC");
					// From: https://github.com/munificent/craftinginterpreters/blob/master/test/benchmark/equality.lox
					auto [module, root] = doir::Lox::parse(R"(
var x = 5; var y = 6; var z = 7;
print x + y * z / (z - y);
					)");
					CHECK(root == 1);
					doir::TrivialModule::set_current_module(module);
					doir::Lox::calculate_child_count(module, root, true);
					doir::Lox::sort_parse_into_reverse_post_order_traversal(module, root);
					doir::Lox::lookup_references(module);

					auto valid = doir::Lox::verify_references(module);
					valid = valid & doir::Lox::verify_redeclarations(module);
					// valid = valid & doir::Lox::verify_call_arrities(module);
					CHECK(valid);
					
					doir::Lox::build_3ac(module);
					CHECK(fp::raii::string{doir::Lox::dump_3ac(module)} ==
R"(23 ← 5 immediate
19 ← 6 immediate
15 ← 7 immediate
10 ← 15 - 19
7 ← 19 * 15
6 ← 7 / 10
4 ← 23 + 6
)");
			
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
			doir::TrivialModule::set_current_module(module);
			doir::Lox::calculate_child_count(module, root, true);
			doir::Lox::sort_parse_into_reverse_post_order_traversal(module, root);
			doir::Lox::lookup_references(module);

			auto valid = doir::Lox::verify_references(module);
			valid = valid & doir::Lox::verify_redeclarations(module);
			// valid = valid & doir::Lox::verify_call_arrities(module);
			CHECK(valid);
#ifdef DOIR_ENABLE_BENCHMARKING
		});
#endif
		DOIR_FRAME_MARK;
	}

	TEST_CASE("doir::Lox::Equality::serialized") {
		#ifdef DOIR_ENABLE_BENCHMARKING
				ankerl::nanobench::Bench().run("doir::Lox::Equality::serialized", []{
		#endif
					DOIR_ZONE_SCOPED_NAMED("doir::Lox::Equality::serialized");
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
			doir::TrivialModule::set_current_module(module);
			doir::Lox::calculate_child_count(module, root, true);
			doir::Lox::sort_parse_into_reverse_post_order_traversal(module, root);
			doir::Lox::lookup_references(module);

			auto valid = doir::Lox::verify_references(module);
			valid = valid & doir::Lox::verify_redeclarations(module);
			// valid = valid & doir::Lox::verify_call_arrities(module);
			CHECK(valid);

			doir::Lox::build_3ac(module);
			auto binary = doir::Lox::to_binary(module, root);
			{
				auto [serialized_module, serialized_root] = doir::Lox::from_binary(binary);
				CHECK(fp::raii::string{doir::Lox::dump(serialized_module, serialized_root)} == fp::raii::string{doir::Lox::dump(module, root)});
			}
#ifdef DOIR_ENABLE_BENCHMARKING
		});
#endif
		DOIR_FRAME_MARK;
	}
}