#include "nowide/iostream.hpp"
#include <string>

#define DOIR_IMPLEMENTATION
#define FP_IMPLEMENTATION
#include "calculator.hpp"

#include <string>

int main() {
	doir::TrivialModule module;
	module.add_component<doir::Calculator::expressions>(module.create_entity());

	std::string line;
	while(nowide::cin) {
		std::getline(nowide::cin, line, ';'); line += ";";
		module = doir::Calculator::parse(line.c_str(), &module);

		// doir::Calculator::print(module, 1);
		auto newest = *fp_back(module.get_component<doir::Calculator::expressions>(1).expr);
		nowide::cout << "= " << doir::Calculator::calculate(module, newest) << std::endl;
	}

	// module.free();
}