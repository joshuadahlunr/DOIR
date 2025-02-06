#include "lox.hpp"

#include <ostream>
#include <reflex/input.h>
#include <nowide/iostream.hpp>

#include "../components.hpp"
#include "fp/dynarray.hpp"

namespace doir::Lox {

	fp_string comparison_buffer = nullptr;

	inline namespace components {
		struct null {};
		struct variable { ecs::entity_t ref = doir::ecs::invalid_entity; };
		struct string {};
		struct literal {};

		struct block {
			ecs::entity_t parent; fp::dynarray<ecs::entity_t> children = nullptr;
			static void swap_entities(block& b, ecs::entity_t eA, ecs::entity_t eB) {
				if(b.parent == eA) b.parent = eB;
				else if(b.parent == eB) b.parent = eA;

				for(auto& child: b.children)
					if(child == eA) child = eB;
					else if(child == eB) child = eA;
			}
		};
		struct call: public block {}; // parent -> object being called on, children -> arguments
		// using call = block; // TODO: How bad of an idea is it for calls to reuse block's storage?
		struct trailing_call {};

		struct declaire {
			doir::lexeme name;
			ecs::entity_t parent; // Parent block
			bool operator==(const declaire& o) const {
				return parent == o.parent && fp_string_view_equal(name.view(comparison_buffer), o.name.view(comparison_buffer));
			}
			static void swap_entities(declaire& decl, ecs::entity_t eA, ecs::entity_t eB) {
				if(decl.parent == eA) decl.parent = eB;
				else if(decl.parent == eB) decl.parent = eA;
			}
		};
		struct variable_declaire : public declaire {};
		struct function_declaire : public declaire {};
		struct parameter_declaire : public declaire {};
		struct parameters {
			fp::dynarray<ecs::entity_t> parameters;
			static void swap_entities(struct parameters& params, ecs::entity_t eA, ecs::entity_t eB) {
				for(auto& param: params.parameters)
					if(param == eA) param = eB;
					else if(param == eB) param = eA;
			}
		};
		// struct BodyMarker {
		// 	ecs::entity_t skipTo;
		// 	static void swap_entities(BodyMarker& mark, ecs::entity eA, ecs::entity eB) {
		// 		if(mark.skipTo == eA) mark.skipTo = eB;
		// 		else if(mark.skipTo == eB) mark.skipTo = eA;
		// 	}
		// };

		struct operation { // Condition, Then, Else, Marker
			ecs::entity_t a = 0, b = 0, c = 0, d = 0;
			std::pair<ecs::entity_t&, ecs::entity_t&> pair() { return {a, b}; }
			std::array<ecs::entity_t, 4> array() { return std::array<ecs::entity_t, 4>{a, b, c, d}; }
			static void swap_entities(operation& op, ecs::entity_t eA, ecs::entity_t eB) {
				for(auto& child: op.array())
					if(child == eA) child = eB;
					else if(child == eB) child = eA;
			}
		};

		struct not_ {};
		struct negate {};
		struct divide {};
		struct multiply {};
		struct add {};
		struct subtract {};
		struct less_than {};
		struct greater_than {};
		struct less_than_equal_to {};
		struct greater_than_equal_to {};
		struct equal_to {};
		struct not_equal_to {};
		struct and_ {};
		struct or_ {};
		struct assign {};
		struct print {};
		struct return_ {};
		struct while_ {};
		struct if_ {};
	}
	namespace comp = component;
	
