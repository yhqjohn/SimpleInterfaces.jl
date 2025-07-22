# SimpleInterfaces.jl

A lightweight, non-intrusive interface system for Julia that provides compile-time contract verification for multi-type interactions.

---
## Development Status

This package is currently under active development. The core functionality is stable, and the first stage goals are met. For our next development cycle, we have a detailed, two-tier plan to enhance both runtime flexibility and developer ergonomics. Please see the **Detailed Development Plan** section below for more information.

---

## Philosophy & Design

This interface system treats an interface as a **compile-time verifiable contract** on a **set of types**. The design embraces Julia's multiple dispatch paradigm while providing static verification capabilities. The key principles are:

1.  **Interfaces as Multi-Type Contracts**: An interface can specify requirements across several interacting types (e.g., a container, its elements, and its index type).
2.  **Implicit Implementation**: A set of types implements an interface simply by satisfying its requirements. No explicit `MyType <: MyInterface` is needed.
3.  **Explicit, Zero-Cost Checking**: Verification is done explicitly via macros, but this check happens entirely at compile-time, incurring **zero runtime cost**.

---

## A Comprehensive Example

This example demonstrates the core features of `SimpleInterfaces.jl`. We define a `ReadableCollection` interface for a container `C` that holds elements of type `E` and is indexed by keys of type `I`.

### 1. Defining the Interface

```julia
@interface ReadableCollection C, E, I<:Integer begin
    # 1. Covariant Field Requirement:
    # The container `C` must have a field `data` that is a subtype of
    # `AbstractArray{E, 1}`. An implementation using `Vector{E}` (which is a
    # subtype) will satisfy this.
    C.data::AbstractArray{E, 1}

    # 2. Field Existence Requirement:
    # It must have a field named `metadata` (type not specified).
    C.metadata

    # 3. Method with Covariant Return Type:
    # It must have a `length` method that returns a subtype of `Integer`.
    function Base.length(::C)::Integer end

    # 4. Multi-Type Method Requirement:
    # It must have a `getindex` method for the specific pair (C, I)
    # that returns an element of type `E`.
    function Base.getindex(::C, ::I)::E end
end
```

### 2. Checking the Interface

```julia
using SimpleInterfaces

# A struct that correctly implements the interface
struct MyCollection{T}
    data::Vector{T} # Vector{T} <: AbstractArray{T, 1} (Covariance)
    metadata::Any
end
Base.length(c::MyCollection)::Int = length(c.data) # Int <: Integer (Covariance)
Base.getindex(c::MyCollection{T}, i::Int)::T where {T} = c.data[i]

# This check passes because all constraints are met.
@assertimpls ReadableCollection MyCollection{String}, String, Int

# Alternative: warn but don't throw an error if constraints fail
@warnimpls ReadableCollection MyCollection{String}, String, Int
```

---
## Interface Inheritance & Composition: The `@impls` Macro

Interface composition allows building complex interfaces from simpler ones. The design uses explicit `@impls` declarations within interface definitions, which provides clear semantics and avoids confusion with Julia's type inheritance system.

### Design Rationale

Why not use `<:` syntax for composition? Because composition represents a different semantic relationship. When we write `@interface CanFooBar I, J, K begin ... end`, the types `I, J, K` are the **type composition** that implements the interface, not the interface itself being parameterized. Using `<:` would suggest that `CanFooBar{I, J, K}` is an instance of some parent interface, which is semantically incorrect—the composition `(I, J, K)` itself is what implements `CanFooBar`.

The `@impls` syntax maintains consistency with how we list different forms of requirements within an interface body, making the inheritance relationship explicit and unambiguous.

### Defining a Composite Interface

Let's say we have two simple interfaces, `CanFoo` and `CanBar`:
```julia
@interface CanFoo X, Y begin
    function foo(::X, ::Y)::Bool end
end

@interface CanBar Z begin
    function bar(::Z)::String end
end
```

