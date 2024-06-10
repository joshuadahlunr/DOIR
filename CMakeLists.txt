cmake_minimum_required(VERSION 3.21)
project(DOIR LANGUAGES CXX)

option(DOIR_ENABLE_TESTS "Weather or not Unit Tests should be built." ${PROJECT_IS_TOP_LEVEL})

file(GLOB sources "src/*.cpp" "thirdparty/*.cpp")
add_executable(doir ${sources})
set_property(TARGET doir PROPERTY CXX_STANDARD 23)

if(${DOIR_ENABLE_TESTS})
	include(FetchContent) # once in the project to include the module

	file(GLOB sources "src/tests/*.cpp" "thirdparty/*.cpp")
	add_executable(tst ${sources})
	set_property(TARGET tst PROPERTY CXX_STANDARD 23)

	FetchContent_Declare(fetch_doctest GIT_REPOSITORY https://github.com/doctest/doctest.git GIT_SHALLOW true)
	FetchContent_MakeAvailable(fetch_doctest)

	target_link_libraries(tst PUBLIC doctest)
	include(build/_deps/fetch_doctest-src/scripts/cmake/doctest.cmake)
	doctest_discover_tests(tst)
else()
	target_compile_definitions(tst PRIVATE DOCTEST_CONFIG_DISABLE)
endif()


