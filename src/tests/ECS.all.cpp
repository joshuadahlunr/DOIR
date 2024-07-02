#include "../../thirdparty/ECS.hpp"
#include "../../thirdparty/ECSquery.hpp"
#include "../../thirdparty/ECSadapter.hpp"

#include <doctest/doctest.h>
#include <tracy/Tracy.hpp>

TEST_SUITE("ECS") {
	TEST_CASE("ECS::Basic") {
		ZoneScoped;
		ecs::scene scene;
		ecs::entity e = scene.create_entity();
		CHECK(e == 0);
		{
			ZoneScoped;
			CHECK((*scene.add_component<float>(e) = 5) == 5);
		}
		{
			ZoneScoped;
			CHECK(*scene.get_component<float>(e) == 5);
			*scene.get_component<float>(e) = 6;
			CHECK(*scene.get_component<float>(e) == 6);
			CHECK(scene.get_component<int>(e).has_value() == false);
		}

		{
			ZoneScoped;
			ecs::entity e2 = scene.create_entity();
			CHECK(e2 == 1);
			CHECK((*scene.add_component<float>(e2) = 5) == 5);
			CHECK(*scene.get_component<float>(e) == 6);
		}
	}

	TEST_CASE("ECS::Removal") {
		ZoneScoped;
		ecs::scene scene;
		ecs::entity e = scene.create_entity();
		CHECK(e == 0);
		scene.add_component<float>(e);
		CHECK(scene.release_entity(e));

		e = scene.create_entity();
		CHECK(e == 0);
		CHECK(scene.has_component<float>(e) == false);

		ecs::entity e2 = scene.create_entity();
		CHECK(e2 == 1);
		ecs::entity e3 = scene.create_entity();
		CHECK(e3 == 2);
		*scene.add_component<float>(e) = 1;
		*scene.add_component<float>(e2) = 2;
		*scene.add_component<float>(e3) = 3;
		CHECK(*scene.get_component<float>(e) == 1);
		CHECK(*scene.get_component<float>(e2) == 2);
		CHECK(*scene.get_component<float>(e3) == 3);

		CHECK(scene.remove_component<float>(e2) == true);
		CHECK(*scene.get_component<float>(e) == 1);
		CHECK(scene.has_component<float>(e2) == false);
		CHECK(*scene.get_component<float>(e3) == 3);
	}

	TEST_CASE("ECS::Query") {
		ZoneScoped;
		ecs::scene scene;
		*scene.add_component<float>(scene.create_entity()) = 1;
		*scene.add_component<float>(scene.create_entity()) = 2;
		*scene.add_component<float>(scene.create_entity()) = 3;

		for(auto [e, value]: ecs::query<ecs::include_entity, float>(scene))
			CHECK(e + 1 == value);

		for(auto [e, value]: ecs::query<ecs::include_entity, std::optional<float>>(scene))
			CHECK(e + 1 == *value);

		for(auto [e, value]: ecs::query<ecs::include_entity, ecs::or_<float, double>>(scene)) {
			CHECK(e + 1 == std::get<std::reference_wrapper<float>>(value));
			REQUIRE_THROWS((void)std::get<std::reference_wrapper<double>>(value));
		}
	}

	TEST_CASE("ECS::SortByValue") {
		ZoneScoped;
		ecs::scene scene;
		auto e0 = scene.create_entity();
		*scene.add_component<float>(e0) = 3;
		auto e1 = scene.create_entity();
		*scene.add_component<float>(e1) = 27;
		auto e2 = scene.create_entity();
		*scene.add_component<float>(e2) = 5;
		auto e3 = scene.create_entity();
		*scene.add_component<float>(e3) = 0;

		auto& storage = *scene.get_storage<float>();
		storage.sort_by_value<float>(scene);
		float* storage_as_float = (float*)storage.data.data();
		CHECK(storage_as_float[0] == 0);
		CHECK(*scene.get_component<float>(e0) == 3);
		CHECK(storage_as_float[1] == 3);
		CHECK(*scene.get_component<float>(e1) == 27);
		CHECK(storage_as_float[2] == 5);
		CHECK(*scene.get_component<float>(e2) == 5);
		CHECK(storage_as_float[3] == 27);
		CHECK(*scene.get_component<float>(e3) == 0);
	}

	TEST_CASE("ECS::SortMontonic") {
		ZoneScoped;
		ecs::scene scene;
		auto e0 = scene.create_entity();
		auto e1 = scene.create_entity();
		auto e2 = scene.create_entity();
		auto e3 = scene.create_entity();
		*scene.add_component<float>(e3) = 0;
		*scene.add_component<float>(e0) = 3;
		*scene.add_component<float>(e2) = 5;
		*scene.add_component<float>(e1) = 27;

		auto& storage = *scene.get_storage<float>();
		storage.sort_monotonic<float>(scene);
		float* storage_as_float = (float*)storage.data.data();
		CHECK(storage_as_float[0] == 3);
		CHECK(*scene.get_component<float>(e0) == 3);
		CHECK(storage_as_float[1] == 27);
		CHECK(*scene.get_component<float>(e1) == 27);
		CHECK(storage_as_float[2] == 5);
		CHECK(*scene.get_component<float>(e2) == 5);
		CHECK(storage_as_float[3] == 0);
		CHECK(*scene.get_component<float>(e3) == 0);
	}

	TEST_CASE("ECS::WithEntity") {
		ZoneScoped;
		ecs::scene scene;
		ecs::entity e = scene.create_entity();
		CHECK(e == 0);
		CHECK((scene.add_component<ecs::with_entity<float>>(e)->value = 5) == 5);
		CHECK(scene.get_component<ecs::with_entity<float>>(e)->entity == e);
		CHECK(*scene.get_component<ecs::with_entity<float>>(e) == 5);
		CHECK(scene.get_component<ecs::with_entity<float>>(e)->entity == e);
		scene.get_component<ecs::with_entity<float>>(e)->value = 6;
		CHECK(*scene.get_component<ecs::with_entity<float>>(e) == 6);
		CHECK(scene.get_component<ecs::with_entity<float>>(e)->entity == e);

		ecs::entity e2 = scene.create_entity();
		CHECK(e2 == 1);
		CHECK((scene.add_component<ecs::with_entity<float>>(e2)->value = 5) == 5);
		CHECK(scene.get_component<ecs::with_entity<float>>(e2)->entity == e2);
		CHECK(*scene.get_component<ecs::with_entity<float>>(e2) == 5);
		CHECK(*scene.get_component<ecs::with_entity<float>>(e) == 6);
		CHECK(scene.get_component<ecs::with_entity<float>>(e2)->entity == e2);

		scene.get_storage<ecs::with_entity<float>>()->sort_by_value<ecs::with_entity<float>>(scene);
		CHECK(*scene.get_component<ecs::with_entity<float>>(e) == 6);
		CHECK(scene.get_component<ecs::with_entity<float>>(e)->entity == e);
		CHECK(*scene.get_component<ecs::with_entity<float>>(e2) == 5);
		CHECK(scene.get_component<ecs::with_entity<float>>(e2)->entity == e2);

		scene.get_storage<ecs::with_entity<float>>()->sort_monotonic<ecs::with_entity<float>>(scene);
		CHECK(*scene.get_component<ecs::with_entity<float>>(e) == 6);
		CHECK(scene.get_component<ecs::with_entity<float>>(e)->entity == e);
		CHECK(*scene.get_component<ecs::with_entity<float>>(e2) == 5);
		CHECK(scene.get_component<ecs::with_entity<float>>(e2)->entity == e2);
	}

	TEST_CASE("ECS::typed") {
		ZoneScoped;
		ecs::scene scene;
		ecs::entity e = scene.create_entity();
		*scene.add_component<float>(e) = 5;
		auto& storage = *get_adapted_component_storage<ecs::typed::component_storage<float>>(scene);
		CHECK(*storage.get(e) == 5);
	}

	TEST_CASE("ECC::hashtable") {
		ZoneScoped;
		using C = ecs::hashtable::component_storage<int>::component_type;

		ecs::scene scene;
		ecs::entity first = scene.create_entity();
		ecs::entity current = first;
		for(size_t i = 0; i < 100; ++i) {
			get_key_and_mark_occupied<int>(scene.add_component<C>(current)) = current;
			current = scene.create_entity();
		}

		auto& hashtable = *get_adapted_component_storage<ecs::hashtable::component_storage<int>>(scene);
		CHECK(hashtable.rehash(scene) == true);
		for(ecs::entity e = first; e < first + 100; ++e) {
			CHECK(*hashtable.find(e) == e);
			CHECK(get_key<int>(scene.get_component<C>(*hashtable.find(e))) == e);
		}
	}
}