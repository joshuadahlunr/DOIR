#pragma once

#include <doctest/doctest.h>
#include <tracy/Tracy.hpp>

#define CAPTURE_CONSOLE_BEGIN std::stringstream capture; \
/* capture(nowide::cout) */{\
	std::streambuf* std__cout_buf = nowide::cout.rdbuf();\
	nowide::cout.rdbuf(capture.rdbuf());

#define CAPTURE_CONSOLE_END nowide::cout.rdbuf(std__cout_buf); }

#define CAPTURE_ERROR_CONSOLE_BEGIN std::stringstream capture; \
/* capture(nowide::cerr) */{\
	std::streambuf* std__cerr_buf = nowide::cerr.rdbuf();\
	nowide::cerr.rdbuf(capture.rdbuf());

#define CAPTURE_ERROR_CONSOLE_END nowide::cerr.rdbuf(std__cerr_buf); }