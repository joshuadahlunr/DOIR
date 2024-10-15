#include "tests.utils.hpp"

#include "../src/JSON/json.hpp"

TEST_SUITE("JSON") {

	TEST_CASE("doir::JSON::Atoms") {
#ifdef DOIR_ENABLE_BENCHMARKING
		ankerl::nanobench::Bench().run("doir::JSON::Atoms", []{
#endif
			{DOIR_ZONE_SCOPED_NAMED("doir::JSON::Atoms::True");
				auto [module, root] = doir::JSON::parse("true");
				CHECK(fp_string_equal(doir::JSON::dump(module, root), "true"));
			}{DOIR_ZONE_SCOPED_NAMED("doir::JSON::Atoms::False");
				auto [module, root] = doir::JSON::parse("false");
				CHECK(fp_string_equal(doir::JSON::dump(module, root), "false"));
			}{DOIR_ZONE_SCOPED_NAMED("doir::JSON::Atoms::Null");
				auto [module, root] = doir::JSON::parse("null");
				CHECK(fp_string_equal(doir::JSON::dump(module, root), "null"));
			}{DOIR_ZONE_SCOPED_NAMED("doir::JSON::Atoms::Number");
				auto [module, root] = doir::JSON::parse("5");
				CHECK(fp_string_equal(doir::JSON::dump(module, root), "5.000000"));
			}{DOIR_ZONE_SCOPED_NAMED("doir::JSON::Atoms::String");
				auto [module, root] = doir::JSON::parse("\"Hello World\"");
				CHECK(fp_string_equal(doir::JSON::dump(module, root), "\"Hello World\""));
			}
#ifdef DOIR_ENABLE_BENCHMARKING
		});
#endif
		DOIR_FRAME_MARK;
	}

	TEST_CASE("doir::JSON::Array") {
#ifdef DOIR_ENABLE_BENCHMARKING
		ankerl::nanobench::Bench().run("doir::JSON::Array", []{
#endif
			DOIR_ZONE_SCOPED_NAMED("doir::JSON::Array");
			auto [module, root] = doir::JSON::parse("[true, false, null, 5.5, \"Hello\"]");
			CHECK(fp_string_equal(doir::JSON::dump(module, root), "[true,false,null,5.500000,\"Hello\"]"));

#ifdef DOIR_ENABLE_BENCHMARKING
		});
#endif
		DOIR_FRAME_MARK;
	}

	TEST_CASE("doir::JSON::Object") {
#ifdef DOIR_ENABLE_BENCHMARKING
		ankerl::nanobench::Bench().run("doir::JSON::Object", []{
#endif
			DOIR_ZONE_SCOPED_NAMED("doir::JSON::Object");
			auto [module, root] = doir::JSON::parse("{\"bool\": true, \"!bool\": false, \"null\": null, \"num\": 5.5, \"str\": \"Hello\"}");
			CHECK(fp_string_equal(doir::JSON::dump(module, root), "{\"bool\":true,\"!bool\":false,\"null\":null,\"num\":5.500000,\"str\":\"Hello\"}"));

#ifdef DOIR_ENABLE_BENCHMARKING
		});
#endif
		DOIR_FRAME_MARK;
	}

	TEST_CASE("doir::JSON::stephenberry") {
#ifdef DOIR_ENABLE_BENCHMARKING
		ankerl::nanobench::Bench().run("doir::JSON::stephenberry", []{
#endif
			DOIR_ZONE_SCOPED_NAMED("doir::JSON::stephenberry");
			// Data from: https://github.com/stephenberry/json_performance
			auto [module, root] = doir::JSON::parse(R"({"fixed_object":{"int_array":[0,1,2,3,4,5,6],"float_array":[0.1,0.2,0.3,0.4,0.5,0.6],"double_array":[3288398.238,2.33e+24,28.9,0.928759872,0.22222848,0.1,0.2,0.3,0.4]},"fixed_name_object":{"name0":"James","name1":"Abraham","name2":"Susan","name3":"Frank","name4":"Alicia"},"another_object":{"string":"here is some text","another_string":"Hello World","escaped_text":"{\"some key\":\"some string value\"}","boolean":false,"nested_object":{"v3s":[[0.12345,0.23456,0.001345],[0.3894675,97.39827,297.92387],[18.18,87.289,2988.298]],"id":"298728949872"}},"string_array":["Cat","Dog","Elephant","Tiger"],"string":"Hello world","number":3.14,"boolean":true,"another_bool":false})");
			auto eq = fp_string_equal(doir::JSON::dump(module, root), R"({"fixed_object":{"int_array":[0.000000,1.000000,2.000000,3.000000,4.000000,5.000000,6.000000],"float_array":[0.100000,0.200000,0.300000,0.400000,0.500000,0.600000],"double_array":[3288398.238000,2330000000000000062914560.000000,28.900000,0.928760,0.222228,0.100000,0.200000,0.300000,0.400000]},"fixed_name_object":{"name0":"James","name1":"Abraham","name2":"Susan","name3":"Frank","name4":"Alicia"},"another_object":{"string":"here is some text","another_string":"Hello World","escaped_text":"{\"some key\":\"some string value\"}","boolean":false,"nested_object":{"v3s":[[0.123450,0.234560,0.001345],[0.389468,97.398270,297.923870],[18.180000,87.289000,2988.298000]],"id":"298728949872"}},"string_array":["Cat","Dog","Elephant","Tiger"],"string":"Hello world","number":3.140000,"boolean":true,"another_bool":false})");
			CHECK(eq);

#ifdef DOIR_ENABLE_BENCHMARKING
		});
#endif
		DOIR_FRAME_MARK;
	}

}