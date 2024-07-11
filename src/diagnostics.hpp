#pragma once

#include "core.hpp"

#include <ostream>
#include <sstream>
#include <iomanip>

namespace doir {
	enum class diagnostic_type {
		Info,
		Warning,
		Error,
		Fatal,
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
		break; case diagnostic_type::Error: return "An error has occured at ";
		break; case diagnostic_type::Fatal: return "A fatal error (causing entire process to halt) has occured at ";
		}
		return "Unknown Problem";
	}

	inline std::string generate_diagnostic(doir::Module& module, doir::Token loc, std::string_view message, diagnostic_type type = diagnostic_type::Error) {
		doir::NamedSourceLocation& location = *module.get_attribute<doir::NamedSourceLocation>(loc);
		doir::Lexeme& lexeme = *module.get_attribute<doir::Lexeme>(loc);

		auto lineStart = module.buffer.rfind("\n", lexeme.start);
		if(lineStart == std::string::npos) lineStart = 0;
		auto lineEnd = module.buffer.find("\n", lexeme.start);
		if(lineEnd == std::string::npos) lineEnd = module.buffer.size() - 1;

		return (std::stringstream{} << introducer(type) << location.to_string(lexeme.length) << "\n"
			<< "   " << module.buffer.substr(lineStart, lineEnd - lineStart) << "\n"
			<< std::setw(location.column + 3) << std::string(lexeme.length, '^') << "\n"
			<< std::setw(location.column + 3) << message).str();
	}
	inline std::string generate_diagnostic(doir::Module& module, doir::Token loc, diagnostic_type type = diagnostic_type::Error) {
		if(module.has_attribute<doir::Error>(loc))
			return generate_diagnostic(module, loc, module.get_attribute<doir::Error>(loc)->message, type);
		return generate_diagnostic(module, loc, "Unknown Error", type);
	}
	
	inline std::ostream& print_diagnostic(doir::Module& module, doir::Token loc, std::string_view message, diagnostic_type type = diagnostic_type::Error) {
		return (type >= diagnostic_type::Error ? std::cerr : std::cout) << generate_diagnostic(module, loc, message, type);
	}
	inline std::ostream& print_diagnostic(doir::Module& module, doir::Token loc, diagnostic_type type = diagnostic_type::Error) {
		return (type >= diagnostic_type::Error ? std::cerr : std::cout) << generate_diagnostic(module, loc, type);
	}
}