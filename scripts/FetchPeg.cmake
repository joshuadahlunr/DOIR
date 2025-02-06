include(FetchContent)

FetchContent_Declare(peg 
	URL https://www.piumarta.com/software/peg/peg-0.1.19.tar.gz
	URL_HASH MD5=6532518a13c3afc0826d27f7addbd76d
)
FetchContent_MakeAvailable(peg)

# Source files
if(${CMAKE_SYSTEM_NAME} STREQUAL Windows)
	set(SOURCES
		${peg_SOURCE_DIR}/src/tree.c
		${peg_SOURCE_DIR}/src/compile.c
		${peg_SOURCE_DIR}/win/getopt.c
	)
else()
	set(SOURCES
		${peg_SOURCE_DIR}/src/tree.c
		${peg_SOURCE_DIR}/src/compile.c
	)
endif()

# Define targets for peg and leg
# add_executable(peg src/peg.c ${SOURCES})
add_executable(peg-leg ${peg_SOURCE_DIR}/src/leg.c ${SOURCES})

if(${CMAKE_SYSTEM_NAME} STREQUAL Windows)
	target_include_directories(peg-leg PUBLIC ${peg_SOURCE_DIR}/win)
endif()

function(add_peg_target TARGET IN OUTPUT OUT)
	cmake_path(GET OUT PARENT_PATH parentPath)
	file(MAKE_DIRECTORY ${parentPath})

	add_custom_command(
		OUTPUT ${OUT}
		COMMAND peg-leg -o${OUT} ${IN} ${ARGN}
		DEPENDS ${IN}
	)
	add_custom_target(${TARGET} ALL DEPENDS ${OUT} ${IN})
	add_dependencies(${TARGET} peg-leg)
endfunction()