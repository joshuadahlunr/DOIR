#define DOIR_IMPLEMENTATION
#define FP_IMPLEMENTATION
// #include "src/components.hpp"
#include "src/diagnostics.hpp"

using namespace doir;

inline namespace components {
	struct block_entry: public array_entry { auto iterate(ecs::TrivialModule& module) {
		return iterate_impl<ecs::entity_t, block_entry>{*this, module};
	}};

	struct block: public array<block_entry> {
		ecs::Entity parent = ecs::invalid_entity;
	};
}
// namespace comp = components;

ecs::entity_t program(TrivialModule& module, fp::string_view& remaining);
ecs::entity_t assignment(TrivialModule& module, fp::string_view& remaining);
ecs::entity_t deducible_type(TrivialModule& module, fp::string_view& remaining);
ecs::entity_t identifier_type_pair(TrivialModule& module, fp::string_view& remaining);
ecs::entity_t function_type(TrivialModule& module, fp::string_view& remaining);
ecs::entity_t type(TrivialModule& module, fp::string_view& remaining);
ecs::entity_t block_(TrivialModule& module, fp::string_view& remaining) { return ecs::invalid_entity; }
ecs::entity_t type_block(TrivialModule& module, fp::string_view& remaining) { return ecs::invalid_entity; }
ecs::entity_t function_call(TrivialModule& module, fp::string_view& remaining) { return ecs::invalid_entity; }
bool terminator(TrivialModule& module, fp::string_view& remaining);
fp::string_view identifier(TrivialModule& module, fp::string_view& remaining);
ecs::entity_t keywords(TrivialModule& module, fp::string_view& remaining);
ecs::entity_t source_info(TrivialModule& module, fp::string_view& remaining) { return ecs::invalid_entity; }
ecs::entity_t constant(TrivialModule& module, fp::string_view& remaining);
ecs::entity_t integer_constant(TrivialModule& module, fp::string_view& remaining);
ecs::entity_t float_constant(TrivialModule& module, fp::string_view& remaining) { return ecs::invalid_entity; }
fp::string_view string_char(TrivialModule& module, fp::string_view& remaining) { return {nullptr, 0}; }
fp::string_view hex_digit(TrivialModule& module, fp::string_view& remaining) { return {nullptr, 0}; }
void _(TrivialModule& module, fp::string_view& remaining);
void wsc(TrivialModule& module, fp::string_view& remaining);
bool long_comment(TrivialModule& module, fp::string_view& remaining);
bool line_comment(TrivialModule& module, fp::string_view& remaining);

void return_void() {}

#define LEXEME_HERE_LENGTH(len) doir::lexeme::from_view(module, remaining.subview_max_size(0, len))
#define LEXEME_HERE() LEXEME_HERE_LENGTH(1)

#define PUSH_ERROR(str, lexeme) do {\
	auto& errors = module.get_or_add_component<doir::diagnostics::error_queue>(ecs::invalid_entity);\
	errors.push_error(module, str, lexeme);\
} while(false);

#define RETURN_ERROR(str, lexeme) do {\
	PUSH_ERROR(str, lexeme)\
	return ecs::invalid_entity;\
} while(false);

#define SETUP_BACKTRACK()\
	auto backtrack = remaining;\
	module.get_or_add_component<doir::diagnostics::error_queue>(ecs::invalid_entity).push_backtrack(module);

#define BACKTRACK() (\
	remaining = backtrack,\
	module.get_component<doir::diagnostics::error_queue>(ecs::invalid_entity).backtrack()\
)


