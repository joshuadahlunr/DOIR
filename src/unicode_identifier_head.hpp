#pragma once

#include "lexer.hpp"

// #include <codecvt>
// #include <cstdint>
// #include <locale>
#include <nowide/utf/utf.hpp>
#include "../thirdparty/unicode_ident.h"


struct XIDIdentifierHeadStatics {
	thread_local static std::string tmp;
	thread_local static bool first /*= true*/;
};

template<bool SupportLeadingPercent = false>
struct XIDIdentifierHead : public XIDIdentifierHeadStatics {
	static nowide::utf::code_point utf8_to_single_utf32(std::string_view view) {
		auto begin = view.begin();
		return nowide::utf::utf_traits<char>::decode(begin, view.end());
	}

	constexpr static auto skip_if_invalid = true;
	static bool next_valid(size_t index, char next) {
		// We save into a temporary string since one utf32 character can be up to 4 utf8 characters
		if(index == 0) {
			tmp.clear();
			first = true;
		}
		tmp += next;

		// We try to convert the character to its code point
		auto res = utf8_to_single_utf32(tmp);
		if(res == nowide::utf::incomplete) return true; // NOTE: We mark partial characters as valid
		tmp.clear(); // If nothing went wrong in the conversion then we need to move onto the next character... thus clearing the buffer

		// If we get a space this is not a valid identififer
		if(std::isspace(res)) return false;
		if(first) { // NOTE: We can't use index == 0 here because the first character might last up to index == 3
			first = false;
			if constexpr(SupportLeadingPercent) if(res == '%') return true;
			return is_xid_start(res);
		}
		return is_xid_continue(res);
	}
	static bool token_valid(std::string_view token) {
		if(!token.empty() && std::isspace(token[0])) return false;
		if(token.size() == 1 && token[0] == '%') return false; // Need a character after the percent!
		// Make sure that the last character is valid (the next_valid step treats partial characters as valid... so if we are given a partial character on the end the string is not valid...)
		bool valid = (token.size() >= 1 && utf8_to_single_utf32(token.substr(token.size() - 1)) != nowide::utf::incomplete)
			|| (token.size() >= 2 && utf8_to_single_utf32(token.substr(token.size() - 2)) != nowide::utf::incomplete)
			|| (token.size() >= 3 && utf8_to_single_utf32(token.substr(token.size() - 3)) != nowide::utf::incomplete)
			|| (token.size() >= 4 && utf8_to_single_utf32(token.substr(token.size() - 4)) != nowide::utf::incomplete);
		return valid;
	}
};

#ifdef DOIR_IMPLEMENTATION
thread_local std::string XIDIdentifierHeadStatics::tmp = {};
thread_local bool XIDIdentifierHeadStatics::first = true;
#endif