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
		doir::Lox::calculate_child_count(module, root, true);
		doir::Lox::sort_parse_into_reverse_post_order_traversal(module, root);
		nowide::cout << doir::Lox::dump(module, root) << std::endl;

		auto binary = doir::Lox::to_binary(module, root);
		nowide::cout << fp_size(binary) << std::endl;
		nowide::cout << line.size() << std::endl;
		nowide::cout << float(fp_size(binary))/line.size() << std::endl;
		{
			auto [module, root] = doir::Lox::from_binary(binary);
			nowide::cout << doir::Lox::dump(module, root) << std::endl;
		}
	}
}