// program <- - assignment*
ecs::entity_t program(TrivialModule& module, fp::string_view& remaining) {
	auto blockE = ecs::Entity::create(module);
	auto& block = blockE.add_component<struct block>();

	// NOTE: We need an entity to exist before error handling will work!
	if(remaining.empty()) RETURN_ERROR("Unexpected end of input!", LEXEME_HERE());

	_(module, remaining);

	ecs::Entity assign;
	while(true) {
		if((assign = assignment(module, remaining)))
			block.push_back(module, assign);
		else if (remaining.empty())
			break;

		// If there is an error eat characters until we reach a terminator or a block end
		else while(!(terminator(module, remaining) || remaining[0] == '}'))
			remaining = remaining.subview(1);
	}

	if(module.has_component<doir::diagnostics::error_queue>(ecs::invalid_entity)) {
		auto& errors = module.get_component<doir::diagnostics::error_queue>(ecs::invalid_entity);
		errors.pop_back(); // The last error should always be an out of input error... no need to display it
		errors.clear_backtracking(module); // Get rid of all the backtracking information
		if(!errors.empty()) return ecs::invalid_entity;
	}
	return blockE;
}
// assignment <- Identifier- ':'- Type- '='- (Constant wsc / Block wsc / type_block / function_call) (SourceInfo wsc)? Terminator-
ecs::entity_t assignment(TrivialModule& module, fp::string_view& remaining) {
	if(remaining.empty()) RETURN_ERROR("Unexpected end of input!", LEXEME_HERE());

	auto ident = identifier(module, remaining);
	if(ident.data() == nullptr) RETURN_ERROR("Invalid identifier!", LEXEME_HERE());
	_(module, remaining);

	if(remaining[0] != ':') RETURN_ERROR("Expected a colon (:)!", LEXEME_HERE());
	remaining = remaining.subview(1);
	_(module, remaining);

	ecs::entity_t typeE;
	if((typeE = type(module, remaining)) == ecs::invalid_entity) return ecs::invalid_entity;
	_(module, remaining);

	if(remaining[0] != '=') RETURN_ERROR("Expected an equals sign (=)!", LEXEME_HERE());
	remaining = remaining.subview(1);
	_(module, remaining);

	SETUP_BACKTRACK();
	if(auto literal = constant(module, remaining); literal) {
		wsc(module, remaining);

	} else if(auto blockE = (BACKTRACK(), block_(module, remaining)); blockE) {
		wsc(module, remaining);

	} else if(auto type = (BACKTRACK(), type_block(module, remaining)); type) {

	} else if(auto call = (BACKTRACK(), function_call(module, remaining)); call) {

	} else RETURN_ERROR("Expected a constant, block, type, or function call!", LEXEME_HERE());

	if(auto source = source_info(module, remaining); source) {
		wsc(module, remaining);

	}

	if(!terminator(module, remaining)) RETURN_ERROR("Expected an assignment terminator (; or newline)!", LEXEME_HERE());

	return /*valid*/1;
}

// deducible_type <- Type wsc / 'deduced'- 'type'wsc
// identifier_type_pair <- Identifier- ':'- deducible_type
// FunctionType <- Identifier- '('- (identifier_type_pair ','-)* ')'
ecs::entity_t function_type(TrivialModule& module, fp::string_view& remaining) {
	return ecs::invalid_entity;
}
// Type <- ('comptime'-)? ('alias' / 'block' / 'namespace' / 'type' / FunctionType / Identifier)
ecs::entity_t type(TrivialModule& module, fp::string_view& remaining) {
	constexpr std::string_view comptime = "comptime";
	constexpr std::string_view alias = "alias";
	constexpr std::string_view block = "block";
	constexpr std::string_view namespace_ = "namespace";
	constexpr std::string_view type = "type";

	if(remaining.empty()) RETURN_ERROR("Unexpected end of input!", LEXEME_HERE());
	if(remaining.subview_max_size(0, comptime.size()) == comptime.data()) {
		remaining = remaining.subview(comptime.size());
		_(module, remaining);

		// comptime present
	}

	SETUP_BACKTRACK();
	if(remaining.subview_max_size(0, alias.size()) == alias.data()) {
		return /*valid*/1;
	} else if(remaining.subview_max_size(0, block.size()) == block.data()) {
		return /*valid*/1;
	} else if(remaining.subview_max_size(0, namespace_.size()) == namespace_.data()) {
		return /*valid*/1;
	} else if(remaining.subview_max_size(0, type.size()) == type.data()) {
		return /*valid*/1;
	} else if(auto func = function_type(module, remaining); func) {
		return func;
	} else if(auto ident = (BACKTRACK(), identifier(module, remaining)); ident.data()) {
		return /*valid*/1;
	} else RETURN_ERROR("Expected alias, block, namespace, type, function_type, or identifier!", LEXEME_HERE());
}

