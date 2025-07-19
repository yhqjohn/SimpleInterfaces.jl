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
        @test @assertimpls GoodCollection{String}, String, Int ReadableCollection # equivalent to @assertimpls (GoodCollection{String}, String, Int) ReadableCollection or @assertimpls((GoodCollection{String}, String, Int), ReadableCollection)
    end

    # Helper to robustly test compile-time errors from macros
    function get_compile_error(expr)
        @test_throws InterfaceImplementationError Core.eval(@__MODULE__, expr)
    end

    @testset "Failed Typed Field" begin
        # Fails because data::Vector{Float64} is not a subtype of AbstractArray{String, 1}
        get_compile_error(:(@assertimpls BadTypedFieldCollection, String, Int ReadableCollection))
    end

    @testset "Failed Untyped Field" begin
        # Fails because it's missing the `metadata` field
        get_compile_error(:(@assertimpls BadUntypedFieldCollection{Any}, Any, Int ReadableCollection))
    end

    @testset "Failed Return Type" begin
        # Fails because length returns Float64, not <: Integer
        get_compile_error(:(@assertimpls BadReturnCollection{Any}, Any, Int ReadableCollection))
    end
    
    @testset "Keyword Argument Support" begin
        # This should pass because GoodKwargsCollection has the `default` keyword
        @test @assertimpls GoodKwargsCollection{String}, String, Int KwargsInterface
        
        # This should fail because BadKwargsCollection is missing the keyword argument
        get_compile_error(:(@assertimpls BadKwargsCollection{String}, String, Int KwargsInterface))
    end
    
    @testset "Error Message Content" begin
        err = @test_throws InterfaceImplementationError Core.eval(@__MODULE__, :(@assertimpls BadUntypedFieldCollection{Any}, Any, Int ReadableCollection))
        
        @test err.value.interface_name == :ReadableCollection
        @test occursin("Field existence requirement failed", err.value.message)
        @test occursin("C.metadata", err.value.message)
    end

    @testset "Runtime Metaprogramming" begin
        @test isdefined(@__MODULE__, :SimpleInterface)
        @test isabstracttype(SimpleInterface)
        
        # Test that the abstract type for the interface was created
        @test isdefined(@__MODULE__, :ReadableCollection)
        @test ReadableCollection isa UnionAll
        @test supertype(ReadableCollection{GoodCollection{Int}, Int, Int}) == SimpleInterface

        # Test the runtime `impls` function
        @test SimpleInterfaces.impls(GoodCollection{String}, String, Int, ReadableCollection)
        @test !SimpleInterfaces.impls(BadReturnCollection{Any}, Any, Int, ReadableCollection)
    end

    @testset "Module-Level Visibility" begin
        # Test that types fulfill the interface in their own module
        @test @assertimpls ModuleA.FulfillsA ModuleA.MyInterface
        @test @assertimpls ModuleB.FulfillsB ModuleB.MyInterface

        # Test that types DO NOT fulfill the interface from the other module
        @test_throws InterfaceImplementationError @assertimpls ModuleA.FulfillsB ModuleA.MyInterface
        @test_throws InterfaceImplementationError @assertimpls ModuleB.FulfillsA ModuleB.MyInterface
    end
end