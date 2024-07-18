#include "lox.parse.hpp"

TEST_CASE("Lox::Nil") {
	ZoneScopedN("Lox::Nil");
	doir::ParseModule module("nil;");
	lox::parse p;
	auto root = module.get_attribute<lox::components::Block>(p.start(module))->children[0];
	CHECK(module.get_attribute<lox::components::Null>(root).has_value());
	FrameMark;
}

TEST_CASE("Lox::True") {
	ZoneScopedN("Lox::True");
	doir::ParseModule module("true;");
	lox::parse p;
	auto root = module.get_attribute<lox::components::Block>(p.start(module))->children[0];
	CHECK(*module.get_attribute<bool>(root) == true);
	FrameMark;
}

TEST_CASE("Lox::False") {
	ZoneScopedN("Lox::False");
	doir::ParseModule module("false;");
	lox::parse p;
	auto root = module.get_attribute<lox::components::Block>(p.start(module))->children[0];
	CHECK(*module.get_attribute<bool>(root) == false);
	FrameMark;
}

TEST_CASE("Lox::String") {
	ZoneScopedN("Lox::String");
	doir::ParseModule module("\"Hello World\";");
	lox::parse p;
	auto root = module.get_attribute<lox::components::Block>(p.start(module))->children[0];
	CHECK(module.has_attribute<lox::components::String>(root));
	CHECK(module.get_attribute<doir::Lexeme>(root)->view(module.buffer) == "Hello World");
	FrameMark;
}

TEST_CASE("Lox::Number") {
	ZoneScopedN("Lox::Number");
	doir::ParseModule module("5.0;");
	lox::parse p;
	auto root = module.get_attribute<lox::components::Block>(p.start(module))->children[0];
	CHECK(*module.get_attribute<double>(root) == 5.0);
	FrameMark;
}

TEST_CASE("Lox::This") {
	ZoneScopedN("Lox::This");
	doir::ParseModule module("this;");
	lox::parse p;
	auto root = module.get_attribute<lox::components::Block>(p.start(module))->children[0];
	CHECK(module.has_attribute<lox::components::Variable>(root));
	CHECK(module.get_attribute<doir::TokenReference>(root)->lexeme().view(module.buffer) == "this");
	FrameMark;
}

TEST_CASE("Lox::Variable") {
	ZoneScopedN("Lox::Variable");
	doir::ParseModule module("x;");
	lox::parse p;
	auto root = module.get_attribute<lox::components::Block>(p.start(module))->children[0];
	CHECK(module.has_attribute<lox::components::Variable>(root));
	CHECK(module.get_attribute<doir::TokenReference>(root)->lexeme().view(module.buffer) == "x");
	FrameMark;
}

TEST_CASE("Lox::Not") {
	ZoneScopedN("Lox::Not");
	doir::ParseModule module("!true;");
	lox::parse p;
	auto root = module.get_attribute<lox::components::Block>(p.start(module))->children[0];
	CHECK(module.has_attribute<lox::components::Not>(root));
	auto target = module.get_attribute<lox::components::Operation>(root)->left;
	CHECK(*module.get_attribute<bool>(target) == true);
	FrameMark;
}

TEST_CASE("Lox::Negate") {
	ZoneScopedN("Lox::Negate");
	doir::ParseModule module("-5;");
	lox::parse p;
	auto root = module.get_attribute<lox::components::Block>(p.start(module))->children[0];
	CHECK(module.has_attribute<lox::components::Negate>(root));
	auto target = module.get_attribute<lox::components::Operation>(root)->left;
	CHECK(*module.get_attribute<double>(target) == 5);
	FrameMark;
}

