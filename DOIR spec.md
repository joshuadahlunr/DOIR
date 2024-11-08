# DOIR Semantics

Important rules:

* Delimiters are required between expressions, either a semicolon or a newline
* Every expression returns a value
* This value must be stored somewhere (these locations are called registers)

```cpp
// register_name (: type)? = (constant | function call)
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

* Optional documentation can be prefixed to every expression
* This documentation is maintained as a queryable attribute

```cpp
/**
 * @note documentation is introduced with /** and terminated with * / (these do not nest)
 * @brief sections are identified with @<name>
 */
%0 : i32 = 0
```

* Constants must be explicitly typed

```cpp
%0 : i15 = 1 // NOTE: arbitrarily sized integers are allowed
%1 : usize = 5 // NOTE: pointer sized integers are also available
```

* Types can be unioned together
* If it can be proved that unioned types are supersets of eachother they are collapsed to a single type
* If void is included, the type may not have a value and in this case is converted to boolean false

```cpp
%0 : i32 | f32 = 1 // NOTE: Error since the constant is now ambigiuous
%1 : i1 | i32 = 1 // NOTE: The type becomes `i32` since i32 is a provable superset of i1
%2 : i32 | void = {} // NOTE: The default for a union containing void is nothing
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
%0 = %2 // NOTE: can be merged into the previous line: %0 = %0.add(%1)
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

* Fat pointers (indicated by wrapping a pointer in []) are returned by some core functions and represent arrays
* A fat pointer is prefixed with a header containing a magic byte (0xFE), followed by the usize length of the array, followed by the array data, followed by the null byte (0x00)
* When a fat pointer is passed to an argument expecting a usize, it will implicitly convert to the length of the array
* Fat pointers can be treated as normal pointers that point to the same type

```cpp
foo : void(u8* p, usize size) = {
    //...
}

%0 : usize = 5
x : u32[*] = stack.alloc.array(u32, %0) // NOTE: [*] indicates that a pointer is fat
_ = foo(x, x)
// Desugars to
%1 : usize = array.length(x)
_ : void = foo(x, %1)
```

* Constant pointers (indicated by appending `constant` or `const` to a pointer) will cause a compilation error if a value is ever stored in the pointer
* If you ever pass a constant pointer to a function expecting a pointer, the pointer will be treated as a constant pointer inside that function.
* It is an error to annotate a function parameter as a constant pointer

```cpp
%0 : u32*const = {}
%1 : usize = 5
x : u32[*]const = data.readonly.alloc.array(u32, %0, %1) // NOTE: Fat pointers can also be constant
%2 : usize = 1
x1 : u32*const = x.array.element(%2)
x1 = %2 // Error: Desugars to a store
foo : void(u32*const p) = { /*...*/ } // Error: Can't explicit mark function parameters as const
_ = foo(x1) 
```

* Functions are introduced "the same way" as registers but with an additional list of parameters
* Parameters support either `type` `name` declaration or `name` `:` `type` declaration

```cpp
// name : return(args...) = { ... }
foo : void(u8* str) = {
    %0 = print(str)
    %r = return() // NOTE: Like all other functions `return` returns void and must have its value stored
}
// Equivalent to
foo : void(str : u8*) = {
    %0 = print(str)
    %r = return() // NOTE: Like all other functions `return` returns void and must have its value stored
}
```

* Functions can have dots (.) in their names, "registers" can not

```cpp
a.b := 0 // Invalid!
b = stack.alloc(i32) // Valid!
%1 = a.b.add(b.c) // interpreted as a.(b.add)
```

* Functions may have their bodys' replaced with `extern` indicating that their code can be found in another module.
* If extern functions remain after compilation has finished, their calls will be converted to dynamic/shared function lookups.

```cpp
external_foo : void(u8* str) = extern;
```

* Ifs just like everything else are expressions and their branches must yield (or return) values
* The parameter to an if is of the special type `bool`, bool can be the type of a register or function parameter but nothing else
* When converting numbers to `bool` values of zero and nan are treated as false while anything else is treated as false
* Bools convert to numbers like u1's with false mapping to 0 and true mapping to 1

```cpp
main : u1() = {
    %0 : u1 = true
    %1 : u1 | void = if %0 { // NOTE: Parenthesis optional, curly braces required
        %2 = yield(%0)
    } else if %0 { // NOTE: For readability an if may be provided directly after an else, however this is interpreted (and later displayed) as } else { if X {...} else {...}}
        %3 = false
        %4 = yield(%3)
    } else { // NOTE: `else` branch required
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
%2 = add(%0, %1) inline // NOTE: May have no effect for unreducable functions
```

* Whenever possible functions are evaluated at compile time, this behavior can be avoided per function or per call

