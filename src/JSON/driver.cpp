#include <nowide/iostream.hpp>

#define DOIR_IMPLEMENTATION
#define FP_IMPLEMENTATION
#include "json.hpp"

#include <string>

int main() {
	std::string line;
	while(nowide::cin) {
		std::getline(std::cin, line, ';'); line += "\n";
		auto [module, root] = doir::JSON::parse(line.c_str());
		auto str = doir::JSON::dump(module, root);
		nowide::cout << str << std::endl;
		fp_string_free(str);
	}
}