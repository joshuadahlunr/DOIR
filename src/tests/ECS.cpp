#include "../../thirdparty/ECS.hpp"
#include "../../thirdparty/ECSquery.hpp"

#include <doctest/doctest.h>
#include <functional>
#include <optional>
#include <ranges>

TEST_SUITE("ECS") {
	TEST_CASE("ECS Basic") {
		ecs::scene scene;
		ecs::entity e = scene.create_entity();
		CHECK(e == 0);
		CHECK((*scene.add_component<float>(e) = 5) == 5);
		CHECK(*scene.get_component<float>(e) == 5);
		*scene.get_component<float>(e) = 6;
		CHECK(*scene.get_component<float>(e) == 6);
		CHECK(scene.get_component<int>(e).has_value() == false);

		ecs::entity e2 = scene.create_entity();
		CHECK(e2 == 1);
		CHECK((*scene.add_component<float>(e2) = 5) == 5);
		CHECK(*scene.get_component<float>(e) == 6);
	}

	TEST_CASE("ECS Removal" * doctest::skip()) {
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

	TEST_CASE("ECS Query") {
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
			REQUIRE_THROWS(std::get<std::reference_wrapper<double>>(value));
		}

		// auto view = std::ranges::owning_view(ecs::query_with_entity<float>(scene));
		// view | std::views::filter([](float value) { return value == 2; });
		// auto filtered = std::ranges::views::filter( | std::views::take(3), [](float value) { return value == 2; });
	}

	
}