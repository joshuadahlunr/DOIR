cmake_minimum_required(VERSION 3.21)
project(DOIR LANGUAGES C CXX)

if(CMAKE_BUILD_TYPE MATCHES Debug)
	set(DOIR_PROFILE_DEFAULT false)
else()
	set(CMAKE_INTERPROCEDURAL_OPTIMIZATION true)
	set(DOIR_PROFILE_DEFAULT ${PROJECT_IS_TOP_LEVEL})
endif()

option(DOIR_ENABLE_TESTS "Weather or not Unit Tests should be built." ${PROJECT_IS_TOP_LEVEL})
option(DOIR_ENABLE_PROFILING "Weather or not profiling instrumentation will be added." ${DOIR_PROFILE_DEFAULT})
option(DOIR_ENABLE_CODE_COVERAGE "Weather or not a code coverage report should be generated" false)

add_subdirectory(thirdparty/nowide)

file(GLOB sources "src/*.cpp" "thirdparty/*.cpp")
add_executable(doir ${sources})
set_property(TARGET doir PROPERTY CXX_STANDARD 23)
target_link_libraries(doir PUBLIC nowide::nowide)

if(${DOIR_ENABLE_TESTS})
	option(DOIR_ENABLE_CLOX "Weather or not Clox test cases for comparison should be built." ${PROJECT_IS_TOP_LEVEL})

	include(FetchContent) # once in the project to include the module
	include(${CMAKE_SOURCE_DIR}/cmake/includeable.cmake)

	FetchContent_Declare(fetch_lox GIT_REPOSITORY https://github.com/munificent/craftinginterpreters GIT_SHALLOW true)
	FetchContent_MakeAvailable(fetch_lox)

	file(GLOB lox_tests "${CMAKE_BINARY_DIR}/_deps/fetch_lox-src/test/**/*.lox")
	foreach(lox_test IN LISTS lox_tests)
		STRING(REGEX REPLACE "^${CMAKE_BINARY_DIR}/_deps/fetch_lox-src/test/" "" lox_test_file ${lox_test})
		make_includeable(${lox_test} "${CMAKE_SOURCE_DIR}/generated/${lox_test_file}.hpp")
	endforeach()

	file(GLOB sources "src/tests/*.all.cpp" "thirdparty/*.cpp")
	file(GLOB lox_sources "src/tests/lox/*.cpp" "src/tests/lox/nystrom/*.cpp" "src/tests/tests.all.cpp" "thirdparty/*.cpp")
	if(WIN32)
		set(unix_only_sources "")
	else()
		file(GLOB unix_only_sources "src/tests/*.unix.cpp")
	endif()

	add_executable(tst ${sources} ${unix_only_sources})
	set_property(TARGET tst PROPERTY CXX_STANDARD 23)
	target_link_libraries(tst PUBLIC nowide::nowide)

	add_executable(lox ${lox_sources})
	set_property(TARGET lox PROPERTY CXX_STANDARD 23)
	target_link_libraries(lox PUBLIC nowide::nowide)

	if(${DOIR_ENABLE_CLOX})
		file(GLOB clox_sources "${CMAKE_BINARY_DIR}/_deps/fetch_lox-src/c/*.c")
		file(GLOB additional_clox_sources "src/tests/clox/*.cpp" "src/tests/tests.all.cpp")
		list(REMOVE_ITEM clox_sources "${CMAKE_BINARY_DIR}/_deps/fetch_lox-src/c/main.c")
		add_executable(clox ${clox_sources} ${additional_clox_sources})
		target_include_directories(clox PUBLIC "${CMAKE_BINARY_DIR}/_deps/fetch_lox-src/c" "src/tests/clox")
		set_property(TARGET clox PROPERTY CXX_STANDARD 23)
		target_link_libraries(clox PUBLIC nowide::nowide)

		include(${CMAKE_SOURCE_DIR}/cmake/CloxPatch.cmake)
		CLOX_PATCH("${clox_sources}")
	endif()

	FetchContent_Declare(fetch_doctest GIT_REPOSITORY https://github.com/doctest/doctest.git GIT_SHALLOW true)
	FetchContent_MakeAvailable(fetch_doctest)

	target_link_libraries(tst PUBLIC doctest)
	target_link_libraries(lox PUBLIC doctest)
	if(TARGET clox)
		target_link_libraries(clox PUBLIC doctest)
	endif()
	include(${CMAKE_BINARY_DIR}/_deps/fetch_doctest-src/scripts/cmake/doctest.cmake)
	doctest_discover_tests(tst)
	doctest_discover_tests(lox)

	if(${DOIR_ENABLE_CODE_COVERAGE})
		include(${CMAKE_SOURCE_DIR}/cmake/CodeCoverage.cmake)
		append_coverage_compiler_flags_to_target(tst)
		append_coverage_compiler_flags_to_target(lox)
		target_compile_definitions(tst PUBLIC DOIR_DISABLE_FLEX_BISON)
    	setup_target_for_coverage_gcovr_html(
			NAME coverage
			EXECUTABLE tst
			BASE_DIRECTORY "${PROJECT_SOURCE_DIR}/src"
			EXCLUDE "tests/flexbison/*"
		)
		setup_target_for_coverage_gcovr_xml(
			NAME coverage_xml
			EXECUTABLE tst
			BASE_DIRECTORY "${PROJECT_SOURCE_DIR}/src"
			EXCLUDE "tests/flexbison/*"
		)
	endif()
else()
	target_compile_definitions(doir PRIVATE DOCTEST_CONFIG_DISABLE)
endif()

if(${DOIR_ENABLE_PROFILING})
	option(DOIR_BUILD_TRACY_PROFILER "Weather or not to build the server needed to view trace results." ON)

	FetchContent_Declare(fetch_tracy GIT_REPOSITORY https://github.com/wolfpld/tracy GIT_SHALLOW true)
	FetchContent_MakeAvailable(fetch_tracy)

	target_link_libraries(doir PUBLIC TracyClient)
	if (TARGET tst)
		target_link_libraries(tst PUBLIC TracyClient)
	endif()
	if (TARGET lox)
		target_link_libraries(lox PUBLIC TracyClient)
	endif()
	if (TARGET clox)
		target_link_libraries(clox PUBLIC TracyClient)
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
	if (TARGET lox)
		target_include_directories(lox PUBLIC thirdparty/stubs)
	endif()
	if (TARGET clox)
		target_include_directories(clox PUBLIC thirdparty/stubs)
	endif()
endif()
