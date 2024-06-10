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
	static std::optional<std::uint32_t> utf8_to_utf32(std::string_view utf8) {
		uint32_t ch;
		// size_t bytes = 0;

		if ((utf8[0] & 0x80) == 0x00) {
			// Single byte (ASCII)
			ch = utf8[0];
			// bytes = 1;
		} else if ((utf8[0] & 0xE0) == 0xC0) {
			// Two bytes
			if(utf8.size() < 2) return {};
			ch = (utf8[0] & 0x1F) << 6;
			ch |= (utf8[1] & 0x3F);
			// bytes = 2;
		} else if ((utf8[0] & 0xF0) == 0xE0) {
			// Three bytes
			if(utf8.size() < 3) return {};
			ch = (utf8[0] & 0x0F) << 12;
			ch |= (utf8[1] & 0x3F) << 6;
			ch |= (utf8[2] & 0x3F);
			// bytes = 3;
		} else if ((utf8[0] & 0xF8) == 0xF0) {
			// Four bytes
			if(utf8.size() < 4) return {};
			ch = (utf8[0] & 0x07) << 18;
			ch |= (utf8[1] & 0x3F) << 12;
			ch |= (utf8[2] & 0x3F) << 6;
			ch |= (utf8[3] & 0x3F);
			// bytes = 4;
		} else return {};
		return ch;
	}

	constexpr static auto skip_if_invalid = true;
	static bool next_valid(size_t index, char next) {
		if(index == 0) {
			tmp.clear();
			first = true;
		}
		tmp += next;
		// std::string debug = tmp;

		auto res = utf8_to_utf32(tmp);
		if(!res) return true;
		tmp.clear(); // If nothing went wrong in the conversion then we need to move onto the next character
		if(std::isspace(*res)) return false;
		if(first) {
			first = false;
            if constexpr(SupportLeadingPercent) if(*res == '%') return true;
			return is_xid_start(*res);
		}
		return is_xid_continue(*res);
	}
	static bool token_valid(std::string_view token) {
		if(!token.empty() && std::isspace(token[0])) return false;
		if(token.size() == 1 && token[0] == '%') return false; // Need a character after the percent!
		// Make sure that the last character is valid!
		bool valid = (token.size() >= 4 && utf8_to_utf32(token.substr(token.size() - 4)).has_value())
			|| (token.size() >= 3 && utf8_to_utf32(token.substr(token.size() - 3)).has_value())
			|| (token.size() >= 2 && utf8_to_utf32(token.substr(token.size() - 2)).has_value())
			|| (token.size() >= 1 && utf8_to_utf32(token.substr(token.size() - 1)).has_value());
		return valid;
	}
};

#ifdef DOIR_IMPLEMENTATION
thread_local std::string XIDIdentifierHeadStatics::tmp = {};
thread_local bool XIDIdentifierHeadStatics::first = true;
#endif