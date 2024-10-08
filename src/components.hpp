#include "ECS/ecs.hpp"

#include <string_view>
#include <fp/string.h>
#include <stddef.h>

#ifdef __cplusplus
	#include <algorithm>
#endif

namespace doir {
	inline namespace component {

		struct source_location {
			size_t line, column;
			fp_string_view filename;

#ifdef __cplusplus
			static source_location calculate(fp_string_view view, size_t position, fp_string_view filename = fp_string_view_null) {
				source_location out{.filename = filename};
				for(size_t i = 0; i < position; ++i)
					if(fp_view_data(char, view)[i] == '\n') {
						++out.line;
						out.column = 0;
					} else ++out.column;
				return out;
			}
#endif
		};
		struct source_range {
			size_t start_line, start_column;
			size_t end_line, end_column;
			fp_string_view filename;

#ifdef __cplusplus
			static source_range calculate(fp_string_view view, size_t start, size_t end, fp_string_view filename = fp_string_view_null) {
				assert(start < end);
				source_range out{.filename = filename};
				for(size_t i = 0; i < end; ++i) {
					if(fp_view_data(char, view)[i] == '\n') {
						++out.end_line;
						out.end_column = 0;
					} else ++out.end_column;
					if(i == start) {
						out.start_line = out.end_line;
						out.start_column = out.end_column;
					}
				}
				return out;
			}
#endif
		};

		struct lexeme {
			size_t start, length;

#ifdef __cplusplus
			inline fp_string_view view(fp_string buffer) const {
				return {buffer + start, length};
			}
			inline fp_string_view view(fp_string_view view) const {
				assert(start + length < fp_view_size(view));
				return {fp_view_data(char, view) + start, length};
			}

			inline source_location start_location(fp_string_view view, fp_string_view filename = fp_string_view_null) const {
				assert(start + length < fp_view_size(view));
				return source_location::calculate(view, start, filename);
			}
			inline source_location end_location(fp_string_view view, fp_string_view filename = fp_string_view_null) const {
				assert(start + length < fp_view_size(view));
				return source_location::calculate(view, start + length, filename);
			}
			inline struct source_range source_range(fp_string_view view, fp_string_view filename = fp_string_view_null) const {
				assert(start + length < fp_view_size(view));
				return source_range::calculate(view, start, start + length);
			}

			inline lexeme merge(const lexeme o) const {
				auto start = std::min(this->start, o.start);
				auto end = std::max(this->start + length, o.start + o.length);
				return {start, end - start};
			}
			inline lexeme operator+(const lexeme o) const  { return merge(o); }
#endif // __cplusplus
		};

		struct entity_reference {
			ecs::entity_t entity = doir::ecs::invalid_entity;
			struct lexeme lexeme;
		};
	}
	namespace comp = component;
}
