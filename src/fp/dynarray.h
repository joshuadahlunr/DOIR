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
#define FPDA_DEFAULT_SIZE_BYTES 16
#endif

struct __FatDynamicArrayHeader {
	size_t capacity;
	struct __FatPointerHeader h;
};

struct __FatDynamicArrayHeader* __fpda_header(const void* da)
#ifdef FP_IMPLEMENTATION
{
	static struct __FatDynamicArrayHeader ref = {
		.capacity = 0,
		.h = {
			.magic = 0,
			.size = 0,
		}
	};
	if(da == nullptr) {
		// ref.capacity = 0;
		// ref.h.size = 0;
		return &ref;
	}

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
	h->capacity = _size;
	h->h.magic = FP_MAGIC_NUMBER;
	h->h.size = 0;
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

size_t fpda_length(const void* da)
#ifdef FP_IMPLEMENTATION
{ return fp_length(da); }
#else
;
#endif

size_t fpda_size(const void* da)
#ifdef FP_IMPLEMENTATION
{ return fp_size(da); }
#else
;
#endif

size_t fpda_capacity(const void* da)
#ifdef FP_IMPLEMENTATION
{
	if(!is_fp(da)) return 0;
	return __fpda_header(da)->capacity;
}
#else
;
#endif

void* __fpda_maybe_grow(void** da, size_t type_size, size_t new_size, bool update_utilized, bool exact_sizing)
#ifdef FP_IMPLEMENTATION
{
	if(*da == nullptr) {
		size_t initial_size = exact_sizing ? new_size : FPDA_DEFAULT_SIZE_BYTES / type_size;
		if(initial_size == 0) initial_size++; // If the size would wind up being 0, make sure the initial size is 1
		*da = __fpda_malloc(initial_size * type_size);
		auto h = __fpda_header(*da);
		h->capacity /= type_size;
		h->h.size = 0;
	}

	auto h = __fpda_header(*da);
	if(h->capacity >= new_size) {
		if(update_utilized) h->h.size = h->h.size > new_size ? h->h.size : new_size;
		return h->h.data + (type_size * (new_size - 1));
	}

	size_t size2 = exact_sizing ? new_size : fp_upper_power_of_two(new_size);
	void* new_ = __fpda_malloc(type_size * size2);
	auto newH = __fpda_header(new_);
	if(update_utilized)
		newH->h.size = h->h.size > new_size ? h->h.size : new_size;
	newH->capacity = size2;
	memcpy(newH->h.data, h->h.data, type_size * size2);

	fpda_free(*da);
	*da = new_;
	return newH->h.data + (type_size * (new_size - 1));
}
#else
;
#endif
#define __fpda_maybe_grow_short(a, _size) ((FP_TYPE_OF(*a)*)__fpda_maybe_grow((void**)&a, sizeof(*a), (_size), true, false))

void* __fpda_back(void* a, size_t type_size)
#ifdef FP_IMPLEMENTATION
{ return ((char*)a) + (fpda_size(a) > 0 ? fpda_size(a) - 1 : 0)  * type_size; }
#else
;
#endif
#define fpda_back(a) ((FP_TYPE_OF(*a)*)__fpda_back((a), sizeof(*a)))
#define fpda_front(a) (a)

#define fpda_reserve(a, _size) ((FP_TYPE_OF(*a)*)__fpda_maybe_grow((void**)&a, sizeof(*a), (_size), false, true))
#define fpda_reserve_void_pointer(a, type_size, _size) (__fpda_maybe_grow((void**)&a, type_size, (_size), false, true))
#define fpda_grow_to_size(a, _size) ((FP_TYPE_OF(*a)*)__fpda_maybe_grow((void**)&a, sizeof(*a), (_size), true, true))
#define fpda_grow(a, _to_add) (__fpda_maybe_grow_short(a, __fpda_header(a)->h.size + _to_add))
#define fpda_push_back(a, _value) (*__fpda_maybe_grow_short(a, __fpda_header(a)->h.size + 1) = (_value))

// Marks the last element of the array as gone and returns a pointer to it
#define fpda_pop_back(a) (__fpda_maybe_grow_short(a, __fpda_header(a)->h.size <= 0 ? 0 : __fpda_header(a)->h.size -= 1) + 1)

void* __fpda_maybe_grow_insert(void** da, size_t type_size, size_t new_index, size_t new_size, bool exact_sizing)
#ifdef FP_IMPLEMENTATION
{
	assert(new_size > 0);
	assert(new_index <= fpda_size(*da)); // TODO: What should the comparison operator be?

	__fpda_maybe_grow(da, type_size, fpda_size(*da) + new_size, /*update_utilized*/true, exact_sizing);

	char* raw = (char*)*da;
	char* oldStart = raw + new_index * type_size;
	char* newStart = oldStart + new_size * type_size;
	size_t length = (raw + fpda_size(*da) * type_size) - newStart;
	memmove(newStart, oldStart, length);
	return oldStart;
}
#else
;
#endif

#define fpda_insert(a, _pos, _val) ((*(FP_TYPE_OF(*a)*)__fpda_maybe_grow_insert((void**)&a, sizeof(*a), (_pos), 1, false)) = _val)
#define fpda_push_front(a, _val) fpda_insert(a, 0, _val)

// Returns a pointer to the first uninitialized element
#define fpda_insert_uninitialized(a, _pos, _count) ((FP_TYPE_OF(*a)*)__fpda_maybe_grow_insert((void**)&a, sizeof(*a), (_pos), (_count), false))


void* __fpda_delete(void** da, size_t type_size, size_t start, size_t count, bool make_size_match_capacity)
#ifdef FP_IMPLEMENTATION
{
	assert(start + count <= fpda_size(*da));

	char* raw = (char*)*da;
	char* newStart = raw + start * type_size;
	char* oldStart = newStart + count * type_size;
	size_t length = (raw + fpda_size(*da) * type_size) - oldStart;

	if(make_size_match_capacity) {
		fp_dynarray(char) new_ = nullptr;
		fpda_grow_to_size(new_, fpda_size(*da) - count);

		newStart = new_ + start * type_size;
		if(oldStart != raw) memcpy(new_, raw, newStart - new_);
		memcpy(newStart, oldStart, length);

		fpda_free(*da);
		*da = new_;

	} else if(count > 0) {
		__fpda_header(*da)->h.size -= count;
		memmove(newStart, oldStart, length);
	}

	return newStart;
}
#else
;
#endif
#define __fpda_delete_impl(a, _pos, _count, _match_size) ((FP_TYPE_OF(*a)*)__fpda_delete((void**)&a, sizeof(*a), (_pos), (_count), (_match_size)))

#define fpda_delete_range(a, _pos, _count) __fpda_delete_impl(a, _pos, _count, false)
#define fpda_delete(a, _pos) fpda_delete_range(a, _pos, 1)
#define fpda_delete_start_end(a, _start, _end) fpda_delete_range(a, _start, ((_end) - (_start) + 1))

#define fpda_shrink_delete_range(a, _pos, _count) __fpda_delete_impl(a, _pos, _count, true)
#define fpda_shrink_delete(a, _pos) fpda_shrink_delete_range(a, _pos, 1)
#define fpda_shrink_delete_start_end(a, _start, _end) fpda_shrink_delete_range(a, _start, ((_end) - (_start) + 1))

#define fpda_resize(a, _size) do { auto __fp_size = (_size);\
		if(__fp_size > fpda_capacity(a)) fpda_grow_to_size(a, __fp_size);\
		else { auto __fp_count = fpda_size(a) - __fp_size; fpda_shrink_delete_range(a, fpda_size(a) - __fp_count, __fp_count); }\
	} while(false)

