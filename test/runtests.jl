# test/runtests.jl
using SimpleInterfaces
using Test

# This test file validates the comprehensive `ReadableCollection` example.

# 1. Define the comprehensive interface from the README
@interface ReadableCollection C, E, I<:Integer begin
    C.data::AbstractArray{E, 1}
    C.metadata
    function Base.length(::C)::Integer end
    function Base.getindex(::C, ::I)::E end
end

# 2. Define types for testing

# A collection that correctly implements the interface
struct GoodCollection{T}
    data::Vector{T} # This is a subtype of AbstractArray{T, 1}
    metadata::String
end
Base.length(c::GoodCollection)::Int = length(c.data) # Int is a subtype of Integer
(Base.getindex(c::GoodCollection{T}, i::Int)::T) where T = c.data[i]

# A collection that fails the typed field check (wrong element type)
struct BadTypedFieldCollection
    data::Vector{Float64}
    metadata::Any
end
Base.length(::BadTypedFieldCollection) = 0
Base.getindex(::BadTypedFieldCollection, ::Int) = 1.0

# A collection that fails the untyped field check (missing `metadata`)
struct BadUntypedFieldCollection{T}
    data::Vector{T}
end
Base.length(::BadUntypedFieldCollection) = 0
Base.getindex(::BadUntypedFieldCollection, ::Int) = 1

# A collection that fails the return type check
struct BadReturnCollection{T}
    data::Vector{T}
    metadata::Any
end
Base.length(c::BadReturnCollection)::Float64 = 1.0 # Not a subtype of Integer
(Base.getindex(c::BadReturnCollection{T}, i::Int)::T) where {T} = c.data[i]


# A collection that correctly implements an interface with kwargs
struct GoodKwargsCollection{T}
    data::Vector{T}
    metadata::Any
end
Base.length(c::GoodKwargsCollection)::Int = length(c.data)
(Base.getindex(c::GoodKwargsCollection{T}, i::Int; default::T)::T) where {T} = get(c.data, i, default)

# An interface that requires a method with a keyword argument
@interface KwargsInterface C, E, I<:Integer begin
    function Base.getindex(::C, ::I; default::E)::E end
end

# A struct that is missing the keyword argument
struct BadKwargsCollection{T}
    data::Vector{T}
    metadata::Any
end
Base.length(c::BadKwargsCollection)::Int = length(c.data)
(Base.getindex(c::BadKwargsCollection{T}, i::Int)::T) where {T} = c.data[i]


module ModuleA
    using SimpleInterfaces
    @interface MyInterface T begin
        T.field_a::Int
    end
    struct FulfillsA
        field_a::Int
    end
    struct FulfillsB
        field_b::String
    end
end

module ModuleB
    using SimpleInterfaces
    @interface MyInterface T begin
        T.field_b::String
    end
    struct FulfillsA
        field_a::Int
    end
    struct FulfillsB
        field_b::String
    end
end

# 3. Write tests
@testset "Final Comprehensive Checks" begin
    
    @testset "Successful Implementation" begin
        # This demonstrates covariance for fields (Vector <: AbstractArray)
        # and return types (Int <: Integer).
        @test @assertimpls ReadableCollection GoodCollection{String}, String, Int # equivalent to @assertimpls ReadableCollection (GoodCollection{String}, String, Int) or @assertimpls(ReadableCollection, (GoodCollection{String}, String, Int))
    end

    # Helper to robustly test compile-time errors from macros
    function get_compile_error(expr)
        @test_throws InterfaceImplementationError Core.eval(@__MODULE__, expr)
    end

    @testset "Failed Typed Field" begin
        # Fails because data::Vector{Float64} is not a subtype of AbstractArray{String, 1}
        get_compile_error(:(@assertimpls ReadableCollection BadTypedFieldCollection, String, Int))
    end

    @testset "Failed Untyped Field" begin
        # Fails because it's missing the `metadata` field
        get_compile_error(:(@assertimpls ReadableCollection BadUntypedFieldCollection{Any}, Any, Int))
    end

    @testset "Failed Return Type" begin
        # Fails because length returns Float64, not <: Integer
        get_compile_error(:(@assertimpls ReadableCollection BadReturnCollection{Any}, Any, Int))
    end
    
    @testset "Keyword Argument Support" begin
        # This should pass because GoodKwargsCollection has the `default` keyword
        @test @assertimpls KwargsInterface GoodKwargsCollection{String}, String, Int
        
        # This should fail because BadKwargsCollection is missing the keyword argument
        get_compile_error(:(@assertimpls KwargsInterface BadKwargsCollection{String}, String, Int))
    end
    
    @testset "Error Message Content" begin
        err = @test_throws InterfaceImplementationError Core.eval(@__MODULE__, :(@assertimpls ReadableCollection BadUntypedFieldCollection{Any}, Any, Int))
        
        @test err.value.interface_name == :ReadableCollection
        @test occursin("Field existence requirement failed", err.value.message)
        @test occursin("C.metadata", err.value.message)
    end

    @testset "Module-Level Visibility" begin
        # Test that types fulfill the interface in their own module
        @test @assertimpls ModuleA.MyInterface ModuleA.FulfillsA
        @test @assertimpls ModuleB.MyInterface ModuleB.FulfillsB

        # Test that types DO NOT fulfill the interface from the other module
        @test_throws InterfaceImplementationError @assertimpls ModuleA.MyInterface ModuleA.FulfillsB
        @test_throws InterfaceImplementationError @assertimpls ModuleB.MyInterface ModuleB.FulfillsA
    end
end


# 1. Define parent interfaces
@interface CanFoo X, Y begin
    function foo(::X, ::Y)::Bool end
end

@interface CanBar Z begin
    function bar(::Z)::String end
end

# 2. Define a composite interface
@interface CanFooBar I, J, K begin
    @impls CanFoo I, J
    @impls CanBar I
    function baz(::I, ::K)::Int end
end

# 3. Define a type that fully implements the composite interface
struct FullImpl
end
foo(::FullImpl, ::Int) = true
bar(::FullImpl) = "hello"
baz(::FullImpl, ::String) = 42

# 4. Define types with partial implementations for failure testing
struct NoBaz end
foo(::NoBaz, ::Any) = true
bar(::NoBaz) = "hello"

struct NoBar end
foo(::NoBar, ::Any) = true
baz(::NoBar, ::Any) = 0

@interface CanFooWithInt J begin
    @impls CanFoo J, Int
end

struct FooWithIntImpl end
foo(::FooWithIntImpl, ::Int) = true # Correctly implements foo(::MyType, ::Int)

struct BadFooWithIntImpl end
foo(::BadFooWithIntImpl, ::String) = false # Does not implement for Int

@testset "Interface Inheritance (@impls)" begin
    # This should pass, as FullImpl satisfies CanFoo (via FullImpl, Int),
    # CanBar (via FullImpl), and CanFooBar's own `baz` requirement.
    @test @assertimpls CanFooBar FullImpl, Int, String

    # This should fail because NoBaz is missing the `baz` method from CanFooBar.
    @test_throws InterfaceImplementationError @assertimpls CanFooBar NoBaz, Int, String

    # This should fail because NoBar is missing the `bar` method from the parent CanBar.
    @test_throws InterfaceImplementationError @assertimpls CanFooBar NoBar, Int, String

    @test @assertimpls CanFooWithInt FooWithIntImpl
    @test_throws InterfaceImplementationError @assertimpls CanFooWithInt BadFooWithIntImpl

end