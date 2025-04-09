cmake_minimum_required(VERSION 3.21)
project(DOIR LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_C_STANDARD 23)

if(CMAKE_BUILD_TYPE MATCHES Debug)
	set(DOIR_PROFILE_DEFAULT false)
else()
	set(CMAKE_INTERPROCEDURAL_OPTIMIZATION true)
	set(DOIR_PROFILE_DEFAULT ${PROJECT_IS_TOP_LEVEL})
endif()

option(DOIR_ENABLE_TESTS "Weather or not Unit Tests should be built." ${PROJECT_IS_TOP_LEVEL})
option(DOIR_ENABLE_PROFILING "Weather or not profiling instrumentation will be added." ${DOIR_PROFILE_DEFAULT})
option(DOIR_ENABLE_CODE_COVERAGE "Weather or not targets to generated a code coverage report should be created." false)

# set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fsanitize=address")

add_subdirectory(thirdparty)

add_executable(doir driver.cpp)
target_link_libraries(doir PUBLIC libfp::fp nowide)

if(${DOIR_ENABLE_TESTS})
	add_subdirectory(tests)
# else()
# 	target_compile_definitions(tst PRIVATE DOCTEST_CONFIG_DISABLE)
endif()

if(${DOIR_ENABLE_PROFILING})
	option(DOIR_BUILD_TRACY_PROFILER "Weather or not to build the server needed to view trace results." ON)

	set(TRACY_NO_EXIT ON CACHE BOOL "Client executable does not exit until all profile data is sent to server")

	FetchContent_Declare(fetch_tracy GIT_REPOSITORY https://github.com/wolfpld/tracy GIT_SHALLOW true)
	FetchContent_MakeAvailable(fetch_tracy)

	target_link_libraries(tst PUBLIC TracyClient)
	target_compile_definitions(tst PUBLIC DOIR_ENABLE_PROFILING)

	if(${DOIR_BUILD_TRACY_PROFILER})
		set(LEGACY ON CACHE BOOL "Instead of Wayland, use the legacy X11 backend on Linux")
		add_subdirectory(${CMAKE_BINARY_DIR}/_deps/fetch_tracy-src/profiler/)
	endif()
else()
	target_include_directories(tst PUBLIC thirdparty/stubs)
	target_compile_definitions(tst PRIVATE DOIR_ENABLE_BENCHMARKING)
endif()