#define DOIR_NO_PROFILING
#define DOIR_IMPLEMENTATION
#define FP_IMPLEMENTATION
#include "src/ECS/ecs.h"

#include "src/ECS/relational.hpp"

#include <nowide/iostream.hpp>

namespace kr = doir::kanren;

int main() {
	doir::ecs::RelationalModule mod; doir::ecs::Entity::set_current_module(mod);
	doir::ecs::Entity bart = mod.create_entity();
	bart.add_component<std::string>() = "Bart";
	doir::ecs::Entity lisa = mod.create_entity();
	lisa.add_component<std::string>() = "Lisa";
	doir::ecs::Entity homer = mod.create_entity();
	homer.add_component<std::string>() = "Homer";
	doir::ecs::Entity marg = mod.create_entity();
	marg.add_component<std::string>() = "Marg";
	doir::ecs::Entity abraham = mod.create_entity();
	abraham.add_component<std::string>() = "Abraham";

	struct parent : public doir::ecs::Relation<> {};
	bart.add_component<parent>() = {{homer, marg}};
	lisa.add_component<parent>() = {{homer, marg}};
	homer.add_component<parent>() = {{abraham}};

	struct male : public doir::ecs::Tag {};
	bart.add_component<male>();
	homer.add_component<male>();

	struct female : public doir::ecs::Tag {};
	lisa.add_component<female>();
	marg.add_component<female>();

	auto grandparent = [](const kr::Term& child, const kr::Term& grandparent) -> kr::Goal {
		return kr::next_variables([=](kr::Variable tmp) -> kr::Goal {
			return doir::ecs::related_entities<parent>(child, {tmp}) & doir::ecs::related_entities<parent>({tmp}, grandparent);
		});
	};

	kr::State state{&mod};
	auto x = kr::Variable::next(state);
	auto y = kr::Variable::next(state);
	auto g = grandparent({x}, {abraham}) & doir::ecs::has_component<male>({x});

	for (const auto& [m, sub, c] : g(state))
		for (const auto& [v, val] : sub)
			if (std::holds_alternative<doir::ecs::Entity>(val)) {
				auto e = std::get<doir::ecs::Entity>(val);
				std::cout << "Var " << v.id << " = " << e.get_component<std::string>() << "\n";
			}
}