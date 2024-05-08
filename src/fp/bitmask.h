#ifndef __LIB_FAT_POINTER_DYN_BITMASK_H__
#define __LIB_FAT_POINTER_DYN_BITMASK_H__

#include "dynarray.h"
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifndef FP_BITMASK_BLOCK_TYPE
#define FP_BITMASK_BLOCK_TYPE uint32_t
#endif
#define FP_BITMASK_BLOCK_SIZE (sizeof(FP_BITMASK_BLOCK_TYPE) * 8)
typedef FP_BITMASK_BLOCK_TYPE* fp_bitmask_t;

void fp_bitmask_init_impl(fp_bitmask_t* self)
#ifdef FP_IMPLEMENTATION
{
	fpda_resize(*self, 1);
	(*self)[0] = 0;
}
#else
;
#endif
#define fp_bitmask_init(self) fp_bitmask_init_impl(&self)
#define fp_bitmask_init_as_null(self) do { self = nullptr; fp_bitmask_init(self); } while(false)
#define fp_bitmask_free(self) fpda_free(self)

size_t fp_bitmask_find_highest_set(fp_bitmask_t self)
#ifdef FP_IMPLEMENTATION
{
	for(size_t block = fpda_size(self); block--; ) {
		if(self[block] == 0) continue;
		// Scary UB from: https://stackoverflow.com/a/23857066
		union { double ddd; int64_t uu; } u;
		u.ddd = self[block] + 0.5;
		auto dbg = FP_BITMASK_BLOCK_SIZE - 1 - (1054 - (int)(u.uu >> 52)) + block * FP_BITMASK_BLOCK_SIZE;
		return dbg;
	}
	return 0;
}
#else
;
#endif

bool fp_bitmask_test(fp_bitmask_t self, size_t offset)
#ifdef FP_IMPLEMENTATION
{
	if(offset / FP_BITMASK_BLOCK_SIZE > fpda_size(self)) return false;

	size_t block = offset / FP_BITMASK_BLOCK_SIZE;
	offset %= FP_BITMASK_BLOCK_SIZE;
	return self[block] & (1 << offset);
}
#else
;
#endif

bool fp_bitmask_test_alln(fp_bitmask_t self, size_t* offsets, size_t length)
#ifdef FP_IMPLEMENTATION
{
	bool all = true;
	for(size_t i = length; --i; ){
		if(offsets[i] == (size_t)-1) continue;
		all &= fp_bitmask_test(self, offsets[i]);
		if(!all) return false;
	}
	return all;
}
#else
;
#endif
bool fp_bitmask_test_all(fp_bitmask_t self, size_t* offsets)
#ifdef FP_IMPLEMENTATION
{
	if(!is_fp(offsets)) return false;
	return fp_bitmask_test_alln(self, offsets, fp_size(offsets));
}
#else
;
#endif

bool fp_bitmask_test_anyn(fp_bitmask_t self, size_t* offsets, size_t length)
#ifdef FP_IMPLEMENTATION
{
	for(size_t i = length; --i; ){
		if(offsets[i] == (size_t)-1) continue;
		if(fp_bitmask_test(self, offsets[i]))
			return true;
	}
	return false;
}
#else
;
#endif
bool fp_bitmask_test_any(fp_bitmask_t self, size_t* offsets)
#ifdef FP_IMPLEMENTATION
{
	if(!is_fp(offsets)) return false;
	return fp_bitmask_test_anyn(self, offsets, fp_size(offsets));
}
#else
;
#endif

char* fp_bitmask_to_string_extended(fp_bitmask_t self, size_t offset, size_t length)
#ifdef FP_IMPLEMENTATION
{
	assert((offset + length) / FP_BITMASK_BLOCK_SIZE <= fpda_size(self));
	char* str = nullptr;
	fpda_resize(str, length);
	// if(length == 1) str[0] = fp_bitmask_test(self, 0) ? '1' : '0';
	// else
	for(size_t i = length; i--; )
		str[length - i - 1] = fp_bitmask_test(self, offset + i) ? '1' : '0';
	return str;
}
#else
;
#endif

char* fp_bitmask_to_string(fp_bitmask_t self)
#ifdef FP_IMPLEMENTATION
{ auto highest = fp_bitmask_find_highest_set(self); return fp_bitmask_to_string_extended(self, 0, highest > 1 ? highest + 1: 1); }
#else
;
#endif

void fp_bitmask_set_state_impl(fp_bitmask_t* self, size_t offset, bool value)
#ifdef FP_IMPLEMENTATION
{
	if(offset / FP_BITMASK_BLOCK_SIZE > fpda_size(self))
		fpda_resize(*self, offset / FP_BITMASK_BLOCK_SIZE + 1);

	size_t block = offset / FP_BITMASK_BLOCK_SIZE;
	offset %= FP_BITMASK_BLOCK_SIZE;
	if(value) (*self)[block] |= (1 << offset);
	else (*self)[block] &= ~(1 << offset);
}
#else
;
#endif
#define fp_bitmask_set_state(self, offset, value) fp_bitmask_set_state_impl(&self, (offset), (value))
#define fp_bitmask_set(self, offset) fp_bitmask_set_state(self, offset, true)
#define fp_bitmask_reset(self, offset) fp_bitmask_set_state(self, offset, false)

bool fp_bitmask_from_binary_stringn_impl(fp_bitmask_t* self, const char* str, size_t length)
#ifdef FP_IMPLEMENTATION
{
	// Make sure the array is zeroed!
	fp_bitmask_init(*self);

	for(size_t i = 0; i <= length; ++i) {
		if( !(str[i] == '0' || str[i] == '1') )
			return false;

		size_t pos = length - i - 1;
		char dbg = str[i];
		fp_bitmask_set_state(*self, pos, str[i] == '1');
	}

	return true;
}
#else
;
#endif
inline bool fp_bitmask_from_binary_string_impl(fp_bitmask_t* self, const char* str) {
	if(is_fp(str)) return fp_bitmask_from_binary_stringn_impl(self, str, fp_size(str));
	else return fp_bitmask_from_binary_stringn_impl(self, str, strlen(str));
}
#define fp_bitmask_from_binary_stringn(self, str, length) fp_bitmask_from_binary_stringn_impl(&self, (str), (length))
#define fp_bitmask_from_binary_string(self, str) fp_bitmask_from_binary_string_impl(&self, (str))

#ifdef __cplusplus
}
#endif

#endif

// int main() {
	// fp_bitmask_t mask = nullptr;
	// fp_bitmask_init(mask);
	// auto s = fp_bitmask_to_string(mask);
	// puts(s); fpda_free(s);

	// fp_bitmask_set(mask, 5);
	// fp_bitmask_set(mask, 6);
	// fp_bitmask_set(mask, 7);
	// puts(s = fp_bitmask_to_string(mask)); fpda_free(s);

	// fp_bitmask_reset(mask, 6);
	// puts(s = fp_bitmask_to_string(mask)); fpda_free(s);

	// fp_bitmask_set(mask, 60);
	// puts(s = fp_bitmask_to_string(mask)); fpda_free(s);
	// puts(s = fp_bitmask_to_string_extended(mask, 0, 10)); fpda_free(s);

	// fp_bitmask_free(mask);
// }