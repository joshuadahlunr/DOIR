// Parse DOIR sources against doir.peg and report syntax errors plus the rules
// that need a tree walk: WF-Term (terminators), WF-Order (a binding read before it is
// bound), D-Return (a `_` destination receiving a `_` return), B-Tail (a tail call ends its block), L-Scan (tower calls at level scope), and I-Language (no frontend
// is registered, so every `language` block is an error). WF-Arg is enforced by the grammar
// itself: `function_call` accepts only `Identifier _` arguments.
//
// Vendored single-header dependency (MIT), cpp-peglib 1.21:
//   curl -sSL -o tools/peglib.h https://raw.githubusercontent.com/yhirose/cpp-peglib/master/peglib.h
// Build and run:
//   g++ -O2 -std=c++17 tools/doir_check.cpp -o doir_check
//   ./doir_check [-a] [-g doir.peg] file.doir... [-p program.doir...]
// Files after -p are programs, whose root must also end with a terminator (L-Entry).

#include "peglib.h"

#include <fstream>
#include <iostream>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <vector>

namespace {

// doir.peg is a D raw string literal; '#' starts a comment inside it.
// Capture markers are dropped so peglib builds a tree instead of token nodes.
std::string load_grammar(const std::string &path) {
	std::ifstream in(path);
	std::string s((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
	auto open = s.find("R\"~(");
	if (open != std::string::npos) {
		s = s.substr(open + 4);
		auto close = s.rfind(")~\"");
		if (close != std::string::npos) s = s.substr(0, close);
	}
	std::string out;
	std::istringstream lines(s);
	for (std::string line; std::getline(lines, line);) {
		char quote = 0;
		bool in_class = false;
		bool named_capture = line.find('$') != std::string::npos;
		for (size_t i = 0; i < line.size(); ++i) {
			char c = line[i];
			if (quote || in_class) {
				out += c;
				if (quote && c == '\\') out += line[++i];
				else if (quote && c == quote) quote = 0;
				else if (in_class && c == ']') in_class = false;
			} else if (c == '#') {
				break;
			} else if (c == '\'' || c == '"') {
				quote = c;
				out += c;
			} else if (c == '[') {
				in_class = true;
				out += c;
			} else if (c == '<' && i + 1 < line.size() && line[i + 1] == '-') {
				out += "<-";
				++i;
			} else if ((c == '<' || c == '>') && !named_capture) {
				continue;
			} else {
				out += c;
			}
		}
		out += "\n";
	}
	return out;
}

std::string read_file(const std::string &path) {
	std::ifstream in(path);
	return std::string((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
}

std::string line_of(const std::string &src, size_t line) {
	std::istringstream lines(src);
	std::string s;
	for (size_t i = 0; i < line && std::getline(lines, s); ++i) {
	}
	return s;
}

std::string text_of(const std::string &src, const peg::Ast &node) {
	return src.substr(node.position, node.length);
}

const std::set<std::string> scanned_calls = {"compiler.levels.make", "compiler.levels.this_file", "compiler.levels.lower_to", "compiler.levels.run_schedule"};

const std::set<std::string> terminators = {"std.return", "std.block_result", "std.halt", "return", "block_result", "halt"};

bool is_tail_call(const std::string &call) {
	return call.rfind("tail", 0) == 0 && call.size() > 4 && (call[4] == ' ' || call[4] == '\t');
}

// A tail call returns its callee's result, so it ends a block like std.return (B-Tail).
bool is_terminator_call(const std::string &call) {
	if (is_tail_call(call)) return true;
	auto paren = call.find('(');
	return terminators.count(paren == std::string::npos ? call : call.substr(0, paren)) > 0;
}

bool block_ends_with_terminator(const peg::Ast &block, const std::string &src) {
	const peg::Ast *last = nullptr;
	for (auto &child : block.nodes) {
		if (child->name == "assignment") last = child.get();
	}
	if (!last) return false;
	for (auto &child : last->nodes) {
		if (child->name != "assignment_value") continue;
		for (auto &inner : child->nodes) {
			if (inner->name == "function_call" && is_terminator_call(text_of(src, *inner)))
				return true;
		}
	}
	return false;
}

std::string callee_of(const peg::Ast &call, const std::string &src) {
	for (auto &child : call.nodes) {
		if (child->name == "Identifier") return text_of(src, *child);
	}
	return "";
}

// The name a type position resolves to: an identifier, or `function` for a function type.
std::string type_name_of(const peg::Ast &type_node, const std::string &src) {
	for (auto &child : type_node.nodes) {
		if (child->name == "Identifier") return text_of(src, *child);
		if (child->name == "FunctionType") return "function";
	}
	return "";
}

const peg::Ast *function_type_of(const peg::Ast &node, const std::string &src) {
	for (auto &child : node.nodes) {
		if (child->name == "FunctionType") return child.get();
		if (child->name == "Type" || child->name == "assignment_value") {
			if (auto found = function_type_of(*child, src)) return found;
		}
	}
	return nullptr;
}

// D-Return: `_` in the return position is a leading deduced parameter that no argument
// binds, so only the destination at the call site can solve it (D-Deduce).
bool return_is_deduced(const peg::Ast &ft, const std::string &src) {
	for (auto &child : ft.nodes) {
		if (child->name != "Type") continue;
		for (auto &inner : child->nodes)
			if (inner->name == "Identifier" && text_of(src, *inner) == "_") return true;
	}
	return false;
}

// Qualified name -> declared function type, used to resolve D-Return at call sites.
using Signatures = std::map<std::string, const peg::Ast *>;

// A declaration typed by a named function type (`add : add_t`), resolved once every type is known.
struct NamedSignature {
	std::string prefix, name, type_name;
};

// The name, `Type` node, and `assignment_value` node of an assignment; absent parts are empty or null.
struct AssignmentParts {
	std::string name;
	const peg::Ast *type_node = nullptr;
	const peg::Ast *value = nullptr;
};

AssignmentParts assignment_parts(const peg::Ast &assignment, const std::string &src) {
	AssignmentParts parts;
	for (auto &part : assignment.nodes) {
		if (part->name == "Identifier" && parts.name.empty()) parts.name = text_of(src, *part);
		if (part->name == "Type") parts.type_node = part.get();
		if (part->name == "assignment_value") parts.value = part.get();
	}
	return parts;
}

// R-Unqual, approximated over namespace prefixes: try `name` in each enclosing namespace, innermost first.
Signatures::const_iterator resolve(const Signatures &sigs, const std::string &name, std::string prefix) {
	while (true) {
		auto it = sigs.find(prefix + name);
		if (it != sigs.end() || prefix.empty()) return it;
		auto dot = prefix.rfind('.', prefix.size() - 2);
		prefix = dot == std::string::npos ? "" : prefix.substr(0, dot + 1);
	}
}

void collect_signatures(const peg::Ast &block, const std::string &src, const std::string &prefix,
	Signatures &sigs, std::vector<NamedSignature> &named) {
	for (auto &child : block.nodes) {
		if (child->name != "assignment") continue;
		auto [name, type_node, value] = assignment_parts(*child, src);
		if (name.empty() || name == "_") continue;
		std::string type_name = type_node ? type_name_of(*type_node, src) : "";
		if (type_name == "namespace" && value) {
			for (auto &part : value->nodes)
				if (part->name == "Block") collect_signatures(*part, src, prefix + name + ".", sigs, named);
			continue;
		}
		if (auto ft = function_type_of(*child, src)) sigs[prefix + name] = ft;
		else if (!type_name.empty()) named.push_back({prefix, name, type_name});
	}
}

void resolve_named_signatures(Signatures &sigs, const std::vector<NamedSignature> &named) {
	for (auto &n : named) {
		auto it = resolve(sigs, n.type_name, n.prefix);
		if (it != sigs.end()) sigs[n.prefix + n.name] = it->second;
	}
}

// A name bound to a value (not a function, type, or namespace) cannot be read before
// its declaration line: SSA binds it once, and C-Order runs effects lexically.
struct Decl {
	std::string name;
	std::string type_name;
	const peg::Ast *value;
	bool is_value;
	bool is_function;
	size_t line;
};

// Every binding identifier a value reads: callees and plain arguments.
void collect_reads(const peg::Ast &node, const std::string &src, std::vector<std::string> &reads);

// The argument nodes of a call: every `Identifier` child but the callee. WF-Arg makes
// identifiers the only argument form, so arguments are direct children of the call.
std::vector<const peg::Ast *> call_arguments(const peg::Ast &call) {
	std::vector<const peg::Ast *> args;
	bool callee = false;
	for (auto &child : call.nodes)
		if (child->name == "Identifier") {
			if (callee) args.push_back(child.get());
			else callee = true;
		}
	return args;
}

void collect_reads_of(const peg::Ast &child, const std::string &src, std::vector<std::string> &reads) {
	if (child.name == "function_call") {
		std::string callee = callee_of(child, src);
		if (!callee.empty() && callee != "_") reads.push_back(callee);
		for (auto *arg : call_arguments(child)) collect_reads_of(*arg, src, reads);
	} else if (child.name == "Identifier") {
		std::string name = text_of(src, child);
		if (name != "_") reads.push_back(name);
	} else if (child.name == "parameter") {
		// A parameter's name declares; only its type and default read (R-Param).
		for (size_t k = 1; k < child.nodes.size(); ++k) collect_reads_of(*child.nodes[k], src, reads);
	} else if (child.name != "Block") {
		collect_reads(child, src, reads);
	}
}

void collect_reads(const peg::Ast &node, const std::string &src, std::vector<std::string> &reads) {
	for (auto &child : node.nodes) collect_reads_of(*child, src, reads);
}

// Names a value passes as a call argument: where a block binding is executed.
void collect_arg_names(const peg::Ast &node, const std::string &src, std::vector<std::string> &names) {
	for (auto &child : node.nodes) {
		if (child->name == "function_call") {
			for (auto *arg : call_arguments(*child)) {
				if (arg->name != "Identifier") continue;
				std::string name = text_of(src, *arg);
				if (name != "_") names.push_back(name);
			}
		} else if (child->name == "Identifier") {
			std::string name = text_of(src, *child);
			if (name != "_") names.push_back(name);
		} else if (child->name != "Block") {
			collect_arg_names(*child, src, names);
		}
	}
}

// `outer` is the enclosing block's name -> (declaration index, line, is a value), and
// `in_function` says whether a function body encloses the block, `level_scope` whether it is a file root or namespace (L-Freeze). `deadline` the index at which this block is spliced into the enclosing one. A spliced block
// cannot read a value the enclosing block binds after that point. `prefix` names the enclosing namespace.
void check_block(const peg::Ast &block, const std::string &src, bool executed, bool ordered,
	const std::map<std::string, std::tuple<size_t, size_t, bool>> &outer, size_t deadline,
	const std::string &prefix, const Signatures &sigs, std::vector<std::string> &errors, bool in_function = false, bool level_scope = true) {
	std::vector<Decl> decls;
	std::map<std::string, size_t> index;
	for (auto &child : block.nodes) {
		if (child->name != "assignment") continue;
		auto [name, type_node, value] = assignment_parts(*child, src);
		if (name.empty() || !type_node || !value) continue;
		std::string type_name = type_name_of(*type_node, src);
		bool body_block = false;
		for (auto &part : value->nodes)
			if (part->name == "Block") body_block = true;
		// A Block value is a function body unless the declared type is `block` itself.
		bool is_function = function_type_of(*child, src) != nullptr ||
			(body_block && type_name != "block" && type_name != "namespace" && type_name != "type");
		// A label may be named before it is placed, so a forward jump can reach it (B-Label).
		bool is_value = !is_function && type_name != "type" && type_name != "namespace" &&
			type_name != "alias" && type_name != "std.label";
		decls.push_back({name, type_name, value, is_value, is_function, child->line});
		// `_ : _ = ...` is a statement: it reads, but it binds no name.
		if (name != "_" && !index.count(name)) index[name] = decls.size() - 1;
	}

	// Where each block binding is first passed to a control-flow primitive: that is where it runs.
	std::map<std::string, size_t> use;
	for (size_t i = 0; i < decls.size(); ++i) {
		std::vector<std::string> names;
		collect_arg_names(*decls[i].value, src, names);
		for (auto &n : names)
			if (!use.count(n) || use[n] > i) use[n] = i;
	}

	std::map<std::string, std::tuple<size_t, size_t, bool>> outer_here;
	for (auto &d : decls)
		if (d.name != "_" && !outer_here.count(d.name))
			outer_here[d.name] = {index[d.name], d.line, d.is_value};

	for (size_t i = 0; i < decls.size(); ++i) {
		const peg::Ast *value = decls[i].value;
		bool is_namespace = decls[i].type_name == "namespace";
		bool is_type = decls[i].type_name == "type";
		bool runs = executed && !is_namespace && !is_type;

		std::vector<std::string> reads;
		collect_reads(*value, src, reads);
		for (auto &part : value->nodes) {
			if (part->name != "function_call") continue;
			// L-Scan: the tower is read before ascent, so the calls that shape it sit at level scope.
			if (!level_scope && scanned_calls.count(callee_of(*part, src)))
				errors.push_back("L-Scan: '" + callee_of(*part, src) + "' at line " + std::to_string(decls[i].line) +
					" is not at level scope, so the scan cannot read the tower from it");
			if (!is_tail_call(text_of(src, *part))) continue;
			if (!in_function)
				errors.push_back("B-Tail: the tail call at line " + std::to_string(decls[i].line) +
					" is outside a function body, so it has nothing to return from");
			else if (i + 1 < decls.size())
				errors.push_back("B-Tail: the tail call at line " + std::to_string(decls[i].line) +
					" is a terminator but does not end its block");
		}
		if (ordered) {
			for (auto &r : reads) {
				auto it = index.find(r);
				if (it != index.end()) {
					if (it->second > i && decls[it->second].is_value)
						errors.push_back("WF-Order: '" + r + "' read at line " + std::to_string(decls[i].line) +
							" before it is bound at line " + std::to_string(decls[it->second].line));
				} else {
					auto o = outer.find(r);
					if (o != outer.end() && std::get<2>(o->second) && std::get<0>(o->second) > deadline)
						errors.push_back("WF-Order: '" + r + "' read in a spliced block at line " +
							std::to_string(decls[i].line) + " before the enclosing block binds it at line " +
							std::to_string(std::get<1>(o->second)));
				}
			}
		}

		for (auto &part : value->nodes) {
			if (part->name == "Block") {
				// WF-Term is syntactic: a body or block binding ends properly wherever it is declared.
				if (!is_namespace && !is_type && !block_ends_with_terminator(*part, src))
					errors.push_back("WF-Term: block at line " + std::to_string(part->line) +
						" does not end with a terminator call");
				// A function body runs when called, so it sees the enclosing scope as it is
				// at the call, not at the declaration; a namespace body is a declaration list
				// whose bindings still bind in lexical order; a named block binding runs where it is
				// first passed to a primitive; an inline block argument runs at its call.
				bool direct_block = !value->nodes.empty() && value->nodes[0]->name == "Block";
				if (decls[i].is_function) {
					check_block(*part, src, true, true, {}, 0, prefix, sigs, errors, true, false);
				} else if (is_namespace) {
					check_block(*part, src, false, true, outer_here, i, prefix + decls[i].name + ".", sigs, errors, in_function, level_scope);
				} else if (direct_block && use.count(decls[i].name)) {
					check_block(*part, src, runs, runs, outer_here, use[decls[i].name], prefix, sigs, errors, in_function, false);
				} else if (direct_block) {
					check_block(*part, src, runs, runs, {}, 0, prefix, sigs, errors, in_function, false);
				} else {
					check_block(*part, src, runs, runs, outer_here, i, prefix, sigs, errors, in_function, false);
				}
			} else if (part->name == "function_call") {
				std::string callee = callee_of(*part, src);
				// D-Return: a `_` destination receiving a `_` return leaves the return type
				// unsolved, control flow included (`_ : void = std.if(...)`, B-If).
				auto it = resolve(sigs, callee, prefix);
				if (it != sigs.end() && decls[i].type_name == "_" && return_is_deduced(*it->second, src))
					errors.push_back("D-Return: '" + callee + "' at line " +
						std::to_string(part->line) + " has an unresolved '_' return type");
			}
		}
	}
}

// I-Language: this prototype registers no foreign frontends, so every `language` block is an error.
void check_languages(const peg::Ast &node, const std::string &src, std::vector<std::string> &errors) {
	if (node.name == "change_language") {
		std::string text = text_of(src, node);
		auto open = text.find('"');
		auto close = text.find('"', open + 1);
		errors.push_back("I-Language: no frontend is registered for language \"" +
			text.substr(open + 1, close - open - 1) + "\" at line " + std::to_string(node.line));
		return;
	}
	for (auto &child : node.nodes) check_languages(*child, src, errors);
}

void dump(const peg::Ast &node, int depth) {
	std::cout << std::string(depth * 2, ' ') << node.name;
	if (node.is_token) std::cout << " '" << node.token << "'";
	std::cout << "\n";
	for (auto &child : node.nodes) dump(*child, depth + 1);
}

} // namespace

int main(int argc, char **argv) {
	bool dump_ast = false;
	std::string grammar_path = "doir.peg";
	std::vector<std::pair<std::string, bool>> files;
	bool programs = false;
	for (int i = 1; i < argc; ++i) {
		std::string a = argv[i];
		if (a == "-a") {
			dump_ast = true;
		} else if (a == "-g") {
			grammar_path = argv[++i];
		} else if (a == "-p") {
			programs = true;
		} else {
			files.push_back({a, programs});
		}
	}

	peg::parser parser;
	parser.set_logger([&](size_t line, size_t col, const std::string &msg, const std::string &) {
		std::cerr << "grammar: line " << line << ":" << col << ": " << msg << "\n";
	});
	if (!parser.load_grammar(load_grammar(grammar_path))) {
		std::cerr << "grammar did not compile\n";
		return 1;
	}
	parser.enable_ast();

	int failures = 0;
	for (auto &[path, is_program] : files) {
		std::string src = read_file(path);
		std::vector<std::string> errors;
		parser.set_logger([&](size_t line, size_t col, const std::string &msg, const std::string &) {
		errors.push_back("line " + std::to_string(line) + ":" + std::to_string(col) + ": " + msg +
			" | near: " + line_of(src, line));
		});
		std::shared_ptr<peg::Ast> ast;
		if (!parser.parse(src, ast) || !ast) {
			if (errors.empty()) errors.push_back("parse failed");
		} else {
			Signatures sigs;
			std::vector<NamedSignature> named;
			collect_signatures(*ast, src, "", sigs, named);
			resolve_named_signatures(sigs, named);
			check_block(*ast, src, true, true, {}, 0, "", sigs, errors);
			check_languages(*ast, src, errors);
			if (is_program && !block_ends_with_terminator(*ast, src))
				errors.push_back("WF-Term: the program's root does not end with a terminator call (L-Entry)");
		}
		if (errors.empty()) {
			std::cout << path << ": ok\n";
		} else {
			std::cout << path << ": FAIL\n";
			for (auto &e : errors) std::cout << "  " << e << "\n";
			++failures;
		}
		if (dump_ast && ast) dump(*ast, 0);
	}
	return failures ? 1 : 0;
}
