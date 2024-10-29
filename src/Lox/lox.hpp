#pragma once

#include "../module.hpp"

namespace doir::Lox {
	std::pair<TrivialModule, ecs::entity_t> parse_view(const fp_string_view view);
	std::pair<TrivialModule, ecs::entity_t> parse(const fp_string string);
	// fp_string dump(TrivialModule& module, ecs::entity_t root);
}