TEST_CASE("Lox::Multiply") {
	ZoneScopedN("Lox::Multiply");
	doir::ParseModule module("5 * 6 * 7;");
	lox::parse p;
	auto root = module.get_attribute<lox::components::Block>(p.start(module))->children[0];
	CHECK(module.has_attribute<lox::components::Multiply>(root));
	auto operands = *module.get_attribute<lox::components::Operation>(root);
	CHECK(*module.get_attribute<double>(operands.right) == 7);
	CHECK(module.has_attribute<lox::components::Multiply>(operands.left));
	operands = *module.get_attribute<lox::components::Operation>(operands.left);
	CHECK(*module.get_attribute<double>(operands.right) == 6);
	CHECK(*module.get_attribute<double>(operands.left) == 5);
	FrameMark;
}

TEST_CASE("Lox::Divide") {
	ZoneScopedN("Lox::Divide");
	doir::ParseModule module("5 / 6 / 7;");
	lox::parse p;
	auto root = module.get_attribute<lox::components::Block>(p.start(module))->children[0];
	CHECK(module.has_attribute<lox::components::Divide>(root));
	auto operands = *module.get_attribute<lox::components::Operation>(root);
	CHECK(*module.get_attribute<double>(operands.right) == 7);
	CHECK(module.has_attribute<lox::components::Divide>(operands.left));
	operands = *module.get_attribute<lox::components::Operation>(operands.left);
	CHECK(*module.get_attribute<double>(operands.right) == 6);
	CHECK(*module.get_attribute<double>(operands.left) == 5);
	FrameMark;
}

TEST_CASE("Lox::MulDiv") {
	ZoneScopedN("Lox::MulDiv");
	doir::ParseModule module("5 * 6 / 7;");
	lox::parse p;
	auto root = module.get_attribute<lox::components::Block>(p.start(module))->children[0];
	CHECK(module.has_attribute<lox::components::Divide>(root));
	auto operands = *module.get_attribute<lox::components::Operation>(root);
	CHECK(*module.get_attribute<double>(operands.right) == 7);
	CHECK(module.has_attribute<lox::components::Multiply>(operands.left));
	operands = *module.get_attribute<lox::components::Operation>(operands.left);
	CHECK(*module.get_attribute<double>(operands.right) == 6);
	CHECK(*module.get_attribute<double>(operands.left) == 5);
	FrameMark;
}

TEST_CASE("Lox::Add") {
	ZoneScopedN("Lox::Add");
	doir::ParseModule module("5 + 6 + 7;");
	lox::parse p;
	auto root = module.get_attribute<lox::components::Block>(p.start(module))->children[0];
	CHECK(module.has_attribute<lox::components::Add>(root));
	auto operands = *module.get_attribute<lox::components::Operation>(root);
	CHECK(*module.get_attribute<double>(operands.right) == 7);
	CHECK(module.has_attribute<lox::components::Add>(operands.left));
	operands = *module.get_attribute<lox::components::Operation>(operands.left);
	CHECK(*module.get_attribute<double>(operands.right) == 6);
	CHECK(*module.get_attribute<double>(operands.left) == 5);
	FrameMark;
}

TEST_CASE("Lox::Sub") {
	ZoneScopedN("Lox::Sub");
	doir::ParseModule module("5 - 6 - 7;");
	lox::parse p;
	auto root = module.get_attribute<lox::components::Block>(p.start(module))->children[0];
	CHECK(module.has_attribute<lox::components::Subtract>(root));
	auto operands = *module.get_attribute<lox::components::Operation>(root);
	CHECK(*module.get_attribute<double>(operands.right) == 7);
	CHECK(module.has_attribute<lox::components::Subtract>(operands.left));
	operands = *module.get_attribute<lox::components::Operation>(operands.left);
	CHECK(*module.get_attribute<double>(operands.right) == 6);
	CHECK(*module.get_attribute<double>(operands.left) == 5);
	FrameMark;
}

