include(FetchContent) # once in the project to include the module

# FetchContent_Declare(fetch_lox GIT_REPOSITORY https://github.com/munificent/craftinginterpreters GIT_SHALLOW true)
# FetchContent_MakeAvailable(fetch_lox)

if(TARGET doctest)
else()
	FetchContent_Declare(fetch_doctest GIT_REPOSITORY https://github.com/doctest/doctest.git GIT_SHALLOW true)
	FetchContent_MakeAvailable(fetch_doctest)
endif()

if(TARGET nanobench)
else()
	FetchContent_Declare(fetch_nanobench GIT_REPOSITORY https://github.com/martinus/nanobench.git GIT_SHALLOW true)
	FetchContent_MakeAvailable(fetch_nanobench)
endif()

file(GLOB sources "*.cpp")
add_executable(tst ${sources})
target_link_libraries(tst PUBLIC libfp::fp nowide doctest nanobench)
set_property(TARGET tst PROPERTY CXX_STANDARD 23)
set_property(TARGET tst PROPERTY C_STANDARD 23)

if(${DOIR_ENABLE_CODE_COVERAGE})
	include(${CMAKE_SOURCE_DIR}/cmake/CodeCoverage.cmake)
	append_coverage_compiler_flags_to_target(tst)
	target_compile_definitions(tst PUBLIC DOIR_DISABLE_FLEX_BISON)
	setup_target_for_coverage_gcovr_html(
		NAME coverage
		EXECUTABLE "tst"
		# BASE_DIRECTORY "${PROJECT_SOURCE_DIR}"
		EXCLUDE "build/*"
	)
	setup_target_for_coverage_gcovr_xml(
		NAME coverage_xml
		EXECUTABLE "tst"
		# BASE_DIRECTORY "${PROJECT_SOURCE_DIR}"
		EXCLUDE "build/*"
	)
endif()