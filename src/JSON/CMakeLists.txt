add_flex_target(json_flex ${CMAKE_SOURCE_DIR}/src/JSON/json.l OUTPUT ${CMAKE_SOURCE_DIR}/src/JSON/gen/scanner.h --namespace=doir::JSON --fast --noindent) 
add_bison_target(json_bison ${CMAKE_SOURCE_DIR}/src/JSON/json.y OUTPUT ${CMAKE_SOURCE_DIR}/src/JSON/gen/parser.h)
add_library(json json.cpp)
add_dependencies(json json_flex json_bison)
target_link_libraries(json PUBLIC libfp::fp ReflexLibStatic)
target_compile_definitions(json PUBLIC DOIR_NO_PROFILING)

add_executable(tst_json driver.cpp)
target_link_libraries(tst_json PUBLIC json)