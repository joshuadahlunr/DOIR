#pragma once

#include "core.hpp"

#include <ostream>
#include <sstream>
#include <iomanip>
#include <string_view>
#include <vector>
#include <map>
#include <algorithm>

#ifdef __cpp_exceptions
#include <exception>
#endif

namespace doir {
#ifdef __cpp_exceptions
	struct Diagnostic : public std::runtime_error { 
		using std::runtime_error::runtime_error; 
		int status;
		Diagnostic(const std::string& message, int status) : std::runtime_error(message), status(status) {}
	};
#endif

	enum class diagnostic_type {
		Info,
		Warning,
		Error,
		Fatal,
	};
	struct Label {
		doir::Token loc;
		std::string message;
	};
	constexpr std::string_view to_string(diagnostic_type type) {
		switch(type){
		break; case diagnostic_type::Info: return "Info";
		break; case diagnostic_type::Warning: return "Warning";
		break; case diagnostic_type::Error: return "Error";
		break; case diagnostic_type::Fatal: return "Fatal Error";
		}
		return "Unknown Problem";
	}
	constexpr std::string_view introducer(diagnostic_type type) {
		switch(type){
		break; case diagnostic_type::Info: return "Info at ";
		break; case diagnostic_type::Warning: return "Warning at ";
		break; case diagnostic_type::Error: return "An error has occurred at ";
		break; case diagnostic_type::Fatal: return "A fatal error (causing entire process to halt) has occurred at ";
		}
		return "Unknown Problem";
	}

	inline std::string generate_diagnostic(doir::Module& module, std::string_view main_message, const std::vector<Label>& labels, diagnostic_type type = diagnostic_type::Error) {
		if (labels.empty()) return std::string(main_message);

		std::stringstream ss;
		ss << to_string(type) << ": " << main_message << "\n";

		struct LineInfo {
			std::string_view filename;
			size_t line;
			size_t lineStart;
			size_t lineEnd;
			std::vector<const Label*> labels;
		};
		std::map<std::pair<std::string_view, size_t>, LineInfo> lines;

		size_t max_line_num = 0;
		for (const auto& label : labels) {
			auto& loc = *module.get_attribute<doir::NamedSourceLocation>(label.loc);
			auto& lex = *module.get_attribute<doir::Lexeme>(label.loc);

			auto key = std::make_pair(loc.filename, loc.line);
			if (lines.find(key) == lines.end()) {
				auto lineStart = module.buffer.rfind("\n", lex.start);
				if (lineStart == std::string::npos) lineStart = 0;
				else lineStart++; // skip the \n

				auto lineEnd = module.buffer.find("\n", lex.start);
				if (lineEnd == std::string::npos) lineEnd = module.buffer.size();

				lines[key] = {loc.filename, loc.line, lineStart, lineEnd, {}};
			}
			lines[key].labels.push_back(&label);
			max_line_num = std::max(max_line_num, loc.line);
		}

		int gutter = std::to_string(max_line_num).length();
		std::string indent(gutter, ' ');

		for (auto& [key, info] : lines) {
			ss << " " << indent << "╭─ " << info.filename << ":" << info.line << "\n";
			ss << " " << indent << "│\n";
			ss << " " << std::setw(gutter) << info.line << " │ " << module.buffer.substr(info.lineStart, info.lineEnd - info.lineStart) << "\n";
			ss << " " << indent << "│ ";

			// Sort labels by column
			std::vector<const Label*> sorted_labels = info.labels;
			std::sort(sorted_labels.begin(), sorted_labels.end(), [&](const Label* a, const Label* b) {
				return module.get_attribute<doir::NamedSourceLocation>(a->loc)->column <
				       module.get_attribute<doir::NamedSourceLocation>(b->loc)->column;
			});

			// Caret line
			size_t current_pos = 0;
			for (const auto* label : sorted_labels) {
				auto col = module.get_attribute<doir::NamedSourceLocation>(label->loc)->column;
				auto len = module.get_attribute<doir::Lexeme>(label->loc)->length;
				if (col > current_pos) {
					ss << std::string(col - current_pos - 1, ' ');
				}
				ss << std::string(len, '^');
				current_pos = col + len - 1;
			}
			ss << "\n";

			// Initial connector line
			ss << " " << indent << "│ ";
			current_pos = 0;
			for (const auto* label : sorted_labels) {
				auto col = module.get_attribute<doir::NamedSourceLocation>(label->loc)->column;
				if (col > current_pos) {
					ss << std::string(col - current_pos - 1, ' ');
					ss << "│";
					current_pos = col;
				}
			}
			ss << "\n";

			// Message lines (vertical style)
			for (int i = sorted_labels.size() - 1; i >= 0; --i) {
				ss << " " << indent << "│ ";
				current_pos = 0;
				for (int j = 0; j <= i; ++j) {
					auto col = module.get_attribute<doir::NamedSourceLocation>(sorted_labels[j]->loc)->column;
					if (col > current_pos) {
						ss << std::string(col - current_pos - 1, ' ');
						if (j < i) {
							ss << "│";
							current_pos = col;
						} else {
							ss << "╰─ " << sorted_labels[i]->message;
						}
					} else if (j == i) {
						ss << "╰─ " << sorted_labels[i]->message;
					}
				}
				ss << "\n";
			}
		}

		return ss.str();
	}

