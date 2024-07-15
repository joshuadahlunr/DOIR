cmake_minimum_required(VERSION 3.21)
project(DOIR LANGUAGES CXX)

if(CMAKE_BUILD_TYPE MATCHES Debug)
	set(DOIR_PROFILE_DEFAULT false)
else()
	set(CMAKE_INTERPROCEDURAL_OPTIMIZATION true)
	set(DOIR_PROFILE_DEFAULT ${PROJECT_IS_TOP_LEVEL})
endif()

option(DOIR_ENABLE_TESTS "Weather or not Unit Tests should be built." ${PROJECT_IS_TOP_LEVEL})
option(DOIR_ENABLE_PROFILING "Weather or not profiling instrumentation will be added." ${DOIR_PROFILE_DEFAULT})

add_subdirectory(thirdparty/nowide)

file(GLOB sources "src/*.cpp" "thirdparty/*.cpp")
add_executable(doir ${sources})
set_property(TARGET doir PROPERTY CXX_STANDARD 23)
target_link_libraries(doir PUBLIC nowide::nowide)

if(${DOIR_ENABLE_TESTS})
	include(FetchContent) # once in the project to include the module


	file(GLOB sources "src/tests/*.all.cpp" "src/tests/lox/*.cpp" "thirdparty/*.cpp")
	if(WIN32)
		set(unix_only_sources "")
	else()
		file(GLOB unix_only_sources "src/tests/*.unix.cpp")
	endif()

	add_executable(tst ${sources} ${unix_only_sources})
	set_property(TARGET tst PROPERTY CXX_STANDARD 23)
	target_link_libraries(tst PUBLIC nowide::nowide)

	FetchContent_Declare(fetch_doctest GIT_REPOSITORY https://github.com/doctest/doctest.git GIT_SHALLOW true)
	FetchContent_MakeAvailable(fetch_doctest)

	target_link_libraries(tst PUBLIC doctest)
	include(${CMAKE_BINARY_DIR}/_deps/fetch_doctest-src/scripts/cmake/doctest.cmake)
	doctest_discover_tests(tst)
else()
	target_compile_definitions(tst PRIVATE DOCTEST_CONFIG_DISABLE)
endif()

if(${DOIR_ENABLE_PROFILING})
	option(DOIR_BUILD_TRACY_PROFILER "Weather or not to build the server needed to view trace results." ON)

	FetchContent_Declare(fetch_tracy GIT_REPOSITORY https://github.com/wolfpld/tracy GIT_SHALLOW true)
	FetchContent_MakeAvailable(fetch_tracy)

	target_link_libraries(doir PUBLIC TracyClient)
	if (TARGET tst)
		target_link_libraries(tst PUBLIC TracyClient)
	endif()

	if(${DOIR_BUILD_TRACY_PROFILER})
		set(LEGACY ON CACHE BOOL "Instead of Wayland, use the legacy X11 backend on Linux")
		add_subdirectory(${CMAKE_BINARY_DIR}/_deps/fetch_tracy-src/profiler/)
	endif()
else()
	target_include_directories(doir PUBLIC thirdparty/stubs)
	if (TARGET tst)
		target_include_directories(tst PUBLIC thirdparty/stubs)
	endif()
endif()


