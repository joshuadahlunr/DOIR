#include <nowide/iostream.hpp>

#define DOIR_IMPLEMENTATION
#define FP_IMPLEMENTATION
#include "json.hpp"

#include <string>
#include "fp/string.hpp"

int main() {
	std::string line;
	while(nowide::cin) {
		std::getline(std::cin, line, ';'); line += "\n";
		auto [module, root] = doir::JSON::parse(line.c_str());
		nowide::cout << fp::raii::string{doir::JSON::dump(module, root)}.data() << std::endl;
	}
}