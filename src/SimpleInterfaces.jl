module SimpleInterfaces

export @interface, @impls, @assertimpls, InterfaceImplementationError, SimpleInterface, impls

abstract type SimpleInterface end

const INTERFACES = Dict{Symbol, Any}() # Keys will be gensym'd Symbols for uniqueness

# This function will be extended by the @interface macro to return the unique key for an interface type
function get_interface_key end

struct InterfaceImplementationError <: Exception
    interface_name::Symbol
    concrete_types::Any
    message::String
end

function Base.showerror(io::IO, err::InterfaceImplementationError)
    type_names = try join([string(t) for t in err.concrete_types], ", ") catch; string(err.concrete_types) end
    print(io, "InterfaceImplementationError: Failed to implement interface `$(err.interface_name)` for types `$(type_names)`.\nReason: $(err.message)")
end

# --- Internal Functions ---

function _parse_interface_params(params_expr)
    params = []
    if params_expr isa Expr && params_expr.head == :tuple
        append!(params, params_expr.args)
    else
        push!(params, params_expr)
    end

    type_vars, type_constraints = [], []
    for p in params
        if p isa Symbol
            push!(type_vars, p)
        elseif p isa Expr && p.head == :(<:)
            push!(type_vars, p.args[1])
            push!(type_constraints, p)
        else
            error("Invalid type parameter format: $p")
        end
    end
    return type_vars, type_constraints
end

function _parse_interface_body(body_expr)
    if !(body_expr isa Expr && body_expr.head == :block)
        error("Interface body must be a `begin...end` block.")
    end
    
    requirements = []
    for item in filter(x -> !(x isa LineNumberNode), body_expr.args)
        # Typed field: T.field::Type
        if item isa Expr && item.head == :(::) && item.args[1] isa Expr && item.args[1].head == :.
            push!(requirements, (type=:field_typed, expr=item))
        # Untyped field: T.field
        elseif item isa Expr && item.head == :.
            push!(requirements, (type=:field_untyped, expr=item))
        # Function
        elseif item isa Expr && item.head == :function
            signature = item.args[1]
            if signature isa Expr && signature.head == :(::)
                push!(requirements, (type=:method, expr=signature.args[1], return_type=signature.args[2]))
            else
                push!(requirements, (type=:method, expr=signature, return_type=nothing))
            end
        else
            error("Unsupported requirement syntax: $item")
        end
    end
    return requirements
end

function check_interface(__module__::Module, interface_key::Symbol, concrete_type_exprs::Vector)
    if !haskey(INTERFACES, interface_key)
        return "Interface with key `$interface_key` not found. This is an internal error."
    end
    def = INTERFACES[interface_key]
    
    type_vars = def.type_vars
    if length(type_vars) != length(concrete_type_exprs)
        return "Incorrect number of types for interface `$interface_name`. Expected $(length(type_vars)), got $(length(concrete_type_exprs))."
    end

    type_map = Dict(zip(type_vars, concrete_type_exprs))
    substitute(e) = e
    substitute(e::Symbol) = get(type_map, e, e)
    substitute(e::QuoteNode) = e # Do not change QuoteNodes
    function substitute(e::Expr)
        # Don't recurse into QuoteNodes
        return Expr(e.head, [arg isa QuoteNode ? arg : substitute(arg) for arg in e.args]...)
    end

    for constraint in def.type_constraints
        is_subtype = Core.eval(__module__, substitute(constraint))
        if !is_subtype
            return "Subtype constraint failed: `$(sprint(print, constraint))` -> `$(sprint(print, substitute(constraint)))` is false."
        end
    end

    for req in def.requirements
        try
            if req.type == :field_typed
                concrete_type = Core.eval(__module__, substitute(req.expr.args[1].args[1]))
                field_name = req.expr.args[1].args[2].value
                field_type = Core.eval(__module__, substitute(req.expr.args[2]))
                if !(hasfield(concrete_type, field_name) && fieldtype(concrete_type, field_name) <: field_type)
                    return "Field requirement failed for `$(concrete_type)`: `$(sprint(print, req.expr))`"
                end
            elseif req.type == :field_untyped
                concrete_type = Core.eval(__module__, substitute(req.expr.args[1]))
                field_name = req.expr.args[2].value
                if !hasfield(concrete_type, field_name)
                    return "Field existence requirement failed for `$(concrete_type)`: `$(sprint(print, req.expr))`"
                end
            elseif req.type == :method
                substituted_call = substitute(req.expr)
                func = Core.eval(__module__, substituted_call.args[1])
                positional_args = filter(arg -> !(arg isa Expr && arg.head == :parameters), substituted_call.args[2:end])
                positional_arg_types_exprs = [
                    if arg isa Expr && arg.head == :(::)
                        arg.args[end]
                    else
                        :Any
                    end
                    for arg in positional_args
                ]
                keyword_index = findfirst(arg -> arg isa Expr && arg.head == :parameters, substituted_call.args)
                if keyword_index !== nothing
                    keyword_params = substituted_call.args[keyword_index].args
                    keyword_names = [
                        if e isa Expr || a.head == :(::)
                            e.args[1]
                        elseif e isa Symbol
                            e
                        end
                        for e in keyword_params
                    ]
                    keyword_names = tuple(keyword_names...)
                else
                    keyword_names = ()
                end
                arg_types = Tuple(Core.eval(__module__, t) for t in positional_arg_types_exprs)

                if !hasmethod(func, arg_types, keyword_names)
                    return "Method not found: `$(sprint(print, substituted_call))` for argument types `$arg_types`."
                end

                if req.return_type !== nothing
                    required_return_type = Core.eval(__module__, substitute(req.return_type))
                    actual_return_types = Base.return_types(func, arg_types)
                    if isempty(actual_return_types) || !all(rt -> rt <: required_return_type, actual_return_types)
                         return "Method `$(sprint(print, substituted_call))` has wrong return type. Expected `<: $(required_return_type)`, got `$(actual_return_types)`."
                    end
                end
            end
        catch e
            return "An error occurred during check: $e"
        end
    end
    
    return nothing
