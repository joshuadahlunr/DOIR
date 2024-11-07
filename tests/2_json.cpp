#include "tests.utils.hpp"

#include "../src/JSON/json.hpp"

#include <nlohmann/json.hpp>
using json = nlohmann::json;

TEST_SUITE("JSON") {

	TEST_CASE("doir::JSON::Atoms") {
#ifdef DOIR_ENABLE_BENCHMARKING
		ankerl::nanobench::Bench().run("doir::JSON::Atoms", []{
#endif
			{DOIR_ZONE_SCOPED_NAMED("doir::JSON::Atoms::True");
				json data = json::parse("true");
				CHECK(data.dump() == "true");
			}{DOIR_ZONE_SCOPED_NAMED("doir::JSON::Atoms::False");
				json data = json::parse("false");
				CHECK(data.dump() == "false");
			}{DOIR_ZONE_SCOPED_NAMED("doir::JSON::Atoms::Null");
				json data = json::parse("null");
				CHECK(data.dump() == "null");
			}{DOIR_ZONE_SCOPED_NAMED("doir::JSON::Atoms::Number");
				json data = json::parse("5");
				CHECK(data.dump() == "5");
			}{DOIR_ZONE_SCOPED_NAMED("doir::JSON::Atoms::String");
				json data = json::parse("\"Hello World\"");
				CHECK(data.dump() == "\"Hello World\"");
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
			json data = json::parse("[true, false, null, 5.5, \"Hello\"]");
			CHECK(data.dump() == "[true,false,null,5.5,\"Hello\"]");

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
			json data = json::parse("{\"bool\": true, \"!bool\": false, \"null\": null, \"num\": 5.5, \"str\": \"Hello\"}");
			CHECK(data.dump() == "{\"!bool\":false,\"bool\":true,\"null\":null,\"num\":5.5,\"str\":\"Hello\"}");

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
			json data = json::parse(R"({"fixed_object":{"int_array":[0,1,2,3,4,5,6],"float_array":[0.1,0.2,0.3,0.4,0.5,0.6],"double_array":[3288398.238,2.33e+24,28.9,0.928759872,0.22222848,0.1,0.2,0.3,0.4]},"fixed_name_object":{"name0":"James","name1":"Abraham","name2":"Susan","name3":"Frank","name4":"Alicia"},"another_object":{"string":"here is some text","another_string":"Hello World","escaped_text":"{\"some key\":\"some string value\"}","boolean":false,"nested_object":{"v3s":[[0.12345,0.23456,0.001345],[0.3894675,97.39827,297.92387],[18.18,87.289,2988.298]],"id":"298728949872"}},"string_array":["Cat","Dog","Elephant","Tiger"],"string":"Hello world","number":3.14,"boolean":true,"another_bool":false})");
			auto eq = data.dump() == R"({"another_bool":false,"another_object":{"another_string":"Hello World","boolean":false,"escaped_text":"{\"some key\":\"some string value\"}","nested_object":{"id":"298728949872","v3s":[[0.12345,0.23456,0.001345],[0.3894675,97.39827,297.92387],[18.18,87.289,2988.298]]},"string":"here is some text"},"boolean":true,"fixed_name_object":{"name0":"James","name1":"Abraham","name2":"Susan","name3":"Frank","name4":"Alicia"},"fixed_object":{"double_array":[3288398.238,2.33e+24,28.9,0.928759872,0.22222848,0.1,0.2,0.3,0.4],"float_array":[0.1,0.2,0.3,0.4,0.5,0.6],"int_array":[0,1,2,3,4,5,6]},"number":3.14,"string":"Hello world","string_array":["Cat","Dog","Elephant","Tiger"]})";
			CHECK(eq);

#ifdef DOIR_ENABLE_BENCHMARKING
		});
#endif
		DOIR_FRAME_MARK;
	}

}