TEST_CASE("Lox::AddSub") {
	ZoneScopedN("Lox::AddSub");
	doir::ParseModule module("5 + 6 - 7;");
	lox::parse p;
	auto root = module.get_attribute<lox::components::Block>(p.start(module))->children[0];
	CHECK(module.has_attribute<lox::components::Subtract>(root));
	auto operands = *module.get_attribute<lox::components::Operation>(root);
	CHECK(*module.get_attribute<double>(operands.right) == 7);
	CHECK(module.has_attribute<lox::components::Add>(operands.left));
	operands = *module.get_attribute<lox::components::Operation>(operands.left);
	CHECK(*module.get_attribute<double>(operands.right) == 6);
	CHECK(*module.get_attribute<double>(operands.left) == 5);
	FrameMark;
}

TEST_CASE("Lox::pemdas1") {
	ZoneScopedN("Lox::pemdas1");
	doir::ParseModule module("7 + 6 * 5 - 3;");
	lox::parse p;
	auto root = module.get_attribute<lox::components::Block>(p.start(module))->children[0];
	CHECK(module.has_attribute<lox::components::Subtract>(root));
	auto operands = *module.get_attribute<lox::components::Operation>(root);
	CHECK(*module.get_attribute<double>(operands.right) == 3);
	CHECK(module.has_attribute<lox::components::Add>(operands.left));
	operands = *module.get_attribute<lox::components::Operation>(operands.left);
	CHECK(*module.get_attribute<double>(operands.left) == 7);
	CHECK(module.has_attribute<lox::components::Multiply>(operands.right));
	operands = *module.get_attribute<lox::components::Operation>(operands.right);
	CHECK(*module.get_attribute<double>(operands.left) == 6);
	CHECK(*module.get_attribute<double>(operands.right) == 5);
	FrameMark;
}

TEST_CASE("Lox::pemdas2") {
	ZoneScopedN("Lox::pemdas2");
	doir::ParseModule module("(7 + 6) * (5 - 3);");
	lox::parse p;
	auto root = module.get_attribute<lox::components::Block>(p.start(module))->children[0];
	CHECK(module.has_attribute<lox::components::Multiply>(root));
	auto operands = *module.get_attribute<lox::components::Operation>(root);
	{
		CHECK(module.has_attribute<lox::components::Add>(operands.left));
		auto t = *module.get_attribute<lox::components::Operation>(operands.left);
		CHECK(*module.get_attribute<double>(t.left) == 7);
		CHECK(*module.get_attribute<double>(t.right) == 6);
	}{
		CHECK(module.has_attribute<lox::components::Subtract>(operands.right));
		auto t = *module.get_attribute<lox::components::Operation>(operands.right);
		CHECK(*module.get_attribute<double>(t.left) == 5);
		CHECK(*module.get_attribute<double>(t.right) == 3);
	}
	FrameMark;
}

TEST_CASE("Lox::Assign") {
	ZoneScopedN("Lox::Assign");
	doir::ParseModule module("x = 5;");
	lox::parse p;
	auto root = module.get_attribute<lox::components::Block>(p.start(module))->children[0];
	CHECK(module.has_attribute<lox::components::Assign>(root));
	CHECK(module.get_attribute<doir::TokenReference>(root)->lexeme() == doir::Lexeme{0, 1});
	auto value = module.get_attribute<lox::components::Operation>(root)->left;
	CHECK(*module.get_attribute<double>(value) == 5);
	FrameMark;
}

TEST_CASE("Lox::ClassAssign") {
	ZoneScopedN("Lox::ClassAssign");
	CAPTURE_ERROR_CONSOLE_BEGIN
		doir::ParseModule module("x.y = 5;");
		lox::parse p;
		auto root = p.start(module);
		CHECK(module.has_attribute<doir::Error>(root));
	CAPTURE_ERROR_CONSOLE_END
	CHECK(capture.str() == R"(An error has occurred at <transient>:1:2-3
   x.y = 5
    ^
Classes are not yet supported!
)");
	FrameMark;
}

