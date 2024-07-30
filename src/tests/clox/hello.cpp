// #include "clox.hpp"

// TEST_CASE("Clox::HelloWorld") {
// 	ZoneScopedN("Clox::HelloWorld");
// 	CAPTURE_CONSOLE_BEGIN
// 		std::string source = R"(print "Hello World!"; print 5;)";
// 		initVM();
// 		CHECK(interpret(source.c_str()) == INTERPRET_OK);
// 		freeVM();
// 	CAPTURE_CONSOLE_END
// #ifndef LOX_PERFORMANT_PRINTING
// 	CHECK(capture.str() == R"(hello world!
// 5
// )");
// #endif
// 	FrameMark;
// }