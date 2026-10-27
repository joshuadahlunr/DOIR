module runner;

static import core.stdc.stdio;

private enum modules = [
	"doir.strings",
	"doir.builders",
	"doir.query",
];

private int runEveryTest() {
	size_t total = 0;

	static foreach (name; modules) {{
		alias mod = mixin("imported!\"" ~ name ~ "\"");
		alias tests = __traits(getUnitTests, mod);
		cast(void) core.stdc.stdio.fprintf(core.stdc.stdio.stderr, "%s (%d tests)\n", name.ptr, cast(int) tests.length);
		static foreach (i, test; tests) {
			cast(void) core.stdc.stdio.fprintf(core.stdc.stdio.stderr, "  [%d] ", cast(int) i);
			test();
			cast(void) core.stdc.stdio.fprintf(core.stdc.stdio.stderr, "ok\n");
			++total;
		}
	}}

	cast(void) core.stdc.stdio.printf("doir: all %d tests passed.\n", cast(int) total);
	return 0;
}

version(DoirCoverage) {
	shared static this() {
		import core.runtime : Runtime, UnitTestResult;
		Runtime.extendedModuleUnitTester = () => UnitTestResult(0, 0, true, false);
	}

	int main() { return runEveryTest(); }
} else
	extern(C) int main() { return runEveryTest(); }
