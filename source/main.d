/// The `doir` executable. For now a hello world that touches each dependency: it builds a root block in the libECRS store through `doir.api.builders`, runs a Mizu program, and reports through libdiagnose.
module main;

static import core.stdc.stdio;

static import fp.string;

static import diagnose;
static import ecrs.context;
static import mizu;

static import doir.api.builders;

/// Builds a root block, runs a Mizu program, and prints its result as a libdiagnose note. Returns 1 if a step fails, 0 otherwise.
extern(C) int main() {
	auto store = ecrs.context.create();
	scope(exit) ecrs.context.free(store);
	auto root = doir.api.builders.createRoot(store);
	if (root.block == doir.api.builders.invalidEntity) return 1;

	static immutable mizu.Opcode[4] program = [
		mizu.setImmediate(mizu.Opcode(&mizu.loadImmediate, mizu.Registers.t(0)), 6),
		mizu.setImmediate(mizu.Opcode(&mizu.loadImmediate, mizu.Registers.t(1)), 7),
		mizu.Opcode(&mizu.multiply, mizu.Registers.a(0), mizu.Registers.t(0), mizu.Registers.t(1)),
		mizu.Opcode(&mizu.halt),
	];
	mizu.RegistersAndStack env;
	mizu.setupEnvironment(env, program[]);
	cast(void) mizu.startFromEnvironment(program[], env);

	diagnose.Manager manager;
	scope(exit) diagnose.free(manager);
	diagnose.Diagnostic hello;
	hello.kind = diagnose.Kind.note;
	hello.message = fp.string.format("hello, world (mizu says 6 * 7 = %d)", cast(int) env.memory[mizu.Registers.a(0)]);
	if (hello.message is null) return 1;
	if (diagnose.push(manager, hello) is null) {
		fp.string.free(hello.message);
		return 1;
	}
	return diagnose.printAll(manager, core.stdc.stdio.stdout) ? 0 : 1;
}
