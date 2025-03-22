#pragma once

#include <string_view>

#include "ECS/ecs.hpp"
#include "ECS/adapter.hpp"
#include "ECS/entity.hpp"

#include "fnv1a.hpp"

namespace doir {
	template<typename T>
	struct ModuleCRTP {
		fp_string buffer = nullptr;

		T& underlying() { return *static_cast<T*>(this); }

		template<typename Th>
		using HashtableStorage = ecs::hashtable::Storage<Th, void, fnv::fnv1a_64<Th>>;

		template<typename Tcomponent>
		HashtableStorage<Tcomponent>& get_hashtable_storage() {
			return ecs::get_adapted_storage<HashtableStorage<Tcomponent>>(underlying());
		}
		template<typename Tcomponent>
		HashtableStorage<Tcomponent>& get_hashtable_storage_rehashed() {
			auto& table = get_hashtable_storage<Tcomponent>();
			table.rehash(underlying());
			return table;
		}

		template<typename Th>
		using HashtableComponent = ecs::hashtable::component_wrapper<Th, void>;

		static void set_current_module(T& module) { ecs::Entity::set_current_module(module); }
		static fp_string get_current_buffer() { 
			auto dbg = (T*)ecs::Entity::get_current_module();
			return dbg->buffer; 
		}
	};

	struct TrivialModule : public ecs::TrivialModule, public ModuleCRTP<TrivialModule> {};
	struct Module : public ecs::Module, public ModuleCRTP<Module> {};
}