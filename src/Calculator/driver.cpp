#include <iostream>
#include <string>

#define FP_IMPLEMENTATION
#include "calculator.hpp"

int main() {
	fp_hashtable(doir::Calculator::calculator_variable) variables = doir::Calculator::create_variable_table();

	std::string line;
	while(std::cin) {
		std::getline(std::cin, line, ';'); line += ";";
		doir::Calculator::calculate(line.c_str(), variables);
	}
}