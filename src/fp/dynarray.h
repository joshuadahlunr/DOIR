#ifndef __LIB_FAT_POINTER_DYN_ARRAY_H__
#define __LIB_FAT_POINTER_DYN_ARRAY_H__

#ifdef __cplusplus
extern "C" {
#endif

#include "pointer.h"
#include <assert.h>
#include <string.h>

#define fp_dynarray(type) type*

#ifndef FPDA_DEFAULT_SIZE_BYTES
#define FPDA_DEFAULT_SIZE_BYTES 64
#endif

struct __FatDynamicArrayHeader {
	size_t utilized_size;
	struct __FatPointerHeader h;
};

struct __FatDynamicArrayHeader* __fpda_header(void* da) 
#ifdef FP_IMPLEMENTATION
{
	static struct __FatDynamicArrayHeader ref = {
		.utilized_size = 0,
		.h = {
			.magic = 0,
			.size = 0,
		}
	};
	if(da == nullptr) return &ref;

	char* p = (char*)da;
	p -= sizeof(struct __FatDynamicArrayHeader);
	return (struct __FatDynamicArrayHeader*)p;
}
#else
;
#endif

void* __fpda_malloc(size_t _size)
#ifdef FP_IMPLEMENTATION
{
	assert(_size > 0);
	size_t size = sizeof(struct __FatDynamicArrayHeader) + _size + 1;
	char* p = (char*)FP_ALLOCATION_FUNCTION(nullptr, size);
	p += sizeof(struct __FatDynamicArrayHeader);
	if(!p) return 0;
	auto h = __fpda_header(p);
	h->utilized_size = 0;
	h->h.magic = FP_MAGIC_NUMBER;
	h->h.size = _size;
	h->h.data[_size] = 0;
	return p;
}
#else
;
#endif

#define fpda_malloc(type, _size) ((type*)((char*)(*__fpda_header(__fpda_malloc(nullptr, sizeof(type) * (_size))) = (struct __FatDynamicArrayHeader){\
	.utilized_size = 0,\
	.h = {\
		.magic = FP_MAGIC_NUMBER,\
		.size = (_size),\
	}\
}).h.data))

void fpda_free(void* da) 
#ifdef FP_IMPLEMENTATION
{ FP_ALLOCATION_FUNCTION(__fpda_header(da), 0); }
#else
;
#endif

size_t fpda_length(void* da) 
#ifdef FP_IMPLEMENTATION
{
	if(!is_fp(da)) return 0;
	return __fpda_header(da)->utilized_size;
}
#else
;
#endif

size_t fpda_size(void* da) 
#ifdef FP_IMPLEMENTATION
{ return fpda_length(da); }
#else
;
#endif

size_t fpda_capacity(void* da) 
#ifdef FP_IMPLEMENTATION
{
	if(!is_fp(da)) return 0;
	return __fpda_header(da)->h.size;
}
#else
;
#endif

void* __fpda_maybe_grow(void** da, size_t type_size, size_t new_size, bool update_utilized, bool exact_sizing)
#ifdef FP_IMPLEMENTATION
{
	if(*da == nullptr) {
		size_t initial_size = FPDA_DEFAULT_SIZE_BYTES / type_size;
		if(initial_size == 0) initial_size++;
		*da = __fpda_malloc(initial_size * type_size);
		auto h = __fpda_header(*da);
		h->h.size = initial_size;
		if(update_utilized)
			h->utilized_size = h->utilized_size > new_size ? h->utilized_size : new_size;
		else h->utilized_size = 0;
	}

	auto h = __fpda_header(*da);
	if(h->h.size >= new_size) return h->h.data + (type_size * (new_size - 1));
	
	size_t size2 = fp_upper_power_of_two(new_size);
	void* new = __fpda_malloc(type_size * size2);
	auto newH = __fpda_header(new);
	if(update_utilized)
		newH->utilized_size = h->utilized_size > new_size ? h->utilized_size : new_size;
	newH->h.size = size2;
	memcpy(newH->h.data, h->h.data, type_size * size2);

	fpda_free(*da);
	*da = new;
	return newH->h.data + (type_size * (new_size - 1));
}
#else
;
#endif
#define __fpda_maybe_grow_short(a, _size) ((typeof(*a)*)__fpda_maybe_grow((void**)&a, sizeof(*a), (_size), true, false))

#define fpda_reserve(a, _size) ((typeof(*a)*)__fpda_maybe_grow((void**)&a, sizeof(*a), (_size), false, true))
#define fpda_reserve_void_pointer(a, type_size, _size) (__fpda_maybe_grow((void**)&a, type_size, (_size), false, true))
#define fpda_resize(a, _size) ((typeof(*a)*)__fpda_maybe_grow((void**)&a, sizeof(*a), (_size), true, true))
#define fpda_grow(a, _to_add) (__fpda_maybe_grow_short(a, __fpda_header(a)->utilized_size += _to_add))
#define fpda_push_back(a, _value) (*__fpda_maybe_grow_short(a, __fpda_header(a)->utilized_size += 1) = (_value))

// Marks the last element of the array as gone and returns a pointer to it
#define fpda_pop_back(a) (__fpda_maybe_grow_short(a, __fpda_header(a)->utilized_size <= 0 ? 0 : __fpda_header(a)->utilized_size -= 1) + 1)

	//   arrins:
	// 	T arrins(T* a, int p, T b);
	// 	  Inserts the item b into the middle of array a, into a[p],
	// 	  moving the rest of the array over. Returns b.

	//   arrinsn:
	// 	void arrinsn(T* a, int p, int n);
	// 	  Inserts n uninitialized items into array a starting at a[p],
	// 	  moving the rest of the array over.

	//   arraddnptr:
	// 	T* arraddnptr(T* a, int n)
	// 	  Appends n uninitialized items onto array at the end.
	// 	  Returns a pointer to the first uninitialized item added.

	//   arraddnindex:
	// 	size_t arraddnindex(T* a, int n)
	// 	  Appends n uninitialized items onto array at the end.
	// 	  Returns the index of the first uninitialized item added.

	//   arrdel:
	// 	void arrdel(T* a, int p);
	// 	  Deletes the element at a[p], moving the rest of the array over.

	//   arrdeln:
	// 	void arrdeln(T* a, int p, int n);
	// 	  Deletes n elements starting at a[p], moving the rest of the array over.

	//   arrdelswap:
	// 	void arrdelswap(T* a, int p);
	// 	  Deletes the element at a[p], replacing it with the element from
	// 	  the end of the array. O(1) performance.

	//   arrsetlen:
	// 	void arrsetlen(T* a, int n);
	// 	  Changes the length of the array to n. Allocates uninitialized
	// 	  slots at the end if necessary.

	//   arrsetcap:
	// 	size_t arrsetcap(T* a, int n);
	// 	  Sets the length of allocated storage to at least n. It will not
	// 	  change the length of the array.

#ifdef __cplusplus
}
#endif

#endif // __LIB_FAT_POINTER_DYN_ARRAY_H__


// #include <stdio.h>

// int main() {
	
// 	fp_dynarray(int) arr = nullptr;
// 	fpda_reserve(arr, 20);
// 	fpda_push(arr, 5);

// 	printf("%d\n", arr[0]);

//	fpda_free(arr);

// }