#define fpda_shrink_to_fit(a) __fpda_delete_impl(a, 0, 0, true)


void __fpda_swap_range(void* da, size_t type_size, size_t range1_start, size_t range2_start, size_t count, bool bidirectional)
#ifdef FP_IMPLEMENTATION
{
	assert(range1_start + count <= fpda_size(da));
	assert(range2_start + count <= fpda_size(da));

	char* start1 = ((char*)da) + type_size * range1_start;
	char* start2 = ((char*)da) + type_size * range2_start;
	char* end1 = start1 + count * type_size - 1;
	char* end2 = start2 + count * type_size - 1;
	bool overlapping = !(end1 < start2 || end2 < start1);
	size_t length = count * type_size;

	bool freeScratch = false;
	char* scratch = nullptr;
	if(bidirectional || overlapping) {
		if(fpda_capacity(da) - fpda_size(da) > count) { // We can use the excess capacity
			freeScratch = false;
			scratch = ((char*)da) + type_size * fpda_size(da);
		} else {
			freeScratch = true;
			fpda_grow_to_size(scratch, length);
		}
	}

	if(bidirectional) {
		memcpy(scratch, start1, length);
		memcpy(start1, start2, length);
		memcpy(start2, scratch, length);
	} else if(overlapping) {
		memcpy(scratch, start1, length);
		memcpy(start2, scratch, length);
	} else memcpy(start2, start1, length);

	if(freeScratch && scratch) fpda_free(scratch);
}
#else
;
#endif

#define fpda_swap_range(a, _start1, _start2, _count) (__fpda_swap_range(a, sizeof(*a), (_start1), (_start2), (_count), true))
#define fpda_swap(a, _pos1, _pos2) fpda_swap_range(a, _pos1, _pos2, 1)

#define fpda_swap_delete_range(a, _pos, _count) (__fpda_swap_range(a, sizeof(*a), fpda_size(a) - (_count), (_pos), (_count), false), __fpda_header(a)->h.size -= _count)
#define fpda_swap_delete(a, _pos) fpda_swap_delete_range(a, _pos, 1)
#define fpda_swap_delete_start_end(a, _start, _end) fpda_swap_delete_range(a, _start, ((_end) - (_start) + 1))

void __fpda_clone(void** dest, void* src, size_t type_size)
#ifdef FP_IMPLEMENTATION
{
	char* rawDest = (char*)*dest;
	fpda_grow_to_size(rawDest, fpda_size(src) * type_size);
	memcpy(rawDest, src, fpda_size(rawDest));
	auto h = __fpda_header(rawDest);
	h->capacity = fpda_capacity(src);
	h->h.size = fpda_size(src);
	*dest = rawDest;
}
#else
;
#endif

#define fpda_clone(dest, src) __fpda_clone((void**)&dest, (src), sizeof(*dest))
#define fpda_copy(dest, src) fpda_clone(dest, src)

#define fpda_iterate_named(a, iter) for(auto __fp_start = (a), iter = __fp_start; iter < __fp_start + fpda_size(__fp_start); iter++)
#define fpda_iterate(a) fpda_iterate_named(a, i)

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