TEST_CASE("Lox::Block") {
	ZoneScopedN("Lox::Block");
	doir::ParseModule module("{x = 5;\nx + 6;}");
	lox::parse p;
	auto rootT = module.get_attribute<lox::components::Block>(p.start(module))->children[0];
	CHECK(module.has_attribute<lox::components::Block>(rootT));
	auto& root = *module.get_attribute<lox::components::Block>(rootT);
	CHECK(root.children.size() == 2);
	{
		CHECK(module.has_attribute<lox::components::Assign>(root.children[0]));
		CHECK(module.get_attribute<doir::TokenReference>(root.children[0])->lexeme() == doir::Lexeme{1, 1});
		auto value = module.get_attribute<lox::components::Operation>(root.children[0])->left;
		CHECK(*module.get_attribute<double>(value) == 5);
	}
	{
		CHECK(module.has_attribute<lox::components::Add>(root.children[1]));
		auto operands = *module.get_attribute<lox::components::Operation>(root.children[1]);
		CHECK(*module.get_attribute<double>(operands.right) == 6);
		CHECK(module.has_attribute<lox::components::Variable>(operands.left));
		CHECK(module.get_attribute<doir::TokenReference>(operands.left)->lexeme().view(module.buffer) == "x");
	}
	FrameMark;
}

TEST_CASE("Lox::Print") {
	ZoneScopedN("Lox::Print");
	doir::ParseModule module("print 5;");
	lox::parse p;
	auto root = module.get_attribute<lox::components::Block>(p.start(module))->children[0];
	CHECK(module.has_attribute<lox::components::Print>(root));
	auto target = module.get_attribute<lox::components::Operation>(root)->left;
	CHECK(*module.get_attribute<double>(target) == 5);
	FrameMark;
}

TEST_CASE("Lox::Return") {
	ZoneScopedN("Lox::Return");
	doir::ParseModule module("return 5;");
	lox::parse p;
	auto root = module.get_attribute<lox::components::Block>(p.start(module))->children[0];
	CHECK(module.has_attribute<lox::components::Return>(root));
	auto target = module.get_attribute<lox::components::Operation>(root)->left;
	CHECK(*module.get_attribute<double>(target) == 5);
	FrameMark;
}

TEST_CASE("Lox::ReturnNothing") {
	ZoneScopedN("Lox::ReturnNothing");
	doir::ParseModule module("return;");
	lox::parse p;
	auto root = module.get_attribute<lox::components::Block>(p.start(module))->children[0];
	CHECK(module.has_attribute<lox::components::Return>(root));
	CHECK(module.has_attribute<lox::components::Operation>(root) == false);
	FrameMark;
}

TEST_CASE("Lox::While") {
	ZoneScopedN("Lox::While");
	doir::ParseModule module("while(true) { print false; }");
	lox::parse p;
	auto root = module.get_attribute<lox::components::Block>(p.start(module))->children[0];
	CHECK(module.has_attribute<lox::components::While>(root));
	auto [condition, block] = *module.get_attribute<lox::components::Operation>(root);
	CHECK(*module.get_attribute<bool>(condition) == true);
	{
		auto marker = module.get_attribute<lox::components::Block>(block)->children[0];
		CHECK(module.has_attribute<lox::components::BodyMarker>(marker));
		CHECK(module.get_attribute<lox::components::BodyMarker>(marker)->skipTo == root);
	}
	{
		auto stmt = module.get_attribute<lox::components::Block>(block)->children[1];
		CHECK(module.has_attribute<lox::components::Print>(stmt));
		auto target = module.get_attribute<lox::components::Operation>(stmt)->left;
		CHECK(*module.get_attribute<bool>(target) == false);
	}
	FrameMark;
}

