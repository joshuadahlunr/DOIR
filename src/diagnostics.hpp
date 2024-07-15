#pragma once

#include "core.hpp"

#include <ostream>
#include <sstream>
#include <iomanip>

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
			<< "   " << module.buffer.substr(lineStart, lineEnd - lineStart + 1) << "\n"
			<< std::setw(location.column + lexeme.length + 2) << std::string(lexeme.length, '^') << "\n"
			<< std::setw(location.column + lexeme.length + 2) << message).str();
	}
	inline std::string generate_diagnostic(doir::Module& module, doir::Token loc, diagnostic_type type = diagnostic_type::Error) {
		if(module.has_attribute<doir::Error>(loc))
			return generate_diagnostic(module, loc, module.get_attribute<doir::Error>(loc)->message, type);
		return generate_diagnostic(module, loc, "Unknown Error", type);
	}
	
	inline std::ostream& print_diagnostic(doir::Module& module, doir::Token loc, std::string_view message, diagnostic_type type = diagnostic_type::Error, int exit_status = -1) {
		auto& ret = (type >= diagnostic_type::Error ? std::cerr : std::cout) << generate_diagnostic(module, loc, message, type);
		if(type == diagnostic_type::Fatal) 
#ifdef __cpp_exceptions
			throw Diagnostic(generate_diagnostic(module, loc, message, type), exit_status);
#else
			std::quick_exit(status);
#endif
		return ret;
	}
	inline std::ostream& print_diagnostic(doir::Module& module, doir::Token loc, diagnostic_type type = diagnostic_type::Error, int exit_status = -1) {
		auto& ret = (type >= diagnostic_type::Error ? std::cerr : std::cout) << generate_diagnostic(module, loc, type);
		if(type == diagnostic_type::Fatal)
#ifdef __cpp_exceptions
			throw Diagnostic(generate_diagnostic(module, loc, type), exit_status);
#else
			std::quick_exit(status);
#endif
		return ret;
	}
}