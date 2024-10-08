#pragma once

#include "../module.hpp"

namespace doir::Calculator {
	inline namespace component {
		struct expressions {
			fp_dynarray(ecs::entity_t) expr = nullptr;
		};
	}
	doir::TrivialModule parse_view(const fp_string_view view, doir::TrivialModule* existing = nullptr);
	doir::TrivialModule parse(const fp_string string, doir::TrivialModule* existing = nullptr);

	void print(TrivialModule& module, ecs::entity_t root, size_t depth = 0);
	float calculate(TrivialModule& module, ecs::entity_t root);
}