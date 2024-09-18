#pragma once

#include "../ECS/ecs.hpp"

namespace doir::Calculator {
	using calculator_variable = std::pair<fp_string, float>;

	fp_hashtable(calculator_variable) create_variable_table();

	void calculate_view(const fp_string_view view, fp_hashtable(calculator_variable) variables = nullptr);
	void calculate(const fp_string string, fp_hashtable(calculator_variable) variables = nullptr);
}