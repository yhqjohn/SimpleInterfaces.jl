# SimpleInterfaces.jl

A lightweight, non-intrusive interface system for Julia, born from a deep reflection on the language's core principles.

---
## Development Status (Current Work)

This package is currently under active development. The core functionality is stable, but some advanced features are still being worked on.

#### Completed & Stable:
- **Core Functionality**: Compile-time checking of fields and methods.
- **Runtime Metaprogramming**: Generation of abstract types for interfaces (e.g., `abstract type MyInterface{T} end`) and a runtime check function (`impls`).

#### Work in Progress / Known Issues:
- **Keyword Argument (kwargs) Support**: Implementation is currently blocked by a persistent `UndefVarError` in the test environment, likely related to macro expansion and evaluation scopes. This feature is temporarily disabled.
- **Interface Inheritance**: The implementation of interface inheritance (`@interface B <: A`) has proven to be highly complex due to the intricacies of recursive type-parameter substitution in Julia's metaprogramming system. This feature is not yet available.

---

## Philosophy & Design

Our core philosophy is that an interface is a **compile-time verifiable contract** on a **set of types**. This approach avoids the pitfalls of OOP-style inheritance in a multiple-dispatch world and embraces Julia's dynamic nature without sacrificing runtime performance. The key principles are:

1.  **Interfaces as Multi-Type Contracts**: An interface can specify requirements across several interacting types (e.g., a container, its elements, and its index type).
2.  **Implicit Implementation**: A set of types implements an interface simply by satisfying its requirements. No explicit `MyType <: MyInterface` is needed.
3.  **Explicit, Zero-Cost Checking**: Verification is done explicitly via macros, but this check happens entirely at compile-time, incurring **zero runtime cost**.

---

## A Comprehensive Example

This example showcases all features of `SimpleInterfaces.jl`. We define a `ReadableCollection` interface for a container `C` that holds elements of type `E` and is indexed by keys of type `I`.

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
using Test

# A struct that correctly implements the interface
struct MyCollection{T}
    data::Vector{T} # Vector{T} <: AbstractArray{T, 1} (Covariance)
    metadata::Any
end
Base.length(c::MyCollection)::Int = length(c.data) # Int <: Integer (Covariance)
Base.getindex(c::MyCollection{T}, i::Int)::T where {T} = c.data[i]

# This check passes because all constraints are met.
@assertimpls MyCollection{String}, String, Int, ReadableCollection
```

---

## Advanced Topic: Covariance and Contravariance

*(This is an advanced topic for users interested in the design details.)*

A key design choice in this library is how we handle subtyping in method requirements. In Julia's type system, function arguments are **contravariant**. This means that if you have a function `f(x::SuperType)`, it can be considered a "subtype" of a more specific function `f(x::SubType)`.

However, for an interface contract, this behavior is often the reverse of what a user expects. If an interface requires a method that can handle *any* `Integer` (`getindex(::C, ::Integer)`), an implementation that only handles `Int` (`getindex(::C, ::Int)`) does **not** fulfill the contract. It is more specific than required, not more general.

This library correctly enforces the user's expectation. If you require a method signature, the implementation must match it or be more general (e.g., implement for `Any` when `Integer` is required).

So, how do you specify "this interface works for any index that is a subtype of `Integer`"? The answer is to make the index type an explicit parameter of the interface, as we did with `I<:Integer`. By passing the concrete type (`Int`) to `@assertimpls`, you are checking for that specific case.

Attempting to automatically "solve" for any possible subtype `I` is not practical:
1.  **Practicality**: It would violate the principle of least surprise, as the library would have to guess which subtypes the user cares about.
2.  **Computability**: It would require solving complex type equations at compile time, which may not even be decidable.

**Conclusion**: For flexibility in a parameter, make it an explicit type parameter of the interface.

---
## DSL Syntax Specification

The body of an `@interface` macro supports the following requirement definitions:

```julia
@interface InterfaceName [<: {SuperInterface, ...}] TypeDeclarations... begin
    fieldDeclarations
    methodDeclarations
end
```
where:
- `InterfaceName` is the name of the interface, a valid Julia identifier.
- `SuperInterface` (Optional) is a super-interface declaration in the format `SuperInterfaceName{TypeParams...}`. Multiple super-interfaces can be provided in a tuple, e.g., `{Super1{T}, Super2{E}}`. The current interface will inherit all requirements from its super-interfaces.
- `TypeDeclarations := TypeName [<: SuperType]`
  - `TypeName` is a valid Julia type name.
  - `SuperType` is an optional valid supertype that the type must inherit from.
- `fieldDeclarations` can be several of the following:
  - `TypeName.fieldName[::FieldType]` to specify a field with a type. where:
    - `TypeName` is a type declared in `TypeDeclarations`.
    - `fieldName` is a valid Julia identifier.
    - `FieldType`(Optioanl) either a valid Julia type or a type parameter declared in `TypeDeclarations`.
- `methodDeclarations` can be several valid Julia method definition that start with `function` and has no body. **Keyword arguments** in method signatures are checked for existence by name, but not by type, consistent with `hasmethod`.

---
## Runtime Utilities and Abstract Types

To bridge the gap between compile-time checks and runtime polymorphism, `SimpleInterfaces.jl` will provide:

1.  **Abstract Supertype**: A new abstract type, `abstract type SimpleInterface end`, is available and exported.
2.  **Generated Interface Types**: For each `@interface Foo T`, a corresponding `abstract type Foo{T} <: SimpleInterface end` is automatically generated and can be used for dispatch.
3.  **Runtime Check Function**: A function `impls(MyType, :MyInterface)` is available for dynamic, runtime verification. *Note: This will have a runtime cost.*

These features will allow for more idiomatic Julia dispatch patterns, e.g., `function my_func(obj::MyInterface)`.

---
## A Note on Return Type Inference
Julia's `Base.return_types` does not always infer the narrowest possible type. If youencounter a false-negative on a return type check, please ensure your implementation of the function has an **explicit return type annotation** (e.g., `function my_func(...)::Int`). This greatly helps the type inference system and ensures your contracts are checked correctly.    