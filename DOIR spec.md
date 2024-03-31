# DOIR Semantics

Important rules:

* Delimiters are required between expressions, either a semicolon or a newline
* Every expression returns a value
* This value must be stored somewhere

```cpp
// name (: type)? = (constant | function call)
%0 : u8* = "f"
%1 : void = print(%0) // void print
```

* `_` is a special name for registers, it is automatically replaced by the next incrementing register

```cpp
%0 : i32 = 0
%1 : i32 = 1
_ = add(%0, %1) // NOTE: _ will be replaced with %2, this also means that trying to read the value stored in _ will result in an identifier not found error
```

* Optional source location information can be added

```cpp
%0 : u8* = "f" <main.c:1:5-6> // <filename:line number:starting column number-ending column number>
%1 : void = print(%0) <1:1> // NOTE: Filename and ending column number are both optional
```

* Constants must be explicitly typed

```cpp
%0 : i15 = 1 // Note: arbitrarily sized integers are allowed
```

* Types can be unioned together
* If it can be proved that unioned types are supersets of eachother they are collapsed to a single type
* If void is included, the type may not have a value and in this case is converted to boolean false

```cpp
%0 : i32 | f32 = 1 // Note: Error since the constant is now ambigiuous
%1 : i1 | i32 = 1 // Note: The type becomes `i32` since i32 is a provable superset of i1
%2 : i32 | void = {} // Note: The default for a union containing void is nothing
```

* Functions can only be called on "registers"
* Functions can be called either as methods or free standing

```cpp
%0 : i32 = 1; %1 : i32 = 2

%2 := %0.add(%1)
// Equivalent to
%3 := add(%0, %1)
// Colons only required before an explicit type
%4 = %0.add(%1)
```

* Pointers are automatically dereferenced one level when passed to functions not expecting pointers

```cpp
%0 : i32* = stack.alloc(i32); %1 : i32 = 1
%2 = %0.add(%1)
%0 = %2 // Note: can be merged into the previous line: %0 = %0.add(%1)
// Equivalent to (when desugared)
%3 : i32 = load(%0)
%4 : i32 = add(%3, %1)
_ : void = store(%0, %4)
```

* Similarly they are automatically dereferenced one level when assigned values

```cpp
%0 = 5
x = stack.alloc(i32)
x = add(%0, %0)
// Equivalent to
x = 10
```

* Functions can have dots (.) in their names, "registers" can not

```cpp
a.b := 0 // Invalid!
b = stack.alloc(i32) // Valid!
%1 = a.b.add(b.c) // interpreted as a.(b.add)
```

* Functions are introduced "the same way" as registers

```cpp
// name : return(args...) = { ... }
foo : void(u8* str) = {
    %0 = print(str)
    %r = return() // Note: Like all other functions `return` returns void and must have its value stored
}
```

* Ifs just like everything else are expressions and their branches must yield (or return) values
* The parameter to an if is of the special type `bool`, bool can be the type of a register or function parameter but nothing else
* When converting numbers to `bool` values of zero and nan are treated as false while anything else is treated as false
* Bools convert to numbers like i1's with false mapping to 0 and true mapping to 1

```cpp
main : i1() = {
    %0 : i1 = true
    %1 : i1 | void = if %0 { // Note: Parenthesis optional, curly braces required
        %2 = yield(%0)
    } else if %0 { // Note: For readibility an if may be provided directly after an else, however this is interpreted (and later displayed) as } else { if X {...} else {...}}
        %3 = false
        %4 = yield(%3)
    } else { // Note: `else` branch required
        %5 = true
        %6 = return(%5)
    }
    %5 = return(%1)
}
```

* Functions can be forced to be always inlined when they are defined

```cpp
foo : void() inline = { %0 = 0; %1 = return(%0); }

// This can be selectively overwritten
%0 = foo() noinline
```

* Functions can also be inlined when they are called

```cpp
%0 : int = 5; %1 : int = 5
%2 = add(%0, %1) inline // Note: May have no effect for unreducable functions
```

* Whenever possible functions are evaluated at compile time, this behavior can be avoided per function or per call

```cpp
foo : void() nocomptime {
    %x = return()
}

%x = foo() nocomptime
```

* Any members stored inside types are reserved space (functions are treated as pointers)
* If a type value is directly passed to a function, that function becomes executable only at compile time
* Type pointers however are passable at runtime (implementations may instead pass them in registers depending on lower level calling conventions)

