
// Every line represents assignment to a virtual register and can take one of six forms:
%1 : i32 = 5 // #1 Constant assignment (name : type = value)
%2 : block = { // #2 Block assignment (%2 stores "quoted" information about the contents of the block)
	%1 : i32 = 6
	_ : _ = yield(%1) // #3 Function execution (_ in a name will use the next numbered register, _ in a type will request inference)
}
%3 : alias = %2 // #4 Alias assignment (%3 is resolved to %2)
math : namespace = { // #5 Namespace assignment (note that registers can be named not just numbered)
	vec2 : type = type { // #6 Type assignment
		x : f32
		y : f32
	}
}

%4 : f32 = 0.0 <main.cpp:32:1-8> // Assignments may optionally be followed by source location information <(filename:)?line:column_start(-column_end)?>
// Types can be used as functions with a parameter for each of their fields
vector : math.vec2 = math.vec2(%4, %4) // namespaces prepend their name to all registers inside of them (mangling rules depend on the currently loaded mangler)

// Functions can take register names (as above) and blocks
%5 : i32 = execute({
	%1 : i32 = 6
	_ : _ = yield(%1) // The yield function indicates the value a block should "return" when it is executed
}) // equivalent to execute(%2)
%6 : i32 = add(%1, %5) // Note: constants must be stored in a register first thus add(5, 6) is invalid

// Functions are created in the same way as a block, however their type is return(args...)
ppchar : type = pointer(pointer(i8))
%7 : void(_ : i32, _ : ppchar) = {
	_ : _ = printf("%g", %6) // Functions can "capture" registers in their parent scope
	_ : _ = return() // Functions must end with a call to a terminator function such as return or exit
}
main : alias = %7 // Functions can be anonymous as %7 or can be given names, additionally anonymous functions can have names aliased to them later

// Control flow is done via functions
%8 : i1 = true
%9 : f32 = if(%8, { // if(condition, true block, false block)
	%1 : f32 = 5.0; _ : _ = yield(%1) // Multiple assignments can be on a single line if separated with a semicolon
}, { _ : _ = yield(%4) })

// Functions can be forcibly inlined
%10 : f32 = inline add(%4, %4)
// It can also be applied to the function type
inline_add_t : type = function.forcibly_inline(i32(i32, i32))
auto_inlined_add : inline_add_t

// Functions can alternatively require tail-call optimization be applied
%11 : f32 = tail add(%4, %4) // NOTE: Functions will be automatically tail-call optimized whenever they can be, this just throws an error diagnostic if this call can't

// Functions can have their Application Binary Interface (ABI) name changed
pchar : type = pointer(i8)
%11 : pchar = "some_mangled_add\0"
_ : _ = function.abi_rename(add, pchar)

// Function parameters can be marked as comptime, they will not be present in the ABI of the resulting function
// Additionally, their names may be mangled based on the currently loaded mangler
comp_pow : void(mantissa : comptime i32, base : i32) = {
	pi32 : type = pointer(i32)
	x : pi32 = stack.allocate(i32) // A pointer to stack memory can be allocated
	%1 : i32 = 0
	%2 : i32 = pointer.load(x) // Values can be loaded from pointers
	%3 : i32 = subtract(%2, %1)
	%4 : void = pointer.store(x, %3) // Values can be stored in pointers
	// Registers are all single static assignment... thus there is no concept of const in the language
	// However pointers can be marked as immutable which will throw an error diagnostic if a value is then stored in them
	const_pi32 : type = immutable(pointer(i32))
	%5 : const_pi32 = cast(x)
	%6 : void = pointer.store(%5, %3) // Error!

	_ : _ = return()
}

// Some types such as `type` or `block` are implicitly comptime
my_add: T(T : type, a : T, b : T) = { ... }

// Types don't have to be explicitly defined when calling a function they can be deduced
my_promote: Tret(Tret : deduce type, T : deduce type, value : T) = { ... } // Note: the return type of the function can also be deduced
%12 : i32 = my_promote(%4) // Tret = i32, T = f32

// DOIR types are structural, if they have the same layout they will implicitly convert
// This can be disabled by making a unique type
list : type(T : type) = {
	pself : type = pointer(type.self) // type.self is a special type that refers to the current type (P.S. How am I gonna implement this magic?)
	out : _ = type {
		value : T
		next : pself
	}
	_ : _ = return(out)
}
int_list : type = list(i32)
%13 : _ = bss.allocate(int_list)
unique_int_list : type = unique(list(i32))
%14 : int_list = pointer.load(%13) // Perfectly fine
%15 : unique_int_list = pointer.load(%13) // Error!
%16 : unique_int_list = cast(%14) // Perfectly fine


// --------------------------------------------------------------------------------------------------------------------------------
// PEG Grammar
// --------------------------------------------------------------------------------------------------------------------------------
// TitleCase productions need whitespace handling (- or wsc) after them when they are used... snake_case productions handle whitespace themselves
program <- - assignment*
assignment <- Identifier- ':'- Type- '='- (Constant wsc / Block wsc / type_block / function_call) (SourceInfo wsc)? Terminator-

deducible_type <- Type wsc / 'deduced'- 'type'wsc
identifier_type_pair <- Identifier- ':'- deducible_type
FunctionType <- Identifier- '('- (identifier_type_pair ','-)* ')'
Type <- ('comptime'-)? ('alias' / 'block' / 'namespace' / 'type' / FunctionType / Identifier)

Block <- '{'- assignment* '}'
type_block <- 'type'- '{'- (identifier_type_pair Terminator-)* '}'wsc
function_call <- ('inline'-/'tail'-)? Identifier- '('- (FunctionType- / Identifier- / Block-)* ')'wsc

Terminator <- ';' / '\n' / '\n\r'
Identifier <- !Keywords [%a-zA-Z_][a-zA-Z0-9_.]*
Keywords <- 'alias' / 'block' / 'comptime' / 'deduced' / 'inline' / 'namespace' / 'tail' / 'type'
SourceInfo <- '<' ((!':' .)* ':')? IntegerConstant ('-' IntegerConstant)? ':' IntegerConstant ('-' IntegerConstant)? '>'

Constant <- FloatConstant / IntegerConstant / ('"' StringChar* '"') / ('\'' StringChar '\'')
IntegerConstant <- (([1-9][0-9]*) / ('0x' HexDigit+) / ('0b' [01]*) / ('0' [0-7]*))
FloatConstant <- (([0-9]* '.' [0-9]+ / [0-9]+ '.'?) ([eE][+\-]? [0-9]+)? )
	/ ('0x' (HexDigit* '.' HexDigit+ / HexDigit+ '.'?) ([pP][+\-]? [0-9]+)?)
StringChar <- (!['"\n\\] .) / ('\\' ['\"?\\%abfnrtv]) / ('\\' [0-7]+) / ('\\x' HexDigit+) / ('\\u' HexDigit HexDigit HexDigit HexDigit)
HexDigit <- [a-fA-F0-9]

- <- ([ \n\r\t] / LongComment / LineComment)*
wsc <- ([ \t] / LongComment / LineComment)*
LongComment <- '/*' (!'*/'.)* '*/'
LineComment <- '//' (!'\n' .)*
