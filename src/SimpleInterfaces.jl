module SimpleInterfaces

export @interface, @impls, @assertimpls, InterfaceImplementationError

const INTERFACES = Dict{Symbol, Any}()

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

function _check_interface(__module__::Module, interface_name::Symbol, concrete_type_exprs::Vector)
    if !haskey(INTERFACES, interface_name)
        return "Interface `$interface_name` not found."
    end
    def = INTERFACES[interface_name]
    
    type_vars = def.type_vars
    if length(type_vars) != length(concrete_type_exprs)
        return "Incorrect number of types for interface `$interface_name`. Expected $(length(type_vars)), got $(length(concrete_type_exprs))."
    end

    type_map = Dict(zip(type_vars, concrete_type_exprs))
    substitute(e) = e
    substitute(e::Symbol) = get(type_map, e, e)
    function substitute(e::Expr)
        return Expr(e.head, [substitute(arg) for arg in e.args]...)
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
                
                arg_types_exprs = [arg.args[end] for arg in substituted_call.args[2:end]]
                arg_types = Tuple(Core.eval(__module__, t) for t in arg_types_exprs)

                if !hasmethod(func, arg_types)
                    return "Method not found: `$(sprint(print, req.expr))` for argument types `$arg_types`."
                end
                if req.return_type !== nothing
                    required_return_type = Core.eval(__module__, substitute(req.return_type))
                    actual_return_types = Base.return_types(func, arg_types)
                    if isempty(actual_return_types) || !all(rt -> rt <: required_return_type, actual_return_types)
                         return "Method `$(sprint(print, req.expr))` has wrong return type. Expected `<: $(required_return_type)`, got `$(actual_return_types)`."
                    end
                end
            end
        catch e
            return "An error occurred during check: $e"
        end
    end
    
    return nothing
end

# --- Macros ---

macro interface(name_expr, params_expr, body_expr)
    interface_name = name_expr
    type_vars, type_constraints = _parse_interface_params(params_expr)
    requirements = _parse_interface_body(body_expr)
    
    interface_obj = (
        name = interface_name,
        type_vars = type_vars,
        type_constraints = type_constraints,
        requirements = requirements
    )
    
    INTERFACES[interface_name] = interface_obj
    
    return esc(:(const $(interface_name) = $(QuoteNode(interface_name))))
end

macro impls(impl_args...)
    interface_name = impl_args[end]
    concrete_type_exprs = [impl_args[1:end-1]...]
    failure_message = _check_interface(__module__, Symbol(interface_name), concrete_type_exprs)
    return isnothing(failure_message)
end

macro assertimpls(impl_args...)
    interface_name = impl_args[end]
    concrete_type_exprs = [impl_args[1:end-1]...]
    failure_message = _check_interface(__module__, Symbol(interface_name), concrete_type_exprs)
    
    if isnothing(failure_message)
        return true
    else
        return :(throw(InterfaceImplementationError($(QuoteNode(Symbol(interface_name))), ($(esc.(concrete_type_exprs)...),), $failure_message)))
    end
end

end # module
