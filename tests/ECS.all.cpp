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

	TEST_CASE("doir::ecs::Removal") {
#ifdef DOIR_ENABLE_BENCHMARKING
		ankerl::nanobench::Bench().run("doir::ecs::Removal", []{
#endif
			ZoneScopedN("doir::ecs::Removal");
			doir::ecs::Module module;
			doir::ecs::entity_t e = module.create_entity();
			CHECK(e == 1);
			module.add_component<float>(e);
			CHECK(module.release_entity(e));

			e = module.create_entity();
			CHECK(e == 1);
			CHECK(module.has_component<float>(e) == false);

			doir::ecs::entity_t e2 = module.create_entity();
			CHECK(e2 == 2);
			doir::ecs::entity_t e3 = module.create_entity();
			CHECK(e3 == 3);
			module.add_component<float>(e) = 1;
			module.add_component<float>(e2) = 2;
			module.add_component<float>(e3) = 3;
			CHECK(module.get_component<float>(e) == 1);
			CHECK(module.get_component<float>(e2) == 2);
			CHECK(module.get_component<float>(e3) == 3);

			CHECK(module.remove_component<float>(e2) == true);
			CHECK(module.get_component<float>(e) == 1);
			CHECK(module.has_component<float>(e2) == false);
			CHECK(module.get_component<float>(e3) == 3);
			// module.should_leak = true; // Don't bother cleaning up after ourselves...
#ifdef DOIR_ENABLE_BENCHMARKING
		});
#endif
		FrameMark;
	}

	TEST_CASE("doir::ecs::SortByValue") {
#ifdef DOIR_ENABLE_BENCHMARKING
		ankerl::nanobench::Bench().run("doir::ecs::SortByValue", []{
#endif
			ZoneScopedN("doir::ecs::SortByValue");
			doir::ecs::Module module;
			auto e0 = module.create_entity();
			module.add_component<float>(e0) = 3;
			auto e1 = module.create_entity();
			module.add_component<float>(e1) = 27;
			auto e2 = module.create_entity();
			module.add_component<float>(e2) = 5;
			auto e3 = module.create_entity();
			module.add_component<float>(e3) = 0;

			auto& storage = module.get_storage<float>();
			storage.sort_by_value<float>(module);
			float* storage_as_float = storage.data<float>();
			CHECK(storage_as_float[0] == 0);
			CHECK(module.get_component<float>(e0) == 3);
			CHECK(storage_as_float[1] == 3);
			CHECK(module.get_component<float>(e1) == 27);
			CHECK(storage_as_float[2] == 5);
			CHECK(module.get_component<float>(e2) == 5);
			CHECK(storage_as_float[3] == 27);
			CHECK(module.get_component<float>(e3) == 0);
			// module.should_leak = true; // Don't bother cleaning up after ourselves...
#ifdef DOIR_ENABLE_BENCHMARKING
		});
#endif
		FrameMark;
	}

	TEST_CASE("doir::ecs::SortMontonic") {
#ifdef DOIR_ENABLE_BENCHMARKING
		ankerl::nanobench::Bench().run("doir::ecs::SortMontonic", []{
#endif
			ZoneScopedN("doir::ecs::SortMontonic");
			doir::ecs::Module module;
			auto e0 = module.create_entity();
			auto e1 = module.create_entity();
			auto e2 = module.create_entity();
			auto e3 = module.create_entity();
			module.add_component<float>(e3) = 0;
			module.add_component<float>(e0) = 3;
			module.add_component<float>(e2) = 5;
			module.add_component<float>(e1) = 27;

			auto& storage = module.get_storage<float>();
			storage.sort_monotonic<float>(module);
			// module.make_monotonic();
			float* storage_as_float = storage.data<float>();
			CHECK(storage_as_float[0] == 3);
			CHECK(module.get_component<float>(e0) == 3);
			CHECK(storage_as_float[1] == 27);
			CHECK(module.get_component<float>(e1) == 27);
			CHECK(storage_as_float[2] == 5);
			CHECK(module.get_component<float>(e2) == 5);
			CHECK(storage_as_float[3] == 0);
			CHECK(module.get_component<float>(e3) == 0);
			// module.should_leak = true; // Don't bother cleaning up after ourselves...
#ifdef DOIR_ENABLE_BENCHMARKING
		});
#endif
		FrameMark;
	}

	TEST_CASE("doir::ecs::WithEntity") {
#ifdef DOIR_ENABLE_BENCHMARKING
		ankerl::nanobench::Bench().run("doir::ecs::WithEntity", []{
#endif
			ZoneScopedN("doir::ecs::WithEntity");
			doir::ecs::Module module;
			doir::ecs::entity_t e = module.create_entity();
			CHECK(e == 1);
			CHECK((module.add_component<doir::ecs::with_entity<float>>(e).value = 5) == 5);
			CHECK(module.get_component<doir::ecs::with_entity<float>>(e).entity == e);
			CHECK(module.get_component<doir::ecs::with_entity<float>>(e) == 5);
			CHECK(module.get_component<doir::ecs::with_entity<float>>(e).entity == e);
			module.get_component<doir::ecs::with_entity<float>>(e).value = 6;
			CHECK(module.get_component<doir::ecs::with_entity<float>>(e) == 6);
			CHECK(module.get_component<doir::ecs::with_entity<float>>(e).entity == e);

			doir::ecs::entity_t e2 = module.create_entity();
			CHECK(e2 == 2);
			CHECK((module.add_component<doir::ecs::with_entity<float>>(e2).value = 5) == 5);
			CHECK(module.get_component<doir::ecs::with_entity<float>>(e2).entity == e2);
			CHECK(module.get_component<doir::ecs::with_entity<float>>(e2) == 5);
			CHECK(module.get_component<doir::ecs::with_entity<float>>(e) == 6);
			CHECK(module.get_component<doir::ecs::with_entity<float>>(e2).entity == e2);

			module.get_storage<doir::ecs::with_entity<float>>().sort_by_value<doir::ecs::with_entity<float>>(module);
			CHECK(module.get_component<doir::ecs::with_entity<float>>(e) == 6);
			CHECK(module.get_component<doir::ecs::with_entity<float>>(e).entity == e);
			CHECK(module.get_component<doir::ecs::with_entity<float>>(e2) == 5);
			CHECK(module.get_component<doir::ecs::with_entity<float>>(e2).entity == e2);

			module.get_storage<doir::ecs::with_entity<float>>().sort_monotonic<doir::ecs::with_entity<float>>(module);
			CHECK(module.get_component<doir::ecs::with_entity<float>>(e) == 6);
			CHECK(module.get_component<doir::ecs::with_entity<float>>(e).entity == e);
			CHECK(module.get_component<doir::ecs::with_entity<float>>(e2) == 5);
			CHECK(module.get_component<doir::ecs::with_entity<float>>(e2).entity == e2);
			// module.should_leak = true; // Don't bother cleaning up after ourselves...
#ifdef DOIR_ENABLE_BENCHMARKING
		});
#endif
		FrameMark;
	}

	TEST_CASE("doir::ecs::UniqueTag") {
#ifdef DOIR_ENABLE_BENCHMARKING
		ankerl::nanobench::Bench().run("doir::ecs::UniqueTag", []{
#endif
			ZoneScopedN("doir::ecs::UniqueTag");
			doir::ecs::Module module;
			auto e0 = module.create_entity();
			auto e1 = module.create_entity();
			auto e2 = module.create_entity();
			auto e3 = module.create_entity();
			module.add_component<float>(e3) = 0;
			module.add_component<float>(e0) = 3;
			module.add_component<float>(e2) = 5;
			module.add_component<float>(e1) = 27;
			module.add_component<float, 1>(e3) = 27;
			module.add_component<float, 1>(e0) = 5;
			module.add_component<float, 1>(e2) = 3;
			module.add_component<float, 1>(e1) = 0;

			{
				auto& storage = module.get_storage<float>();
				storage.sort_monotonic<float>(module);
				float* storage_as_float = storage.data<float>();
				CHECK(storage_as_float[0] == 3);
				CHECK(module.get_component<float>(e0) == 3);
				CHECK(storage_as_float[1] == 27);
				CHECK(module.get_component<float>(e1) == 27);
				CHECK(storage_as_float[2] == 5);
				CHECK(module.get_component<float>(e2) == 5);
				CHECK(storage_as_float[3] == 0);
				CHECK(module.get_component<float>(e3) == 0);
			}
			{
				auto& storage = module.get_storage<float, 1>();
				storage.sort_monotonic<float, 1>(module);
				float* storage_as_float = storage.data<float>();
				CHECK(storage_as_float[0] == 5);
				CHECK(module.get_component<float, 1>(e0) == 5);
				CHECK(storage_as_float[1] == 0);
				CHECK(module.get_component<float, 1>(e1) == 0);
				CHECK(storage_as_float[2] == 3);
				CHECK(module.get_component<float, 1>(e2) == 3);
				CHECK(storage_as_float[3] == 27);
				CHECK(module.get_component<float, 1>(e3) == 27);
			}
			// module.should_leak = true; // Don't bother cleaning up after ourselves...
#ifdef DOIR_ENABLE_BENCHMARKING
		});
#endif
		FrameMark;
	}

	// TEST_CASE("doir::ecs::Query") {
	// 	ZoneScoped;
	// 	doir::ecs::module module;
	// 	*module.add_component<float>(module.create_entity()) = 1;
	// 	*module.add_component<float>(module.create_entity()) = 2;
	// 	*module.add_component<float>(module.create_entity()) = 3;

	// 	for(auto [e, value]: doir::ecs::query<doir::ecs::include_entity, float>(module))
	// 		CHECK(e + 1 == value);

	// 	for(auto [e, value]: doir::ecs::query<doir::ecs::include_entity, std::optional<float>>(module))
	// 		CHECK(e + 1 == *value);

	// 	for(auto [e, value]: doir::ecs::query<doir::ecs::include_entity, doir::ecs::or_<float, double>>(module)) {
	// 		CHECK(e + 1 == std::get<std::reference_wrapper<float>>(value));
	// 		REQUIRE_THROWS((void)std::get<std::reference_wrapper<double>>(value));
	// 	}
	// }

	// TEST_CASE("doir::ecs::typed") {
	// 	ZoneScoped;
	// 	doir::ecs::module module;
	// 	doir::ecs::entity e = module.create_entity();
	// 	*module.add_component<float>(e) = 5;
	// 	auto& storage = *get_adapted_component_storage<doir::ecs::typed::component_storage<float>>(module);
	// 	CHECK(*storage.get(e) == 5);
	// }

	// TEST_CASE("doir::ecs::hashtable") {
	// 	ZoneScoped;
	// 	using C = doir::ecs::hashtable::component_storage<int>::component_type;

	// 	doir::ecs::module module;
	// 	doir::ecs::entity first = module.create_entity();
	// 	doir::ecs::entity current = first;
	// 	for(size_t i = 0; i < 100; ++i) {
	// 		get_key_and_mark_occupied<int>(module.add_component<C>(current)) = current;
	// 		current = module.create_entity();
	// 	}

	// 	auto& hashtable = *get_adapted_component_storage<doir::ecs::hashtable::component_storage<int>>(module);
	// 	CHECK(hashtable.rehash(module) == true);
	// 	for(doir::ecs::entity e = first; e < first + 100; ++e) {
	// 		CHECK(*hashtable.find(e) == e);
	// 		CHECK(get_key<int>(module.get_component<C>(*hashtable.find(e))) == e);
	// 	}
	// }

	TEST_CASE("doir::ecs::component_id_free_maps") {
		ZoneScopedN("doir::ecs::component_id_free_maps");
		doir::ecs::component_id_free_maps();
	}
}