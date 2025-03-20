#pragma once

#include <string_view>

#include "ECS/ecs.hpp"
#include "ECS/adapter.hpp"
#include "ECS/entity.hpp"

namespace doir {
	template<typename T>
	struct ModuleCRTP {
		fp_string buffer = nullptr;

		T& underlying() { return *static_cast<T*>(this); }

		template<typename Th>
		using HashtableStorage = ecs::hashtable::Storage<Th>;

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
	};

	struct TrivialModule : public ecs::TrivialModule, public ModuleCRTP<TrivialModule> {};
	struct Module : public ecs::Module, public ModuleCRTP<Module> {};
}