// Block <- '{'- assignment* '}'
// type_block <- 'type'- '{'- (identifier_type_pair Terminator-)* '}'wsc
// function_call <- ('inline'-/'tail'-)? Identifier- '('- (FunctionType- / Identifier- / Block-)* ')'wsc

// Terminator <- ';' / '\n' / '\n\r'
bool terminator(TrivialModule& module, fp::string_view& remaining)  {
	if(remaining.empty()) { PUSH_ERROR("Unexpected end of input!", LEXEME_HERE()); return false; }
	if(remaining[0] == ';') {
		remaining = remaining.subview(1);
		return true;
	}
	if(remaining.size() >= 2 && remaining[0] == '\n' && remaining[1] == '\r') {
		remaining = remaining.subview(2);
		return true;
	}
	if(remaining[0] == '\n') {
		remaining = remaining.subview(1);
		return true;
	}

	return false;
}
// Identifier <- !Keywords [%a-zA-Z_][a-zA-Z0-9_.]*
fp::string_view identifier(TrivialModule& module, fp::string_view& remaining) {
	constexpr std::array<std::string_view, 8> keywords{"alias", "block", "comptime", "deduced", "inline", "namespace", "tail", "type" };

	fp::string_view out = {nullptr, 0};
	fp::string_view keyword_view = remaining;

	if(remaining.empty()) { PUSH_ERROR("Unexpected end of input!", LEXEME_HERE()); return {nullptr, 0}; }
	if(std::isalpha(remaining[0]) || remaining[0] == '_' || remaining[0] == '%') {
		out = remaining.subview(0, 1);
		remaining = {remaining.subview(1)};
	} else return {nullptr, 0};

	for(auto keyword: keywords)
		if(keyword_view.subview_max_size(0, keyword.size()) == keyword.data())
			return {nullptr, 0};

	while(remaining.size())
		if(std::isalnum(remaining[0]) || remaining[0] == '_') {
			++out.raw().size;
			remaining = {remaining.subview(1)};
		} else break;

	// Ensure % is only followed by numbers
	if(out[0] == '%') {
		if(out.size() == 1)
			PUSH_ERROR("`%` must be followed by a number!", doir::lexeme::from_view(module, out));
		for(size_t i = 1; i < out.size(); ++i)
			if(!std::isdigit(out[i])) {
				PUSH_ERROR("Numeric identifier can't contain non-numbers!", doir::lexeme::from_view(module, out))
				return out;
			}
	}
	return out;
}

// Keywords <- 'alias' / 'block' / 'comptime' / 'deduced' / 'inline' / 'namespace' / 'tail' / 'type'
// SourceInfo <- '<' ((!':' .)* ':')? IntegerConstant ('-' IntegerConstant)? ':' IntegerConstant ('-' IntegerConstant)? '>'