TEST_CASE("Lox::If") {
	ZoneScopedN("Lox::If");
	doir::ParseModule module("if(x < y) print \"true\";");
	lox::parse p;
	auto root = module.get_attribute<lox::components::Block>(p.start(module))->children[0];
	CHECK(module.has_attribute<lox::components::If>(root));
	auto [a] = *module.get_attribute<lox::components::OperationIf>(root);
	auto [condition, stmt, _, marker] = a;
	{
		CHECK(module.has_attribute<lox::components::LessThan>(condition));
		auto operands = *module.get_attribute<lox::components::Operation>(condition);
		CHECK(module.has_attribute<lox::components::Variable>(operands.left));
		CHECK(module.get_attribute<doir::TokenReference>(operands.left)->lexeme().view(module.buffer) == "x");
		CHECK(module.has_attribute<lox::components::Variable>(operands.right));
		CHECK(module.get_attribute<doir::TokenReference>(operands.right)->lexeme().view(module.buffer) == "y");
	}
	{
		CHECK(module.has_attribute<lox::components::Print>(stmt));
		auto target = module.get_attribute<lox::components::Operation>(stmt)->left;
		CHECK(module.has_attribute<lox::components::String>(target));
		CHECK(module.get_attribute<doir::Lexeme>(target)->view(module.buffer) == "true");
	}
	{
		CHECK(module.has_attribute<lox::components::BodyMarker>(marker));
		CHECK(module.get_attribute<lox::components::BodyMarker>(marker)->skipTo == root);
		CHECK(_ == 0);
	}
	FrameMark;
}

TEST_CASE("Lox::IfElse") {
	ZoneScopedN("Lox::IfElse");
	doir::ParseModule module("if(x < y) print \"true\"; else print 5;");
	lox::parse p;
	auto root = module.get_attribute<lox::components::Block>(p.start(module))->children[0];
	CHECK(module.has_attribute<lox::components::If>(root));
	auto [a] = *module.get_attribute<lox::components::OperationIf>(root);
	auto [condition, then, Else, marker] = a;
	{
		CHECK(module.has_attribute<lox::components::LessThan>(condition));
		auto operands = *module.get_attribute<lox::components::Operation>(condition);
		CHECK(module.has_attribute<lox::components::Variable>(operands.left));
		CHECK(module.get_attribute<doir::TokenReference>(operands.left)->lexeme().view(module.buffer) == "x");
		CHECK(module.has_attribute<lox::components::Variable>(operands.right));
		CHECK(module.get_attribute<doir::TokenReference>(operands.right)->lexeme().view(module.buffer) == "y");
	}
	{
		CHECK(module.has_attribute<lox::components::Print>(then));
		auto target = module.get_attribute<lox::components::Operation>(then)->left;
		CHECK(module.has_attribute<lox::components::String>(target));
		CHECK(module.get_attribute<doir::Lexeme>(target)->view(module.buffer) == "true");
	}
	{
		CHECK(module.has_attribute<lox::components::Print>(Else));
		auto target = module.get_attribute<lox::components::Operation>(Else)->left;
		CHECK(*module.get_attribute<double>(target) == 5);
	}
	{
		CHECK(module.has_attribute<lox::components::BodyMarker>(marker));
		CHECK(module.get_attribute<lox::components::BodyMarker>(marker)->skipTo == root);
	}
	FrameMark;
}

