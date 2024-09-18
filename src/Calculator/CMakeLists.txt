add_flex_target(calculator_flex ${CMAKE_SOURCE_DIR}/src/Calculator/calculator.l OUTPUT ${CMAKE_SOURCE_DIR}/src/Calculator/gen/scanner.h)
add_bison_target(calculator_bison ${CMAKE_SOURCE_DIR}/src/Calculator/calculator.y OUTPUT ${CMAKE_SOURCE_DIR}/src/Calculator/gen/parser.h)
add_library(calculator calculator.cpp)
add_dependencies(calculator calculator_flex calculator_bison)
target_link_libraries(calculator PUBLIC libfp::fp)
target_compile_definitions(calculator PUBLIC DOIR_NO_PROFILING)

add_executable(tst_calculator driver.cpp)
target_link_libraries(tst_calculator PUBLIC calculator)