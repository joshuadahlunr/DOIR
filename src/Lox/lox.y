%{
	int yylex(reflex::Input* input = nullptr);
	int yyparse();
	void yyerror(const char* s);
	#define YYSTYPE ecs::entity_t
%}

%define parse.error detailed

%token IDENTIFIER
%token NUMBER
%token STRING
%token True False Null
%token CLASS FUN VAR FOR IF ELSE PRINT RETURN WHILE OR AND THIS SUPER
%token NOT_EQUAL EQUAL GREATER_EQUAL LESS_EQUAL
%left '{' '}' '[' ']'
%left ','
%left ':'


%%


START: program;
program: declaration | declaration program;
declaration: classDecl | funDecl | varDecl | statement;

classDecl: CLASS { yyerror("Classes not supported!"); YYERROR; } IDENTIFIER classDeclTail;
classDeclTail: '<' IDENTIFIER '{' functionList '}' | '{' functionList '}';
functionList: function | function functionList;
funDecl: FUN function;
varDecl: VAR IDENTIFIER varDeclTail {
	$$ = $2;
	auto& lexeme2 = module->get_component<doir::comp::lexeme>($2);
	module->add_component<variable_declaire>($2) = {lexeme2, *fpda_back(blocks)};
	current_block().children.push_back($2);

	if($3) {
		auto assignment = module->create_entity();
		module->add_component<doir::comp::lexeme>(assignment) = lexeme2 + module->get_component<doir::comp::lexeme>($3);
		module->add_component<assign>(assignment);
		module->add_component<operation>(assignment) = {$2, $3};
		current_block().children.push_back(assignment);
	}
};
varDeclTail: '=' expression ';' { $$ = $2; } | ';' { $$ = 0; };

statement: exprStmt
| forStmt
| ifStmt
| printStmt
| returnStmt
| whileStmt
| block;

exprStmt: expression ';' { $$ = $1; current_block().children.push_back($$); };

forStmt: FOR '(' forStmtContentFirst forStmtContent forStmtContentLast ')' statement {
	fpda_pop_back(current_block().children);
	auto $$ = module->create_entity();
	auto& lexeme = module->add_component<doir::comp::lexeme>($$) = module->get_component<doir::comp::lexeme>($7);
	if($5) lexeme = module->get_component<doir::comp::lexeme>($5) + lexeme;
	if($4) lexeme = module->get_component<doir::comp::lexeme>($4) + lexeme;
	if($3) lexeme = module->get_component<doir::comp::lexeme>($3) + lexeme;
	if($$ != $$) module->add_component<doir::comp::lexeme>($$) = lexeme;
	module->add_component<while_>($$);
	module->add_component<operation>($$) = {$4, $7};
	current_block().children.push_back($$);
	if($5) {
		auto innerBlock = module->create_entity();
		module->get_component<operation>($$).b = innerBlock;
		module->add_component<doir::comp::lexeme>(innerBlock) = module->get_component<doir::comp::lexeme>($5) + module->get_component<doir::comp::lexeme>($7);
		auto& block = module->add_component<struct block>(innerBlock);
		block.children.push_back($7);
		block.children.push_back($5);
	}
};
forStmtContentFirst: varDecl { $$ = $1; } | exprStmt { $$ = $1; } | ';' { $$ = 0; };
forStmtContent: exprStmt { $$ = $1; fpda_pop_back(current_block().children); } | ';' { $$ = 0; };
forStmtContentLast: expression { $$ = $1; } | { $$ = 0; };

ifStmt: IF '(' expression ')' statement { fpda_pop_back(current_block().children); } ifStmtTail {
	$$ = module->create_entity();
	auto& lexeme = module->add_component<doir::comp::lexeme>($$) = module->get_component<doir::comp::lexeme>($3) + module->get_component<doir::comp::lexeme>($5);
	if($7) lexeme = lexeme + module->get_component<doir::comp::lexeme>($7);
	module->add_component<if_>($$);
	module->add_component<operation>($$) = {$3, $5, $7};
	current_block().children.push_back($$);
};
ifStmtTail: ELSE statement { $$ = $2; fpda_pop_back(current_block().children); } | { $$ = 0; };

