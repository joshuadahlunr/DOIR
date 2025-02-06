include(FetchContent)

FetchContent_Declare(peg GIT_REPOSITORY https://github.com/Leandros/PackCC.git)
FetchContent_GetProperties(peg)
if(NOT peg_POPULATED)
	FetchContent_Populate(peg)

	# Patch PackCC so its output can be compiled with a C++ compiler
	file(READ ${peg_SOURCE_DIR}/src/packcc.c FILE_CONTENTS)
	string(REPLACE "(void *)" "(pcc_action_t)" FILE_CONTENTS "${FILE_CONTENTS}")
	string(REPLACE "(const)" "(const size_t)" FILE_CONTENTS "${FILE_CONTENTS}")
	file(WRITE ${peg_SOURCE_DIR}/src/packcc.c "${FILE_CONTENTS}")
endif()

add_executable(packcc ${peg_SOURCE_DIR}/src/packcc.c)

function(add_peg_target TARGET IN OUTPUT OUT)
	cmake_path(GET OUT PARENT_PATH parentPath)
	file(MAKE_DIRECTORY ${parentPath})

	add_custom_command(
		OUTPUT ${OUT}.h ${OUT}.c
		COMMAND packcc -o${OUT} ${IN} ${ARGN}
		DEPENDS ${IN}
	)
	add_custom_target(${TARGET} ALL DEPENDS ${OUT}.c ${IN})
endfunction()