We can define a new interface, `CanFooBar`, that requires a type composition to satisfy both:
```julia
@interface CanFooBar I, J, K begin
    # This says: "The first two type variables (I, J) of CanFooBar
    # must implement CanFoo."
    @impls CanFoo I, J

    # This says: "The first type variable (I) of CanFooBar must implement CanBar."
    @impls CanBar I

    # CanFooBar can also add its own requirements.
    function baz(::I, ::K)::Int end
end
```
The `@impls` macro maps the type variables of the child interface to the required parent interface. The mapping is positional: `I` maps to `CanFoo`'s `X`, and `J` maps to `Y`.

You can also map concrete types:
```julia
@interface CanFooWithInt J begin
    # This requires that the type composition (J, Int) implements `CanFoo`.
    @impls CanFoo J, Int
end
```

### Checking a Composite Interface

Checking an implementation recursively verifies all requirements from parent interfaces plus the new requirements from the child interface itself:
```julia
@assertimpls CanFooBar MyType, YourType, TheirType
```
The system ensures that if there's a failure, the earliest error in the inheritance chain is reported, helping you pinpoint the root cause quickly.

---

## Interface Verification Macros

SimpleInterfaces.jl provides three macros for interface verification, each with different behavior when constraints are not met:

### `@impls`
Returns a boolean value indicating whether the type composition implements the interface. This is useful for conditional logic:
```julia
if @impls ReadableCollection MyCollection{String}, String, Int
    println("MyCollection implements ReadableCollection")
end
```

### `@assertimpls` 
Throws an `InterfaceImplementationError` if the type composition does not implement the interface. This is useful for enforcing strict contracts:
```julia
@assertimpls ReadableCollection MyCollection{String}, String, Int
# Throws error if not implemented
```

### `@warnimpls`
Emits a compile-time warning if the type composition does not implement the interface, but continues execution. Returns a boolean like `@impls`. This is useful during development or for non-critical interface checks:
```julia
result = @warnimpls ReadableCollection MyCollection{String}, String, Int
# Warns if not implemented but doesn't throw an error
```

All three macros perform the same compile-time verification. The difference lies only in how they handle failures.

---

## Advanced Topic: Covariance and Contravariance

*(This is an advanced topic for users interested in the design details.)*

A key design choice in this library is how we handle subtyping in method requirements. In Julia's type system, function arguments are **contravariant**. This means that if you have a function `f(x::SuperType)`, it can be considered a "subtype" of a more specific function `f(x::SubType)`.

However, for an interface contract, this behavior is often the reverse of what a user expects. If an interface requires a method that can handle *any* `Integer` (`getindex(::C, ::Integer)`), an implementation that only handles `Int` (`getindex(::C, ::Int)`) does **not** fulfill the contract. It is more specific than required, not more general.

This library correctly enforces the user's expectation. If you require a method signature, the implementation must match it or be more general (e.g., implement for `Any` when `Integer` is required).

So, how do you specify "this interface works for any index that is a subtype of `Integer`"? The answer is to make the index type an explicit type variable of the interface, as we did with `I<:Integer`. By passing the concrete type (`Int`) to `@assertimpls`, you are checking for that specific case.

Attempting to automatically "solve" for any possible subtype `I` is not practical:
1.  **Practicality**: It would violate the principle of least surprise, as the library would have to guess which subtypes the user cares about.
2.  **Computability**: It would require solving complex type equations at compile time, which may not even be decidable.

**Conclusion**: For flexibility in a type variable, make it an explicit type variable of the interface.

---
## DSL Syntax Specification

The body of an `@interface` macro supports the following requirement definitions:

```julia
@interface InterfaceName TypeComposition begin
    requirements...
end
```
where:
- `InterfaceName` is the name of the interface, a valid Julia identifier.
- `TypeComposition` is a single `TypeVariable` or a tuple of `TypeVariable`, indicating the type composition to implement the interface.
  - `TypeVariable := T[<: SuperType]` where `T` is a valid Julia name and `SuperType` is an optional valid supertype that the type must inherit from. `T` serves as a binding name that can be used as a type variable in the interface body (the block between `begin` and `end`).
