#include "printf_redirect.h"
#include "../tests.utils.hpp"
#include <cstdarg>
#include <sstream>

// This file captures (f)printf calls from the clox implementation and redirects them to cout/cerr so that tests can capture their results

static void format2stream(std::ostream& out, const char* format, va_list args) {
	while (*format) {
		if (*format == '%') {
			++format;
			switch (*format) {
			break; case 'd': [[fallthrough]];
				case 'i': out << va_arg(args, int);
			break; case 'f': [[fallthrough]];
				case 'g': out << va_arg(args, double);
			break; case 's': out << va_arg(args, const char*);
			break; case '%': out << '%';
			break; default: out << '%' << *format;
			}
		} else
			out << *format;
		++format;
	}
}

int test_print(const char* format, ...) {
	std::stringstream buf;

	va_list args;
	va_start(args, format);
	format2stream(buf, format, args);
	va_end(args);

	auto res = buf.str();
	nowide::cout << res;
	//  << std::endl;
	return res.size();
}

int test_fprint(FILE* file, const char* format, ...) {
	std::stringstream buf;

	va_list args;
	va_start(args, format);
	format2stream(buf, format, args);
	va_end(args);

	auto res = buf.str();
	nowide::cerr << res;
	//  << std::endl;
	return res.size();
}

int test_vfprint(FILE* file, const char* format, va_list args) {
	std::stringstream buf;
	format2stream(buf, format, args);

	auto res = buf.str();
	nowide::cerr << res;
	//  << std::endl;
	return res.size();
}