printStmt: PRINT expression ';' {
	$$ = module->create_entity();
	module->add_component<doir::comp::lexeme>($$) = module->get_component<doir::comp::lexeme>($2);
	module->add_component<print>($$);
	module->add_component<operation>($$) = {$2};
	current_block().children.push_back($$);
};
returnStmt: RETURN expression ';' {
	$$ = module->create_entity();
	module->add_component<doir::comp::lexeme>($$) = module->get_component<doir::comp::lexeme>($2);
	module->add_component<return_>($$);
	module->add_component<operation>($$) = {$2};
	current_block().children.push_back($$);
} | RETURN ';' {
	$$ = module->create_entity();
	module->add_component<doir::comp::lexeme>($$) = module->get_component<doir::comp::lexeme>($2);
	module->add_component<return_>($$);
	current_block().children.push_back($$);
};
whileStmt: WHILE '(' expression ')' statement {
	fpda_pop_back(current_block().children);
	$$ = module->create_entity();
	module->add_component<doir::comp::lexeme>($$) = module->get_component<doir::comp::lexeme>($3) + module->get_component<doir::comp::lexeme>($5);
	module->add_component<while_>($$);
	module->add_component<operation>($$) = {$3, $5};
	current_block().children.push_back($$);
};
block: '{' {
	auto dbg = $$ = module->create_entity();
	module->add_component<doir::comp::lexeme>($$) = {location, 1};
	module->add_component<block>($$);
	fpda_push_back(blocks, $$);
} declarationList '}' { $$ = *fpda_pop_back(blocks); }
| '{' '}' {
	auto dbg = $$ = module->create_entity();
	module->add_component<doir::comp::lexeme>($$) = {location - 1, 1};
	module->add_component<block>($$);
};
declarationList: declaration | declaration declarationList;

expression: assignment { $$ = $1; };

assignment: call '.' { yyerror("Classes not supported!"); YYERROR; } IDENTIFIER '=' assignment
| IDENTIFIER '=' assignment {
	$$ = module->create_entity();
	module->add_component<doir::comp::lexeme>($$) = module->get_component<doir::comp::lexeme>($1) + module->get_component<doir::comp::lexeme>($3);
	module->add_component<assign>($$);
	module->add_component<operation>($$) = {$1, $3};
} | logic_or { $$ = $1; };

logic_or: logic_and logic_orTail {
	if($2 == 0)
		$$ = $1;
	else {
		$$ = *fpda_pop_back(objects);

		module->get_component<operation>($2).a = $1;
		auto& lexeme = module->get_component<doir::comp::lexeme>($2);
		lexeme = module->get_component<doir::comp::lexeme>($1) + lexeme;
	}
};
logic_orTail: OR logic_and logic_orTail {
	$$ = module->create_entity();
	module->add_component<doir::comp::lexeme>($$) = module->get_component<doir::comp::lexeme>($2);
	module->add_component<or_>($$);
	module->add_component<operation>($$) = {0, $2};
	if($3 == 0)
		fpda_push_back(objects, $$);
	else {
		module->get_component<operation>($3).a = $$;
		auto& lexeme = module->get_component<doir::comp::lexeme>($3);
		lexeme = module->get_component<doir::comp::lexeme>($$) + lexeme;
	}
} | { $$ = 0; };

logic_and: equality logic_andTail {
	if($2 == 0)
		$$ = $1;
	else {
		$$ = *fpda_pop_back(objects);

		module->get_component<operation>($2).a = $1;
		auto& lexeme = module->get_component<doir::comp::lexeme>($2);
		lexeme = module->get_component<doir::comp::lexeme>($1) + lexeme;
	}
};
logic_andTail: AND equality logic_andTail {
	$$ = module->create_entity();
	module->add_component<doir::comp::lexeme>($$) = module->get_component<doir::comp::lexeme>($2);
	module->add_component<and_>($$);
	module->add_component<operation>($$) = {0, $2};
	if($3 == 0)
		fpda_push_back(objects, $$);
	else {
		module->get_component<operation>($3).a = $$;
		auto& lexeme = module->get_component<doir::comp::lexeme>($3);
		lexeme = module->get_component<doir::comp::lexeme>($$) + lexeme;
	}
} | { $$ = 0; };