- `requirements` can be several of the following:
  - `T.fieldName[::FieldType]` to specify type `T` must have a field `fieldName` of type `FieldType`.
    - `T` is a type variable declared in `TypeComposition`.
    - `fieldName` is a valid Julia identifier, the name of the field.
    - `FieldType`(Optional) either a valid Julia type or a type variable declared in `TypeComposition`. **If `FieldType` is omitted, it defaults to `Any`.**
  - `function [modulename.]name(args...[; kwargs...])[::ReturnType] end` to specify a method must be implemented for the type composition given by its signature.
    - `modulename`(Optional) is a valid Julia module name.
    - `name` is a valid Julia identifier, the name of the function.
    - `args` in either one of the following forms:
      - `argname::TypeName` to specify a positional argument `argname` of type `TypeName`. `TypeName` can be either a valid Julia type or a type variable declared in `TypeComposition`.
      - `::TypeName` to specify a positional argument of type `TypeName`.
      - `argname` to specify a positional argument of type `Any`.
    - `kwargs`(Optional) in either one of the following forms:
      - `argname[::TypeName][=default]` to specify a keyword argument `argname` of type `TypeName` with a default value `default`. `TypeName` and `default` do not take effect up to Julia 1.11.
    - `ReturnType`(Optional) either a valid Julia type or a type variable declared in `TypeComposition`. **If `ReturnType` is omitted, it defaults to `Any`.**
  - `@impls ParentInterfaceName TypeComposition` to specify that the type composition must implement the interface `ParentInterfaceName`.
    - `ParentInterfaceName` is the name of the interface to implement.
    - `TypeComposition` is a tuple of concrete types or type variables declared in the interface's `TypeComposition`.

---
## Keyword Arguments: A Note on Dispatch

A crucial design decision in this library is how to handle keyword arguments (kwargs). Our philosophy is to align with Julia's own method dispatch system, not to create a new, stricter one.

In Julia, `hasmethod` checks if a method exists that can be *called* with a given set of arguments. For kwargs, this has a specific consequence: a method is considered implemented even if some of its non-defaulted kwargs are not provided in the call. Julia only raises a runtime `UndefKeywordError` when the method is actually executed, not during method lookup.

For example, if an interface requires `f(x; mandatory_kw)`, an implementation `f(x; mandatory_kw, optional_kw=1)` is considered valid by `hasmethod`, and therefore by `SimpleInterfaces.jl`. Likewise, an implementation `f(x)` is considered to satisfy a requirement for `f(x; optional_kw=1)`.

**Our Guarantee**: We verify that a method signature *exists* according to Julia's dispatch rules. We do not (and cannot reliably) perform static analysis to prevent potential runtime `UndefKeywordError` or `TypeError` from misuse of kwargs.

**Recommendation**: Due to this inherent limitation in Julia's dispatch system, we advise against using keyword arguments for critical type contracts. For strict type enforcement, prefer positional arguments.

---
## A Note on Return Type Inference
Julia's `Base.return_types` does not always infer the narrowest possible type. If you encounter a false-negative on a return type check, please ensure your implementation of the function has an **explicit return type annotation** (e.g., `function my_func(...)::Int`). This greatly helps the type inference system and ensures your contracts are checked correctly.    
---
## Detailed Development Plan: The Recommended API

The core philosophy of "satisfying a contract implies implementation" is powerful. However, this implicit model is best suited for static, compile-time checks with concrete types. To provide a more robust and universal solution, especially for use inside generic functions, we are introducing a new, **recommended API** based on explicit implementation marking.

The existing `@impls`, `@assertimpls`, and `@warnimpls` macros remain part of the library. They are perfectly valid for their original purpose: performing one-off, compile-time-only checks. However, for most users, especially those writing generic libraries, the new API will be the preferred choice. This ensures that even early users are not alienated; their code still works, but a better path forward is now offered.

### The Recommended API: Zero-Cost Checks for Generic Code

This new system is designed for zero-cost checks inside generic functions, a cornerstone of high-performance programming in Julia. It consists of three main components.

**1. The `ImplState` Hierarchy (The Trait Types)**

We will introduce a type hierarchy to represent the implementation status. This provides a robust foundation for dispatch.

