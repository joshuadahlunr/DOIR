function(CLOX_PATCH SOURCES)
	foreach(FILE ${SOURCES})
		if(EXISTS ${FILE})
			if(MSVC)
				execute_process(
					COMMAND powershell -Command "(Get-Content ${FILE}) -replace 'vfprintf', 'test_vfprint' | Set-Content ${FILE}"
					RESULT_VARIABLE result
					ERROR_VARIABLE error
					OUTPUT_VARIABLE output
				)
				execute_process(
					COMMAND powershell -Command "(Get-Content ${FILE}) -replace 'fprintf', 'test_fprint' | Set-Content ${FILE}"
					RESULT_VARIABLE result
					ERROR_VARIABLE error
					OUTPUT_VARIABLE output
				)
				execute_process(
					COMMAND powershell -Command "(Get-Content ${FILE}) -replace 'printf', 'test_print' | Set-Content ${FILE}"
					RESULT_VARIABLE result
					ERROR_VARIABLE error
					OUTPUT_VARIABLE output
				)		
			elseif(APPLE)
				execute_process(
					COMMAND sed -i "" "s/vfprintf/test_vfprint/g" "${FILE}" 
					RESULT_VARIABLE result
					ERROR_VARIABLE error
					OUTPUT_VARIABLE output
				)
				execute_process(
					COMMAND sed -i "" "s/fprintf/test_fprint/g" "${FILE}"
					RESULT_VARIABLE result
					ERROR_VARIABLE error
					OUTPUT_VARIABLE output
				)
				execute_process(
					COMMAND sed -i "" "s/printf/test_print/g" "${FILE}"
					RESULT_VARIABLE result
					ERROR_VARIABLE error
					OUTPUT_VARIABLE output
				)
			else()
				execute_process(
					COMMAND sed -i "s/vfprintf/test_vfprint/g" "${FILE}" 
					RESULT_VARIABLE result
					ERROR_VARIABLE error
					OUTPUT_VARIABLE output
				)
				execute_process(
					COMMAND sed -i "s/fprintf/test_fprint/g" "${FILE}"
					RESULT_VARIABLE result
					ERROR_VARIABLE error
					OUTPUT_VARIABLE output
				)
				execute_process(
					COMMAND sed -i "s/printf/test_print/g" "${FILE}"
					RESULT_VARIABLE result
					ERROR_VARIABLE error
					OUTPUT_VARIABLE output
				)
			endif()

			file(READ "${FILE}" FILE_CONTENTS)
			set(NEW_CONTENT "#include <printf_redirect.h>\n${FILE_CONTENTS}")
			file(WRITE "${FILE}" "${NEW_CONTENT}")

			if(result EQUAL 0)
				message(STATUS "Successfully replaced (f)printf in ${FILE}")
			else()
				message(WARNING "Failed to replace (f)printf in ${FILE}. Error: ${error}")
			endif()
		else()
			message(WARNING "FILE not found: ${FILE}")
		endif()
	endforeach()
endfunction()