#include "tests.utils.hpp"

#include "../src/ECS/ecs.hpp"
// #include "../src/ECS/query.hpp"
// #include "../src/ECS/adapter.hpp"

TEST_SUITE("ECS") {
	TEST_CASE("doir::ecs::get_global_component_id") {
		ZoneScopedN("doir::ecs::get_global_component_id");
		{ZoneScopedN("First"); CHECK(doir::ecs::get_global_component_id<float>() == 0);}
		{ZoneScopedN("Second"); CHECK(doir::ecs::get_global_component_id<float>() == 0);}
		{ZoneScopedN("Int"); CHECK(doir::ecs::get_global_component_id<int>() == 1);}
		{ZoneScopedN("Lookup"); CHECK(doir::ecs::doir_ecs_component_id_from_name("float") == 0);}
		{ZoneScopedN("Lookup::NonExist"); CHECK(doir::ecs::doir_ecs_component_id_from_name("alice") == 2);}
		{ZoneScopedN("Lookup::NonExistNorCreate"); CHECK(doir::ecs::doir_ecs_component_id_from_name("bob", false) == -1);}
		{ZoneScopedN("Name"); 
			CHECK(std::string_view(doir::ecs::doir_ecs_component_id_name(0)) == "float");
			CHECK(std::string_view(doir::ecs::doir_ecs_component_id_name(1)) == "int");
			CHECK(std::string_view(doir::ecs::doir_ecs_component_id_name(2)) == "alice");
		}
		FrameMark;
	}

	TEST_CASE("doir::ecs::Basic") {
#ifdef DOIR_ENABLE_BENCHMARKING
		ankerl::nanobench::Bench().run("doir::ecs::Basic", []{
#endif
			ZoneScopedN("doir::ecs::Basic");
			doir::ecs::Module module;
			doir::ecs::entity_t e = module.create_entity();
			CHECK(e == 1);
			{
				ZoneScopedN("Add::Initial");
				CHECK((module.add_component<float>(e) = 5) == 5);
			}
			{
				ZoneScopedN("Get");
				CHECK(module.get_component<float>(e) == 5);
				module.get_component<float>(e) = 6;
				CHECK(module.get_component<float>(e) == 6);
				CHECK(module.has_component<int>(e) == false);
			}

			{
				ZoneScopedN("E2");
				doir::ecs::entity_t e2 = module.create_entity();
				CHECK(e2 == 2);
				CHECK((module.add_component<float>(e2) = 5) == 5);
				CHECK(module.get_component<float>(e) == 6);
			}
			// module.should_leak = true; // Don't bother cleaning up after ourselves...
#ifdef DOIR_ENABLE_BENCHMARKING
		});
#endif
		FrameMark;
	}

	// TEST_CASE("doir::ecs::Removal") {
	// 	ZoneScoped;
	// 	doir::ecs::scene scene;
	// 	doir::ecs::entity e = scene.create_entity();
	// 	CHECK(e == 0);
	// 	scene.add_component<float>(e);
	// 	CHECK(scene.release_entity(e));

	// 	e = scene.create_entity();
	// 	CHECK(e == 0);
	// 	CHECK(scene.has_component<float>(e) == false);

	// 	doir::ecs::entity e2 = scene.create_entity();
	// 	CHECK(e2 == 1);
	// 	doir::ecs::entity e3 = scene.create_entity();
	// 	CHECK(e3 == 2);
	// 	*scene.add_component<float>(e) = 1;
	// 	*scene.add_component<float>(e2) = 2;
	// 	*scene.add_component<float>(e3) = 3;
	// 	CHECK(*scene.get_component<float>(e) == 1);
	// 	CHECK(*scene.get_component<float>(e2) == 2);
	// 	CHECK(*scene.get_component<float>(e3) == 3);

	// 	CHECK(scene.remove_component<float>(e2) == true);
	// 	CHECK(*scene.get_component<float>(e) == 1);
	// 	CHECK(scene.has_component<float>(e2) == false);
	// 	CHECK(*scene.get_component<float>(e3) == 3);
	// }

	// TEST_CASE("doir::ecs::Query") {
	// 	ZoneScoped;
	// 	doir::ecs::scene scene;
	// 	*scene.add_component<float>(scene.create_entity()) = 1;
	// 	*scene.add_component<float>(scene.create_entity()) = 2;
	// 	*scene.add_component<float>(scene.create_entity()) = 3;

	// 	for(auto [e, value]: doir::ecs::query<doir::ecs::include_entity, float>(scene))
	// 		CHECK(e + 1 == value);

	// 	for(auto [e, value]: doir::ecs::query<doir::ecs::include_entity, std::optional<float>>(scene))
	// 		CHECK(e + 1 == *value);

	// 	for(auto [e, value]: doir::ecs::query<doir::ecs::include_entity, doir::ecs::or_<float, double>>(scene)) {
	// 		CHECK(e + 1 == std::get<std::reference_wrapper<float>>(value));
	// 		REQUIRE_THROWS((void)std::get<std::reference_wrapper<double>>(value));
	// 	}
	// }

	// TEST_CASE("doir::ecs::SortByValue") {
	// 	ZoneScoped;
	// 	doir::ecs::scene scene;
	// 	auto e0 = scene.create_entity();
	// 	*scene.add_component<float>(e0) = 3;
	// 	auto e1 = scene.create_entity();
	// 	*scene.add_component<float>(e1) = 27;
	// 	auto e2 = scene.create_entity();
	// 	*scene.add_component<float>(e2) = 5;
	// 	auto e3 = scene.create_entity();
	// 	*scene.add_component<float>(e3) = 0;

	// 	auto& storage = *scene.get_storage<float>();
	// 	storage.sort_by_value<float>(scene);
	// 	float* storage_as_float = (float*)storage.data.data();
	// 	CHECK(storage_as_float[0] == 0);
	// 	CHECK(*scene.get_component<float>(e0) == 3);
	// 	CHECK(storage_as_float[1] == 3);
	// 	CHECK(*scene.get_component<float>(e1) == 27);
	// 	CHECK(storage_as_float[2] == 5);
	// 	CHECK(*scene.get_component<float>(e2) == 5);
	// 	CHECK(storage_as_float[3] == 27);
	// 	CHECK(*scene.get_component<float>(e3) == 0);
	// }

	// TEST_CASE("doir::ecs::SortMontonic") {
	// 	ZoneScoped;
	// 	doir::ecs::scene scene;
	// 	auto e0 = scene.create_entity();
	// 	auto e1 = scene.create_entity();
	// 	auto e2 = scene.create_entity();
	// 	auto e3 = scene.create_entity();
	// 	*scene.add_component<float>(e3) = 0;
	// 	*scene.add_component<float>(e0) = 3;
	// 	*scene.add_component<float>(e2) = 5;
	// 	*scene.add_component<float>(e1) = 27;

	// 	auto& storage = *scene.get_storage<float>();
	// 	storage.sort_monotonic<float>(scene);
	// 	// scene.make_monotonic();
	// 	float* storage_as_float = (float*)storage.data.data();
	// 	CHECK(storage_as_float[0] == 3);
	// 	CHECK(*scene.get_component<float>(e0) == 3);
	// 	CHECK(storage_as_float[1] == 27);
	// 	CHECK(*scene.get_component<float>(e1) == 27);
	// 	CHECK(storage_as_float[2] == 5);
	// 	CHECK(*scene.get_component<float>(e2) == 5);
	// 	CHECK(storage_as_float[3] == 0);
	// 	CHECK(*scene.get_component<float>(e3) == 0);
	// }

	// TEST_CASE("doir::ecs::WithEntity") {
	// 	ZoneScoped;
	// 	doir::ecs::scene scene;
	// 	doir::ecs::entity e = scene.create_entity();
	// 	CHECK(e == 0);
	// 	CHECK((scene.add_component<doir::ecs::with_entity<float>>(e)->value = 5) == 5);
	// 	CHECK(scene.get_component<doir::ecs::with_entity<float>>(e)->entity == e);
	// 	CHECK(*scene.get_component<doir::ecs::with_entity<float>>(e) == 5);
	// 	CHECK(scene.get_component<doir::ecs::with_entity<float>>(e)->entity == e);
	// 	scene.get_component<doir::ecs::with_entity<float>>(e)->value = 6;
	// 	CHECK(*scene.get_component<doir::ecs::with_entity<float>>(e) == 6);
	// 	CHECK(scene.get_component<doir::ecs::with_entity<float>>(e)->entity == e);

	// 	doir::ecs::entity e2 = scene.create_entity();
	// 	CHECK(e2 == 1);
	// 	CHECK((scene.add_component<doir::ecs::with_entity<float>>(e2)->value = 5) == 5);
	// 	CHECK(scene.get_component<doir::ecs::with_entity<float>>(e2)->entity == e2);
	// 	CHECK(*scene.get_component<doir::ecs::with_entity<float>>(e2) == 5);
	// 	CHECK(*scene.get_component<doir::ecs::with_entity<float>>(e) == 6);
	// 	CHECK(scene.get_component<doir::ecs::with_entity<float>>(e2)->entity == e2);

	// 	scene.get_storage<doir::ecs::with_entity<float>>()->sort_by_value<doir::ecs::with_entity<float>>(scene);
	// 	CHECK(*scene.get_component<doir::ecs::with_entity<float>>(e) == 6);
	// 	CHECK(scene.get_component<doir::ecs::with_entity<float>>(e)->entity == e);
	// 	CHECK(*scene.get_component<doir::ecs::with_entity<float>>(e2) == 5);
	// 	CHECK(scene.get_component<doir::ecs::with_entity<float>>(e2)->entity == e2);

	// 	scene.get_storage<doir::ecs::with_entity<float>>()->sort_monotonic<doir::ecs::with_entity<float>>(scene);
	// 	CHECK(*scene.get_component<doir::ecs::with_entity<float>>(e) == 6);
	// 	CHECK(scene.get_component<doir::ecs::with_entity<float>>(e)->entity == e);
	// 	CHECK(*scene.get_component<doir::ecs::with_entity<float>>(e2) == 5);
	// 	CHECK(scene.get_component<doir::ecs::with_entity<float>>(e2)->entity == e2);
	// }

	// TEST_CASE("doir::ecs::typed") {
	// 	ZoneScoped;
	// 	doir::ecs::scene scene;
	// 	doir::ecs::entity e = scene.create_entity();
	// 	*scene.add_component<float>(e) = 5;
	// 	auto& storage = *get_adapted_component_storage<doir::ecs::typed::component_storage<float>>(scene);
	// 	CHECK(*storage.get(e) == 5);
	// }

	// TEST_CASE("doir::ecs::hashtable") {
	// 	ZoneScoped;
	// 	using C = doir::ecs::hashtable::component_storage<int>::component_type;

	// 	doir::ecs::scene scene;
	// 	doir::ecs::entity first = scene.create_entity();
	// 	doir::ecs::entity current = first;
	// 	for(size_t i = 0; i < 100; ++i) {
	// 		get_key_and_mark_occupied<int>(scene.add_component<C>(current)) = current;
	// 		current = scene.create_entity();
	// 	}

	// 	auto& hashtable = *get_adapted_component_storage<doir::ecs::hashtable::component_storage<int>>(scene);
	// 	CHECK(hashtable.rehash(scene) == true);
	// 	for(doir::ecs::entity e = first; e < first + 100; ++e) {
	// 		CHECK(*hashtable.find(e) == e);
	// 		CHECK(get_key<int>(scene.get_component<C>(*hashtable.find(e))) == e);
	// 	}
	// }

	// TEST_CASE("doir::ecs::UniqueTag") {
	// 	ZoneScoped;
	// 	doir::ecs::scene scene;
	// 	auto e0 = scene.create_entity();
	// 	auto e1 = scene.create_entity();
	// 	auto e2 = scene.create_entity();
	// 	auto e3 = scene.create_entity();
	// 	*scene.add_component<float>(e3) = 0;
	// 	*scene.add_component<float>(e0) = 3;
	// 	*scene.add_component<float>(e2) = 5;
	// 	*scene.add_component<float>(e1) = 27;
	// 	*scene.add_component<float, 1>(e3) = 27;
	// 	*scene.add_component<float, 1>(e0) = 5;
	// 	*scene.add_component<float, 1>(e2) = 3;
	// 	*scene.add_component<float, 1>(e1) = 0;

	// 	{
	// 		auto& storage = *scene.get_storage<float>();
	// 		storage.sort_monotonic<float>(scene);
	// 		// scene.make_monotonic();
	// 		float* storage_as_float = (float*)storage.data.data();
	// 		CHECK(storage_as_float[0] == 3);
	// 		CHECK(*scene.get_component<float>(e0) == 3);
	// 		CHECK(storage_as_float[1] == 27);
	// 		CHECK(*scene.get_component<float>(e1) == 27);
	// 		CHECK(storage_as_float[2] == 5);
	// 		CHECK(*scene.get_component<float>(e2) == 5);
	// 		CHECK(storage_as_float[3] == 0);
	// 		CHECK(*scene.get_component<float>(e3) == 0);
	// 	}
	// 	{
	// 		auto& storage = *scene.get_storage<float, 1>();
	// 		storage.sort_monotonic<float, 1>(scene);
	// 		// scene.make_monotonic();
	// 		float* storage_as_float = (float*)storage.data.data();
	// 		CHECK(storage_as_float[0] == 5);
	// 		CHECK(*scene.get_component<float, 1>(e0) == 5);
	// 		CHECK(storage_as_float[1] == 0);
	// 		CHECK(*scene.get_component<float, 1>(e1) == 0);
	// 		CHECK(storage_as_float[2] == 3);
	// 		CHECK(*scene.get_component<float, 1>(e2) == 3);
	// 		CHECK(storage_as_float[3] == 27);
	// 		CHECK(*scene.get_component<float, 1>(e3) == 27);
	// 	}
	// }
}