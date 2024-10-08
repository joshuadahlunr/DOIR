#include "tests.utils.hpp"

#include "../src/Calculator/calculator.hpp"

TEST_SUITE("calculator") {
	TEST_CASE("doir::Calculator::Operations") {
#ifdef DOIR_ENABLE_BENCHMARKING
		ankerl::nanobench::Bench().run("doir::Calculator::Operations", []{
#endif
			{
				DOIR_ZONE_SCOPED_NAMED("2 + 2");
				auto module = doir::Calculator::parse("2 + 2;");
				CHECK(doir::Calculator::calculate(module, 1) == 4);
			}{
				DOIR_ZONE_SCOPED_NAMED("2 - 2");
				auto module = doir::Calculator::parse("2 - 2;");
				CHECK(doir::Calculator::calculate(module, 1) == 0);
			}{	
				DOIR_ZONE_SCOPED_NAMED("2 * 2");
				auto module = doir::Calculator::parse("2 * 2;");
				CHECK(doir::Calculator::calculate(module, 1) == 4);
			}{
				DOIR_ZONE_SCOPED_NAMED("2 / 2");
				auto module = doir::Calculator::parse("2 / 2;");
				CHECK(doir::Calculator::calculate(module, 1) == 1);
			}{
				DOIR_ZONE_SCOPED_NAMED("2^2");
				auto module = doir::Calculator::parse("2 ^ 2;");
				CHECK(doir::Calculator::calculate(module, 1) == 4);
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
			DOIR_ZONE_SCOPED_NAMED("doir::Calculator::Variables");
			auto module = doir::Calculator::parse("x = 5; x^2;");
			CHECK(doir::Calculator::calculate(module, 1) == 25);
#ifdef DOIR_ENABLE_BENCHMARKING
		});
#endif
		DOIR_FRAME_MARK;
	}

	TEST_CASE("doir::Calculator::PEMDAS") {
#ifdef DOIR_ENABLE_BENCHMARKING
		ankerl::nanobench::Bench().run("doir::Calculator::PEMDAS", []{
#endif
			DOIR_ZONE_SCOPED_NAMED("doir::Calculator::PEMDAS");
			auto module = doir::Calculator::parse("x = 2; y = 6; y^2 / x*(1+x);");
			CHECK(doir::Calculator::calculate(module, 1) == 54);
#ifdef DOIR_ENABLE_BENCHMARKING
		});
#endif
		DOIR_FRAME_MARK;
	}

	TEST_CASE("doir::Calculator::PEMDAS2") {
#ifdef DOIR_ENABLE_BENCHMARKING
		ankerl::nanobench::Bench().run("doir::Calculator::PEMDAS2", []{
#endif
			DOIR_ZONE_SCOPED_NAMED("doir::Calculator::PEMDAS2");
			auto module = doir::Calculator::parse("x = 2; y = 6; y*y / x*(1+x);");
			CHECK(doir::Calculator::calculate(module, 1) == 54);
#ifdef DOIR_ENABLE_BENCHMARKING
		});
#endif
		DOIR_FRAME_MARK;
	}
}