```cpp
// name (: `type`)? = type { ... }
vec3 : type = type {
    x : f16 // Note: Initial values not required...
    y : f32 = 2 // But supported (TODO: Do we want types to have initial values?)
    z : f64
}

%0 : vec3 = {0, 2, 0}
// Equivalent to
%1 : vec3 = {x: 0, z: 0} // Note: Y can be omitted since it has an initial value

%2 = vec3.stack.alloc() // Note: When allocated initial values are ignored...
%2 = {} // But can be added latter (this vec3 now has the values x = f16 default value (0), y = 2, z = f64 default value (0))
// Equivalent to (when desugared)
%3 : vec3* = stack.alloc(vec3)
%4 : u64 = 0
%5 : f16* = type.member.access.index(%3, %4)
%5 : f16 = type.member.default_value(vec3, %4)
%6 : u64 = 1
%7 : f32* = type.member.access.index(%3, %6)
%7 : f32 = type.member.default_value(vec3, %6)
%8 : u64 = 2
%9 : f64* = type.member.access.index(%3, %8)
%9 : f64 = type.member.default_value(vec3, %8)
```

* Functions can both take and return types
* Functions taking types can not be called at runtime (they must be inlined/optimized away at that point)
* When a function is used in place of a type it is called with angle brackets instead of parenthesis

```cpp
List : type(type T) = {
    %r = type {
        size: i128
        data: T*
    }
    %x = return(%r)
}

%0 = 10
%1 : i32* = i32.heap.alloc.array(%0)
int_list : List<i32> = {%0, %1}
```

* Expressions can be grouped together into blocks which then yield a final value
* "Register" names can shadow (be the same as) "register"s outside the block

```cpp
x = 5
%0 = block {
    %0 : i32 = 5 // Note: Unique from the %0 outside the block
    %1 : i32 = 5
    %2 = subtract(%0, %1)
    %x = yield(%2)
}
```

* Functions can take and return identifiers and blocks
* If the last parameter to a function is a block it can be passed by placing it after the call

```cpp
while : void(block condition, block body) inline = {
    impl : void(block condition, block body) { // Note: Local functions don't "capture" any of their surrounding scope, thus everything relevant must be passed in (the exception is that a function can recursively call itself)!
        %0 = condition.unquote() // Note: if a condition is based on a pointer, the value pointed to may be changeable by the body as a side effect!
        _ = if %0 {
            %0 = body.replace_parameterless_call(break) { // Note: The block following the function is passed as the last argument
                %x = return()
            }
            %1 = %0.replace_parameterless_call(continue) { // Note: `continue` is an identififer
                %res : type = typeof(body)
                %0 : %res = {}
                %x = yield(%0)
            }
            _ = %1.unquote()
            _ = impl()
            %x = return()
        } else {
            %x = return()
        }
        %x = return()
    }
    _ = impl(condition, body) inline // Note: Inlining will cause this statement to be replaced with one level of the loop!
    %x = return()
}

x = i32.stack.alloc()
x = 5
%0 = 0
%1 = while(block {
    %1 = x.greater_equal(%0)
    %x = yield(%1)
}, block {
    %0 = print(x)
    %1 : i32 = 1
    x = add(x, %1)
    %x = yield()
})
// Equivalent to
%2 = while() {
    %1 = x.greater_equal(%0)
    %x = yield(%1)
}{ // Note: More than one block can be chained back to back if they are the last n parameters to the function
    %0 = print(x)
    %1 : i32 = 1
    x = add(x, %1)
    %x = yield()
}
```

* The type arguments to a function may be of type `implicit type` if so it need not be explicitly provided and will be deduced based on its first use (implicit types are required to be grouped at the front of the parameter list)
* Type parameters cam be used in the parameter list after they have been defined
* A parameter can be made varridic by adding ... to its type

```cpp
add.all : auto(implicit type T, T first, T... tail) = {
    %0 : u64 = 0
    %1 = pack.size(tail)
    %2 = %1.greater_equal(%0)
    %x = if %2 { // Note: %2 is known at compile time thus at runtime this if is replaced by whichever branch is appropriate
        %0 = add.all(T, tail) inline // NOTE: tail is automatically expanded // NOTE: Since we know when the function is called how large tail is inlining will unroll into all of the repeated adds
        // %0 = tail; is invalid since tail might be more than one variable
        %1 = first.add(%0)
        %x = return(%0)
    } else {
        %x = return(first)
    }

    %0 : i32 = 3; %1 : i32 = 4; %2 : i32 = 5
    %3 = add.all(%0, %1, %2) nocomptime // Note: We don't need to to provide a type for T since it is implicit (but we could)
    // Without the `nocomptime` %3 would be replaced with %3 : i32 = 12 at compile time
}
```

* Functions can be marked intrinsic, the bodies of these functions are only used for type inference their implementation is expected to be provided somewhere else (most often by the compiler)
* If any intrinsic functions remain after all compilation passes, an error will be displayed for each.
* If the interpretor encounters any intrinsic functions it doesn't have an implementation for, an error will be displayed.

```cpp
// The add instruction is defined as so:
add : auto(implicit type T, T a, T b) intrinsic = {
    %0 : T = {}
    %x = return(%0) // NOTE: We return the default value of T only so that type inference knows to replace `auto` with `T`
}
```

* Functions can be marked as terminating, these functions either never end or don't allow blocks to continue past them (e.x. the `return`` function)

```cpp
// The terminate instruction is defined as so:
terminate : void(int status) terminating intrinsic = {
    %x = return()
}
```

