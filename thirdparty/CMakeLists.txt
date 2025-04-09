add_subdirectory(libfp)

add_library(nowide ${CMAKE_CURRENT_SOURCE_DIR}/nowide-standalone/src/iostream.cpp)
target_include_directories(nowide PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/nowide-standalone/include) #N