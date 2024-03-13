#pragma once

#include <memory>
#include <vector>
#include <cassert>
#include <limits>

extern size_t globalAttributeCounter;
namespace ECS {
	template<typename T>
	size_t GetAttributeID(T reference = {}) {
		static size_t id = globalAttributeCounter++;
		return id;
	}

	using Token = size_t;

	struct AttributeStorage {
		size_t elementSize = -1;
		std::vector<std::byte> data;

		AttributeStorage() : elementSize(-1), data(1, std::byte{0}) {}
		AttributeStorage(size_t elementSize) : elementSize(elementSize) { data.reserve(5 * elementSize); }

		template<typename Tcomponent>
		AttributeStorage(Tcomponent reference = {}) : AttributeStorage(sizeof(Tcomponent)) {}

		template<typename Tcomponent>
		Tcomponent& Get(Token e) {
			assert(sizeof(Tcomponent) == elementSize);
			assert(e < (data.size() / elementSize));
			return *(Tcomponent*)(data.data() + e * elementSize);
		}

		template<typename Tcomponent>
		std::pair<Tcomponent&, size_t> Allocate(size_t count = 1) {
			assert(sizeof(Tcomponent) == elementSize);
			assert(count < 100);
			auto originalEnd = data.size();
			data.insert(data.end(), elementSize * count, std::byte{0});
			for(size_t i = 0; i < count - 1; i++) // Skip the last one
				new(data.data() + originalEnd + i * elementSize) Tcomponent();
			return {
				*new(data.data() + data.size() - elementSize) Tcomponent(),
				data.size() / elementSize
			};
		}

		template<typename Tcomponent>
		Tcomponent& GetOrAllocate(Token e) {
			assert(sizeof(Tcomponent) == elementSize);
			size_t size = data.size() / elementSize;
			if (size <= e)
				Allocate<Tcomponent>(std::max<int64_t>(int64_t(e) - size, 1));
			return Get<Tcomponent>(e);
		}
	};


	template<typename Storage = AttributeStorage>
	struct ParseData {
		std::vector<std::vector<bool>> entityMasks;
		std::vector<Storage> storages = {Storage()};

		template<typename Tcomponent>
		Storage& GetStorage() {
			size_t id = GetAttributeID<Tcomponent>();
			if(storages.size() <= id)
				storages.insert(storages.cend(), std::max<int64_t>(id - storages.size(), 1), Storage());
			if (storages[id].elementSize == std::numeric_limits<size_t>::max())
				storages[id] = Storage(Tcomponent{});
			return storages[id];
		}

		Token CreateToken() {
			Token e = entityMasks.size();
			entityMasks.emplace_back(std::vector<bool>{false});
			return e;
		}

		template<typename Tcomponent>
		Tcomponent& AddAttribute(Token e) {
			size_t id = GetAttributeID<Tcomponent>();
			auto& eMask = entityMasks[e];
			if(eMask.size() <= id)
				eMask.resize(id + 1, false);
			eMask[id] = true;
			return GetStorage<Tcomponent>().template GetOrAllocate<Tcomponent>(e);
		}

		template<typename Tcomponent>
		void RemoveAttribute(Token e) {
			size_t id = GetAttributeID<Tcomponent>();
			auto& eMask = entityMasks[e];
			if(eMask.size() > id)
				eMask[id] = false;
		}

		template<typename Tcomponent>
		Tcomponent& GetAttribute(Token e) {
			size_t id = GetAttributeID<Tcomponent>();
			assert(entityMasks[e][id]);
			return GetStorage<Tcomponent>().template Get<Tcomponent>(e);
		}

		template<typename Tcomponent>
		bool HasAttribute(Token e) {
			size_t id = GetAttributeID<Tcomponent>();
			return entityMasks.size() > e && entityMasks[e].size() > id && entityMasks[e][id];
		}
	};




	// Niceties!

	struct SkiplistAttributeStorage {
		size_t elementSize = -1;
		std::vector<size_t> indices;
		std::vector<std::byte> data;

		SkiplistAttributeStorage() : elementSize(-1), indices(1, -1), data(1, std::byte{0}) {}
		SkiplistAttributeStorage(size_t elementSize) : elementSize(elementSize) { data.reserve(5 * elementSize); }

		template<typename Tcomponent>
		SkiplistAttributeStorage(Tcomponent reference = {}) : SkiplistAttributeStorage(sizeof(Tcomponent)) {}

		template<typename Tcomponent>
		Tcomponent& Get(Token e) {
			assert(sizeof(Tcomponent) == elementSize);
			assert(e < indices.size());
			assert(indices[e] != std::numeric_limits<size_t>::max());
			return *(Tcomponent*)(data.data() + indices[e]);
		}

		template<typename Tcomponent>
		std::pair<Tcomponent&, size_t> Allocate() {
			assert(sizeof(Tcomponent) == elementSize);
			data.insert(data.end(), elementSize, std::byte{0});
			return {
				*new(data.data() + data.size() - elementSize) Tcomponent(),
				(data.size() - 1) / elementSize
			};
		}

		template<typename Tcomponent>
		Tcomponent& Allocate(Token e) {
			auto [ert, i] = Allocate<Tcomponent>();
			indices[e] = i * elementSize;
			return ert;
		}

		template<typename Tcomponent>
		Tcomponent& GetOrAllocate(Token e) {
			assert(sizeof(Tcomponent) == elementSize);
			if (indices.size() <= e)
				indices.insert(indices.end(), std::max<int64_t>(int64_t(e) - indices.size(), 1), -1);
			if (indices[e] == std::numeric_limits<size_t>::max())
				return Allocate<Tcomponent>(e);
			return Get<Tcomponent>(e);
		}
	};


	using post_increment_t = int;

	template<typename... Tcomponents>
	struct ParseDataView {
		ParseData<SkiplistAttributeStorage>& scene;

		struct Sentinel {};
		struct Iterator {
			ParseData<SkiplistAttributeStorage>* scene = nullptr;
			Token e;

			bool valid() { return (scene->HasAttribute<Tcomponents>(e) && ...); }

			bool operator==(Sentinel) { return scene == nullptr || e >= scene->entityMasks.size(); }

			Iterator& operator++(post_increment_t) {
				do {
					e++;
				} while(!valid() && e < scene->entityMasks.size());
				return *this;
			}
			Iterator operator++() {
				Iterator old;
				operator++(0);
				return old;
			}

			// Token operator*() { return e; }
			std::tuple<std::add_lvalue_reference_t<Tcomponents>...> operator*() { return { scene->GetAttribute<Tcomponents>(e)... }; }
		};

		Iterator begin() {
			Iterator out{&scene, 0};
			if(!out.valid()) ++out;
			return out;
		}
		Sentinel end() { return {}; }
	};
}