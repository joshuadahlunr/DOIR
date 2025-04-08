#define ANKERL_NANOBENCH_IMPLEMENT
#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include "tests.utils.hpp"

#include <cstdlib>

#ifdef DOIR_MEMORY_PROFILING
	inline void* profiled_alloc(void* p, size_t size) {
		if(size == 0) {
			TracyFreeNS(p, 10, "fp");
			free(p);
			return nullptr;
		}

		if(p) TracyFreeNS(p, 10, "fp");
		p = realloc(p, size);
		TracyAllocNS(p, size, 10, "fp");
		return p;
	}
	#define FP_ALLOCATION_FUNCTION profiled_alloc
#endif

#define DOIR_IMPLEMENTATION
#define FP_IMPLEMENTATION
#include "../src/ECS/ecs.hpp"
#include "../src/ECS/entity.hpp"