```cpp
foo : void() nocomptime {
    %x = return()
}

%x = foo() nocomptime
```

* Function parameters can be marked as comptime
* This requires them to have a compile time known value and any comptime parameters are optimized out of the runtime interface

```cpp
baked_add : i32(comptime i32 a, b: comptime i32) {
    %0 = add(a, b)
    _ = return(%0)
}

%0 : i32 = 5; %1 : i32 = 6
%2 : i32 = read_integer_from_user_somehow() // NOTE: not an available function
%3 = baked_add(%0, %1) // Fine... will get replaced with the constant 11
%4 = baked_add(%0, %2) // Error: The value stored in %2 isn't known at compile time!

```

* Any members stored inside types are reserved space (functions are treated as pointers)
* If a type value is directly passed to a function, that function becomes executable only at compile time
* Type pointers however are passable at runtime (implementations may instead pass them in registers depending on lower level calling conventions)

```cpp
// name (: `type`)? = type { ... }
vec3 : type = type {
    x : f16 // NOTE: Initial values not required...
    y : f32 = 2 // But supported (TODO: Do we want types to have initial values?)
    z : f64
}

%0 : vec3 = {0, 2, 0}
// Equivalent to
%1 : vec3 = {x: 0, z: 0} // NOTE: Y can be omitted since it has an initial value

%2 = vec3.stack.alloc() // NOTE: When allocated initial values are ignored...
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
* Type parameters are implicitly declared comptime and similarly must be known at compile time and will not be present in the runtime interface
* Type parameters can be used as the return type of a function
* When a function is used in place of a type it is called with angle brackets instead of parenthesis

```cpp
List : type(type T) = {
    %r = type {
        size: usize
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
    %0 : i32 = 5 // NOTE: Unique from the %0 outside the block
    %1 : i32 = 5
    %2 = subtract(%0, %1)
    %x = yield(%2)
}
```

* Functions can take and return identifiers and blocks
* Both identifier and block parameters are accepted via the `block` type if an identifier is passed to a block parameter it becomes wrapped in a block which simply yields that identifier
* Identifier/block parameters are implicitly declared comptime and similarly must be known at compile time and will not be present in the runtime interface
* If the last parameters to a function are blocks, they can be passed by placing them after the call

```cpp
while : void(block condition, block body) inline = {
    impl : void(block condition, block body) { // NOTE: Local functions don't "capture" any of their surrounding scope, thus everything relevant must be passed in (the exception is that a function can recursively call itself)!
        %0 = condition.block.unquote() // NOTE: if a condition is based on a pointer, the value pointed to may be changeable by the body as a side effect!
        _ = if %0 {
            %0 = body.replace_parameterless_call(break) { // NOTE: The block following the function is passed as the last argument
                %x = return()
            }
            %1 = %0.replace_parameterless_call(continue) { // NOTE: `continue` is an identififer
                %res : type = typeof(body)
                %0 : %res = {}
                %x = yield(%0)
            }
            _ = %1.block.unquote()
            _ = impl()
            %x = return()
        } else {
            %x = return()
        }
        %x = return()
    }
    _ = impl(condition, body) inline // NOTE: Inlining will cause this statement to be replaced with one level of the loop!
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
}{ // NOTE: More than one block can be chained back to back if they are the last n parameters to the function
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
    %x = if %2 { // NOTE: %2 is known at compile time thus at runtime this if is replaced by whichever branch is appropriate
        %0 = add.all(T, tail) inline // NOTE: tail is automatically expanded // NOTE: Since we know when the function is called how large tail is inlining will unroll into all of the repeated adds
        // %0 = tail; is invalid since tail might be more than one variable
        %1 = first.add(%0)
        %x = return(%0)
    } else {
        %x = return(first)
    }

    %0 : i32 = 3; %1 : i32 = 4; %2 : i32 = 5
    %3 = add.all(%0, %1, %2) nocomptime // NOTE: We don't need to to provide a type for T since it is implicit (but we could)
    // Without the `nocomptime` %3 would be replaced with %3 : i32 = 12 at compile time
}
```

* Functions can be marked as terminating, these functions either never end or don't allow blocks to continue past them (e.x. the `return`` function)

```cpp
// The terminate instruction is defined as so:
terminate : void(int status) terminating = {
    %x = return()
}
```

## Async Draft

* Fork expressions evaluate every block provided concurrently (what concurrently means is up to the implementation)
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

* Functions can be marked as transactions, all memory manipulated by a transaction is copied before the manipulation, if the transaction succeeds the manipulated values are then copied back
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
    // However on failure %1 always evaluates to boolean false (if a value was returned it is still accessible anywhere not looking for a boolea)
}

## Low Level Draft

* Assembly languages are expected to begin with a function `target.name` that returns a string (canoncically allocated in rodata)

