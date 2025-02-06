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

		if(!root) continue;
		doir::Lox::sort_parse_into_reverse_post_order_traversal(module, root);
		doir::Lox::dump(module, root);
	}
}