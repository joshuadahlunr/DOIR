#pragma once

#include "../module.hpp"

namespace doir::Lox {
	std::pair<TrivialModule, ecs::entity_t> parse_view(const fp_string_view view);
	std::pair<TrivialModule, ecs::entity_t> parse(const fp_string string);

	void dump(TrivialModule& module, ecs::entity_t root, size_t depth = 0);

	// void sort_parse_into_reverse_post_order_traversal(doir::Module& module, doir::ecs::entity_t root);
}