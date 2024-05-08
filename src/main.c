#include <assert.h>
#include <stdio.h>

#define FP_IMPLEMENTATION
#include "fp/dynarray.h"
#include "fp/bitmask.h"

typedef uint32_t entity_t;
typedef size_t doir_skiplist_index_t;

#pragma region ComponentStorage

#ifdef DOIR_COMPONENT_STORAGE_ENSURE_MONOTONIC_GROWTH
	#define DOIRComponentStorageTyped(type) struct {\
		size_t element_size;\
		fp_dynarray(doir_skiplist_index_t) indices;\
		fp_dynarray(type) data; /* Fat pointer dynamic array */\
		entity_t last_entity;\
	}
#else
	#define DOIRComponentStorageTyped(type) struct {\
		size_t element_size;\
		fp_dynarray(doir_skiplist_index_t) indices;\
		fp_dynarray(type) data; /* Fat pointer dynamic array */\
	}
#endif
	typedef DOIRComponentStorageTyped(uint8_t) DOIRComponentStorage;

	#define __DOIRComponentStorageTypedCast(type, this) ((DOIRComponentStorageTyped(type)*)(this))

	void doir_component_storage_default (DOIRComponentStorage* this) {
		this->element_size = -1;
		this->indices = nullptr;
		this->data = nullptr;
	#ifdef DOIR_COMPONENT_STORAGE_ENSURE_MONOTONIC_GROWTH
		this->last_entity = 0;
	#endif
	}

	void doir_component_storage_init_impl (DOIRComponentStorage* this, size_t element_size) {
		this->element_size = element_size;
		this->indices = nullptr;
		this->data = nullptr;
	#ifdef DOIR_COMPONENT_STORAGE_ENSURE_MONOTONIC_GROWTH
		this->last_entity = 0;
	#endif
	}

	#define doir_component_storage_initial_reservation(type, this, initialSize) (doir_component_storage_init_impl(this, sizeof(type)), fpda_reserve(__DOIRComponentStorageTypedCast(type, this)->data, initialSize))
	#define doir_component_storage_init(type, this) doir_component_storage_initial_reservation(type, this, 5)

	void doir_component_storage_free (DOIRComponentStorage* this) {
		if(this->indices) fpda_free(this->indices);
		if(this->data) fpda_free(this->data);
		doir_component_storage_default(this);
	}

	size_t doir_component_storage_capacity(DOIRComponentStorage* this) { return fpda_capacity(this->indices); }
	size_t doir_component_storage_size(DOIRComponentStorage* this) { return fpda_size(this->indices); }

	void* doir_component_storage_get_impl(DOIRComponentStorage* this, entity_t e, size_t type_size_validator) {
	#ifndef DOIR_COMPONENT_STORAGE_DONT_VALIDATE_TYPE_SIZES
		assert(type_size_validator == this->element_size);
	#else
		(void)type_size_validator;
	#endif
		assert(e < doir_component_storage_size(this));
		assert(this->indices[e] != (size_t)-1);
		return this->data + this->indices[e];
	}
	void* doir_component_storage_get_no_validation_impl(DOIRComponentStorage* this, entity_t e) { return doir_component_storage_get_impl(this, e, this->element_size); }
	#define doir_component_storage_get(type, this, e) ((type*)doir_component_storage_get_impl((void*)(this), (e), sizeof(type)))
	#define doir_component_storage_get_no_validation(type, this, e) ((type*)doir_component_storage_get_no_validation_impl((void*)(this), (e)))

	struct doir_component_storage_allocate_raw_impl_return_t {void* ret; size_t i;}
		doir_component_storage_allocate_raw_impl(DOIRComponentStorage* this, size_t type_size_validator)
	{
	#ifndef DOIR_COMPONENT_STORAGE_DONT_VALIDATE_TYPE_SIZES
		assert(type_size_validator == this->element_size);
	#else
		(void)type_size_validator;
	#endif

		fpda_grow(this->data, this->element_size);
		return (struct doir_component_storage_allocate_raw_impl_return_t){
			this->data + fpda_size(this->data) - this->element_size,
			(fpda_size(this->data) - 1) / this->element_size
		};
	}

	void* doir_component_storage_allocate_impl(DOIRComponentStorage* this, entity_t e, size_t type_size_validator) {
	#ifdef DOIR_COMPONENT_STORAGE_ENSURE_MONOTONIC_GROWTH
		assert(e >= this->last_entity);
		this->last_entity = e;
	#endif
		auto res = doir_component_storage_allocate_raw_impl(this, type_size_validator);
		if (fpda_size(this->indices) <= e) {
			auto start = fpda_size(this->indices);
			fpda_grow(this->indices, ((int64_t)e) - fpda_size(this->indices) + 1);
			for(auto cur = this->indices + start; cur < fpda_back(this->indices); cur++)
				*cur = (doir_skiplist_index_t)-1;
		}
		this->indices[e] = res.i * this->element_size;
		return res.ret;
	}
	#define doir_component_storage_allocate(type, this, e) ((type*)doir_component_storage_allocate_impl((void*)(this), (e), sizeof(type)))

	void* doir_component_storage_get_or_allocate_impl(DOIRComponentStorage* this, entity_t e, size_t type_size_validator) {
		if (fpda_size(this->indices) <= e || this->indices[e] == (doir_skiplist_index_t)-1)
			return doir_component_storage_allocate_impl(this, e, type_size_validator);
		return doir_component_storage_get_impl(this, e, type_size_validator);
	}
	#define doir_component_storage_get_or_allocate(type, this, e) ((type*)doir_component_storage_get_or_allocate_impl((void*)(this), (e), sizeof(type)))

#pragma endregion ComponentStorage


int main() {
	DOIRComponentStorage s;
	doir_component_storage_init(int, &s);
	*doir_component_storage_get_or_allocate(int, &s, 100) = 5;
	*doir_component_storage_get_or_allocate(int, &s, 50) = 5;

	DOIRComponentStorageTyped(int)* typed = &s;
	int cap = fpda_capacity(typed->data) / typed->element_size;
	int size = fpda_size(typed->data) / typed->element_size;
	cap = fpda_capacity(typed->indices);
	size = fpda_size(typed->indices);
	auto five = *doir_component_storage_get_or_allocate(int, typed, 100);
	five = *(int*)(s.data + typed->indices[100]);

	auto a = typed->indices[50];
	auto b = typed->indices[100];

	doir_component_storage_free(&s);
}