equality: comparison equalityTail {
	if($2 == 0)
		$$ = $1;
	else {
		$$ = *fpda_pop_back(objects);

		module->get_component<operation>($2).a = $1;
		auto& lexeme = module->get_component<doir::comp::lexeme>($2);
		lexeme = module->get_component<doir::comp::lexeme>($1) + lexeme;
	}
};
equalityTail: NOT_EQUAL comparison equalityTail {
	$$ = module->create_entity();
	module->add_component<doir::comp::lexeme>($$) = module->get_component<doir::comp::lexeme>($2);
	module->add_component<not_equal_to>($$);
	module->add_component<operation>($$) = {0, $2};
	if($3 == 0)
		fpda_push_back(objects, $$);
	else {
		module->get_component<operation>($3).a = $$;
		auto& lexeme = module->get_component<doir::comp::lexeme>($3);
		lexeme = module->get_component<doir::comp::lexeme>($$) + lexeme;
	}
} | EQUAL comparison equalityTail {
	$$ = module->create_entity();
	module->add_component<doir::comp::lexeme>($$) = module->get_component<doir::comp::lexeme>($2);
	module->add_component<equal_to>($$);
	module->add_component<operation>($$) = {0, $2};
	if($3 == 0)
		fpda_push_back(objects, $$);
	else {
		module->get_component<operation>($3).a = $$;
		auto& lexeme = module->get_component<doir::comp::lexeme>($3);
		lexeme = module->get_component<doir::comp::lexeme>($$) + lexeme;
	}
} | { $$ = 0; };

comparison: term comparisonTail {
	if($2 == 0)
		$$ = $1;
	else {
		$$ = *fpda_pop_back(objects);

		module->get_component<operation>($2).a = $1;
		auto& lexeme = module->get_component<doir::comp::lexeme>($2);
		lexeme = module->get_component<doir::comp::lexeme>($1) + lexeme;
	}
};
comparisonTail: '>' term comparisonTail {
	$$ = module->create_entity();
	module->add_component<doir::comp::lexeme>($$) = module->get_component<doir::comp::lexeme>($2);
	module->add_component<greater_than>($$);
	module->add_component<operation>($$) = {0, $2};
	if($3 == 0)
		fpda_push_back(objects, $$);
	else {
		module->get_component<operation>($3).a = $$;
		auto& lexeme = module->get_component<doir::comp::lexeme>($3);
		lexeme = module->get_component<doir::comp::lexeme>($$) + lexeme;
	}
} | GREATER_EQUAL term comparisonTail {
	$$ = module->create_entity();
	module->add_component<doir::comp::lexeme>($$) = module->get_component<doir::comp::lexeme>($2);
	module->add_component<greater_than_equal_to>($$);
	module->add_component<operation>($$) = {0, $2};
	if($3 == 0)
		fpda_push_back(objects, $$);
	else {
		module->get_component<operation>($3).a = $$;
		auto& lexeme = module->get_component<doir::comp::lexeme>($3);
		lexeme = module->get_component<doir::comp::lexeme>($$) + lexeme;
	}
} | '<' term comparisonTail {
	$$ = module->create_entity();
	module->add_component<doir::comp::lexeme>($$) = module->get_component<doir::comp::lexeme>($2);
	module->add_component<less_than>($$);
	module->add_component<operation>($$) = {0, $2};
	if($3 == 0)
		fpda_push_back(objects, $$);
	else {
		module->get_component<operation>($3).a = $$;
		auto& lexeme = module->get_component<doir::comp::lexeme>($3);
		lexeme = module->get_component<doir::comp::lexeme>($$) + lexeme;
	}
} | LESS_EQUAL term comparisonTail {
	$$ = module->create_entity();
	module->add_component<doir::comp::lexeme>($$) = module->get_component<doir::comp::lexeme>($2);
	module->add_component<less_than_equal_to>($$);
	module->add_component<operation>($$) = {0, $2};
	if($3 == 0)
		fpda_push_back(objects, $$);
	else {
		module->get_component<operation>($3).a = $$;
		auto& lexeme = module->get_component<doir::comp::lexeme>($3);
		lexeme = module->get_component<doir::comp::lexeme>($$) + lexeme;
	}
} | { $$ = 0; };

