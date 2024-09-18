#pragma once

#include <doctest/doctest.h>
#include <nanobench.h>

#include "../src/utility/profile.config.hpp"

#define CAPTURE_CONSOLE_BEGIN std::stringstream capture; \
/* capture(std::cout) */{\
	std::streambuf* std__cout_buf = std::cout.rdbuf();\
	std::cout.rdbuf(capture.rdbuf());

#define CAPTURE_CONSOLE_END std::cout.rdbuf(std__cout_buf); }

#define CAPTURE_ERROR_CONSOLE_BEGIN std::stringstream capture; \
/* capture(std::cerr) */{\
	std::streambuf* std__cerr_buf = std::cerr.rdbuf();\
	std::cerr.rdbuf(capture.rdbuf());

#define CAPTURE_ERROR_CONSOLE_END std::cerr.rdbuf(std__cerr_buf); }

#include <iostream>