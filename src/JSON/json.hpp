#pragma once

#include "../ECS/ecs.hpp"

namespace doir::JSON {
	char* parse_view(const fp_string_view view);
	char* parse(const fp_string string);
}