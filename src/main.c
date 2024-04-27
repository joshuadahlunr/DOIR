#include <assert.h>
#include <stdint.h>
#include <stdio.h>

#define FP_IMPLEMENTATION
#include "fp/dynarray.h"

typedef uint32_t entity_t;

#define CSPrefix(name) doir_component_storage_##name

#define DOIRComponentStorageTyped(type) struct {\
	size_t element_size;\
	fp_dynarray(type) data; /* Fat pointer dynamic array */\
}
typedef DOIRComponentStorageTyped(uint8_t) DOIRComponentStorage;

#define __DOIRComponentStorageTypedCast(type, this) ((DOIRComponentStorageTyped(type)*)(this))

void CSPrefix(default) (DOIRComponentStorage* this) {
	this->element_size = -1;
	this->data = nullptr;
}

void CSPrefix(init_impl) (DOIRComponentStorage* this, size_t element_size) {
	this->element_size = element_size;
	this->data = nullptr;
}

#define doir_component_storage_initial_reservation(type, this, initialSize) (CSPrefix(init_impl)(this, sizeof(type)), fpda_reserve(__DOIRComponentStorageTypedCast(type, this)->data, initialSize))
#define doir_component_storage_init(type, this) doir_component_storage_initial_reservation(type, this, 5)

void CSPrefix(free) (DOIRComponentStorage* this) {
	fpda_free(this->data);
	CSPrefix(default)(this);
}

size_t CSPrefix(capacity)(DOIRComponentStorage* this) { return fpda_capacity(this->data) / this->element_size; }
size_t CSPrefix(size)(DOIRComponentStorage* this) { return fpda_size(this->data) / this->element_size; }

void* CSPrefix(get_impl) (DOIRComponentStorage* this, entity_t e, size_t type_size_validator) {
#ifndef DOIR_COMPONENT_STORAGE_DONT_VALIDATE_TYPE_SIZES
	assert(type_size_validator == this->element_size);
#else
	(void)type_size_validator;
#endif
	assert(e < fpda_size(this->data) / this->element_size);
	return this->data + e * this->element_size;
}
void* CSPrefix(get_no_validation) (DOIRComponentStorage* this, entity_t e) { return CSPrefix(get_impl)(this, e, this->element_size); }
#define doir_component_storage_get(type, this, e) ((type*)CSPrefix(get_impl)((void*)(this), (e), sizeof(type)))

void* CSPrefix(allocate_impl)(DOIRComponentStorage* this, size_t count, size_t type_size_validator) {
#ifndef DOIR_COMPONENT_STORAGE_DONT_VALIDATE_TYPE_SIZES
	assert(type_size_validator == this->element_size);
#else
	(void)type_size_validator;
#endif

	fpda_grow(this->data, this->element_size * count);
	return this->data + fpda_size(this->data) - this->element_size;
}
#define doir_component_storage_allocate_count(type, this, count) ((type*)CSPrefix(allocate_impl)((void*)(this), (count), sizeof(type)))
#define doir_component_storage_allocate(type, this) ((type*)CSPrefix(allocate_impl)((void*)(this), 1, sizeof(type)))

void* CSPrefix(get_or_allocate_impl)(DOIRComponentStorage* this, entity_t e, size_t type_size_validator) {
	size_t size = CSPrefix(size)(this);
	if (size <= e)
		CSPrefix(allocate_impl)(this, ((int64_t)e) - size + 1, type_size_validator);
	return CSPrefix(get_impl)(this, e, type_size_validator);
}
#define doir_component_storage_get_or_allocate(type, this, e) ((type*)CSPrefix(get_or_allocate_impl)((void*)(this), (e), sizeof(type)))



int main() {
	DOIRComponentStorage s;
	doir_component_storage_init(int, &s);
	*doir_component_storage_get_or_allocate(int, &s, 100) = 5;

	DOIRComponentStorageTyped(int)* typed = &s;
	int cap = fpda_capacity(typed->data) / typed->element_size;
	int size = fpda_size(typed->data) / typed->element_size;
	auto five = *doir_component_storage_get_or_allocate(int, typed, 100);
	five = typed->data[100];

	doir_component_storage_free(&s);
}