TEST_CASE("Lox::For") {
	ZoneScopedN("Lox::For");
	doir::ParseModule module("for(y = 0; x > y; x + 1) { print x; }");
	lox::parse p;
	auto root = module.get_attribute<lox::components::Block>(p.start(module))->children[0];
	auto& rootC = module.get_attribute<lox::components::Block>(root)->children;
	CHECK(rootC.size() == 2);
	{
		auto root = rootC[0];
		CHECK(module.has_attribute<lox::components::Assign>(root));
		CHECK(module.get_attribute<doir::TokenReference>(root)->lexeme().view(module.buffer) == "y");
		auto value = module.get_attribute<lox::components::Operation>(root)->left;
		CHECK(*module.get_attribute<double>(value) == 0);
	}
	{
		auto root = rootC[1];
		CHECK(module.has_attribute<lox::components::While>(root));
		auto [condition, block] = *module.get_attribute<lox::components::Operation>(root);
		{
			CHECK(module.has_attribute<lox::components::GreaterThan>(condition));
			auto operands = *module.get_attribute<lox::components::Operation>(condition);
			CHECK(module.has_attribute<lox::components::Variable>(operands.left));
			CHECK(module.get_attribute<doir::TokenReference>(operands.left)->lexeme().view(module.buffer) == "x");
			CHECK(module.has_attribute<lox::components::Variable>(operands.right));
			CHECK(module.get_attribute<doir::TokenReference>(operands.right)->lexeme().view(module.buffer) == "y");
		}
		{
			auto& rootC = module.get_attribute<lox::components::Block>(block)->children;
			CHECK(rootC.size() == 3);
			{
				auto marker = rootC[0];
				CHECK(module.has_attribute<lox::components::BodyMarker>(marker));
				CHECK(module.get_attribute<lox::components::BodyMarker>(marker)->skipTo == root);
			}
			{
				auto root = rootC[1];
				CHECK(module.has_attribute<lox::components::Print>(root));
				auto target = module.get_attribute<lox::components::Operation>(root)->left;
				CHECK(module.has_attribute<lox::components::Variable>(target));
				CHECK(module.get_attribute<doir::TokenReference>(target)->lexeme().view(module.buffer) == "x");
			}
			{
				auto root = rootC[2];
				CHECK(module.has_attribute<lox::components::Add>(root));
				auto operands = *module.get_attribute<lox::components::Operation>(root);
				CHECK(*module.get_attribute<double>(operands.right) == 1);
				CHECK(module.has_attribute<lox::components::Variable>(operands.left));
				CHECK(module.get_attribute<doir::TokenReference>(operands.left)->lexeme().view(module.buffer) == "x");
			}
		}
	}
	FrameMark;
}

TEST_CASE("Lox::ForEmpty") {
	ZoneScopedN("Lox::ForEmpty");
	doir::ParseModule module("for(;;) print x;");
	lox::parse p;
	auto& rootC = module.get_attribute<lox::components::Block>(p.start(module))->children;
	CHECK(rootC.size() == 2); // 1 + builtin clock
	{
		auto root = rootC[0];
		CHECK(module.has_attribute<lox::components::While>(root));
		auto [condition, block] = *module.get_attribute<lox::components::Operation>(root);
		CHECK(*module.get_attribute<bool>(condition) == true);
		{
			auto& rootC = module.get_attribute<lox::components::Block>(block)->children;
			CHECK(rootC.size() == 2);
			{
				auto marker = rootC[0];
				CHECK(module.has_attribute<lox::components::BodyMarker>(marker));
				CHECK(module.get_attribute<lox::components::BodyMarker>(marker)->skipTo == root);
			}
			{
				auto stmt = rootC[1];
				CHECK(module.has_attribute<lox::components::Print>(stmt));
				auto target = module.get_attribute<lox::components::Operation>(stmt)->left;
				CHECK(module.has_attribute<lox::components::Variable>(target));
				CHECK(module.get_attribute<doir::TokenReference>(target)->lexeme().view(module.buffer) == "x");
			}
		}
	}
	FrameMark;
}

TEST_CASE("Lox::Var") {
	ZoneScopedN("Lox::Var");
	doir::ParseModule module("var x;");
	lox::parse p;
	auto root = module.get_attribute<lox::components::Block>(p.start(module))->children[0];
	CHECK(get_key<lox::components::VariableDeclaire>(module.get_hashtable_attribute<lox::components::VariableDeclaire>(root)).name.view(module.buffer) == "x");
	CHECK(module.has_attribute<lox::components::Operation>(root) == false);

	auto& hashtable = *module.get_hashtable<lox::components::VariableDeclaire>();
	CHECK(*hashtable.find({{module.buffer.find("x"), 1}, 1}) == root);
	FrameMark;
}

