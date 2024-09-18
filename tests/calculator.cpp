#include "tests.utils.hpp"

#include "../src/Calculator/calculator.hpp"

TEST_SUITE("calculator") {
	TEST_CASE("doir::Calculator::Basic") {
#ifdef DOIR_ENABLE_BENCHMARKING
		ankerl::nanobench::Bench().run("doir::Calculator::Basic", []{
#endif
			{DOIR_ZONE_SCOPED_NAMED("Map");
				auto variables = doir::Calculator::create_variable_table();
				REQUIRE(variables != nullptr);
				{DOIR_ZONE_SCOPED_NAMED("Free");
					fp_hash_free(variables);
				}
			}

			CAPTURE_CONSOLE_BEGIN {
				DOIR_ZONE_SCOPED_NAMED("2 + 2");
				doir::Calculator::calculate("2 + 2;");
			} CAPTURE_CONSOLE_END
			CHECK(capture.str() == " = 4\n");
#ifdef DOIR_ENABLE_BENCHMARKING
		});
#endif
		DOIR_FRAME_MARK;
	}

	TEST_CASE("doir::Calculator::Operations") {
#ifdef DOIR_ENABLE_BENCHMARKING
		ankerl::nanobench::Bench().run("doir::Calculator::Operations", []{
#endif
			{
				CAPTURE_CONSOLE_BEGIN {
					DOIR_ZONE_SCOPED_NAMED("2 + 2");
					doir::Calculator::calculate("2 + 2;");
				} CAPTURE_CONSOLE_END
				CHECK(capture.str() == " = 4\n");
			}{
				CAPTURE_CONSOLE_BEGIN {
					DOIR_ZONE_SCOPED_NAMED("2 - 2");
					doir::Calculator::calculate("2 - 2;");
				} CAPTURE_CONSOLE_END
				CHECK(capture.str() == " = 0\n");
			}{
				CAPTURE_CONSOLE_BEGIN {
					DOIR_ZONE_SCOPED_NAMED("2 * 2");
					doir::Calculator::calculate("2 * 2;");
				} CAPTURE_CONSOLE_END
				CHECK(capture.str() == " = 4\n");
			}{
				CAPTURE_CONSOLE_BEGIN {
					DOIR_ZONE_SCOPED_NAMED("2 / 2");
					doir::Calculator::calculate("2 / 2;");
				} CAPTURE_CONSOLE_END
				CHECK(capture.str() == " = 1\n");
			}{
				CAPTURE_CONSOLE_BEGIN {
					DOIR_ZONE_SCOPED_NAMED("2^2");
					doir::Calculator::calculate("2^2;");
				} CAPTURE_CONSOLE_END
				CHECK(capture.str() == " = 4\n");
			}
#ifdef DOIR_ENABLE_BENCHMARKING
		});
#endif
		DOIR_FRAME_MARK;
	}

	TEST_CASE("doir::Calculator::Variables") {
#ifdef DOIR_ENABLE_BENCHMARKING
		ankerl::nanobench::Bench().run("doir::Calculator::Variables", []{
#endif
			CAPTURE_CONSOLE_BEGIN {
				DOIR_ZONE_SCOPED_NAMED("doir::Calculator::Variables");
				doir::Calculator::calculate("x = 5; x^2;");
			} CAPTURE_CONSOLE_END
			CHECK(capture.str() == " = 5\n = 25\n");
#ifdef DOIR_ENABLE_BENCHMARKING
		});
#endif
		DOIR_FRAME_MARK;
	}

	TEST_CASE("doir::Calculator::PEMDAS") {
#ifdef DOIR_ENABLE_BENCHMARKING
		ankerl::nanobench::Bench().run("doir::Calculator::PEMDAS", []{
#endif
			CAPTURE_CONSOLE_BEGIN {
				DOIR_ZONE_SCOPED_NAMED("doir::Calculator::PEMDAS");
				doir::Calculator::calculate("x = 2; y = 6; y^2 / x*(1+x);");
			} CAPTURE_CONSOLE_END
			CHECK(capture.str() == " = 2\n = 6\n = 54\n");
#ifdef DOIR_ENABLE_BENCHMARKING
		});
#endif
		DOIR_FRAME_MARK;
	}

	TEST_CASE("doir::Calculator::PEMDAS2") {
#ifdef DOIR_ENABLE_BENCHMARKING
		ankerl::nanobench::Bench().run("doir::Calculator::PEMDAS2", []{
#endif
			CAPTURE_CONSOLE_BEGIN {
				DOIR_ZONE_SCOPED_NAMED("doir::Calculator::PEMDAS2");
				doir::Calculator::calculate("x = 2; y = 6; y*y / x*(1+x);");
			} CAPTURE_CONSOLE_END
			CHECK(capture.str() == " = 2\n = 6\n = 54\n");
#ifdef DOIR_ENABLE_BENCHMARKING
		});
#endif
		DOIR_FRAME_MARK;
	}
}