	// #define YY_DEBUG
	#define YYSTYPE ecs::entity_t
	#define YY_CTX_LOCAL
	#define YY_CTX_MEMBERS fp_string_view source;\
		TrivialModule* module;\
		fp::dynarray<ecs::entity_t> blocks = nullptr;\
		fp::dynarray<ecs::entity_t> objects = nullptr;
	#define YY_INPUT(yy, buf, result, max_size) {\
		result = std::min<size_t>(fp_view_size(yy->source), max_size);\
		if(result > 0)\
			memcpy(buf, fp_view_data(char, yy->source), result);\
		yy->source = fp_view_subview(char, yy->source, result, fp_view_size(yy->source) - result);\
	}

	#define CURRENT_BLOCK() yy->module->get_component<block>(yy->blocks.back())
	#define APPEND_TO_CURRENT_BLOCK(v) CURRENT_BLOCK().children.push_back(v)
	#define DEFAULT_LEXEME(_entity) (yy->module->add_component<lexeme>(_entity) = lexeme::from_module_and_view(*yy->module, fp_string_view_literal(yytext, static_cast<size_t>(yyleng))))
	#define MERGE_BINARY_OPS(_leftmost, _start, _tail, _res) if(!_tail) _res = _leftmost;\
		else {\
			auto left = _res = yy->objects.pop_back(), right = left;\
			while(yy->objects.size() > _start) {\
				right = std::exchange(left, yy->objects.pop_back());\
				auto& op = yy->module->get_component<operation>(right);\
				op.b = std::exchange(op.a, left);\
				yy->module->get_component<lexeme>(right) = yy->module->get_component<lexeme>(left) + yy->module->get_component<lexeme>(right);\
			}\
			auto& op = yy->module->get_component<operation>(left);\
			op.b = std::exchange(op.a, _leftmost);\
			yy->module->get_component<lexeme>(left) = yy->module->get_component<lexeme>(_leftmost) + yy->module->get_component<lexeme>(left);\
		}

	#include "gen/peg-parser.h"

	std::pair<TrivialModule, ecs::entity_t> parse_view(const fp_string_view view) {
		DOIR_ZONE_SCOPED_AGRO;

		yycontext ctx;
		memset(&ctx, 0, sizeof(yycontext));
		ctx.source = view;
		TrivialModule out;
		ctx.module = &out;
		fp_string_view_concatenate_inplace(out.buffer, view);
		ctx.blocks.push_back(ctx.module->create_entity());
		ctx.module->add_component<block>(ctx.blocks.back()) = {0, nullptr};
		
		yyparse(&ctx);
		// std::cout << "parsed!" << std::endl;
		auto pair = std::pair<TrivialModule, ecs::entity_t>{out, ctx.blocks.empty() ? 0 : ctx.blocks.back()};
		if(ctx.objects) ctx.objects.free_and_null();
		if(ctx.blocks) ctx.blocks.free_and_null();
		return pair;
	}

	std::pair<TrivialModule, ecs::entity_t> parse(const fp_string string) {
		DOIR_ZONE_SCOPED_AGRO;
		return parse_view(fp_string_to_view_const(string));
	}

	void dump(TrivialModule& module, ecs::entity_t root, size_t depth /* = 0 */) {
		std::string indent(depth, '\t');
		auto end = [&](std::ostream& s) { s << " (" << root << ")" << std::endl; };
		if(module.has_component<literal>(root)) {
			if(module.has_component<bool>(root))
				end(nowide::cout << indent << (module.get_component<bool>(root) ? "true" : "false"));
			else if(module.has_component<string>(root)) {
				auto lexeme = module.get_component<doir::comp::lexeme>(root).view(module.buffer);
				end(nowide::cout << indent << fp_string_view_to_std(lexeme));
			} else if(module.has_component<double>(root))
				end(nowide::cout << indent << module.get_component<double>(root));
			else end(nowide::cout << indent << "null");
		} else if(module.has_component<variable>(root)) {
			auto ref = module.get_component<variable>(root).ref;
			auto lexeme = module.get_component<doir::comp::lexeme>(root).view(module.buffer);
			end(nowide::cout << indent << "var:" << fp_string_view_to_std(lexeme) << " -> " << ref);
		} else if(module.has_component<not_>(root)) {
			auto& op = module.get_component<operation>(root);
			end(nowide::cout << indent << "! [not]");
			dump(module, op.a, depth + 1);
		} else if(module.has_component<negate>(root)) {
			auto& op = module.get_component<operation>(root);
			end(nowide::cout << indent << "- [negate]");
			dump(module, op.a, depth + 1);
		} else if(module.has_component<add>(root)) {
			auto& op = module.get_component<operation>(root);
			end(nowide::cout << indent << "+ [add]");
			dump(module, op.a, depth + 1);
			dump(module, op.b, depth + 1);
		} else if(module.has_component<subtract>(root)) {
			auto& op = module.get_component<operation>(root);
			end(nowide::cout << indent << "- [subtract]");
			dump(module, op.a, depth + 1);
			dump(module, op.b, depth + 1);
		} else if(module.has_component<multiply>(root)) {
			auto& op = module.get_component<operation>(root);
			end(nowide::cout << indent << "* [multiply]");
			dump(module, op.a, depth + 1);
			dump(module, op.b, depth + 1);
		} else if(module.has_component<divide>(root)) {
			auto& op = module.get_component<operation>(root);
			end(nowide::cout << indent << "/ [divide]");
			dump(module, op.a, depth + 1);
			dump(module, op.b, depth + 1);
		} else if(module.has_component<or_>(root)) {
			auto& op = module.get_component<operation>(root);
			end(nowide::cout << indent << "or");
			dump(module, op.a, depth + 1);
			dump(module, op.b, depth + 1);
		} else if(module.has_component<and_>(root)) {
			auto& op = module.get_component<operation>(root);
			end(nowide::cout << indent << "and");
			dump(module, op.a, depth + 1);
			dump(module, op.b, depth + 1);
		} else if(module.has_component<equal_to>(root)) {
			auto& op = module.get_component<operation>(root);
			end(nowide::cout << indent << "== [equal]");
			dump(module, op.a, depth + 1);
			dump(module, op.b, depth + 1);
		} else if(module.has_component<not_equal_to>(root)) {
			auto& op = module.get_component<operation>(root);
			end(nowide::cout << indent << "!= [not equal]");
			dump(module, op.a, depth + 1);
			dump(module, op.b, depth + 1);
		} else if(module.has_component<greater_than>(root)) {
			auto& op = module.get_component<operation>(root);
			end(nowide::cout << indent << "> [greater]");
			dump(module, op.a, depth + 1);
			dump(module, op.b, depth + 1);
		} else if(module.has_component<less_than>(root)) {
			auto& op = module.get_component<operation>(root);
			end(nowide::cout << indent << "< [less]");
			dump(module, op.a, depth + 1);
			dump(module, op.b, depth + 1);
		} else if(module.has_component<greater_than_equal_to>(root)) {
			auto& op = module.get_component<operation>(root);
			end(nowide::cout << indent << ">= [greater equal]");
			dump(module, op.a, depth + 1);
			dump(module, op.b, depth + 1);
		} else if(module.has_component<less_than_equal_to>(root)) {
			auto& op = module.get_component<operation>(root);
			end(nowide::cout << indent << "<= [less equal]");
			dump(module, op.a, depth + 1);
			dump(module, op.b, depth + 1);
		} else if(module.has_component<print>(root)) {
			auto& op = module.get_component<operation>(root);
			end(nowide::cout << indent << "print");
			dump(module, op.a, depth + 1);
		} else if(module.has_component<return_>(root)) {
			auto* op = module.has_component<operation>(root) ? &module.get_component<operation>(root) : nullptr;
			end(nowide::cout << indent << "return");
			if(op) dump(module, op->a, depth + 1);
		} else if(module.has_component<while_>(root)) {
			auto& op = module.get_component<operation>(root);
			end(nowide::cout << indent << "while:condition:");
			dump(module, op.a, depth + 1);
			nowide::cout << indent << "while:then:" << "\n";
			dump(module, op.b, depth + 1);
		} else if(module.has_component<if_>(root)) {
			auto& op = module.get_component<operation>(root);
			end(nowide::cout << indent << "if:condition:");
			dump(module, op.a, depth + 1);
			nowide::cout << indent << "if:then:" << "\n";
			dump(module, op.b, depth + 1);
			if(op.c){
				nowide::cout << indent << "if:else:" << "\n";
				dump(module, op.c, depth + 1);
			}
		} else if(module.has_component<variable_declaire>(root)) {
			auto& var = module.get_component<variable_declaire>(root);
			end(nowide::cout << indent << "declaire:var:" << fp_string_view_to_std(var.name.view(module.buffer)));
		} else if(module.has_component<parameter_declaire>(root)) {
			auto& param = module.get_component<parameter_declaire>(root);
			end(nowide::cout << indent << "declaire:param:" << fp_string_view_to_std(param.name.view(module.buffer)));
		} else if(module.has_component<function_declaire>(root)) {
			auto& decl = module.get_component<function_declaire>(root);
			auto* params = module.has_component<parameters>(root) ? &module.get_component<parameters>(root) : nullptr;
			auto& block = module.get_component<struct block>(root);
			end(nowide::cout << indent << "declaire:fun:" << fp_string_view_to_std(decl.name.view(module.buffer)));
			if(params) for(auto& param: params->parameters)
				dump(module, param, depth + 1);
			nowide::cout << indent << "{" << "\n";
			for(auto& e: block.children)
				dump(module, e, depth + 1);
			nowide::cout << indent << "}" << std::endl;
		} else if(module.has_component<assign>(root)){
			auto& op = module.get_component<operation>(root);
			end(nowide::cout << indent << "assign:" << op.a << " =");
			dump(module, op.b, depth + 1);
		} else if(module.has_component<call>(root)){
			auto& call = module.get_component<struct call>(root);
			end(nowide::cout << indent << "call:");
			dump(module, call.parent, depth + 1);
			nowide::cout << indent << "call:args:" << "\n";
			for(auto& e: call.children)
				dump(module, e, depth + 1);
		} else if(module.has_component<block>(root)){
			auto& block = module.get_component<struct block>(root);
			end(nowide::cout << indent << "{");
			for(auto& e: block.children)
				dump(module, e, depth + 1);
			nowide::cout << indent << "}" << std::endl;
		}
	}
}