end

"""
    impls(concrete_types..., interface_name::Symbol) -> Bool

Runtime function to check if a set of concrete types implements a given interface.
This is the runtime equivalent of the `@impls` macro.
"""
function impls(concrete_types_and_interface...)
    if length(concrete_types_and_interface) < 2
        error("impls function requires at least one concrete type and an interface name")
    end
    interface = concrete_types_and_interface[end]
    interface_key = get_interface_key(interface)
    concrete_types = concrete_types_and_interface[1:end-1]
    
    # The check is performed in the module where the interface was defined
    interface_module = INTERFACES[interface_key].__module__
    failure_message = check_interface(interface_module, interface_key, Any[concrete_types...])
    return isnothing(failure_message)
end


# --- Macros ---

macro interface(name_expr, params_expr, body_expr)
    interface_name = name_expr
    type_vars, type_constraints = _parse_interface_params(params_expr)
    requirements = _parse_interface_body(body_expr)
    
    unique_key = gensym(interface_name)

    interface_obj = (
        name = interface_name,
        __module__ = __module__, # Store the defining module
        type_vars = type_vars,
        type_constraints = type_constraints,
        requirements = requirements
    )
    
    INTERFACES[unique_key] = interface_obj

    # 1. Define the abstract type for the interface
    abstract_type_def = if !isempty(type_vars)
        :(abstract type $(esc(interface_name)){$(esc.(type_vars)...)} <: SimpleInterface end)
    else
        :(abstract type $(esc(interface_name)) <: SimpleInterface end)
    end
    
    # 2. Define a method to get the unique key from the type
    get_key_def = :(SimpleInterfaces.get_interface_key(::Type{<:$(esc(interface_name))}) = $(QuoteNode(unique_key)))

    return quote
        export $(esc(interface_name))
        $(abstract_type_def)
        $(get_key_def)
    end
end

macro impls(impl_args...)
    # This check happens at COMPILE TIME.
    interface_expr = impl_args[end]
    concrete_type_exprs = impl_args[1:end-1]
    
    try
        interface_type = Core.eval(__module__, interface_expr)
        interface_key = get_interface_key(interface_type)
        interface_def_module = INTERFACES[interface_key].__module__
        concrete_types = [Core.eval(__module__, expr) for expr in concrete_type_exprs]
        
        failure_message = check_interface(interface_def_module, interface_key, concrete_types)
        return isnothing(failure_message)
    catch e
        # For user errors (like UndefVarError), rethrow them after a warning.
        @warn "SimpleInterfaces.jl: A compile-time check in `@impls` failed. This is likely due to a user error (e.g., a typo or undefined type). See the original error below."
        rethrow(e)
    end
end

macro assertimpls(impl_args...)
    # This check happens at COMPILE TIME.
    interface_expr = impl_args[end]
    concrete_type_exprs = impl_args[1:end-1]

    try
        interface_type = Core.eval(__module__, interface_expr)
        interface_key = get_interface_key(interface_type)
        interface_def_module = INTERFACES[interface_key].__module__
        interface_name_for_error = INTERFACES[interface_key].name
        concrete_types = [Core.eval(__module__, expr) for expr in concrete_type_exprs]

        failure_message = check_interface(interface_def_module, interface_key, concrete_types)
        
        if isnothing(failure_message)
            return true # Success, inject `true`
        else
            # Failure, inject a `throw` expression
            return :(throw(InterfaceImplementationError($(QuoteNode(interface_name_for_error)), ($(esc.(concrete_type_exprs)...),), $failure_message)))
        end
    catch e
        # For user errors (like UndefVarError), rethrow them after a warning.
        @warn "SimpleInterfaces.jl: A compile-time check in `@assertimpls` failed. This is likely due to a user error (e.g., a typo or undefined type). See the original error below."
        rethrow(e)
    end
end

end # module