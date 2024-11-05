/* definitions */

%{
	int yylex(reflex::Input* input = nullptr);
	int yyparse();
	void yyerror(const char* s);

	#define YYSTYPE doir::ecs::entity_t
%}

%token NUMBER
%token IDENTIFIER


%% /* Rules */


expressionList: expressionList expression ';' { fpda_push_back(module->get_or_add_component<comp::expressions>(moduleRoot).expr, $2); }
	| expression ';' { fpda_push_back(module->get_or_add_component<comp::expressions>(moduleRoot).expr, $1); };

expression: identifier '=' expression { 
		auto& _1 = module->get_component<doir::comp::lexeme>($1);
		get_key_and_mark_occupied(module->add_component<comp::variable_definition_hash>($1)) = {
			.name = _1,
			.value = 0
		};

		$$ = module->create_entity();
		module->add_component<doir::comp::lexeme>($$) = _1 + module->get_component<doir::comp::lexeme>($3);
		module->add_component<comp::operation>($$) = {$1, $3};
		module->add_component<comp::assignment>($$);
	} | addExpression { $$ = $1; };
addExpression: addExpression '+' mulExpression {
		$$ = module->create_entity();
		module->add_component<doir::comp::lexeme>($$) = module->get_component<doir::comp::lexeme>($1) + module->get_component<doir::comp::lexeme>($3);
		module->add_component<comp::operation>($$) = {$1, $3};
		module->add_component<comp::add>($$);
	}
	| addExpression '-' mulExpression {
		$$ = module->create_entity();
		module->add_component<doir::comp::lexeme>($$) = module->get_component<doir::comp::lexeme>($1) + module->get_component<doir::comp::lexeme>($3);
		module->add_component<comp::operation>($$) = {$1, $3};
		module->add_component<comp::subtract>($$);
	}
	| mulExpression { $$ = $1; };
mulExpression: mulExpression '*' powExpression {
		$$ = module->create_entity();
		module->add_component<doir::comp::lexeme>($$) = module->get_component<doir::comp::lexeme>($1) + module->get_component<doir::comp::lexeme>($3);
		module->add_component<comp::operation>($$) = {$1, $3};
		module->add_component<comp::multiply>($$);
	}
	| mulExpression '/' powExpression {
		$$ = module->create_entity();
		module->add_component<doir::comp::lexeme>($$) = module->get_component<doir::comp::lexeme>($1) + module->get_component<doir::comp::lexeme>($3);
		module->add_component<comp::operation>($$) = {$1, $3};
		module->add_component<comp::divide>($$);
	}
	| powExpression { $$ = $1; };
powExpression: powExpression '^' term {
		$$ = module->create_entity();
		module->add_component<doir::comp::lexeme>($$) = module->get_component<doir::comp::lexeme>($1) + module->get_component<doir::comp::lexeme>($3);
		module->add_component<comp::operation>($$) = {$1, $3};
		module->add_component<comp::power>($$);
	}
	| term { $$ = $1; };

term: '(' expression ')' { $$ = $2; }
	| NUMBER { $$ = $1; }
	| identifier { 
		module->add_component<comp::variable_access>($1).variable.lexeme = module->get_component<doir::comp::lexeme>($1);
		$$ = $1;
	};
identifier: IDENTIFIER { $$ = yylval; };


%% /* Code */


inline void yyerror(const char* s) {
	nowide::cerr << s << std::endl;
}