```cpp
target.name : u8*() = {
    %0 : u8* = "rv32"
    _ = return(%0)
}
```

* Assembly languages then look for a function called `register.types` which returns void
* It is expected that a series of calls to `register.type.add` will be invoked inside of this function
* Providing `offset` or `immediate` as a type name will result in an error

```cpp
register.types : void() = {
    %0 : u8* = "integer" // String literals are allocated in rodata
    %1 = register.type.add(%0) // register.type.add takes a string and returns void
    %2 : u8* = "floating"
    %3 = register.type.add(%2)
    _ = return()
}
```

* Assembly languages then look for a function `instructions` which repeatedly calls `instruction.add` with a string name and list of classes
* All of the classes defined in `register.types` are available, prefixed with the result of `target.name`
* `offset` and `immediate` are valid types in addition to the types provided above

```cpp
instructions : u8**() = {
    %0 : u8* = "sw"
    %1 = instruction.add(%0, rv32.integer, offset, rv32.integer) // NOTE: the types are usable like types in regular functions

    %2 : u8* = "add"
    %3 = instruction.add.return(%2, rv32.integer, rv32.integer, rv32.integer)  // NOTE: the .return variant treats the first type as a return type meaning that `x0 = add(x1, x2)` will be treated the same as `_ = add(x0, x1, x2)`

    %4 : u8* = "mv.i.i"
    %5 : u8* = "mv"
    %5 = instruction.add.override.return(%4, %5, rv32.integer, rv32.integer) // .override and .override.return expect a unique name followed by a name to be emitted (in case the same instruction can be used with multiple register types)
    //...
    _ = return()
}
```

* Assembly languages then look for a function `registers` which repeatedly calls `register.add` with a string name and a register type

```cpp
registers : void() = {
    %4 : u8* = "s0"
    %5 = register.add(%4, rv32.integer) // NOTE: unlike the previous steps functions which return void, register.add returns a u64
    %6 : u8* = "x8"
    %7 = register.add.alias(%5, %6) // This allows for multiple names to be assigned to the same register (only the first name registered will show up in output assembly)

    %0 : u8* = "zero"
    %1 : u64 = register.add.reserved(%0, rv32.integer) // The .reserved version indicates that the register shouldn't be used by the automatic register assigner
    %2 : u8* = "x0"
    %3 : u64 = register.add.alias(%1, %2) // No .reserved nessicary for aliases
    //...
    _ = return()
}
```

* When creating assembly languages, functions can be marked as `assembler`s
* Assembler functions have access to assembly.* functions, and are interpreted in two passes: one to place all of the instructions, and one to determine label offsets.
* Assembly languages need to define functions 

// TODO: constant functions

* Assembly languages are then asked for an `if.implementation` function which is provided a register storing the condition, a block for the true case, a block for the false case, and a string which contains a unique value for every if
* They can also optionally provide a `fork.implementation` function (if not provided, one based on instruction interweaving will be used), it is similarly given a block for every block of the fork, and string containing a unique value

```cpp
if.implementation : auto(bool condition, block T, block F, u8* unique) assembler {
    %0 = "if.true."
    %true = string.concat(%0, unique)
    %1 = "if.false."
    %false = string.concat(%1, unique)
    %2 = "if.false.staging."
    %staging = string.concat(%2, unique)
    %3 = "if.end."
    %end = string.concat(%3, unique)

    %4 = block {
        %0 = T.block.return_type()
        %1 = F.block.return_type()
        %2 = type.union(%0, %1)
        $3 = type.floating(%2)
        %4 = if %3 {
            _ = yield(rv32.floating)
        } else {
            _ = yield(rv32.integer)
        }
        _ = yield(%4)
    }
    %r = register.get.return(%4)
    %c : rv32.integer* = condition.register.get()
    Tsize = T.block.instructions.count()

    %5 : u32 = 1048576
    %6 = Tsize.less(%5)
    if %5 {
        %0 = assembly.label.unordered_lookup(%false)
        %1 = assembly.label.offset_from_current_instruction(%0)
        %c = rv32.not(%c)
        %2 = rv32.bgez(%c, %1)

        %3 = assembly.label(%true)
        %4 = T.block.unquote()

        %5 = assembly.label.unordered_lookup.offset(%end)
        %6 = rv32.j(%5)

        %7 = assembly.label(%false)
        %8 = F.block.unquote()

        %9 = assembly.label(%end)
    } else {
        // ...
    }
}

fork.implementation : void(block first, block... rest, u8* unique) assembler {
    //...
}
```

// TODO: Call implementation

