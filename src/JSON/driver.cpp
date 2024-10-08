#include <nowide/iostream.hpp>

#define FP_IMPLEMENTATION
#include "json.hpp"

#include <string>

int main() {
	std::string line;
	while(nowide::cin) {
		std::getline(std::cin, line, ';'); line += "\n";
		doir::JSON::parse(line.c_str()/*, variables*/);
		nowide::cout << std::endl; // Make sure input is moved to the next line!
	}
}