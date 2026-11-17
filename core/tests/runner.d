/// Runs every module's unittests, which `-betterC` has no built-in runner for, through `fp.testing.runTests`.
/// Progress goes to the unbuffered `stderr`, so a test that hangs or aborts still shows how far the run got.
module runner;

private alias modules = imported!"std.meta".AliasSeq!(
	"doir.core.strings",
	"doir.core.testing",
	"doir.core.syntax.lexer",
	"doir.core.syntax.parser",
	"doir.core.components.ast",
	"doir.core.components.types",
	"doir.core.components.source",
	"doir.core.builders",
	"doir.core.parse",
);

private int runEveryTest() {
	cast(void) imported!"fp.testing".runTests!modules("doir-core");
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
