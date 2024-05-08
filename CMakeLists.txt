cmake_minimum_required(VERSION 3.21)
project(Ccore LANGUAGES C CXX)

file(GLOB sources "src/*.c")
add_executable(tst ${sources})
set_property(TARGET tst PROPERTY C_STANDARD 23)

if(PROJECT_IS_TOP_LEVEL)
    enable_testing()
    include(cmake/doctest.cmake)
    
    add_executable(tests src/tests/tests.cpp)
    target_link_libraries(tests PUBLIC tcmalloc)
    set_property(TARGET tests PROPERTY CXX_STANDARD 23)
    doctest_discover_tests(tests)
endif()
