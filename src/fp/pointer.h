#ifndef __LIB_FAT_POINTER_H__
#define __LIB_FAT_POINTER_H__

#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>
#include <stdlib.h>
#include <stdbool.h>

#ifndef FP_ALLOCATION_FUNCTION
	/**
	* @brief Function used by libFP to allocate memory
	* @param p pointer to reallocate
	* @note if \p p is null, then new memory is expected to be allocated, otherwise a reallocation and data copy is expected to occur
	* @param size the size in raw bytes to allocate
	* @note if \p size is 0, then the memory pointed to by \p p should be freed
	* @note if \p size is the same as the size of the current allocation of \p p it is valid to simply return \p p
	* @return a pointer to the new allocation or null if the allocation was freed
	*/
	void* __fp_alloc_default_impl(void* p, size_t size)
	#ifdef FP_IMPLEMENTATION
	{
		if(size == 0) {
			free(p);
			return nullptr;
		}

		return realloc(p, size);
	}
	#else
	;
	#endif
#define FP_ALLOCATION_FUNCTION __fp_alloc_default_impl
#endif

// From: https://stackoverflow.com/a/466278
size_t fp_upper_power_of_two(size_t v)
#ifdef FP_IMPLEMENTATION
{
    v--;
    v |= v >> 1;
    v |= v >> 2;
    v |= v >> 4;
    v |= v >> 8;
    v |= v >> 16;
    v++;
    return v;
}
#else
;
#endif

#define FP_MAGIC_NUMBER 0xFE

struct __FatPointerHeader {
	unsigned char magic;
	size_t size;
	char data[];
};

#define FP_CONCAT_(x,y) x##y
#define FP_CONCAT(x,y) FP_CONCAT_(x,y)

#ifndef __cplusplus
#define FP_TYPE_OF(x) typeof(x)
#else
#include <type_traits>
#define FP_TYPE_OF(x) std::remove_reference<decltype(x)>::type
#endif

#ifndef __cplusplus
#define fp_salloc(type, _size) ((type*)(((char*)&(struct {\
		unsigned char magic;\
		size_t size;\
		char data[sizeof(type) * (_size) + 1];\
	}) {\
		.magic = FP_MAGIC_NUMBER,\
		.size = (_size),\
		.data = {0}\
	}) + sizeof(struct __FatPointerHeader)))
#else
#define fp_salloc(type, _size) ((type*)((char*)&((*(__FatPointerHeader*)alloca(sizeof(__FatPointerHeader) + sizeof(type) * _size)) = \
    __FatPointerHeader {\
		.magic = FP_MAGIC_NUMBER,\
		.size = (_size),\
	}) + sizeof(struct __FatPointerHeader)))
#endif

struct __FatPointerHeader* __fp_header(const void* _p)
#ifdef FP_IMPLEMENTATION
{
	char* p = (char*)_p;
	p -= sizeof(struct __FatPointerHeader);
	return (struct __FatPointerHeader*)p;
}
#else
;
#endif


void* __fp_alloc(void* _p, size_t _size)
#ifdef FP_IMPLEMENTATION
{
	if(_p == nullptr && _size == 0) return nullptr;
	if(_size == 0)
		return FP_ALLOCATION_FUNCTION(__fp_header(_p), 0);

	size_t size = sizeof(struct __FatPointerHeader) + _size + 1;
	char* p = (char*)FP_ALLOCATION_FUNCTION(_p == nullptr ? _p : __fp_header(_p), size);
	p += sizeof(struct __FatPointerHeader);
	if(!p) return 0;
	auto h = __fp_header(p);
	h->magic = FP_MAGIC_NUMBER;
	h->size = _size;
	h->data[_size] = 0;
	return p;
}
#else
;
#endif

void* __fp_malloc(size_t size)
#ifdef FP_IMPLEMENTATION
{ return __fp_alloc(nullptr, size); }
#else
;
#endif

#define fp_malloc(type, _size) ((type*)((char*)(*__fp_header(__fp_malloc(sizeof(type) * (_size))) = (struct __FatPointerHeader){\
	.magic = FP_MAGIC_NUMBER,\
	.size = (_size),\
}).data))

#define fp_realloc(type, p, _size) ((type*)((char*)(*__fp_header(__fp_alloc((p), sizeof(type) * (_size))) = (struct __FatPointerHeader){\
	.magic = FP_MAGIC_NUMBER,\
	.size = (_size),\
}).data))

bool is_fp(const void* p)
#ifdef FP_IMPLEMENTATION
{
	if(p == nullptr) return false;
	auto h = __fp_header(p);
	return h->magic == FP_MAGIC_NUMBER && h->size > 0;
}
#else
;
#endif

void fp_free(void* p)
#ifdef FP_IMPLEMENTATION
{ __fp_alloc(p, 0); }
#else
;
#endif

size_t fp_length(const void* p)
#ifdef FP_IMPLEMENTATION
{
	if(!is_fp(p)) return 0;
	return __fp_header(p)->size;
}
#else
;
#endif

size_t fp_size(const void* p)
#ifdef FP_IMPLEMENTATION
{ return fp_length(p); }
#else
;
#endif

#ifdef __cplusplus
}
#endif

#endif

// #include <stdio.h>

// int main() {
// 	// int* arr = fp_salloc(int, 20);
// 	int* arr = fp_malloc(int, 20);
// 	arr = fp_realloc(int, arr, 25);
// 	arr[20] = 6;

// 	printf(is_fp(arr) ? "true\n" : "false\n");
// 	printf("%lu\n", fp_length(arr));
// 	printf("%d\n", arr[20]);
// 	printf("%lu\n", sizeof(struct __FatPointerHeader));

// 	fp_free(arr);
// }