* Finally assembly languages are expected to provide implementations for all of the core extern functions
* All of the instructions will be available (prefixed with the language name)
* All of the registers will be available (their types will be the language name prefixed to their class, they can be used the same as pointers in the rest of the language)
* The function `register.get` can be used to get the register associated a type (returns a pointer to the register, there are no implications of this beyond the fact that they behave like pointers in the rest of the language)
* The function `register.get.return` can be used to get the register a return value can be stored in

```cpp
add : auto(implicit type T, T a, T, b) inline assembler = {
    %0 = sizeof(T)
    %1 : u32 = 8
    %2 = %1.less(%2)
    %3 = type.integer(T)
    %4 = %2.and(%3)
    _ = if %4 {
        %a : rv32.integer* = a.register.get()
        %b = b.register.get()
        %r = register.get.return(rv32.integer)

        %0 = type.integer.unsigned(T)
        if %0 {
            s0 = rv32.add(%a, %b) // All of the registers added in `registers` are available (and can be used like pointers)
            %r = rv32.mv.i.i(s0) // All of the instructions in `instructions` are available (prefixed with the result returned from `target.name`)
        } else {
            %r = rv32.addu(%a, %b)
        }
    } else {
        %1 = equal(T, float)
        _ = if %1 {
            //...
        } else {
            //...
        }
    }
    _ = return() // NOTE: Returns are still nessicary!!
}

// The minimal 
subtract : auto(implicit type T, T a, T, b) inline = {
    %0 : u8* = "`subtract` not yet implemented"
    _ = message.error(%0)
}
```

## Grammar

The input file is assumed to be UTF-8 encoded. Additional formats may be supported by specific implementations.

Whitespace and comments are ignored en mass except anywhere a terminator can be expected, then newlines are instead treated as terminators (in the main implementation whitespace is examined one character at a time, however this is not explicitly required).

```cpp
top_level ::= expression*
expression ::= documentation? identifier (":" type?)? "=" (constant | identifier | block | function_call | if | compound | type_block | "external") terminator
type ::= type_impl | (type "|" type_impl) | ("(" type ")")
type_impl ::= ("auto" | "type" | "block" | identifier) ("<" (type | constant) ("," (type | constant))* ">" | "(" (function_parameter ("," function_parameter)*)? ")" function_modifiers | "*" ("const" | "constant")? | "[*]" ("const" | "constant")? )*
function_parameter ::= "implicit"? type "..."? (nodot_identifier | ":" "implicit"? type "..."?) // NOTE: This grammar allows illegal parameter definitions, since if a `:` is present the leading `implicit` and `...` are invalid and the only valid path through type is one which results in a nodot_identifier

terminator ::= source_location? (";" | "\n") source_location?
source_location ::= ("<" (filename ":")? decimal_number ":" decimal_number ("-" decimal_number)? ">")?

block ::= "{" (expression)+ "}"
function_call ::= identifier "(" ((type | compound) ("," (type | compound))* )?  ")" function_modifiers block*
if ::= "if" (nodot_identifier | "(" nodot_identifier ")") block "else" (block | if)
compound ::= "block" block
type_block ::= "type" "{" (documentation? nodot_identifier ":" type ("=" constant)? terminator)* "}"

function_modifiers ::= ("inline" | "noinline" | "comptime" | "nocomptime" | "terminating" | "assembler")*
identifier ::= nodot_identifier ("." nodot_identifier)* // NOTE: Whitespace and comments are not cannonically allowed between identifiers and their dots, implementations may allow it however
constant ::= number | string | "true" | "false" | ("{" (constant ("," constant)* )? "}")
number ::= binary_number | decimal_number | hexadecimal_number | character
```

### Terminal Regexs

nodot_identifier = `(%[_0-9a-zA-Z]+)|([_a-zA-Z][_0-9a-zA-Z]*)` (A minimal definition)
nodot_identifier = `%UNICODE_XID_CONTINUE+|(UNICODE_XID_START|_)UNICODE_XID_CONTINUE*`
binary_number = `0[bB]([01]+|[01]+\.|[01]*\.[01]+)([eE][+-]?[01]+)?`
decimal_number = `([0-9]+|[0-9]+\.|[0-9]*\.[0-9]+)([eE][+-]?[0-9]+)?` NOTE: Any valid octal_number string is also a valid decimal_number string!
hexadecimal_number = `0[xX]([0-9A-F]+|[0-9A-F]+\.|[0-9A-F]*\.[0-9A-F]+)(e[+-]?[0-9A-F]+)?`
string = `"(\\"|[^"])*"`
character = `'(\\'|[^'])'` NOTE: Any single valid UTF-32 character

documentation = `(/\*\*(.*?)\*/)`
comment = `(//[^\n]*\n)|(/\*(.*?)\*/)`
whitespace = `[ \t\n\r]+`

filename = `[^:]+?`
