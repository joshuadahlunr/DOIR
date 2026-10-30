/// Runs every module's unittests, which `-betterC` has no built-in runner for, through `fp.testing.runTests`.
/// Progress goes to the unbuffered `stderr`, so a test that hangs or aborts still shows how far the run got.
module runner;

private alias modules = imported!"std.meta".AliasSeq!(
	"doir.strings",
	"doir.syntax.lexer",
	"doir.syntax.parser",
	"doir.engine.locations",
	"doir.engine.positions",
	"doir.query",
	"doir.engine.logs",
	"doir.components.query",
	"doir.components.ast",
	"doir.components.types",
	"doir.components.levels",
	"doir.components.source",
	"doir.components.effects",
	"doir.components.lowering",
	"doir.builders",
	"doir.effects",
	"doir.imports",
	"doir.source",
	"doir.format",
	"doir.names",
	"doir.checks",
	"doir.schedules",
	"doir.printer",
	"doir.bench",
	"doir.lsp.positions",
	"doir.lsp.tokens",
	"doir.lsp.server",
);

private int runEveryTest() {
	cast(void) imported!"fp.testing".runTests!modules("doir");
	return 0;
}

// `tools/coverage.py` builds this as ordinary D, since `-cov` registers its counters through druntime, which needs druntime's own `main`.
version(DoirCoverage) {
	// Stops druntime running every unittest itself before `main` runs them again.
	shared static this() {
		static import core.runtime;
		core.runtime.Runtime.extendedModuleUnitTester = () => core.runtime.UnitTestResult(0, 0, true, false);
	}

	int main() { return runEveryTest(); }
} else
	extern(C) int main() { return runEveryTest(); }