	inline std::string generate_diagnostic(doir::Module& module, doir::Token loc, std::string_view message, diagnostic_type type = diagnostic_type::Error) {
		return generate_diagnostic(module, message, {{loc, std::string(message)}}, type);
	}
	inline std::string generate_diagnostic(doir::Module& module, doir::Token loc, diagnostic_type type = diagnostic_type::Error) {
		if(module.has_attribute<doir::Error>(loc))
			return generate_diagnostic(module, loc, module.get_attribute<doir::Error>(loc)->message, type);
		return generate_diagnostic(module, loc, "Unknown Error", type);
	}

	struct Report {
		diagnostic_type type;
		std::string main_message;
		std::vector<Label> labels;

		Report(diagnostic_type type, std::string message) : type(type), main_message(message) {}

		Report& with_label(Token loc, std::string message) {
			labels.push_back({loc, message});
			return *this;
		}

		std::string generate(doir::Module& module) const {
			return generate_diagnostic(module, main_message, labels, type);
		}

		std::ostream& print(doir::Module& module, int exit_status = -1) const {
			auto msg = generate(module);
			auto& ret = (type >= diagnostic_type::Error ? nowide::cerr : nowide::cout) << msg;
			if(type == diagnostic_type::Fatal)
#ifdef __cpp_exceptions
				throw Diagnostic(msg, exit_status);
#else
				std::quick_exit(exit_status);
#endif
			return ret;
		}
	};
	
	inline std::ostream& print_diagnostic(doir::Module& module, doir::Token loc, std::string_view message, diagnostic_type type = diagnostic_type::Error, int exit_status = -1) {
		auto& ret = (type >= diagnostic_type::Error ? nowide::cerr : nowide::cout) << generate_diagnostic(module, loc, message, type);
		if(type == diagnostic_type::Fatal) 
#ifdef __cpp_exceptions
			throw Diagnostic(generate_diagnostic(module, loc, message, type), exit_status);
#else
			std::quick_exit(exit_status);
#endif
		return ret;
	}
	inline std::ostream& print_diagnostic(doir::Module& module, doir::Token loc, diagnostic_type type = diagnostic_type::Error, int exit_status = -1) {
		auto& ret = (type >= diagnostic_type::Error ? nowide::cerr : nowide::cout) << generate_diagnostic(module, loc, type);
		if(type == diagnostic_type::Fatal)
#ifdef __cpp_exceptions
			throw Diagnostic(generate_diagnostic(module, loc, type), exit_status);
#else
			std::quick_exit(exit_status);
#endif
		return ret;
	}
}