term: factor termTail {
	if($2 == 0)
		$$ = $1;
	else {
		auto dbg = $$ = *fpda_pop_back(objects);

		module->get_component<operation>($2).a = $1;
		auto& lexeme = module->get_component<doir::comp::lexeme>($2);
		lexeme = module->get_component<doir::comp::lexeme>($1) + lexeme;
	}
};
termTail: '-' factor termTail {
	$$ = module->create_entity();
	module->add_component<doir::comp::lexeme>($$) = module->get_component<doir::comp::lexeme>($2);
	module->add_component<subtract>($$);
	module->add_component<operation>($$) = {0, $2};
	if($3 == 0)
		fpda_push_back(objects, $$);
	else {
		module->get_component<operation>($3).a = $$;
		auto& lexeme = module->get_component<doir::comp::lexeme>($3);
		lexeme = module->get_component<doir::comp::lexeme>($$) + lexeme;
	}
} | '+' factor termTail {
	$$ = module->create_entity();
	module->add_component<doir::comp::lexeme>($$) = module->get_component<doir::comp::lexeme>($2);
	module->add_component<add>($$);
	module->add_component<operation>($$) = {0, $2};
	if($3 == 0)
		fpda_push_back(objects, $$);
	else {
		module->get_component<operation>($3).a = $$;
		auto& lexeme = module->get_component<doir::comp::lexeme>($3);
		lexeme = module->get_component<doir::comp::lexeme>($$) + lexeme;
	}
} | { $$ = 0; };

factor: unary factorTail {
	if($2 == 0)
		$$ = $1;
	else {
		auto dbg = $$ = *fpda_pop_back(objects);

		module->get_component<operation>($2).a = $1;
		auto& lexeme = module->get_component<doir::comp::lexeme>($2);
		lexeme = module->get_component<doir::comp::lexeme>($1) + lexeme;
	}
};
factorTail: '/' unary factorTail {
	$$ = module->create_entity();
	module->add_component<doir::comp::lexeme>($$) = module->get_component<doir::comp::lexeme>($2);
	module->add_component<divide>($$);
	module->add_component<operation>($$) = {0, $2};
	if($3 == 0)
		fpda_push_back(objects, $$);
	else {
		module->get_component<operation>($3).a = $$;
		auto& lexeme = module->get_component<doir::comp::lexeme>($3);
		lexeme = module->get_component<doir::comp::lexeme>($$) + lexeme;
	}
} | '*' unary factorTail {
	$$ = module->create_entity();
	module->add_component<doir::comp::lexeme>($$) = module->get_component<doir::comp::lexeme>($2);
	module->add_component<multiply>($$);
	module->add_component<operation>($$) = {0, $2};
	if($3 == 0)
		fpda_push_back(objects, $$);
	else {
		module->get_component<operation>($3).a = $$;
		auto& lexeme = module->get_component<doir::comp::lexeme>($3);
		lexeme = module->get_component<doir::comp::lexeme>($$) + lexeme;
	}
} | { $$ = 0; };

unary: '!' unary {
	$$ = module->create_entity();
	module->add_component<doir::comp::lexeme>($$) = module->get_component<doir::comp::lexeme>($2);
	module->add_component<not_>($$);
	module->add_component<operation>($$) = {$2};
} | '-' unary {
	$$ = module->create_entity();
	module->add_component<doir::comp::lexeme>($$) = module->get_component<doir::comp::lexeme>($2);
	module->add_component<negate>($$);
	module->add_component<operation>($$) = {$2};
} | call { $$ = $1; };