// Constant <- FloatConstant / IntegerConstant / ('"' StringChar* '"') / ('\'' StringChar '\'')
ecs::entity_t constant(TrivialModule& module, fp::string_view& remaining) {
	if(remaining.empty()) RETURN_ERROR("Unexpected end of input!", LEXEME_HERE());

	SETUP_BACKTRACK();
	if(auto flt = float_constant(module, remaining); flt) {
		return flt;
	} else if(auto integer = (BACKTRACK(), integer_constant(module, remaining)); integer) {
		return integer;
	} else if(auto str = (BACKTRACK(), [&]() -> ecs::entity_t {
		if(remaining[0] != '"') return ecs::invalid_entity;
		remaining = remaining.subview(1);

		fp::string_view string = remaining; string.raw().size = 0;
		fp::string_view chr;
		while(chr = string_char(module, remaining), chr.data())
			string.raw().size += chr.size();

		if(remaining[0] != '"') return ecs::invalid_entity;
		remaining = remaining.subview(1);

		return /*valid*/1;
	}()); str) {
		return str;
	} else if(auto chr = (BACKTRACK(), [&]() -> ecs::entity_t {
		if(remaining[0] != '\'') return ecs::invalid_entity;
		remaining = remaining.subview(1);

		fp::string_view chr;
		if(chr = string_char(module, remaining), !chr.data()) return ecs::invalid_entity;

		if(remaining[0] != '\'') return ecs::invalid_entity;
		remaining = remaining.subview(1);

		return /*valid*/1;
	}()); chr) {
		return chr;
	} else RETURN_ERROR("Expected a number, string, or character!", LEXEME_HERE());
}
// IntegerConstant <- (([1-9][0-9]*) / ('0x' HexDigit+) / ('0b' [01]*) / ('0' [0-7]*))
ecs::entity_t integer_constant(TrivialModule& module, fp::string_view& remaining) {
	if(remaining.empty()) return ecs::invalid_entity;

	SETUP_BACKTRACK();
	if(auto integer = [&]() -> ecs::entity_t {
		auto integer = remaining; integer.raw().size = 0;
		if(!(remaining[0] >= '1' && remaining[0] <= '9')) return ecs::invalid_entity;
		remaining = remaining.subview(1);
		++integer.raw().size;

		while(remaining[0] >= '0' && remaining[0] <= '9') {
			remaining = remaining.subview(1);
			++integer.raw().size;
		}

		char* end;
		auto value = std::strtoll(integer.data(), &end, 10);
		if(end - integer.data() != integer.size()) return ecs::invalid_entity;

		return /*valid*/1;
	}(); integer) {
		return integer;
	} else if(auto hex = (BACKTRACK(), [&]() -> ecs::entity_t {
		if(remaining.subview_max_size(0, 2) != "0x") return ecs::invalid_entity;
		remaining = remaining.subview(2);

		auto integer = remaining; integer.raw().size = 0;
		fp::string_view hex;
		while(hex = hex_digit(module, remaining), hex.data())
			integer.raw().size += hex.size();
		if(integer.size() == 0) return ecs::invalid_entity;

		char* end;
		auto value = std::strtoll(integer.data(), &end, 16);
		if(end - integer.data() != integer.size()) return ecs::invalid_entity;

		return /*valid*/1;
	}()); hex) {
		return hex;
	} else if(auto binary = (BACKTRACK(), [&]() -> ecs::entity_t {
		if(remaining.subview_max_size(0, 2) != "0b") return ecs::invalid_entity;
		remaining = remaining.subview(2);

		auto integer = remaining; integer.raw().size = 0;
		while(remaining[0] == '0' || remaining[0] == '1') {
			remaining = remaining.subview(1);
			++integer.raw().size;
		}
		if(integer.size() == 0) return ecs::invalid_entity;

		char* end;
		auto value = std::strtoll(integer.data(), &end, 2);
		if(end - integer.data() != integer.size()) return ecs::invalid_entity;

		return /*valid*/1;
	}()); binary) {
		return binary;
	} else if(auto octal = (BACKTRACK(), [&]() -> ecs::entity_t {
		if(remaining[0] != '0') return ecs::invalid_entity;
		remaining = remaining.subview(1);

		auto integer = remaining; integer.raw().size = 0;
		while(remaining[0] >= '0' && remaining[0] <= '7') {
			remaining = remaining.subview(1);
			++integer.raw().size;
		}
		if(integer.size() == 0) return ecs::invalid_entity;

		char* end;
		auto value = std::strtoll(integer.data(), &end, 8);
		if(end - integer.data() != integer.size()) return ecs::invalid_entity;

		return /*valid*/1;
	}()); binary) {
		return octal;
	} return ecs::invalid_entity;
}
// FloatConstant <- (([0-9]* '.' [0-9]+ / [0-9]+ '.'?) ([eE][+\-]? [0-9]+)? )
// 	/ ('0x' (HexDigit* '.' HexDigit+ / HexDigit+ '.'?) ([pP][+\-]? [0-9]+)?)
// StringChar <- (!['"\n\\] .) / ('\\' ['\"?\\%abfnrtv]) / ('\\' [0-7]+) / ('\\x' HexDigit+) / ('\\u' HexDigit HexDigit HexDigit HexDigit)
// HexDigit <- [a-fA-F0-9]