## Async Draft

* Fork expressions evaluate every block provided concurrently (what concurently means is up to the implementaion)
* The result of a fork expression is a pointer to an array holding the values yielded by all the blocks in the sync
* If threads are used by the implementation, the first block of a fork will execute on the thread the fork was issued on (a `fork.detach` in this block will cause a new thread to be spawned and detached)

```cpp
%result : int* = fork {
    %0 = 5
    %x = yield(%0)
} {
    %0 = 6
    %x = yield(%0)
} {
    %0 = 7
    %x = fork.stop(%0) // Acts like a yield but also stops all other syncs
    // %x = sync.stop.yield_all(%0, %0) // The second value defines what is yielded by all other syncs
} {
    %0 = 8
    %x = fork.detach(%0) // Acts like a yield, however instead of stopping the execution of the block it allows it to continue (this code is now lost and will run until finished on its own)
    // NOTE: sync.detach may be treated as a no-op on systems which don't use threads as part of their implementation of fork
}
%idx = 1
%0 : int* = %result.array.extract(%idx) // Returns a pointer pointing to 6 (the result yielded by the second block)
```

* Functions can be marked as transactions, all memory manipulated by a transaction is copied before the manipulation, if the transaction succedes the manipulated values are then copied back
* Success and failure are indicated by associatedly labeled return statements
* If an expression containing a transaction fails it will always be converted to boolean false
* Any functions called by a transaction are implicitly inlined (Is this restriction nessicary?)

```cpp
global = data.alloc(int) // Reserve a global int
foo.transaction : int(int x) transaction = {
    global = x // The value of global is now copied and the copy is changed
    %1 = true
    %x = if %1 {
        %x = return.success(%0) // The value in global gets copied back
    } else {
        %x = return.failure(%1) // The value in our copied global is popped off the stack and lost
    }
}

%0 = 5
%1 = foo.transaction(%0) // TODO: Should the type of %1 be int? int! or something similar?
%2 = if %1 {
    // On success normal rules apply, %1 has type int and it is implicitly converted to a boolean
} else {
    // However on failure %1 always evaluates to boolean false (if a value was returned it is still accessable anywhere not looking for a boolea)
}

## Grammar

The input file is assumed to be UTF-8 encoded. Additional formats may be supported by specific implementations.

Whitespace and comments are ignored en mass except anywhere a terminator can be expected, then newlines are instead treated as terminators (in the main implementation whitespace is examined one character at a time, however this is not explicitly required).

```cpp
top_level = { expression }
expression = identifier [":" [type]] "=" (constant | identifier | block | function_call | if | compound | type_block) terminator
type = type_impl | type "|" type_impl | "(" type ")"
type_impl = ("auto" | "type" | "block" | identifier) { "<" (type | constant) { "," (type | constant) } ">" | "(" ["implicit"] type ["..."] nodot_identifier { "," ["implicit"] type ["..."] nodot_identifier } ")" function_modifiers | "*" }

terminator = source_location (";" | "\n") | (";" | "\n") source_location
source_location = ["<" [filename ":"] decimal_number ":" decimal_number ["-" decimal_number] ">"]

block = "{" { expression } "}"
function_call = identifier "(" { type | compound } ")" function_modifiers { block }
if = "if" (nodot_identifier | "(" nodot_identifier ")") block "else" (block | if)
compound = "block" block
type_block = "type" "{" { nodot_identifier ":" type ["=" constant] terminator } "}"

function_modifiers = { "inline" | "noinline" | "comptime" | "nocomptime" | "intrinsic" | "terminating" }
identifier = nodot_identifier { "." nodot_identifier } // NOTE: Whitespace and comments are not cannonically allowed between identifiers and their dots, implementations may allow it however
constant = number | string | "true" | "false" | ("{" constant { "," constant } "}")
number = binary_number | decimal_number | hexadecimal_number
```

### Terminal Regexs

nodot_identifier = `(%[_0-9a-zA-Z]+)|([_a-zA-Z][_0-9a-zA-Z]*)` (A minimal definition)
nodot_identifier = `%UNICODE_XID_CONTINUE+|(UNICODE_XID_START|_)UNICODE_XID_CONTINUE*`
binary_number = `0[bB]([01]+|[01]+\.|[01]*\.[01]+)([eE][+-]?[01]+)?`
decimal_number = `([0-9]+|[0-9]+\.|[0-9]*\.[0-9]+)([eE][+-]?[0-9]+)?` Note: Any valid octal_number string is also a valid decimal_number string!
hexadecimal_number = `0[xX]([0-9A-F]+|[0-9A-F]+\.|[0-9A-F]*\.[0-9A-F]+)(e[+-]?[0-9A-F]+)?`
string = `"(\\"|[^"])*"`

comment = `(//[^\n]*\n)|(/\*(.*?)\*/)`
whitespace = `[ \t\n\r]+`

filaname = `[^:]+?`
