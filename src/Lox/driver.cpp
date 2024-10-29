#include <nowide/iostream.hpp>

#define DOIR_IMPLEMENTATION
#define FP_IMPLEMENTATION
#include "lox.hpp"

#include <string>

int main() {
	std::string line;
	while(nowide::cin) {
		std::getline(std::cin, line, '~');
		auto [module, root] = doir::Lox::parse(line.c_str());
		// auto str = doir::JSON::dump(module, root);
		if(root) doir::Lox::dump(module, root);
		// nowide::cout << str << std::endl;
		// fp_string_free(str);
	}
}