 
cmake_minimum_required(VERSION 3.21)
project(Tokenizer LANGUAGES CXX)

file(GLOB sources "src/*.cpp" "src/*.c")
add_executable(tst ${sources})
set_property(TARGET tst PROPERTY CXX_STANDARD 23)


