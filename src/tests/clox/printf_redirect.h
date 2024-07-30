#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif
    int test_print(const char* format, ...);
    int test_fprint(FILE* file, const char* format, ...);
    int test_vfprint(FILE* file, const char* format, va_list args);
#ifdef __cplusplus
}
#endif