```julia
# An abstract type to represent implementation status
abstract type ImplState end

# A concrete type indicating that an implementation has been verified
struct ImplVerified <: ImplState end

# A concrete type indicating that an implementation is not known/registered
struct ImplUnknown <: ImplState end

# For convenience, allow these types to be used in boolean contexts
Base.convert(::Type{Bool}, ::ImplVerified) = true
Base.convert(::Type{Bool}, ::ImplUnknown) = false
```

**2. The `ImplState` Trait Functionality**

Following Julia's idiomatic "Holy Trait" pattern, we add methods to the `ImplState` abstract type, allowing it to be used directly as the trait function.

```julia
# By adding methods to the abstract type, it can be called like a function.
# This is a common pattern for traits in Julia.
# By default, the implementation state for any type is unknown.
ImplState(::Type, ::Type{<:SimpleInterface}) = ImplUnknown()
```

**3. The `@implement` Macro (The User-Facing Tool)**

This new top-level macro is the primary entry point for the recommended API. When a user declares `@implement CanFoo MyType`, it performs two critical actions:
-   **Compile-Time Verification**: It first runs the same logic as `@assertimpls` to guarantee the type composition satisfies the interface contract. An error is thrown at compile time if the contract is violated.
-   **Trait Generation**: Upon successful verification, it emits the trait specialization that powers runtime checks:
    ```julia
    # This method is generated by @implement CanFoo MyType
    SimpleInterfaces.ImplState(::Type{MyType}, ::Type{CanFoo}) = ImplVerified()
    ```

**Putting It All Together: Zero-Cost Generic Programming**

This system allows for highly efficient, generic code:
```julia
function generic_function(x::T) where T
    # We call the ImplState type directly to get the trait status.
    # Thanks to Base.convert, the result can be used in a boolean context.
    if ImplState(T, CanFoo)
        println("`$(T)` is a verified implementation of `CanFoo`!")
        # We can now confidently use the interface methods
    else
        println("`$(T)` is not a known implementation of `CanFoo`.")
    end
end
```
When Julia's compiler specializes (or "monomorphizes") this function for a call with `MyType`, it resolves `ImplState(MyType, CanFoo)` to the constant `ImplVerified()`. This allows the compiler to eliminate the conditional and the `else` branch entirely (dead-code elimination). The cost of this check is paid once during this compilation step, resulting in code that has **zero cost at runtime**.

### Future Goal: Default Method Implementations

The `@implement` macro is the natural and sole mechanism for activating default method implementations provided by an interface. This creates a clear and powerful workflow: developers fulfill the minimal required contract, and `@implement` handles the rest, from trait registration to providing useful default functionality.

**Proposed Syntax**: We will extend the `@interface` macro to accept methods with full bodies. These default methods can be defined in terms of other methods or fields required by the same interface contract.

**Example**:
```julia
@interface IndexedCollection C, E, I begin
    # Core contract: Every implementation MUST provide these.
    function Base.getindex(::C, ::I)::E end
    function Base.length(::C)::Integer end

    # Default implementation, defined in terms of the core contract.
    function Base.firstindex(c::C)
        if length(c) == 0
            throw(BoundsError(c, 1))
        end
        return 1 # Assuming 1-based indexing for this example
    end
end

struct MySimpleArray{T}
    data::Vector{T}
end

# User only needs to implement the core contract.
Base.getindex(c::MySimpleArray{T}, i::Int) where T = c.data[i]
Base.length(c::MySimpleArray) = length(c.data)

# This single declaration will do it all:
# 1. Verify that MySimpleArray implements getindex and length.
# 2. Emit the Holy Trait for ImplState.
# 3. Define `Base.firstindex(c::MySimpleArray)` automatically.
@implement IndexedCollection MySimpleArray{String}, String, Int
```

**Conflict Resolution**: The `@implement` macro will be designed to be non-intrusive. If a user has already provided their own specific implementation for a default method (e.g., a more optimized `firstindex`), `@implement` will detect this using `hasmethod` and will **not** generate the default version, thereby respecting the user's specialization.
