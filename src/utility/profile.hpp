#pragma once

#ifdef DOIR_ENABLE_PROFILING
	#include <tracy/Tracy.hpp>

	#define DOIR_ZONE_SCOPED ZoneScoped
	#define DOIR_ZONE_SCOPED_NAMED(name) ZoneScopedN(name)
	#define DOIR_FRAME_MARK FrameMark

	#ifdef DOIR_AGGRESSIVE_PROFILING
		#define DOIR_ZONE_SCOPED_AGGRO ZoneScoped
		#define DOIR_ZONE_SCOPED_NAMED_AGGRO(name) ZoneScopedN(name)
	#else
		#define DOIR_ZONE_SCOPED_AGGRO ((void)0)
		#define DOIR_ZONE_SCOPED_NAMED_AGGRO(name) ((void)0)
	#endif // DOIR_AGGRESSIVE_PROFILING
#else // DOIR_NO_PROFILING
	#define DOIR_ZONE_SCOPED ((void)0)
	#define DOIR_ZONE_SCOPED_NAMED(name) ((void)0)
	#define DOIR_ZONE_SCOPED_AGGRO ((void)0)
	#define DOIR_ZONE_SCOPED_NAMED_AGGRO(name) ((void)0)
	#define DOIR_FRAME_MARK ((void)0)
#endif

