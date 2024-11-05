#include "calculator.hpp"
#include <algorithm>
#include <functional>
#include <string_view>

#include <reflex/input.h>
#include <nowide/iostream.hpp>
#include <cmath>

#include "../components.hpp"
#include "../module.hpp"

namespace doir::Calculator {

	inline namespace component {
		struct variable_definition {
			static TrivialModule* comparison_module;
			lexeme name;
			float value;

			bool operator==(const variable_definition& o) const {
				return fp_string_view_compare(name.view(comparison_module->buffer), o.name.view(comparison_module->buffer)) == 0;
			}
		};
		TrivialModule* variable_definition::comparison_module = nullptr;
		using variable_definition_hash = ecs::hashtable::Storage<variable_definition>::component_type;

		struct variable_access {
			entity_reference variable;
		};
		struct constant {
			float value;
		};

		struct operation {
			ecs::entity_t left, right;
		};
		struct add {};
		struct subtract {};
		struct multiply {};
		struct divide {};
		struct power {};
		struct assignment {};
	}
	namespace comp = component;

	static size_t location = 0;
	TrivialModule* module;
	ecs::entity_t moduleRoot;

	#include "gen/parser.h"
}

#include "gen/scanner.h"

namespace doir::Calculator {

	inline int yylex(reflex::Input* input /* = nullptr */) {
		static Lexer lexer;
		if(input) { lexer = Lexer(*input); return true; }
		else return lexer.lex();
	}

	inline void set_input(reflex::Input& input) {
		yylex(&input);
	}
	inline void set_input(reflex::Input&& input) {
		yylex(&input);
	}

	TrivialModule parse_view(const fp_string_view view, TrivialModule* existing /*= nullptr*/) {
		DOIR_ZONE_SCOPED_AGRO;
		set_input(reflex::Input(fp_view_data(char, view), fp_view_size(view)));

		TrivialModule out = existing ? std::move(*existing) : TrivialModule{};
		module = &out;
		moduleRoot = existing ? 1 : out.create_entity();
		if(!existing) out.add_component<comp::expressions>(moduleRoot);

		location = fp_string_length(out.buffer);
		fp_string_view_concatenate_inplace(out.buffer, view);
		yyparse();
		return out;
	}

	TrivialModule parse(const fp_string string, TrivialModule* existing /*= nullptr*/) {
		DOIR_ZONE_SCOPED_AGRO;
		return parse_view(fp_string_to_view_const(string), existing);
	}


	void print(TrivialModule& module, ecs::entity_t root, size_t depth /* = 0 */) {
		#define PRINT_ENDER " (" << root << ")" << std::endl
		nowide::cout << std::string(depth, '\t');
		if(module.has_component<comp::constant>(root))
			nowide::cout << "const:" << module.get_component<comp::constant>(root).value << PRINT_ENDER;
		else if(module.has_component<comp::variable_access>(root)) {
			auto& var = module.get_component<comp::variable_access>(root).variable;
			nowide::cout << "var:" << fp_string_view_to_std(var.lexeme.view(module.buffer));
			if(var.entity != doir::ecs::invalid_entity)
				nowide::cout << " -> " << var.entity;
			nowide::cout << PRINT_ENDER;
		} else if(module.has_component<comp::add>(root)) {
			auto& op = module.get_component<comp::operation>(root);
			nowide::cout << "+" << PRINT_ENDER;
			print(module, op.left, depth + 1);
			print(module, op.right, depth + 1);
		} else if(module.has_component<comp::subtract>(root)) {
			auto& op = module.get_component<comp::operation>(root);
			nowide::cout << "-" << PRINT_ENDER;
			print(module, op.left, depth + 1);
			print(module, op.right, depth + 1);
		} else if(module.has_component<comp::multiply>(root)) {
			auto& op = module.get_component<comp::operation>(root);
			nowide::cout << "*" << PRINT_ENDER;
			print(module, op.left, depth + 1);
			print(module, op.right, depth + 1);
		} else if(module.has_component<comp::divide>(root)) {
			auto& op = module.get_component<comp::operation>(root);
			nowide::cout << "/" << PRINT_ENDER;
			print(module, op.left, depth + 1);
			print(module, op.right, depth + 1);
		} else if(module.has_component<comp::power>(root)) {
			auto& op = module.get_component<comp::operation>(root);
			nowide::cout << "^" << PRINT_ENDER;
			print(module, op.left, depth + 1);
			print(module, op.right, depth + 1);
		} else if(module.has_component<comp::assignment>(root)) {
			auto& op = module.get_component<comp::operation>(root);
			auto& var = get_key(module.get_component<comp::variable_definition_hash>(op.left));
			nowide::cout << op.left << " (" << fp_string_view_to_std(var.name.view(module.buffer))
				<< ")" << " assign" << PRINT_ENDER;
			print(module, op.right, depth + 1);
		} else if(module.has_component<comp::variable_definition_hash>(root)) {
			auto& var = get_key(module.get_component<comp::variable_definition_hash>(root));
			nowide::cout << "define:" << fp_string_view_to_std(var.name.view(module.buffer)) << PRINT_ENDER;
		} else if(module.has_component<comp::expressions>(root)) {
			auto& exprs = module.get_component<comp::expressions>(root).expr;
			nowide::cout << "{" << PRINT_ENDER;
			fp_iterate_named(exprs, e)
				print(module, *e, depth + 1);
			nowide::cout << "}" << std::endl;
		}
		#undef PRINT_ENDER
	}


