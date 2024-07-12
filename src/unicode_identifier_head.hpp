#pragma once

#include "lexer.hpp"

#include <codecvt>
#include <cstdint>
#include <locale>
#include "../thirdparty/unicode_ident.h"

struct XIDIdentifierHeadStatics {
	thread_local static std::string tmp;
	thread_local static bool first /*= true*/;
};

template<bool SupportLeadingPercent = false>
struct XIDIdentifierHead : public XIDIdentifierHeadStatics {
	static std::optional<std::uint32_t> utf8_to_single_utf32(std::string_view utf8) {
		uint32_t ch;

		if ((utf8[0] & 0x80) == 0x00)
			ch = utf8[0];
		else if ((utf8[0] & 0xE0) == 0xC0) {
			if(utf8.size() < 2) return {};
			ch = (utf8[0] & 0x1F) << 6;
			ch |= (utf8[1] & 0x3F);
		} else if ((utf8[0] & 0xF0) == 0xE0) {
			if(utf8.size() < 3) return {};
			ch = (utf8[0] & 0x0F) << 12;
			ch |= (utf8[1] & 0x3F) << 6;
			ch |= (utf8[2] & 0x3F);
		} else if ((utf8[0] & 0xF8) == 0xF0) {
			if(utf8.size() < 4) return {};
			ch = (utf8[0] & 0x07) << 18;
			ch |= (utf8[1] & 0x3F) << 12;
			ch |= (utf8[2] & 0x3F) << 6;
			ch |= (utf8[3] & 0x3F);
		} else return {};

		return ch;
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
		if(!res) return true; // NOTE: We mark partial characters as valid
		tmp.clear(); // If nothing went wrong in the conversion then we need to move onto the next character... thus clearing the buffer

		// If we get a space this is not a valid identififer
		if(std::isspace(*res)) return false;
		if(first) { // NOTE: We can't use index == 0 here because the first character might last up to index == 3
			first = false;
			if constexpr(SupportLeadingPercent) if(*res == '%') return true;
			return is_xid_start(*res);
		}
		return is_xid_continue(*res);
	}
	static bool token_valid(std::string_view token) {
		if(!token.empty() && std::isspace(token[0])) return false;
		if(token.size() == 1 && token[0] == '%') return false; // Need a character after the percent!
		// Make sure that the last character is valid (the next_valid step treats partial characters as valid... so if we are given a partial character on the end the string is not valid...)
		bool valid = (token.size() >= 1 && utf8_to_single_utf32(token.substr(token.size() - 1)).has_value())
			|| (token.size() >= 2 && utf8_to_single_utf32(token.substr(token.size() - 2)).has_value())
			|| (token.size() >= 3 && utf8_to_single_utf32(token.substr(token.size() - 3)).has_value())
			|| (token.size() >= 4 && utf8_to_single_utf32(token.substr(token.size() - 4)).has_value());
		return valid;
	}
};

#ifdef DOIR_IMPLEMENTATION
thread_local std::string XIDIdentifierHeadStatics::tmp = {};
thread_local bool XIDIdentifierHeadStatics::first = true;
#endif