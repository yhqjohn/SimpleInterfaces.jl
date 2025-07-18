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


# 3. Write tests
@testset "Final Comprehensive Checks" begin
    
    @testset "Successful Implementation" begin
        # This demonstrates covariance for fields (Vector <: AbstractArray)
        # and return types (Int <: Integer).
        @test @assertimpls GoodCollection{String} String Int ReadableCollection
    end

    # Helper to robustly test compile-time errors from macros
    function get_compile_error(expr)
        @test_throws InterfaceImplementationError Core.eval(@__MODULE__, expr)
    end

    @testset "Failed Typed Field" begin
        # Fails because data::Vector{Float64} is not a subtype of AbstractArray{String, 1}
        get_compile_error(:(@assertimpls BadTypedFieldCollection String Int ReadableCollection))
    end

    @testset "Failed Untyped Field" begin
        # Fails because it's missing the `metadata` field
        get_compile_error(:(@assertimpls BadUntypedFieldCollection{Any} Any Int ReadableCollection))
    end

    @testset "Failed Return Type" begin
        # Fails because length returns Float64, not <: Integer
        get_compile_error(:(@assertimpls BadReturnCollection{Any} Any Int ReadableCollection))
    end
    
    @testset "Error Message Content" begin
        err = @test_throws InterfaceImplementationError Core.eval(@__MODULE__, :(@assertimpls BadUntypedFieldCollection{Any} Any Int ReadableCollection))
        
        @test err.value.interface_name == :ReadableCollection
        @test occursin("Field existence requirement failed", err.value.message)
        @test occursin("C.metadata", err.value.message)
    end
end