	void lookup_variables(TrivialModule& module, ecs::entity_t root) {
		variable_definition::comparison_module = &module;
		auto& lookup = module.get_hashtable_storage_rehashed<variable_definition>();
		auto& expr = module.get_component<comp::expressions>(1);

		auto i = std::min_element(expr.expr, expr.expr + fp_size(expr.expr), [root](ecs::entity_t a, ecs::entity_t b) {
			return abs(int64_t(root) - int64_t(a)) < abs(int64_t(root) - int64_t(b));
		});
		size_t e = 0;
		if(i != expr.expr) e = *(--i) + 1;

		for(size_t size = module.entity_count(); e < size; ++e) {
			if(!module.has_component<comp::variable_access>(e)) continue;

			auto& access = module.get_component<comp::variable_access>(e);
			auto name = module.get_component<doir::comp::lexeme>(e);

			auto res = lookup.find({name, 0});
			if(!res) {
				nowide::cerr << "Failed to lookup variable: " << fp_string_view_to_std(name.view(module.buffer)) << std::endl;
				exit(1);
			}
			access.variable.entity = *res;
		}
	}

	float _calculate(TrivialModule& module, ecs::entity_t root) {
		if(module.has_component<comp::constant>(root))
			return module.get_component<comp::constant>(root).value;
		else if(module.has_component<comp::variable_access>(root)) {
			auto e = module.get_component<comp::variable_access>(root).variable.entity;
			return get_key(module.get_component<comp::variable_definition_hash>(e)).value;
		} else if(module.has_component<comp::add>(root)) {
			auto& op = module.get_component<comp::operation>(root);
			return _calculate(module, op.left) + _calculate(module, op.right);
		} else if(module.has_component<comp::subtract>(root)) {
			auto& op = module.get_component<comp::operation>(root);
			return _calculate(module, op.left) - _calculate(module, op.right);
		} else if(module.has_component<comp::multiply>(root)) {
			auto& op = module.get_component<comp::operation>(root);
			return _calculate(module, op.left) * _calculate(module, op.right);
		} else if(module.has_component<comp::divide>(root)) {
			auto& op = module.get_component<comp::operation>(root);
			return _calculate(module, op.left) / _calculate(module, op.right);
		} else if(module.has_component<comp::power>(root)) {
			auto& op = module.get_component<comp::operation>(root);
			return std::pow(_calculate(module, op.left), _calculate(module, op.right));
		} else if(module.has_component<comp::assignment>(root)) {
			auto& op = module.get_component<comp::operation>(root);
			auto& def = get_key(module.get_component<comp::variable_definition_hash>(op.left));
			return def.value = _calculate(module, op.right);
		} else if(module.has_component<comp::expressions>(root)) {
			auto& exprs = module.get_component<comp::expressions>(root).expr;
			int64_t size = fp_size(exprs);
			for(size_t i = 0; i < size - 1; ++i)
				_calculate(module, exprs[i]);
			return _calculate(module, exprs[size - 1]);
		} else return std::nan("");
	}

	float calculate(TrivialModule& module, ecs::entity_t root) {
		lookup_variables(module, root);
		return _calculate(module, root);
	}
}

namespace std {
	template<>
	struct hash<doir::Calculator::variable_definition> {
		size_t operator()(const doir::Calculator::variable_definition& def) {
			return std::hash<size_t>{}(def.name.start) ^ std::hash<size_t>{}(def.name.length);
		}
	};
}