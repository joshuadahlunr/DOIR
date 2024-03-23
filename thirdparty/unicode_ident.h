#include "stdint.h"

extern "C" {
    // Checks if the given char32_t code point is a valid XID_START character
    char is_xid_start(char32_t ch);
    // Checks if the given char32_t code point is a valid XID_CONTINUE character
    char is_xid_continue(char32_t ch);
}