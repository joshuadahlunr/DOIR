cmake_minimum_required(VERSION 3.21)
project(Core LANGUAGES C)

file(GLOB sources "src/*.c")
add_executable(tst ${sources})
target_link_libraries(tst PUBLIC m)
set_property(TARGET tst PROPERTY C_STANDARD 23)