call: primary callTail {
	if($2 == 0)
		$$ = $1;
	else {
		auto dbg = $$ = *fpda_pop_back(objects);

		module->get_component<call>($2).parent = $1;
		auto& lexeme = module->get_component<doir::comp::lexeme>($2);
		lexeme = module->get_component<doir::comp::lexeme>($1) + lexeme;
	}
};
callTail: '(' ')' callTail {
	$$ = module->create_entity();
	module->add_component<doir::comp::lexeme>($$) = {location - 1, 2};
	module->add_component<call>($$) = {block{.parent = 0, .children = nullptr}};
	if($3 == 0)
		fpda_push_back(objects, $$);
	else {
		module->get_component<call>($3).parent = $$;
		auto& lexeme = module->get_component<doir::comp::lexeme>($3);
		lexeme = module->get_component<doir::comp::lexeme>($$) + lexeme;
	}
}
| '(' { $$ = fpda_size(objects); } arguments ')' callTail {
	auto end_size = $2;
	$$ = module->create_entity();
	auto& call = module->add_component<struct call>($$) = {block{.parent = 0, .children = nullptr}};
	while(fpda_size(objects) > end_size)
		call.children.push_back(*fpda_pop_back(objects));
	module->add_component<doir::comp::lexeme>($$) = module->get_component<doir::comp::lexeme>(*fpda_front(call.children)) 
		+ module->get_component<doir::comp::lexeme>(call.children.back());

	if($5 == 0)
		fpda_push_back(objects, $$);
	else {
		module->get_component<struct call>($5).parent = $$;
		auto& lexeme = module->get_component<doir::comp::lexeme>($5);
		lexeme = module->get_component<doir::comp::lexeme>($$) + lexeme;
	}
}
| '.' { yyerror("Classes not supported!"); YYERROR; } IDENTIFIER callTail { $$ = 0; } | { $$ = 0; };

primary: True { $$ = $1; }
| False { $$ = $1; }
| Null { $$ = $1; }
| THIS { yyerror("Classes (this) not supported!"); YYERROR; }
| NUMBER { $$ = $1; }
| STRING { $$ = $1; }
| IDENTIFIER {
	module->add_component<variable>($1);
	$$ = $1;
} | '(' expression ')' { $$ = $2; }
| SUPER { yyerror("Classes (super) not supported!"); YYERROR; } '.' IDENTIFIER;

function: IDENTIFIER '(' ')' block {
	auto dbg = $$ = $4;
	auto& decl = module->add_component<function_declaire>($$) = {declaire{.name = module->get_component<doir::comp::lexeme>($1), .parent = *fpda_back(blocks)}};
	auto& lexeme = module->get_component<doir::comp::lexeme>($$);
	lexeme = decl.name + lexeme;
	current_block().children.push_back($$);
} | IDENTIFIER '(' {module->add_component<parameters>($1); fpda_push_back(objects, $1);} parameters ')' block {
	auto dbg = $$ = $6;
	auto& decl = module->add_component<function_declaire>($$) = {declaire{.name = module->get_component<doir::comp::lexeme>($1), .parent = *fpda_back(blocks)}};
	auto& lexeme = module->get_component<doir::comp::lexeme>($$);
	lexeme = decl.name + lexeme;
	module->add_component<parameters>($$) = module->get_component<parameters>($1);
	current_block().children.push_back($$);
};
parameters: IDENTIFIER {
	auto func = *fpda_back(objects);
	module->add_component<parameter_declaire>($1) = {declaire{.name = module->get_component<doir::comp::lexeme>($1), .parent = func}};
	auto& params = module->get_component<parameters>(func);
	params.parameters.push_back($1);
} parametersTail;
parametersTail: ',' IDENTIFIER {
	auto func = *fpda_back(objects);
	module->add_component<parameter_declaire>($2) = {declaire{.name = module->get_component<doir::comp::lexeme>($2), .parent = func}};
	auto& params = module->get_component<parameters>(func);
	params.parameters.push_back($2);
} parametersTail | { $$ = 0; };

arguments: expression argumentsTail { fpda_push_back(objects, $1); };
argumentsTail: ',' expression argumentsTail { fpda_push_back(objects, $2); } | { $$ = 0; };

%%

void yyerror(const char* s) {
	nowide::cerr << s << std::endl;
}