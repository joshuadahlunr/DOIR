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
		doir::TrivialModule::set_current_module(module);

		if(!root) continue;
		doir::Lox::calculate_child_count(module, root, true);
		doir::Lox::sort_parse_into_reverse_post_order_traversal(module, root);
		doir::Lox::lookup_references(module);

		auto valid = doir::Lox::verify_references(module);
		valid = valid & doir::Lox::verify_redeclarations(module);
		// valid = valid & doir::Lox::verify_call_arrities(module);
		if(!valid) continue;
		
		nowide::cout << doir::Lox::dump(module, root) << std::endl;
		doir::Lox::interpret(module);
	}
}