#pragma once

#include <fp/dynarray.h>
#include <fp/string.h>

#ifdef DOIR_IMPLEMENTATION
	#ifndef __cplusplus
	#error The implementation of the C interface requires a C++ compiler!
	#endif

	#include "ecs.hpp"
	using namespace doir::ecs;

	extern "C" {
#else
	#ifdef __cplusplus
	extern "C" {
	#endif

	typedef size_t entity_t;

	size_t get_next_component_id();
	size_t doir_ecs_component_id_from_name_view(const fp_string_view view, bool create_if_not_found /*= true*/);
	size_t doir_ecs_component_id_from_name(const fp_string str, bool create_if_not_found /*= true*/);
	const fp_string doir_ecs_component_id_name(size_t componentID);
	void doir_ecs_component_id_free_maps();

	struct Storage;
	struct Module {
		fp_dynarray(fp_dynarray(size_t)) entity_component_indices;
		fp_dynarray(Storage) storages;
		fp_dynarray(entity_t) freelist;
		bool should_leak;
	};
#endif

#define doir_ecs_component_id_from_type(type) doir_ecs_component_id_from_name(#type)

Module doir_ecs_module_initalize()
#ifdef DOIR_IMPLEMENTATION
{ return {}; }
#else
;
#endif

void doir_ecs_module_free(Module* module)
#ifdef DOIR_IMPLEMENTATION
{ module->free(); }
#else
;
#endif

entity_t doir_ecs_module_create_entity(Module* module)
#ifdef DOIR_IMPLEMENTATION
{ return module->create_entity(); }
#else
;
#endif

bool doir_ecs_module_release_entity(Module* module, entity_t e, bool clearMemory /*= true*/)
#ifdef DOIR_IMPLEMENTATION
{ return module->release_entity(e, clearMemory); }
#else
;
#endif

void* doir_ecs_module_add_component(Module* module, entity_t e, size_t componentID, size_t element_size)
#ifdef DOIR_IMPLEMENTATION
{ return module->add_component(e, componentID, element_size); }
#else
;
#endif
#define doir_ecs_module_add_component_typed(type, module, e, componentID) doir_ecs_module_add_component((module), (e), (componentID), sizeof(type))

void* doir_ecs_module_get_component(Module* module, entity_t e, size_t componentID)
#ifdef DOIR_IMPLEMENTATION
{ return module->get_component(e, componentID); }
#else
;
#endif

bool doir_ecs_module_has_component(Module* module, entity_t e, size_t componentID)
#ifdef DOIR_IMPLEMENTATION
{ return module->has_component(e, componentID); }
#else
;
#endif

#ifdef __cplusplus
} // extern "C"
#endif