TEST_CASE("Lox::VarDefault") {
	ZoneScopedN("Lox::VarDefault");
	doir::ParseModule module("var x = 5;");
	lox::parse p;
	auto root = module.get_attribute<lox::components::Block>(p.start(module))->children[0];
	CHECK(get_key<lox::components::VariableDeclaire>(module.get_hashtable_attribute<lox::components::VariableDeclaire>(root)).name.view(module.buffer) == "x");
	auto target = module.get_attribute<lox::components::Operation>(root)->left;
	CHECK(*module.get_attribute<double>(target) == 5);

	auto& hashtable = *module.get_hashtable<lox::components::VariableDeclaire>();
	CHECK(*hashtable.find({{module.buffer.find("x"), 1}, 1}) == root);
	FrameMark;
}

TEST_CASE("Lox::Fun") {
	ZoneScopedN("Lox::Fun");
	doir::ParseModule module("fun f(x, y) { return x; }");
	lox::parse p;
	auto root = module.get_attribute<lox::components::Block>(p.start(module))->children[0];
	CHECK(get_key<lox::components::FunctionDeclaire>(module.get_hashtable_attribute<lox::components::FunctionDeclaire>(root)).name.view(module.buffer) == "f");
	{
		auto& params = *module.get_attribute<lox::components::Parameters>(root);
		CHECK(params.size() == 2);
		CHECK(module.has_hashtable_attribute<lox::components::ParameterDeclaire>(params[0]));
		CHECK(module.get_attribute<doir::Lexeme>(params[0])->view(module.buffer) == "x");
		CHECK(module.has_hashtable_attribute<lox::components::ParameterDeclaire>(params[1]));
		CHECK(module.get_attribute<doir::Lexeme>(params[1])->view(module.buffer) == "y");
	}
	{
		auto body = module.get_attribute<lox::components::Operation>(root)->left;
		auto marker = module.get_attribute<lox::components::Block>(body)->children[0];
		CHECK(module.has_attribute<lox::components::BodyMarker>(marker));
		CHECK(module.get_attribute<lox::components::BodyMarker>(marker)->skipTo == root);
		auto stmt = module.get_attribute<lox::components::Block>(body)->children[1];
		CHECK(module.has_attribute<lox::components::Return>(stmt));
		auto target = module.get_attribute<lox::components::Operation>(stmt)->left;
		CHECK(module.has_attribute<lox::components::Variable>(target));
		CHECK(module.get_attribute<doir::TokenReference>(target)->lexeme().view(module.buffer) == "x");
	}

	auto& hashtable = *module.get_hashtable<lox::components::FunctionDeclaire>();
	CHECK(*hashtable.find({{module.buffer.find("f"), 1}, 1}) == root);
	FrameMark;
}

TEST_CASE("Lox::Call") {
	ZoneScopedN("Lox::Call");
	doir::ParseModule module("f(x);");
	lox::parse p;
	auto root = module.get_attribute<lox::components::Block>(p.start(module))->children[0];
	auto& call = *module.get_attribute<lox::components::Call>(root);
	{
		CHECK(module.has_attribute<lox::components::Variable>(call.parent));
		CHECK(module.get_attribute<doir::TokenReference>(call.parent)->lexeme().view(module.buffer) == "f");
	}
	{
		CHECK(call.children.size() == 1);
		CHECK(module.has_attribute<lox::components::Variable>(call.children[0]));
		CHECK(module.get_attribute<doir::TokenReference>(call.children[0])->lexeme().view(module.buffer) == "x");
	}
	FrameMark;
}

TEST_CASE("Lox::Parse") {
	ZoneScopedN("Lox::Parse");
	doir::ParseModule module("f(x);");
	lox::parse p;
	auto root = module.get_attribute<lox::components::Block>(p.start(module))->children[0];
	auto& call = *module.get_attribute<lox::components::Call>(root);
	{
		CHECK(module.has_attribute<lox::components::Variable>(call.parent));
		CHECK(module.get_attribute<doir::TokenReference>(call.parent)->lexeme().view(module.buffer) == "f");
	}
	{
		CHECK(call.children.size() == 1);
		CHECK(module.has_attribute<lox::components::Variable>(call.children[0]));
		CHECK(module.get_attribute<doir::TokenReference>(call.children[0])->lexeme().view(module.buffer) == "x");
	}
	FrameMark;
}