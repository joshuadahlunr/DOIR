#pragma once

#ifndef DOIR_NO_PROFILING
	#include <tracy/Tracy.hpp>

	#define DOIR_ZONE_SCOPED ZoneScoped
	#define DOIR_ZONE_SCOPED_NAMED(name) ZoneScopedN(name)

	#ifdef DOIR_AGGRESSIVE_PROFILING
		#define DOIR_ZONE_SCOPED_AGRO ZoneScoped
		#define DOIR_ZONE_SCOPED_NAMED_AGRO(name) ZoneScopedN(name)
	#else
		#define DOIR_ZONE_SCOPED_AGRO ((void)0)
		#define DOIR_ZONE_SCOPED_NAMED_AGRO(name) ((void)0)
	#endif // DOIR_AGGRESSIVE_PROFILING
#else // DOIR_NO_PROFILING
	#define DOIR_ZONE_SCOPED ((void)0)
	#define DOIR_ZONE_SCOPED_NAMED(name) ((void)0)
	#define DOIR_ZONE_SCOPED_AGRO ((void)0)
	#define DOIR_ZONE_SCOPED_NAMED_AGRO(name) ((void)0)
#endif

