#pragma once

#include "components.hpp"
#include <nowide/iostream.hpp>

// namespace doir {
// 	inline namespace component {
// 		struct lexeme;
// 	}
// }

namespace doir::diagnostics {
	inline namespace components {
		struct error { fp::wrapped::string message = nullptr; };
		struct error_queue : fp::dynarray<ecs::Entity> {
			struct backtrack_marker {};

			ecs::Entity push_error(TrivialModule& module, const char* message, doir::lexeme lexeme) {
				auto out = ecs::Entity::create(module);
				out.add_component<error>().message = message;
				out.add_component<doir::lexeme>() = lexeme;
				push_back(out);
				return out;
			}

			ecs::Entity push_backtrack(TrivialModule& module) {
				auto out = ecs::Entity::create(module);
				out.add_component<backtrack_marker>();
				push_back(out);
				return out;
			}

			void backtrack() {
				while(!back().has_component<backtrack_marker>() && !empty())
					pop_back();
			}

			void clear_backtracking(TrivialModule& module) {
				for(size_t i = 0; i < size(); ++i)
					if(module.has_component<backtrack_marker>(operator[](i)))
						swap_delete(i--);
			}
		};
	}


	inline static fp_string generate(const TrivialModule& module, const fp_string_view message, const doir::lexeme& lexeme, const char* filename = "<generated>") {
		auto lines = module.buffer.split("\n");
		auto range = lexeme.source_range(module.buffer.to_view(), fp::string_view::from_cstr(filename));
		auto line = lines[range.start_line];

		size_t line_start = std::max<ptrdiff_t>(0, std::ptrdiff_t(range.start_column) - 35);
		size_t line_end = std::min<size_t>(line.size() - 1, range.start_column + 37);
		if(line.empty()) line_end = 0;
		else line = line.subview_start_end(line_start, line_end);
		auto start = range.start_column - line_start;

		return (
			fp::builder::string{nullptr} << fp::raii::string(range.to_string()) << " -> " << message << "\n"
			<< (line_start > 0 ? "  ..." : "  ") << line << (line_end < line.size() - 1 ? "..." : "") << "\n"
			<< " " << fp::raii::string{" "}.replicate(start) << fp::raii::string("^").replicate(lexeme.length) << "\n"
		).release();
	}

	inline static fp_string generate(const TrivialModule& module, ecs::Entity e, const char* filename = "<generated>") {
		if(!e.has_component<error>(module)) return nullptr;
		auto error = e.get_component<struct error>(module);
		auto lexeme = e.get_component<doir::lexeme>(module);
		return generate(module, error.message.to_view(), lexeme, filename);
	}

}