// - <- ([ \n\r\t] / LongComment / LineComment)*
void _(TrivialModule& module, fp::string_view& remaining) {
	if(remaining.empty()) { PUSH_ERROR("Unexpected end of input!", LEXEME_HERE()); return; }

	bool eat_one = true;
	auto backtrack = remaining;
	while((eat_one = true, std::isspace(remaining[0])) || (eat_one = false, long_comment(module, remaining)) || (remaining = backtrack, line_comment(module, remaining))) {
		if(eat_one) remaining = {remaining.subview(1)};
		backtrack = remaining;
	}
}
// wsc <- ([ \t] / LongComment / LineComment)*
void wsc(TrivialModule& module, fp::string_view& remaining) {
	if(remaining.empty()) { PUSH_ERROR("Unexpected end of input!", LEXEME_HERE()); return; }

	bool eat_one = true;
	auto backtrack = remaining;
	while(
		(eat_one = true, std::isspace(remaining[0]) && remaining[0] != '\n' && remaining[0] != '\r')
		|| (eat_one = false, long_comment(module, remaining)) || (remaining = backtrack, line_comment(module, remaining))
	) {
		if(eat_one) remaining = {remaining.subview(1)};
		backtrack = remaining;
	}
}
// LongComment <- '/*' (!'*/'.)* '*/'
bool long_comment(TrivialModule& module, fp::string_view& remaining) {
	if(remaining.empty()) { PUSH_ERROR("Unexpected end of input!", LEXEME_HERE()); return false; }
	if(remaining.subview_max_size(0, 2) != "/*") return false;
	while(remaining.subview_max_size(0, 2) != "*/") {
		remaining = {remaining.subview(1)};
		if(remaining.size() <= 2) return false;
	}
	return true;
}
// LineComment <- '//' (!'\n' .)*
bool line_comment(TrivialModule& module, fp::string_view& remaining) {
	if(remaining.empty()) { PUSH_ERROR("Unexpected end of input!", LEXEME_HERE()); return false; }
	if(remaining.subview_max_size(0, 2) != "//") return false;
	while(remaining[0] != '\n') {
		remaining = {remaining.subview(1)};
		if(remaining.size() <= 1) return false;
	}
	return true;
}

std::pair<TrivialModule, ecs::entity_t> parse(const fp_string str) {
	TrivialModule module; module.buffer = fp::string{str};
	TrivialModule::set_current_module(module);
	fp::string_view view = module.buffer.to_view();

	auto root = program(module, view);
	if(module.has_component<doir::diagnostics::error_queue>(root))
		for(auto e: module.get_component<doir::diagnostics::error_queue>(root))
			if(module.has_component<doir::diagnostics::error>(e))
				nowide::cerr << doir::diagnostics::generate(module, e) << std::endl;
	return {module, root};
}
std::pair<TrivialModule, ecs::entity_t> parse_view(const fp_string_view str) { return parse(fp_string_view_make_dynamic(str)); }


int main() {
	auto [module, root] = parse("%0 : i32 = 5;");
	std::cout << root << std::endl;
}