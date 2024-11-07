#include "tests.utils.hpp"

#include "../src/JSON/json.hpp"
#include <glaze/glaze.hpp>

TEST_SUITE("JSON") {

	TEST_CASE("doir::JSON::Atoms") {
#ifdef DOIR_ENABLE_BENCHMARKING
		ankerl::nanobench::Bench().run("doir::JSON::Atoms", []{
#endif
			glz::json_t json;
			{DOIR_ZONE_SCOPED_NAMED("doir::JSON::Atoms::True");
				CHECK(!glz::read_json(json, "true"));
				CHECK(glz::write_json(json).value() == "true");
			}{DOIR_ZONE_SCOPED_NAMED("doir::JSON::Atoms::False");
				CHECK(!glz::read_json(json, "false"));
				CHECK(glz::write_json(json).value() == "false");
			}{DOIR_ZONE_SCOPED_NAMED("doir::JSON::Atoms::Null");
				CHECK(!glz::read_json(json, "null"));
				CHECK(glz::write_json(json).value() == "null");
			}{DOIR_ZONE_SCOPED_NAMED("doir::JSON::Atoms::Number");
				CHECK(!glz::read_json(json, "5"));
				CHECK(glz::write_json(json).value() == "5");
			}{DOIR_ZONE_SCOPED_NAMED("doir::JSON::Atoms::String");
				CHECK(!glz::read_json(json, "\"Hello World\""));
				CHECK(glz::write_json(json).value() == "\"Hello World\"");
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
			glz::json_t json;
			CHECK(!glz::read_json(json, "[true, false, null, 5.5, \"Hello\"]"));
			CHECK(glz::write_json(json).value() == "[true,false,null,5.5,\"Hello\"]");

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
			glz::json_t json;
			CHECK(!glz::read_json(json, "{\"bool\": true, \"!bool\": false, \"null\": null, \"num\": 5.5, \"str\": \"Hello\"}"));
			CHECK(glz::write_json(json).value() == "{\"!bool\":false,\"bool\":true,\"null\":null,\"num\":5.5,\"str\":\"Hello\"}");
			// auto [module, root] = doir::JSON::parse("{\"bool\": true, \"!bool\": false, \"null\": null, \"num\": 5.5, \"str\": \"Hello\"}");
			// CHECK(fp_string_equal(doir::JSON::dump(module, root), "{\"bool\":true,\"!bool\":false,\"null\":null,\"num\":5.500000,\"str\":\"Hello\"}"));

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
			glz::json_t json;
			CHECK(!glz::read_json(json, R"({"fixed_object":{"int_array":[0,1,2,3,4,5,6],"float_array":[0.1,0.2,0.3,0.4,0.5,0.6],"double_array":[3288398.238,2.33e+24,28.9,0.928759872,0.22222848,0.1,0.2,0.3,0.4]},"fixed_name_object":{"name0":"James","name1":"Abraham","name2":"Susan","name3":"Frank","name4":"Alicia"},"another_object":{"string":"here is some text","another_string":"Hello World","escaped_text":"{\"some key\":\"some string value\"}","boolean":false,"nested_object":{"v3s":[[0.12345,0.23456,0.001345],[0.3894675,97.39827,297.92387],[18.18,87.289,2988.298]],"id":"298728949872"}},"string_array":["Cat","Dog","Elephant","Tiger"],"string":"Hello world","number":3.14,"boolean":true,"another_bool":false})"));
			CHECK(glz::write_json(json).value() == R"({"another_bool":false,"another_object":{"another_string":"Hello World","boolean":false,"escaped_text":"{\"some key\":\"some string value\"}","nested_object":{"id":"298728949872","v3s":[[0.12345,0.23456,0.001345],[0.3894675,97.39827,297.92387],[18.18,87.289,2988.298]]},"string":"here is some text"},"boolean":true,"fixed_name_object":{"name0":"James","name1":"Abraham","name2":"Susan","name3":"Frank","name4":"Alicia"},"fixed_object":{"double_array":[3288398.238,2.33E24,28.9,0.928759872,0.22222848,0.1,0.2,0.3,0.4],"float_array":[0.1,0.2,0.3,0.4,0.5,0.6],"int_array":[0,1,2,3,4,5,6]},"number":3.14,"string":"Hello world","string_array":["Cat","Dog","Elephant","Tiger"]})");

#ifdef DOIR_ENABLE_BENCHMARKING
		});
#endif
		DOIR_FRAME_MARK;
	}

}