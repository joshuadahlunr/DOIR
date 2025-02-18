#include "lox.hpp"

#include <nowide/iostream.hpp>

namespace doir::Lox {
    void dump(TrivialModule& module, ecs::entity_t root, size_t depth /* = 0 */) {
		std::string indent(depth, '\t');
		auto end = [&](std::ostream& s) {
			if(module.has_component<doir::comp::children>(root)) {
				auto children = module.get_component<doir::comp::children>(root);
				s << " (" << root << " ↓" << children.total << ")" << std::endl;
			} else s << " (" << root << ")" << std::endl;
		};
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
		} else if(module.has_component<Module::HashtableComponent<variable_declaire>>(root)) {
			auto& var = get_key(module.get_component<Module::HashtableComponent<variable_declaire>>(root));
			end(nowide::cout << indent << "declaire:var:" << fp_string_view_to_std(var.name.view(module.buffer)));
		} else if(module.has_component<Module::HashtableComponent<parameter_declaire>>(root)) {
			auto& param = get_key(module.get_component<Module::HashtableComponent<parameter_declaire>>(root));
			end(nowide::cout << indent << "declaire:param:" << fp_string_view_to_std(param.name.view(module.buffer)));
		} else if(module.has_component<Module::HashtableComponent<function_declaire>>(root)) {
			auto& decl = get_key(module.get_component<Module::HashtableComponent<function_declaire>>(root));
			auto* params = module.has_component<parameters>(root) ? &module.get_component<parameters>(root) : nullptr;
			auto& block = module.get_component<struct block>(root);
			end(nowide::cout << indent << "declaire:fun:" << fp_string_view_to_std(decl.name.view(module.buffer)));
			if(params) for(auto param: params->params.iterate(module))
				dump(module, param, depth + 1);
			nowide::cout << indent << "{" << "\n";
			for(auto e: block.children.iterate(module))
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
			for(auto e: call.children.iterate(module))
				dump(module, e, depth + 1);
		} else if(module.has_component<block>(root)){
			auto& block = module.get_component<struct block>(root);
			end(nowide::cout << indent << "{");
			for(auto e: block.children.iterate(module))
				dump(module, e, depth + 1);
			nowide::cout << indent << "}" << std::endl;
		} else
			end(nowide::cout << "<Unknown Component>");
	}
}